# Cost, security, and troubleshooting

### Cost

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

### Security notes

- The instance role carries `AmazonSSMManagedInstanceCore` plus, when
  `logging_enabled` is true, an inline policy allowing CloudWatch Logs writes
  under `/aws/ssm/session/`. That managed policy grants no `logs:PutLogEvents`,
  so shell transcripts do not stream without it. Add anything further through
  `extra_iam_policy_arns` only with a concrete reason.
- Restrict who may connect with IAM: scope `ssm:StartSession` on the
  `AWS-StartPortForwardingSessionToRemoteHost` document to the intended roles.
- There are no long lived keys on the host to rotate.

### Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `bastion '...' not found; skipping env` | Instance not running, wrong region or profile, or the Name tag does not match. Compare `terraform output name` with `client/tunnel.json`. |
| `[FATAL] AWS credentials check failed` | Run `aws sso login --sso-session <name>`, or re-run `./bootstrap.sh`. |
| SSM session opens then dies immediately | The bastion cannot reach SSM: missing VPC endpoints and no NAT. |
| `psql` or `kubectl` connects but hangs | The target security group does not allow inbound from the bastion. Add it to `target_ingress_rules`. |
| Stale tunnels after laptop sleep | `pkill -f session-manager-plugin; pkill -f 'haproxy -f'`, then re-run `tunnel.sh`. |
| HAProxy will not bind 443 | Something else owns the port. `sudo lsof -i :443`. |
