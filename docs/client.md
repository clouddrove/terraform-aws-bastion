# Client: tunnels, cost, and troubleshooting

The [`client/`](../client) directory holds the piece with no equivalent on the
registry: SSM port forwarding plus a local HAProxy SNI router, so private
endpoints answer on their real hostnames with TLS intact.

## Requirements

macOS shown. `sudo` is needed because HAProxy binds 443 and 5432 and the script
edits `/etc/hosts`.

| Tool | Install |
|---|---|
| AWS CLI v2 | `brew install awscli` |
| Session Manager plugin | `brew install --cask session-manager-plugin` |
| `jq` | `brew install jq` |
| `haproxy` | `brew install haproxy` |

## Configure and run

```bash
cd client
./bootstrap.sh            # writes AWS SSO profiles into ~/.aws/config
./bootstrap.sh --dry-run  # preview without writing

aws sso login --sso-session <your-sso-session>

./tunnel.sh --env dev
```

Point `client/tunnel.json` at the bastion this module created:

```bash
terraform output tunnel_config
```

Leave `tunnel.sh` running. Ctrl+C tears down every tunnel and kills HAProxy.

## What it can reach

Every resource is opt-in per environment in `tunnel.json`, and anything missing
is skipped with a `[WARN]` rather than failing the run.

| Resource | Port | Routing |
|---|---|---|
| `eks` | 443 | HAProxy SNI, writes a kubeconfig context at `~/.kube/config-tunnel` |
| `internal_alb` | 443 | HAProxy SNI, one entry per host-header rule |
| `aurora` | 5432 | HAProxy SNI |
| `rds_proxy` | 5432 | HAProxy SNI |
| `postgres` | 5432 | HAProxy SNI, so `sslmode=verify-full` still works |
| `mysql` | 3306 | Direct local port. `engine` selects `mysql` or `mariadb` |
| `redis` | 6379 | Direct. ElastiCache Serverless |
| `redis_cluster` | 6379 | Direct. Classic replication group, configuration or primary endpoint |
| `memcached` | 11211 | Direct, via the configuration endpoint |
| `documentdb` | 27017 | Direct. Connect with `directConnection=true` |
| `opensearch` | 443 | HAProxy SNI. Covers Dashboards at `/_dashboards` on the same endpoint |
| `msk` | 9094 | Direct, first TLS bootstrap broker only |
| `custom[]` | any | Direct, or `sni_443: true` to route through HAProxy |

`custom[]` takes a host and a port directly, so a self-managed database on EC2,
a peered partner endpoint, or an internal service by IP goes through the same
bastion as everything else.

Resources on 443 and 5432 route through HAProxy so the real hostname resolves
locally and certificate validation still passes. Everything else is a direct
local port, which means you connect to `127.0.0.1` and strict hostname
verification will not match.

## Connect

```bash
kubectl --kubeconfig ~/.kube/config-tunnel --context dev get nodes
psql "host=<real-aurora-endpoint> port=5432 sslmode=require dbname=app user=app_user"
mysql -h 127.0.0.1 -P <local-port> -u <user> -p --ssl-mode=REQUIRED
redis-cli -h localhost -p 18004 --tls
mongosh "mongodb://<user>@localhost:<local-port>/?tls=true&directConnection=true"
open https://<opensearch-host>/_dashboards
```

## Cost

- One `t4g.micro` runs roughly 3 to 5 USD per month on demand. Setting
  `schedule_enabled = true` stops it outside working hours and roughly halves
  that.
- Interface VPC endpoints cost roughly 7 USD per month each per AZ, three of
  them. Still cheaper and more private than a NAT gateway, which is why
  `examples/complete` uses endpoints.
- Session logging is close to free. Connection records are a few hundred bytes
  each and a busy team produces a few thousand a month, well under 1 USD of
  ingestion at 7 day retention. Shell transcripts scale with terminal output, so
  budget more if `session_preferences_managed` is on and sessions are chatty.
  The dashboard is free: an account gets 3 at no charge, then 3 USD each.

## Security notes

- The instance role carries `AmazonSSMManagedInstanceCore` plus, when
  `logging_enabled` is true, an inline policy allowing CloudWatch Logs writes
  under `/aws/ssm/session/`. That managed policy grants no `logs:PutLogEvents`,
  so shell transcripts do not stream without it. Add anything further through
  `extra_iam_policy_arns` only with a concrete reason.
- Restrict who may connect with IAM: scope `ssm:StartSession` on the
  `AWS-StartPortForwardingSessionToRemoteHost` document to the intended roles.
- There are no long lived keys on the host to rotate.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `bastion '...' not found; skipping env` | Instance not running, wrong region or profile, or the Name tag does not match. Compare `terraform output name` with `client/tunnel.json`. |
| `[FATAL] AWS credentials check failed` | Run `aws sso login --sso-session <name>`, or re-run `./bootstrap.sh`. |
| SSM session opens then dies immediately | The bastion cannot reach SSM: missing VPC endpoints and no NAT. |
| `psql` or `kubectl` connects but hangs | The target security group does not allow inbound from the bastion. Add it to `target_ingress_rules`. |
| A service is skipped with `[WARN] no ... found` | Discovery is first-match-by-substring on the environment name. Check the resource identifier actually contains it. |
| Stale tunnels after laptop sleep | `pkill -f session-manager-plugin; pkill -f 'haproxy -f'`, then re-run `tunnel.sh`. |
| HAProxy will not bind 443 | Something else owns the port. `sudo lsof -i :443`. |
