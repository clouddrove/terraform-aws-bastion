#!/usr/bin/env bash
# tunnel.sh — JSON-driven SSM port-forwarding + HAProxy SNI router.
#
# Part of the CloudDrove terraform-aws-bastion module.
#   https://github.com/clouddrove/terraform-aws-bastion
#   https://clouddrove.com
#
# PREREQUISITE (SSO only): run ./bootstrap.sh once to create the AWS profiles
# referenced from each environment in tunnel.json. If you use plain IAM
# profiles, skip bootstrap and just reference existing profile names.
#
# Each environment in the config:
#   - declares which resources it wants (eks, internal_alb, aurora, rds_proxy, redis)
#   - is processed only if a bastion EC2 instance can be discovered for it
#   - tolerates any individual resource being absent (skipped with a [WARN])
#
# Ports auto-allocate from base_port; HTTPS-bearing resources route through
# HAProxy so the real hostname resolves locally and TLS validation still passes:
#   * :443   -> EKS apiserver, internal ALB hostnames (SNI dispatch)
#   * :5432  -> Aurora, RDS Proxy (SNI dispatch)
#   * Redis  -> direct local-port tunnel (no HAProxy)
#
# Usage:
#   ./tunnel.sh [--config tunnel.json] [--env dev [--env prod ...]]

set -euo pipefail

CONFIG_FILE="$(dirname "$0")/tunnel.json"
SELECTED_ENVS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)   CONFIG_FILE="$2"; shift 2 ;;
    --env)      SELECTED_ENVS+=("$2"); shift 2 ;;
    --help|-h)
      sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "[ERROR] Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

