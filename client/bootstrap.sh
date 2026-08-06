#!/usr/bin/env bash
# bootstrap.sh — idempotent provisioner for ~/.aws/config (AWS SSO profiles).
#
# Part of the CloudDrove terraform-aws-bastion module.
#   https://github.com/clouddrove/terraform-aws-bastion
#   https://clouddrove.com
#
# Reads tunnel.json and manages:
#   - One [sso-session <name>] block (from .defaults.sso_session_name)
#   - One [profile <name>] block per (account, role) pair, where:
#       <name> = .profiles.profile_name_template with {account} and {role_short}
#                substituted from .profiles.accounts and .profiles.roles.
#
# Idempotency: every managed section carries a sentinel comment line:
#   # jump-host-bootstrap: managed
# Re-runs delete sections carrying this sentinel (and any name collisions with
# sections we are about to write), then re-create them from the current JSON.
# Anything else in ~/.aws/config is left untouched.
#
# NOTE: Skip this script entirely if you use plain IAM named profiles instead of
# AWS IAM Identity Center (SSO). Just ensure each env's "profile" in tunnel.json
# already exists in ~/.aws/config.
#
# Usage:
#   ./bootstrap.sh [--config tunnel.json] [--dry-run]

set -euo pipefail

CONFIG_FILE="$(dirname "$0")/tunnel.json"
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)  CONFIG_FILE="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --help|-h)
      sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) echo "[ERROR] Unknown arg: $1" >&2; exit 1 ;;
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

  AWS SSO Profile Bootstrap  ::  terraform-aws-bastion
  https://clouddrove.com

EOF
}
print_banner

[[ -f "$CONFIG_FILE" ]] || { echo "[FATAL] Config not found: $CONFIG_FILE" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "[FATAL] jq not installed" >&2; exit 1; }

AWS_CONFIG="${AWS_CONFIG_FILE:-$HOME/.aws/config}"
mkdir -p "$(dirname "$AWS_CONFIG")"
touch "$AWS_CONFIG"

SENTINEL="# jump-host-bootstrap: managed"

#############################################################################
# Read .defaults
#############################################################################
SSO_SESSION_NAME=$(jq -r '.defaults.sso_session_name // empty' "$CONFIG_FILE")
SSO_START_URL=$(jq -r '.defaults.sso_start_url // empty' "$CONFIG_FILE")
SSO_REGION=$(jq -r '.defaults.sso_region // empty' "$CONFIG_FILE")
SSO_SCOPES=$(jq -r '.defaults.sso_registration_scopes // "sso:account:access"' "$CONFIG_FILE")

for v in SSO_SESSION_NAME SSO_START_URL SSO_REGION; do
  [[ -n "${!v}" ]] || { echo "[FATAL] .defaults.${v,,} missing in $CONFIG_FILE" >&2; exit 1; }
done

#############################################################################
# Read .profiles
#############################################################################
PROFILE_NAME_TPL=$(jq -r '.profiles.profile_name_template // empty' "$CONFIG_FILE")
[[ -n "$PROFILE_NAME_TPL" ]] || { echo "[FATAL] .profiles.profile_name_template missing" >&2; exit 1; }

