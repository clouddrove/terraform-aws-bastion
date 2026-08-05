# SSM Jump Host — end-to-end private access from localhost

Reach **private** cloud resources — EKS API server, internal ALBs, Aurora /
PostgreSQL, RDS Proxy, ElastiCache Redis/Valkey — from your laptop, **without
exposing anything to the internet**.

The jump host is a small EC2 instance in private subnets with:

- **No SSH key**
- **No public IP**
- **No inbound security-group rules**

Access is exclusively through **AWS Systems Manager (SSM) Session Manager**,
authenticated by your own AWS IAM / SSO identity. A client script opens SSM
**port-forwarding** tunnels and routes them through a local **HAProxy** so the
real hostnames resolve to `localhost` — meaning TLS and certificate validation
keep working end to end (`kubectl`, `psql`, `redis-cli` all behave normally).

![SSM jump host architecture](docs/architecture.svg)

> **Editable source:** [`docs/architecture.drawio`](docs/architecture.drawio) —
> open at [diagrams.net](https://app.diagrams.net) (File → Open) or with the
> draw.io VS Code extension. The rendered [`docs/architecture.svg`](docs/architecture.svg)
> above is regenerated from it.

---

## Repository layout

```
jump_host/
├── README.md                     ← you are here
├── modules/
│   ├── network/                  ← VPC + private subnets + SSM VPC endpoints (+ optional NAT)
│   └── ssm-jumphost/             ← IAM role, hardened SG, launch template, ASG (desired=1)
├── examples/
│   ├── terraform/                ← plain Terraform root wiring both modules
│   └── terragrunt/               ← Terragrunt root + 010-network + 020-jumphost units
└── client/
    ├── tunnel.json               ← config: SSO details, profiles, per-env resources
    ├── bootstrap.sh              ← writes AWS SSO profiles into ~/.aws/config (idempotent)
    └── tunnel.sh                 ← opens SSM tunnels + HAProxy SNI router
```

> **Placeholders.** The scaffolding uses `myorg` (organisation), `myproject`
> (project), example account IDs, and `example` domains. Find-and-replace these
> with your own before use.

---

## Prerequisites

**On the deploying machine (IaC):**

- [Terraform](https://developer.hashicorp.com/terraform/downloads) ≥ 1.5, and/or
  [Terragrunt](https://terragrunt.gruntwork.io/) ≥ 0.55
- AWS credentials for the target account with permission to create VPC, EC2,
  IAM, and ASG resources

**On the client machine (connecting):**

| Tool | macOS install | Purpose |
|---|---|---|
| AWS CLI v2 | `brew install awscli` | AWS API + `aws ssm start-session` |
| Session Manager plugin | `brew install --cask session-manager-plugin` | SSM port forwarding |
| `jq` | `brew install jq` | reads `tunnel.json` |
| `haproxy` | `brew install haproxy` | local SNI routing on :443 / :5432 |
| `curl` | preinstalled | tunnel keep-alive |

`sudo` is required on the client: HAProxy binds privileged ports 443/5432 and
the script edits `/etc/hosts`.

---

## Part 1 — Deploy the infrastructure

### Option A: plain Terraform

```bash
cd examples/terraform
cp terraform.tfvars.example terraform.tfvars
# edit terraform.tfvars: aws_profile, region, project_name, environment, vpc_cidr

terraform init
terraform apply -var-file=terraform.tfvars
```

Outputs include `bastion_name` — the EC2 Name tag the client uses for discovery
(pattern `<project>-<env>-ssm-bastion`).

### Option B: Terragrunt

```bash
cd examples/terragrunt
# edit root.hcl: project_name, environment, region, profile, account_id, state_bucket

terragrunt apply --working-dir 010-network
terragrunt apply --working-dir 020-jumphost
# or, for the whole stack:  terragrunt run-all apply
```

### Using an existing VPC

Skip the `network` module and pass your own IDs straight to `ssm-jumphost`:

```hcl
module "jumphost" {
  source        = "../../modules/ssm-jumphost"
  project_name  = "myproject"
  environment   = "dev"
  vpc_id        = "vpc-0abc..."
  vpc_cidr      = "10.0.0.0/16"
  subnet_ids    = ["subnet-0a...", "subnet-0b..."]
}
```

If you reuse an existing VPC **without NAT**, make sure it already has the SSM
interface endpoints (`ssm`, `ssmmessages`, `ec2messages`); otherwise the SSM
agent cannot register and the jump host will be invisible to Session Manager.
The `network` module creates these for you when `create_ssm_endpoints = true`.

### Let the jump host reach your resources

The jump host SG allows **egress** to the whole VPC CIDR, but each target still
needs to allow **inbound** from the jump host SG. The module wires this for you —
list the target SGs and ports via `target_ingress_rules` and it attaches the
ingress rules from the jump host SG automatically:

```hcl
module "jumphost" {
  source = "../../modules/ssm-jumphost"
  # ... vpc_id / subnet_ids / etc ...

  target_ingress_rules = [
    { security_group_id = "sg-0eks...",    port = 443,  description = "EKS API from jump host" },
    { security_group_id = "sg-0aurora...", port = 5432, description = "Aurora from jump host" },
    { security_group_id = "sg-0redis...",  port = 6379, description = "Redis from jump host" },
  ]
}
```

Leave it empty for a greenfield deploy and fill it in once the targets exist (or
keep managing those ingress rules from the targets' own modules — either works).

> **EKS kubectl access is separate.** To run `kubectl` your own IAM/SSO principal
> also needs an EKS **access entry** (or `aws-auth` mapping) on the cluster. That
> is a property of your identity on your cluster, not of the jump host.

---

## Part 2 — Configure the client

Edit `client/tunnel.json`:

1. **`defaults.sso_*`** — your IAM Identity Center start URL, region, session name.
2. **`profiles`** — accounts + roles. `bootstrap.sh` turns these into named
   profiles, e.g. `myorg-dev-admin`.
3. **`defaults.bastion_name_template`** — must match the Terraform output
   (`myproject-{env}-ssm-bastion`).
4. **`environments.<env>.resources`** — flip `enabled: true` on the resources you
   want tunneled per environment.

### Create AWS profiles (SSO)

```bash
cd client
./bootstrap.sh            # writes managed blocks into ~/.aws/config (backs it up first)
./bootstrap.sh --dry-run  # preview without writing

aws sso login --sso-session myorg-sso
```

`bootstrap.sh` only touches sections it owns (marked with a sentinel comment) —
your hand-written profiles are left alone.

### Using plain IAM profiles instead of SSO

Skip `bootstrap.sh` entirely. Ensure the profile named in each env's `profile`
field already exists in `~/.aws/config`, e.g.:

```ini
[profile myorg-dev-admin]
region = eu-west-1
# ... your access keys, role_arn + source_profile, or credential_process ...
```

`tunnel.sh` only needs `aws sts get-caller-identity --profile <name>` to succeed.

---

## Part 3 — Open the tunnels

```bash
cd client
./tunnel.sh                       # all envs in tunnel.json
./tunnel.sh --env dev             # one env
./tunnel.sh --env dev --env prod  # several
```

You'll be asked for your `sudo` password (HAProxy + `/etc/hosts`), then see a
table of what got wired:

```
| RESOURCE            | LOCAL ENDPOINT     | REMOTE HOST
| bastion             |                    | i-0123456789abcdef0
| EKS apiserver       | localhost:18000    | ABCD1234....eks.amazonaws.com:443
| Aurora (writer)     | localhost:18002    | myproject-dev.cluster-xxxx.rds.amazonaws.com:5432
...
[SUCCESS] Tunnels are LIVE. Ctrl+C to terminate.
```

Leave it running. **Ctrl+C** tears down every tunnel, kills HAProxy, and removes
the `/etc/hosts` entries it added.

### Connect

**EKS** (kubeconfig is written automatically to `~/.kube/config-tunnel`):

```bash
kubectl --kubeconfig ~/.kube/config-tunnel --context dev get nodes
```

**PostgreSQL / Aurora** (host is the real endpoint, now pointing at localhost):

```bash
psql "host=myproject-dev.cluster-xxxx.rds.amazonaws.com port=5432 sslmode=require dbname=app user=app_user"
```

**Redis / Valkey** (direct local port shown in the table; TLS if enabled):

```bash
redis-cli -h localhost -p 18004 --tls
```

---

## How it works

- **Discovery is name/tag based.** The jump host is found by its `Name` tag; EKS,
  Aurora, RDS Proxy, and Redis are matched by the first resource whose identifier
  contains the env name; the internal ALB is matched by tag filters. Nothing is
  hard-coded, so the same config follows your infrastructure as it changes.
- **HAProxy SNI routing.** HTTPS-bearing resources share local ports 443/5432.
  HAProxy peeks at the TLS SNI / handshake and dispatches to the right SSM
  tunnel. `/etc/hosts` maps each real hostname to `127.0.0.1`, so certificate
  hostnames validate exactly as they would in-cluster.
- **Redis is a direct tunnel** (Redis has no SNI), on its own local port.
- **Self-healing host.** The ASG keeps `desired=1`; a terminated instance is
  replaced automatically. Optional start/stop schedules park it out of hours.

---

## Module reference

### `modules/network` inputs

| Name | Type | Default | Purpose |
|---|---|---|---|
| `name_prefix` | string | — (required) | Prefix for all resource names, e.g. `myproject-dev`. |
| `vpc_cidr` | string | `10.60.0.0/16` | VPC CIDR. Private subnets carved as `/20`, public as `/24`. |
| `az_count` | number | `2` | AZs to spread subnets across (1–4). |
| `enable_nat` | bool | `false` | Add public subnets + IGW + NAT for outbound internet. Off = SSM endpoints only. |
| `single_nat_gateway` | bool | `true` | When NAT on, share one NAT across AZs vs one per AZ. |
| `create_ssm_endpoints` | bool | `true` | Create ssm/ssmmessages/ec2messages interface + S3 gateway endpoints. Required when `enable_nat=false`. |
| `tags` | map(string) | `{}` | Extra tags on every resource. |

Outputs: `vpc_id`, `vpc_cidr`, `private_subnet_ids`, `public_subnet_ids`, `availability_zones`.

### `modules/ssm-jumphost` inputs

| Name | Type | Default | Purpose |
|---|---|---|---|
| `project_name` | string | — (required) | Used in names/tags. |
| `environment` | string | — (required) | Used in names/tags. Drives the bastion Name tag `<project>-<env>-ssm-bastion`. |
| `vpc_id` | string | — (required) | VPC the host lives in. |
| `subnet_ids` | list(string) | — (required) | Private subnet IDs for the ASG. |
| `vpc_cidr` | string | — (required) | Allowed as egress so the host can reach in-VPC resources. |
| `instance_type` | string | `t4g.micro` | EC2 type. arm64 (`t4g.*`) or x86_64 (`t3.*`) — AMI arch auto-detected. |
| `target_ingress_rules` | list(object) | `[]` | `{security_group_id, port, description}` — opens each target SG inbound from the jump host SG. |
| `schedule_enabled` | bool | `false` | Attach ASG start/stop schedules. |
| `asg_schedules` | list(object) | `[]` | `{name, min_size, max_size, desired_capacity, recurrence}` (cron, UTC). |
| `extra_egress_cidrs` | list(string) | `[]` | Extra egress CIDRs beyond the VPC. |
| `extra_iam_policy_arns` | list(string) | `[]` | Extra managed policies beyond `AmazonSSMManagedInstanceCore`. |
| `user_data` | string | `""` | Optional cloud-init. Empty = base AL2023 + SSM agent. |
| `tags` | map(string) | `{}` | Extra tags on every resource. |

Outputs: `bastion_name`, `security_group_id`, `iam_role_arn`, `iam_role_name`, `asg_name`, `launch_template_id`.

> **Instance type used by default: `t4g.micro`** (arm64/Graviton — cheapest that
> comfortably runs the SSM agent + port forwarding). Switch to `t3.micro` for
> x86_64; nothing else needs changing, the AMI architecture follows the type.

## Cost / operations

- One `t4g.micro` runs ~\$3–5/mo on-demand. The optional ASG schedule
  (`schedule_enabled = true`) can stop it overnight/weekends to roughly halve
  that.
- Interface VPC endpoints cost ~\$7/mo each per AZ (three of them) — still far
  cheaper and more secure than a NAT gateway, and the reason `enable_nat`
  defaults to `false`.
- No inbound exposure means no bastion patch-panic: even a fully unpatched host
  has no listening service reachable from outside the VPC.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `bastion '...-ssm-bastion' not found; skipping env` | Instance not running, wrong region/profile, or Name tag ≠ `bastion_name_template`. Check `aws ec2 describe-instances --profile <p>`. |
| `[FATAL] AWS credentials check failed` | Run `aws sso login --sso-session <name>`, or the profile is missing — re-run `./bootstrap.sh`. |
| SSM session opens then dies immediately | Jump host can't reach SSM: missing VPC endpoints and no NAT. Add endpoints (`create_ssm_endpoints = true`) or enable NAT. |
| `psql`/`kubectl` connects but hangs | Target SG doesn't allow inbound from the jump host SG. Add the rule (see Part 1). |
| "IAM auth failed" / stale tunnels after sleep | Kill leftover processes: `pkill -f session-manager-plugin; pkill -f 'haproxy -f'`, then re-run `tunnel.sh`. |
| HAProxy won't bind :443 | Something else owns the port (a prior run, local nginx). `sudo lsof -i :443`, stop it, retry. |
| kubeconfig context missing | The EKS tunnel failed to start; check the run table for a `[WARN]` on that cluster. |

---

## Security notes

- The jump host role carries **only** `AmazonSSMManagedInstanceCore`. Grant more
  via `extra_iam_policy_arns` only if you have a concrete reason.
- All access is logged: enable **SSM Session Manager logging** to CloudWatch/S3
  at the account level for a full audit trail of who connected and when.
- IMDSv2 is enforced (`http_tokens = required`) and the metadata hop limit is 1.
- Scope who can reach the host with IAM: restrict `ssm:StartSession` on the
  `AWS-StartPortForwardingSessionToRemoteHost` document to the intended roles.
- Rotate nothing — there are no long-lived keys on the host to rotate.
```
