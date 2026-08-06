# Client: opening the tunnels

### Client: opening the tunnels

The [`client/`](client) directory holds the piece with no equivalent on the
registry: SSM port forwarding plus a local HAProxy SNI router, so private
endpoints answer on their real hostnames with TLS intact.

**Requirements** (macOS shown, `sudo` needed because HAProxy binds 443 and 5432
and the script edits `/etc/hosts`):

| Tool | Install |
|---|---|
| AWS CLI v2 | `brew install awscli` |
| Session Manager plugin | `brew install --cask session-manager-plugin` |
| `jq` | `brew install jq` |
| `haproxy` | `brew install haproxy` |

**Configure and run:**

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

**Connect:**

```bash
kubectl --kubeconfig ~/.kube/config-tunnel --context dev get nodes
psql "host=<real-aurora-endpoint> port=5432 sslmode=require dbname=app user=app_user"
redis-cli -h localhost -p 18004 --tls
```