# accounts: map -> tab-separated "name<TAB>id<TAB>default_region"
ACCOUNTS_TSV=$(jq -r '
  .profiles.accounts as $accts
  | (.profiles.default_region_per_account // {}) as $regions
  | $accts | to_entries[]
  | [.key, .value, ($regions[.key] // "")] | @tsv
' "$CONFIG_FILE")

# roles: list of {name, short} -> tab-separated "name<TAB>short"
ROLES_TSV=$(jq -r '.profiles.roles[] | [.name, .short] | @tsv' "$CONFIG_FILE")

#############################################################################
# Backup once per day
#############################################################################
if (( ! DRY_RUN )); then
  BACKUP="$AWS_CONFIG.bak.$(date +%Y%m%d)"
  if [[ ! -f "$BACKUP" ]]; then
    cp "$AWS_CONFIG" "$BACKUP"
    echo "[INFO] Backed up $AWS_CONFIG -> $BACKUP"
  fi
fi

#############################################################################
# Strip every managed section from the config.
#
# A "managed" section is one that EITHER:
#   - has the sentinel as the first non-blank line under its header, OR
#   - has a header in the list of names we're about to overwrite.
#############################################################################
strip_managed_sections() {
  local input="$1" output="$2"
  local names_to_remove="$3"  # newline-separated list of "[section name]" headers
  python3 - "$input" "$output" "$SENTINEL" "$names_to_remove" <<'PY'
import sys, re
inp, outp, sentinel, names_blob = sys.argv[1:5]
collision_names = {n.strip() for n in names_blob.splitlines() if n.strip()}

with open(inp) as f:
    lines = f.readlines()

result = []
i = 0
while i < len(lines):
    line = lines[i]
    if line.startswith("["):
        section = [line]
        i += 1
        while i < len(lines) and not lines[i].startswith("["):
            section.append(lines[i])
            i += 1
        managed = False
        for s in section[1:]:
            t = s.strip()
            if not t:
                continue
            if t == sentinel:
                managed = True
            break
        if not managed and section[0].rstrip() in collision_names:
            managed = True
        if not managed:
            result.extend(section)
    else:
        result.append(line)
        i += 1

text = "".join(result)
text = re.sub(r"\n{3,}", "\n\n", text)
with open(outp, "w") as f:
    f.write(text)
PY
}

#############################################################################
# Append a managed section
#############################################################################
append_section() {
  local header="$1"; shift
  {
    [[ -s "$AWS_CONFIG" ]] && [[ -n "$(tail -c1 "$AWS_CONFIG")" ]] && echo ""
    echo ""
    echo "$header"
    echo "$SENTINEL"
    printf "%s\n" "$@"
  } >> "$AWS_CONFIG"
}

#############################################################################
# Compute the list of section names we will write.
#############################################################################
HEADERS_TO_WRITE="[sso-session $SSO_SESSION_NAME]"
PROFILE_PLAN_TSV=""  # "header<TAB>account_id<TAB>role<TAB>region" rows
while IFS=$'\t' read -r acct_name acct_id acct_region; do
  [[ -z "$acct_name" ]] && continue
  region="$acct_region"
  [[ -z "$region" ]] && region="$SSO_REGION"
  while IFS=$'\t' read -r role_full role_short; do
    [[ -z "$role_full" ]] && continue
    profile_name="$PROFILE_NAME_TPL"
    profile_name="${profile_name//\{account\}/$acct_name}"
    profile_name="${profile_name//\{role_short\}/$role_short}"
    HEADERS_TO_WRITE+=$'\n'"[profile $profile_name]"
    PROFILE_PLAN_TSV+="[profile $profile_name]"$'\t'"$acct_id"$'\t'"$role_full"$'\t'"$region"$'\n'
  done <<< "$ROLES_TSV"
done <<< "$ACCOUNTS_TSV"

#############################################################################
# Build new config
#############################################################################
WORK=$(mktemp)
strip_managed_sections "$AWS_CONFIG" "$WORK" "$HEADERS_TO_WRITE"

if (( DRY_RUN )); then
  echo "[DRY-RUN] Would write a new $AWS_CONFIG with these managed sections:"
  echo ""
fi

mv "$WORK" "${AWS_CONFIG}.new"
AWS_CONFIG_ORIG="$AWS_CONFIG"
AWS_CONFIG="${AWS_CONFIG}.new"

# Write SSO session block
append_section "[sso-session $SSO_SESSION_NAME]" \
  "sso_start_url = $SSO_START_URL" \
  "sso_region = $SSO_REGION" \
  "sso_registration_scopes = $SSO_SCOPES"
echo "[INFO] Managed: [sso-session $SSO_SESSION_NAME]"

# Write each profile block from the plan
while IFS=$'\t' read -r header acct_id role_full region; do
  [[ -z "$header" ]] && continue
  append_section "$header" \
    "sso_session = $SSO_SESSION_NAME" \
    "sso_account_id = $acct_id" \
    "sso_role_name = $role_full" \
    "region = $region" \
    "output = json"
  echo "[INFO] Managed: $header (account=$acct_id role=$role_full region=$region)"
done <<< "$PROFILE_PLAN_TSV"

if (( DRY_RUN )); then
  echo ""
  echo "[DRY-RUN] New file would be:"
  cat "$AWS_CONFIG"
  rm -f "$AWS_CONFIG"
  AWS_CONFIG="$AWS_CONFIG_ORIG"
  echo ""
  echo "[DRY-RUN] Not modifying $AWS_CONFIG_ORIG."
else
  mv "$AWS_CONFIG" "$AWS_CONFIG_ORIG"
  AWS_CONFIG="$AWS_CONFIG_ORIG"
  echo ""
  echo "[SUCCESS] $AWS_CONFIG updated."
  echo ""
  echo "Next steps:"
  echo "  1. Log in (once per session lifetime, typically ~8h):"
  echo "       aws sso login --sso-session $SSO_SESSION_NAME"
  echo "  2. Verify a profile works:"
  echo "       aws sts get-caller-identity --profile <profile-name>"
fi

echo ""
echo "Built with ❤️  by CloudDrove  ::  https://clouddrove.com  ::  hello@clouddrove.com"
