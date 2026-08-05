# terraform-aws-bastion

Reach **private** cloud resources (EKS API server, internal ALBs, Aurora,
RDS Proxy, ElastiCache) from your laptop **without exposing anything to the
internet**.

The bastion is a small EC2 instance in private subnets with:

- **No SSH key**
- **No public IP**
- **No inbound security group rules**

Access is exclusively through **AWS Systems Manager Session Manager**,
authenticated by your own IAM or SSO identity. A companion client script opens
SSM **port forwarding** tunnels and routes them through a local **HAProxy** so
the real hostnames resolve to `localhost`, which means TLS and certificate
validation keep working end to end. `kubectl`, `psql`, and `redis-cli` all
behave normally.

![Architecture](docs/architecture.svg)

## Composition

Every AWS resource is created through a published CloudDrove module. This
module composes them and declares no `aws_*` resources of its own.

| Concern | Module | Version |
|---|---|---|
| Naming and tagging | `clouddrove/labels/aws` | 1.3.1 |
| Instance role | `clouddrove/iam-role/aws` | 1.4.0 |
| Bastion security group, zero ingress | `clouddrove/security-group/aws` | 2.0.3 |
| Per target ingress rules | `clouddrove/security-group/aws` | 2.0.3 |
| Launch template and Auto Scaling Group | `clouddrove/ec2-autoscaling/aws` | 1.3.4 |

## Prerequisite: enable IMDSv2 at the account level

`clouddrove/ec2-autoscaling` 1.3.4 has no `metadata_options` input, so IMDSv2
cannot be required from this module. Set it as an account and region default
instead, which is stronger because it also covers instances launched outside
this module.

```bash
aws ec2 modify-instance-metadata-defaults \
  --http-tokens required \
  --http-put-response-hop-limit 1 \
  --region eu-west-1
```

Run once per account and region. See
[docs/composition-tradeoffs.md](docs/composition-tradeoffs.md) for this and two
other properties the composition cannot express, each with a workaround.

## Usage

### Existing VPC

The VPC must already reach Systems Manager, either through the `ssm`,
`ssmmessages`, and `ec2messages` interface endpoints or through NAT. Without one
of those the SSM agent cannot register and the bastion stays invisible to
Session Manager.

```hcl
module "bastion" {
  source  = "clouddrove/bastion/aws"
  version = "1.0.0"

  name        = "myproject"
  environment = "dev"

  vpc_id     = "vpc-0abc"
  vpc_cidr   = "10.60.0.0/16"
  subnet_ids = ["subnet-0a", "subnet-0b"]
}
```

### Greenfield

[`examples/complete`](examples/complete) builds the VPC, private subnets, and
SSM interface endpoints from `clouddrove/vpc/aws` and `clouddrove/subnet/aws`,
then the bastion on top. No NAT gateway and no public subnets.

```bash
cd examples/complete
terraform init
terraform apply -var region=eu-west-1 -var name=myproject -var environment=dev
```

### Letting the bastion reach your resources

The bastion security group allows egress to the whole VPC CIDR, but each target
must also allow **inbound** from the bastion security group. List the target
security groups and ports and this module attaches the rules for you, without
editing the targets' own modules.

```hcl
target_ingress_rules = [
  { security_group_id = "sg-0eks",    port = 443,  description = "EKS API from bastion" },
  { security_group_id = "sg-0aurora", port = 5432, description = "Aurora from bastion" },
  { security_group_id = "sg-0redis",  port = 6379, description = "Redis from bastion" },
]
```

Leave it empty for a greenfield deploy and fill it in once the targets exist.

> **EKS `kubectl` access is separate.** Your own IAM or SSO principal also needs
> an EKS access entry on the cluster. That is a property of your identity, not
> of the bastion.

## Client: opening the tunnels

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

## Availability

`desired_capacity` defaults to 1. Raising it does **not** keep an in flight
tunnel alive: SSM sessions bind to an instance ID and cannot fail over. What a
second instance buys is time to reconnect, immediate rather than waiting out an
Auto Scaling Group replacement of roughly three minutes.

## Audit trail

CloudTrail is the audit source, not Session Manager transcript logging.
Transcripts capture terminal output, and port forwarding sessions have no
terminal. CloudTrail `StartSession` events carry the caller identity, the target
instance, the document name, and the port forwarding parameters, which is who
connected, when, and to which private host and port.

## Cost

- One `t4g.micro` runs roughly 3 to 5 USD per month on demand. Setting
  `schedule_enabled = true` stops it outside working hours and roughly halves
  that.
- Interface VPC endpoints cost roughly 7 USD per month each per AZ, three of
  them. Still cheaper and more private than a NAT gateway, which is why
  `examples/complete` uses endpoints.

## Security notes

- The instance role carries only `AmazonSSMManagedInstanceCore`. Add more
  through `extra_iam_policy_arns` only with a concrete reason.
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
| Stale tunnels after laptop sleep | `pkill -f session-manager-plugin; pkill -f 'haproxy -f'`, then re-run `tunnel.sh`. |
| HAProxy will not bind 443 | Something else owns the port. `sudo lsof -i :443`. |

<!-- BEGIN_TF_DOCS -->
<!-- END_TF_DOCS -->

## License

See [LICENSE](LICENSE).