#############################################################################
# Banner
#############################################################################
print_banner() {
  cat <<'EOF'

   ____ _                 _ ____
  / ___| | ___  _   _  __| |  _ \ _ __ _____   _____
 | |   | |/ _ \| | | |/ _` | | | | '__/ _ \ \ / / _ \
 | |___| | (_) | |_| | (_| | |_| | | | (_) \ V /  __/
  \____|_|\___/ \__,_|\__,_|____/|_|  \___/ \_/ \___|

  SSM Jump Host Tunnel  ::  terraform-aws-bastion
  https://clouddrove.com

EOF
}
print_banner

for cmd in aws jq haproxy curl session-manager-plugin; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "[FATAL] Missing: $cmd" >&2; exit 1; }
done
[[ -f "$CONFIG_FILE" ]] || { echo "[FATAL] Config not found: $CONFIG_FILE" >&2; exit 1; }

#############################################################################
# State (cleaned up on exit)
#############################################################################
TMPDIR=$(mktemp -d)
HAPROXY_CFG="$TMPDIR/haproxy.cfg"
KUBECONFIG_FILE="$HOME/.kube/config-tunnel"

FRONTEND_443=()
FRONTEND_5432=()
BACKEND_ENTRIES=()
HOSTS_TO_ADD=()
TUNNEL_PIDS=()
KEEPALIVE_PIDS=()
TMPDIRS=()
NEXT_PORT_FILE="$TMPDIR/next_port"

CLEANUP_DONE=0
cleanup() {
  (( CLEANUP_DONE )) && return
  CLEANUP_DONE=1
  # Ignore further Ctrl+C / signals during cleanup so the user doesn't abort
  # halfway and leave HAProxy bound to :443 / :5432.
  trap '' INT TERM HUP QUIT
  set +m 2>/dev/null || true
  echo ""
  echo "[INFO] Shutting down tunnels and HAProxy..."

  # Sudo keep-alive
  [[ -n "${SUDO_KEEPALIVE_PID:-}" ]] && kill -TERM "$SUDO_KEEPALIVE_PID" 2>/dev/null || true

  # Keep-alive curl loops
  for pid in "${KEEPALIVE_PIDS[@]:-}"; do kill -TERM "$pid" 2>/dev/null || true; done

  # SSM tunnel subshells (these own session-manager-plugin children).
  for pid in "${TUNNEL_PIDS[@]:-}"; do kill -TERM "$pid" 2>/dev/null || true; done
  # Stragglers: session-manager-plugin children sometimes outlive their parent.
  pkill -TERM -f session-manager-plugin 2>/dev/null || true

  # HAProxy is a daemon forked off our sudo invocation, so target it by the
  # exact config path, which is unique to this run.
  if [[ -n "${HAPROXY_CFG:-}" && -f "$HAPROXY_CFG" ]]; then
    sudo -n pkill -TERM -f -- "haproxy -f $HAPROXY_CFG" 2>/dev/null || true
    sleep 0.5
    sudo -n pkill -KILL -f -- "haproxy -f $HAPROXY_CFG" 2>/dev/null || true
  fi

  for d in "${TMPDIRS[@]:-}"; do rm -rf "$d" 2>/dev/null || true; done
  rm -rf "$TMPDIR" 2>/dev/null || true
  stty sane 2>/dev/null || true
  echo "[SUCCESS] Cleanup complete."
}
trap cleanup EXIT INT TERM HUP QUIT

#############################################################################
# Defaults
#############################################################################
BASTION_TEMPLATE=$(jq -r '.defaults.bastion_name_template // "myproject-{env}-ssm-bastion"' "$CONFIG_FILE")
SSO_SESSION_NAME=$(jq -r '.defaults.sso_session_name // empty' "$CONFIG_FILE")

#############################################################################
# Verify credentials for the first env's profile
#############################################################################
FIRST_ENV=$(jq -r '.environments | keys[0]' "$CONFIG_FILE")
FIRST_PROFILE=$(jq -r --arg e "$FIRST_ENV" '.environments[$e].profile // empty' "$CONFIG_FILE")
[[ -n "$FIRST_PROFILE" ]] || { echo "[FATAL] First env '$FIRST_ENV' has no .profile" >&2; exit 1; }

echo "[INFO] Verifying credentials for profile $FIRST_PROFILE..."
STS_OUTPUT=$(aws sts get-caller-identity --profile "$FIRST_PROFILE" --output text 2>&1) || STS_RC=$?
if [[ ${STS_RC:-0} -ne 0 ]]; then
  echo "" >&2
  echo "[FATAL] AWS credentials check failed." >&2
  echo "        AWS CLI said: $STS_OUTPUT" >&2
  echo "" >&2
  if echo "$STS_OUTPUT" | grep -qi "could not be found\|profile.*not found\|did not find profile"; then
    echo "  Profile '$FIRST_PROFILE' is missing from ~/.aws/config." >&2
    echo "  Run the bootstrap script (SSO), or add the profile manually (IAM):" >&2
    echo "    ./bootstrap.sh" >&2
  else
    echo "  Refresh your SSO session:" >&2
    echo "    aws sso login --sso-session ${SSO_SESSION_NAME:-<your-sso-session>}" >&2
  fi
  echo "" >&2
  exit 1
fi
echo "[INFO] Credentials OK"

#############################################################################
# Port allocator
#############################################################################
allocate_port() {
  local p
  p=$(<"$NEXT_PORT_FILE")
  echo $((p + 1)) > "$NEXT_PORT_FILE"
  echo "$p"
}

#############################################################################
# AWS discovery
#############################################################################
discover_bastion() {
  local env="$1" region="$2" profile="$3" template="$4"
  local name="${template//\{env\}/$env}"
  aws ec2 describe-instances \
    --region "$region" --profile "$profile" \
    --filters "Name=tag:Name,Values=$name" \
              "Name=instance-state-name,Values=running" \
    --query "Reservations[0].Instances[0].InstanceId" \
    --output text 2>/dev/null
}

discover_eks_cluster() {
  local env="$1" region="$2" profile="$3"
  aws eks list-clusters \
    --region "$region" --profile "$profile" \
    --query "clusters[?contains(@, '${env}')] | [0]" \
    --output text 2>/dev/null
}

discover_eks_endpoint() {
  local cluster="$1" region="$2" profile="$3"
  aws eks describe-cluster \
    --region "$region" --profile "$profile" \
    --name "$cluster" \
    --query "cluster.endpoint" \
    --output text 2>/dev/null | sed 's|https://||;s|/||g'
}

discover_internal_alb() {
  local env="$1" region="$2" profile="$3" tag_filters_json="$4"
  local albs
  albs=$(aws elbv2 describe-load-balancers \
           --region "$region" --profile "$profile" \
           --query "LoadBalancers[?Type=='application'].LoadBalancerArn" \
           --output text 2>/dev/null | tr '\t' '\n')
  [[ -z "$albs" ]] && return
  local alb tags_json expanded_filters match
  while IFS= read -r alb; do
    [[ -z "$alb" ]] && continue
    tags_json=$(aws elbv2 describe-tags --resource-arns "$alb" \
                  --region "$region" --profile "$profile" 2>/dev/null \
                | jq -c '.TagDescriptions[0].Tags | from_entries' 2>/dev/null || echo "{}")
    expanded_filters=$(echo "$tag_filters_json" | sed "s#{env}#${env}#g")
    match=$(jq -n --argjson tags "$tags_json" --argjson filters "$expanded_filters" '
      $filters | any(. as $f | ($f | to_entries | all(.value as $v | $tags[.key] == $v)))
    ' 2>/dev/null)
    if [[ "$match" == "true" ]]; then
      echo "$alb"
      return
    fi
  done <<< "$albs"
}

discover_alb_dns() {
  local alb="$1" region="$2" profile="$3"
  aws elbv2 describe-load-balancers \
    --region "$region" --profile "$profile" \
    --load-balancer-arns "$alb" \
    --query "LoadBalancers[0].DNSName" --output text 2>/dev/null
}

discover_alb_listener_hosts() {
  local alb="$1" region="$2" profile="$3"
  local listeners
  listeners=$(aws elbv2 describe-listeners \
                --region "$region" --profile "$profile" \
                --load-balancer-arn "$alb" \
                --query "Listeners[].ListenerArn" \
                --output text 2>/dev/null | tr '\t' '\n')
  local l
  while IFS= read -r l; do
    [[ -z "$l" ]] && continue
    aws elbv2 describe-rules \
      --region "$region" --profile "$profile" \
      --listener-arn "$l" \
      --query "Rules[].Conditions[?Field=='host-header'].Values[]" \
      --output text 2>/dev/null | tr '\t' '\n'
  done <<< "$listeners" | sort -u | grep -v '^$' || true
}

discover_aurora_endpoint() {
  local env="$1" region="$2" profile="$3" kind="$4"
  local field
  case "$kind" in
    writer) field="Endpoint" ;;
    reader) field="ReaderEndpoint" ;;
    *)      field="Endpoint" ;;
  esac
  aws rds describe-db-clusters \
    --region "$region" --profile "$profile" \
    --query "DBClusters[?contains(DBClusterIdentifier, '${env}')] | [0].${field}" \
    --output text 2>/dev/null
}

discover_rds_proxy_endpoint() {
  local env="$1" region="$2" profile="$3"
  aws rds describe-db-proxies \
    --region "$region" --profile "$profile" \
    --query "DBProxies[?contains(DBProxyName, '${env}')] | [0].Endpoint" \
    --output text 2>/dev/null
}

discover_redis_endpoint() {
  local env="$1" region="$2" profile="$3"
  aws elasticache describe-serverless-caches \
    --region "$region" --profile "$profile" \
    --query "ServerlessCaches[?contains(ServerlessCacheName, '${env}')] | [0].Endpoint.Address" \
    --output text 2>/dev/null
}

#############################################################################
# Tunnel + HAProxy plumbing
#############################################################################
keep_alive() {
  local port="$1"
  while true; do
    curl -sk --max-time 5 "https://localhost:$port" > /dev/null 2>&1 || true
    sleep 30
  done
}

start_tunnel() {
  local env="$1" region="$2" profile="$3" host="$4" port="$5" target_port="$6" label="$7" instance_id="$8"

  if [[ -z "$host" || -z "$port" || "$host" == "None" ]]; then
    printf "| %-19s | %-18s | %s\n" "$label" "(missing)" "[WARN] no host discovered, skipping"
    return 1
  fi

  printf "| %-19s | %-18s | %s:%s\n" "$label" "localhost:$port" "$host" "$target_port"

  local tmpdir="/tmp/ssm-${env}-${port}"
  mkdir -p "$tmpdir"
  TMPDIRS+=("$tmpdir")

  (
    TMPDIR="$tmpdir"
    aws ssm start-session \
      --no-paginate \
      --region "$region" --profile "$profile" \
      --target "$instance_id" \
      --document-name AWS-StartPortForwardingSessionToRemoteHost \
      --parameters "{\"portNumber\":[\"$target_port\"],\"localPortNumber\":[\"$port\"],\"host\":[\"$host\"]}" \
      > /dev/null 2>&1
  ) &
  TUNNEL_PIDS+=($!)
  ( keep_alive "$port" ) &
  KEEPALIVE_PIDS+=($!)
  return 0
}

append_backend_block() {
  local port="$1"
  BACKEND_ENTRIES+=("backend backend_${port}
    server s1 127.0.0.1:${port}")
}

generate_haproxy_config() {
  {
    echo "global"
    echo "    daemon"
    echo "    maxconn 256"
    echo ""
    echo "defaults"
    echo "    mode tcp"
    echo "    timeout connect 10s"
    echo "    timeout client  1m"
    echo "    timeout server  1m"
    echo ""
    if (( ${#FRONTEND_443[@]} > 0 )); then
      echo "frontend https_in"
      echo "    bind *:443"
      echo "    tcp-request inspect-delay 5s"
      echo "    tcp-request content accept if { req.ssl_hello_type 1 }"
      for entry in "${FRONTEND_443[@]}"; do echo "    use_backend $entry"; done
      echo ""
    fi
    if (( ${#FRONTEND_5432[@]} > 0 )); then
      echo "frontend pgsql_in"
      echo "    bind *:5432"
      echo "    tcp-request inspect-delay 5s"
      echo "    tcp-request content accept if { req.ssl_hello_type 1 }"
      for entry in "${FRONTEND_5432[@]}"; do echo "    use_backend $entry"; done
      echo ""
    fi
    for backend in "${BACKEND_ENTRIES[@]}"; do echo "$backend"; echo ""; done
  } > "$HAPROXY_CFG"
}

#############################################################################
# sudo keep-alive (needed to bind :443 / :5432 and edit /etc/hosts)
#############################################################################
sudo -v || { echo "[ERROR] sudo auth failed" >&2; exit 1; }
( while true; do sleep 60; sudo -n true 2>/dev/null || true; done ) 2>/dev/null &
SUDO_KEEPALIVE_PID=$!
disown "$SUDO_KEEPALIVE_PID" 2>/dev/null || true

#############################################################################
# Iterate envs
#############################################################################
ALL_ENVS=$(jq -r '.environments | keys[]' "$CONFIG_FILE")
if (( ${#SELECTED_ENVS[@]} == 0 )); then
  ENVS_TO_PROCESS=($ALL_ENVS)
else
  ENVS_TO_PROCESS=("${SELECTED_ENVS[@]}")
fi

echo ""
echo "================================================================================================================================"
printf "| %-19s | %-18s | %s\n" "RESOURCE" "LOCAL ENDPOINT" "REMOTE HOST"
echo "================================================================================================================================"

for ENV in "${ENVS_TO_PROCESS[@]}"; do
  if ! jq -e --arg e "$ENV" '.environments[$e]' "$CONFIG_FILE" >/dev/null 2>&1; then
    echo "| [WARN] env '$ENV' not present in config, skipping"
    continue
  fi

  REGION=$(jq -r --arg e "$ENV" '.environments[$e].region' "$CONFIG_FILE")
  BASE_PORT=$(jq -r --arg e "$ENV" '.environments[$e].base_port' "$CONFIG_FILE")
  PROFILE=$(jq -r --arg e "$ENV" '.environments[$e].profile // empty' "$CONFIG_FILE")

  if [[ -z "$PROFILE" ]]; then
    echo "| [WARN] env '$ENV' has no .profile in config, skipping"
    continue
  fi

  echo "$BASE_PORT" > "$NEXT_PORT_FILE"

  echo "|------------------------------------------------------------------------------------------------------------------------------"
  echo "| ENVIRONMENT: $ENV  (Region: $REGION, Profile: $PROFILE, BasePort: $BASE_PORT)"
  echo "|------------------------------------------------------------------------------------------------------------------------------"

  INSTANCE_ID=$(discover_bastion "$ENV" "$REGION" "$PROFILE" "$BASTION_TEMPLATE") || true
  if [[ -z "$INSTANCE_ID" || "$INSTANCE_ID" == "None" ]]; then
    echo "| [WARN] bastion '${BASTION_TEMPLATE//\{env\}/$ENV}' not found; skipping entire env"
    continue
  fi
  printf "| %-19s | %-18s | %s\n" "bastion" "" "$INSTANCE_ID"

  # ---- EKS ----
  if [[ "$(jq -r --arg e "$ENV" '.environments[$e].resources.eks.enabled // false' "$CONFIG_FILE")" == "true" ]]; then
    CLUSTER=$(discover_eks_cluster "$ENV" "$REGION" "$PROFILE")
    if [[ -n "$CLUSTER" && "$CLUSTER" != "None" ]]; then
      EKS_HOST=$(discover_eks_endpoint "$CLUSTER" "$REGION" "$PROFILE")
      PORT=$(allocate_port)
      if start_tunnel "$ENV" "$REGION" "$PROFILE" "$EKS_HOST" "$PORT" "443" "EKS apiserver" "$INSTANCE_ID"; then
        FRONTEND_443+=("backend_${PORT} if { req.ssl_sni -i ${EKS_HOST} }")
        append_backend_block "$PORT"
        HOSTS_TO_ADD+=("$EKS_HOST")
        aws eks update-kubeconfig --region "$REGION" --profile "$PROFILE" \
          --name "$CLUSTER" --kubeconfig "$KUBECONFIG_FILE" --alias "$ENV" >/dev/null 2>&1 || true
      fi
    else
      printf "| %-19s | %-18s | %s\n" "EKS apiserver" "(missing)" "[WARN] no EKS cluster found"
    fi
  fi

  # ---- Internal ALB ----
  if [[ "$(jq -r --arg e "$ENV" '.environments[$e].resources.internal_alb.enabled // false' "$CONFIG_FILE")" == "true" ]]; then
    TAG_FILTERS=$(jq -c --arg e "$ENV" '.environments[$e].resources.internal_alb.tag_filters // []' "$CONFIG_FILE")
    ALB_ARN=$(discover_internal_alb "$ENV" "$REGION" "$PROFILE" "$TAG_FILTERS")
    if [[ -n "$ALB_ARN" ]]; then
      ALB_DNS=$(discover_alb_dns "$ALB_ARN" "$REGION" "$PROFILE")
      PORT=$(allocate_port)
      if start_tunnel "$ENV" "$REGION" "$PROFILE" "$ALB_DNS" "$PORT" "443" "Internal ALB" "$INSTANCE_ID"; then
        append_backend_block "$PORT"
        SNI_HOSTS=$(jq -r --arg e "$ENV" '.environments[$e].resources.internal_alb.sni_hosts // [] | .[]' "$CONFIG_FILE")
        if [[ -z "$SNI_HOSTS" ]]; then
          SNI_HOSTS=$(discover_alb_listener_hosts "$ALB_ARN" "$REGION" "$PROFILE")
        fi
        if [[ -z "$SNI_HOSTS" ]]; then
          printf "| %-19s | %-18s | %s\n" "  ALB SNI hosts" "" "[WARN] no host-header rules found and no sni_hosts configured"
        else
          while IFS= read -r host; do
            [[ -z "$host" ]] && continue
            FRONTEND_443+=("backend_${PORT} if { req.ssl_sni -i ${host} }")
            HOSTS_TO_ADD+=("$host")
            printf "| %-19s | %-18s | %s\n" "  ALB SNI" "" "$host"
          done <<< "$SNI_HOSTS"
        fi
      fi
    else
      printf "| %-19s | %-18s | %s\n" "Internal ALB" "(missing)" "[WARN] no matching ALB found"
    fi
  fi

  # ---- Aurora ----
  if [[ "$(jq -r --arg e "$ENV" '.environments[$e].resources.aurora.enabled // false' "$CONFIG_FILE")" == "true" ]]; then
    KIND=$(jq -r --arg e "$ENV" '.environments[$e].resources.aurora.endpoint_type // "writer"' "$CONFIG_FILE")
    AUR_HOST=$(discover_aurora_endpoint "$ENV" "$REGION" "$PROFILE" "$KIND")
    if [[ -n "$AUR_HOST" && "$AUR_HOST" != "None" ]]; then
      PORT=$(allocate_port)
      if start_tunnel "$ENV" "$REGION" "$PROFILE" "$AUR_HOST" "$PORT" "5432" "Aurora ($KIND)" "$INSTANCE_ID"; then
        FRONTEND_5432+=("backend_${PORT} if { req.ssl_sni -i ${AUR_HOST} }")
        append_backend_block "$PORT"
        HOSTS_TO_ADD+=("$AUR_HOST")
      fi
    else
      printf "| %-19s | %-18s | %s\n" "Aurora" "(missing)" "[WARN] no Aurora cluster found"
    fi
  fi

  # ---- RDS Proxy ----
  if [[ "$(jq -r --arg e "$ENV" '.environments[$e].resources.rds_proxy.enabled // false' "$CONFIG_FILE")" == "true" ]]; then
    PROXY_HOST=$(discover_rds_proxy_endpoint "$ENV" "$REGION" "$PROFILE")
    if [[ -n "$PROXY_HOST" && "$PROXY_HOST" != "None" ]]; then
      PORT=$(allocate_port)
      if start_tunnel "$ENV" "$REGION" "$PROFILE" "$PROXY_HOST" "$PORT" "5432" "RDS Proxy" "$INSTANCE_ID"; then
        FRONTEND_5432+=("backend_${PORT} if { req.ssl_sni -i ${PROXY_HOST} }")
        append_backend_block "$PORT"
        HOSTS_TO_ADD+=("$PROXY_HOST")
      fi
    else
      printf "| %-19s | %-18s | %s\n" "RDS Proxy" "(missing)" "[WARN] no RDS proxy found"
    fi
  fi

  # ---- Redis / Valkey — direct local port, no HAProxy ----
  if [[ "$(jq -r --arg e "$ENV" '.environments[$e].resources.redis.enabled // false' "$CONFIG_FILE")" == "true" ]]; then
    REDIS_HOST=$(discover_redis_endpoint "$ENV" "$REGION" "$PROFILE")
    if [[ -n "$REDIS_HOST" && "$REDIS_HOST" != "None" ]]; then
      PORT=$(allocate_port)
      start_tunnel "$ENV" "$REGION" "$PROFILE" "$REDIS_HOST" "$PORT" "6379" "Redis/Valkey" "$INSTANCE_ID" || true
      HOSTS_TO_ADD+=("$REDIS_HOST")
    else
      printf "| %-19s | %-18s | %s\n" "Redis/Valkey" "(missing)" "[WARN] no ElastiCache serverless cache found"
    fi
  fi

done

echo "================================================================================================================================"

#############################################################################
# HAProxy
#############################################################################
if (( ${#BACKEND_ENTRIES[@]} > 0 )); then
  echo ""
  generate_haproxy_config
  echo "[INFO] Launching HAProxy..."
  sudo haproxy -f "$HAPROXY_CFG" >/dev/null 2>&1 &
  sleep 2
else
  echo "[INFO] No HAProxy-routed backends configured; skipping HAProxy launch."
fi

#############################################################################
# /etc/hosts — point discovered hostnames at localhost so TLS SNI/cert works
#############################################################################
if (( ${#HOSTS_TO_ADD[@]} > 0 )); then
  echo "[INFO] Syncing /etc/hosts entries..."
  for endpoint in "${HOSTS_TO_ADD[@]}"; do
    host_only=$(echo "$endpoint" | cut -d: -f1)
    if ! grep -qE "^\s*127\.0\.0\.1\s+${host_only}(\s|\$)" /etc/hosts; then
      echo "127.0.0.1 $host_only" | sudo tee -a /etc/hosts >/dev/null
    fi
  done
fi

echo ""
echo "[SUCCESS] Tunnels are LIVE. Ctrl+C to terminate."
echo "================================================================================================================================"
echo "Examples:"
echo "  kubectl --kubeconfig ~/.kube/config-tunnel --context <env> get nodes"
echo "  psql 'host=<aurora-host> port=5432 sslmode=require dbname=<db> user=<user>'"
echo "  redis-cli -h localhost -p <local-port> --tls"
echo "================================================================================================================================"
echo "Built with ❤️  by CloudDrove  ::  https://clouddrove.com  ::  hello@clouddrove.com"
echo ""

while true; do sleep 1; done
