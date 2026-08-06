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

Every AWS resource is created through a published CloudDrove module, with one
documented exception.

| Concern | Module | Version |
|---|---|---|
| Naming and tagging | `clouddrove/labels/aws` | 1.3.1 |
| Instance role | `clouddrove/iam-role/aws` | 1.4.0 |
| Bastion security group, zero ingress | `clouddrove/security-group/aws` | 2.0.3 |
| Per target ingress rules | `clouddrove/security-group/aws` | 2.0.3 |
| Launch template and Auto Scaling Group | `clouddrove/ec2-autoscaling/aws` | 1.3.4 |
| Connection audit rule | `clouddrove/cloudwatch-event-rule/aws` | 1.0.2 |
| Dashboard | `clouddrove/cloudwatch-dashboard/aws` | 1.0.1 |

The exception is session logging, which declares four `aws_*` resources
directly: two log groups, a log group resource policy, and the SSM session
document. No CloudDrove module covers any of those.
[docs/composition-tradeoffs.md](docs/composition-tradeoffs.md) records why.

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
  # This repository is private and is not published to the Terraform Registry,
  # so `source = "clouddrove/bastion/aws"` does not resolve. Pin a commit.
  source = "git::https://github.com/clouddrove/terraform-aws-bastion.git?ref=969b02e"

  name        = "myproject"
  environment = "dev"

  vpc_id     = "vpc-0abc"
  vpc_cidr   = "10.60.0.0/16"
  subnet_ids = ["subnet-0a", "subnet-0b"]
}
```

There are no tags yet, so `ref` takes a commit SHA. Find the current one with:

```bash
git ls-remote https://github.com/clouddrove/terraform-aws-bastion.git master
```

Do not use `ref=master`. Terraform caches modules in `.terraform/modules`, so a
moving ref means two runs of the same configuration can build different
infrastructure with no diff to explain it.

### Giving CI access to a private module

`terraform init` clones this repository over the network, so any runner needs
credentials. Without them it fails with `Repository not found`, which is a
permissions error rather than a missing repository.

**GitHub Actions**, using a token with read access to this repository:

```yaml
- name: Allow Terraform to clone private modules
  run: |
    git config --global url."https://oauth2:${{ secrets.MODULE_READ_TOKEN }}@github.com".insteadOf "https://github.com"
- run: terraform init
```

The default `GITHUB_TOKEN` is scoped to the calling repository alone and cannot
read this one. Use a fine-grained PAT, a GitHub App installation token, or make
the runner a member of a team with read access.

**Deploy key**, for CI outside GitHub Actions. Add the public half to this
repository's deploy keys, then switch the source to SSH:

```hcl
source = "git::ssh://git@github.com/clouddrove/terraform-aws-bastion.git?ref=969b02e"
```

Watch for a global `insteadOf` rule rewriting HTTPS to SSH or the reverse. It
applies to Terraform's clones too, and silently overrides whichever protocol
the source specifies.

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

## Session logging and audit

CloudTrail is the audit source, not Session Manager transcript logging.
Transcripts capture terminal output, and port forwarding sessions have no
terminal. CloudTrail `StartSession` events carry the caller identity, the target
instance, the document name, and the port forwarding parameters, which is who
connected, when, and to which private host and port.

The module turns that into two log groups, both at `log_retention_days` (7 by
default), and one dashboard.

| Log group | Holds | Created when |
|---|---|---|
| `/aws/bastion/<name>/connections` | One flat record per `StartSession`, `ResumeSession`, and `TerminateSession`: principal, source IP, target instance, tunnelled host and port, session ID | `logging_enabled` (default true) |
| `/aws/ssm/session/<name>` | Full terminal transcripts of interactive shells | `session_preferences_managed` (default false) |

The connection audit covers every session type, including the port forwards
`client/tunnel.sh` opens. Transcript logging covers interactive shells only.

### Prerequisite: a CloudTrail trail in the region

Session Manager publishes no native EventBridge event, so the audit rule matches
CloudTrail-sourced API calls, and those reach EventBridge only while a trail is
logging management events. Without a trail the log group stays empty and the
dashboard shows nothing.

```bash
aws cloudtrail describe-trails --query 'trailList[].{Name:Name,Multi:IsMultiRegionTrail}' --output table
```

Most accounts already have an organization trail. The module does not create
one, because a trail is account level state that outlives any single bastion.

### Turning on shell transcripts

`session_preferences_managed = true` creates `SSM-SessionManagerRunShell`. That
document is an **account and region singleton**: it governs shell logging for
every SSM session in the region, not only this bastion's, and two deployments in
one account collide on it. Leave it false in shared accounts.

If the document already exists, import it first or the apply fails:

```bash
terraform import 'module.bastion.aws_ssm_document.session_preferences[0]' SSM-SessionManagerRunShell
```

Running with `create_iam_role = false` means the module cannot grant the
instance the CloudWatch Logs writes transcripts need, since it does not own the
role. Attach `terraform output -raw session_log_policy_json` to your role
yourself.

### Dashboard

`terraform output -raw dashboard_url` opens it. Seven widgets: recent sessions,
sessions per principal, event counts, instances in service, CPU, network, and
shell transcripts. Log widgets follow the dashboard time picker, which defaults
to the last 7 days.

Session duration is not a widget, because it needs start and end paired by
session ID. Run this in Logs Insights against the audit group instead:

```
fields @timestamp, event, principal, coalesce(sessionId, endedSession) as sid, targetHost, targetPort
| stats earliest(principal) as who,
        earliest(targetHost) as host,
        earliest(targetPort) as port,
        min(@timestamp) as started,
        max(@timestamp) as ended,
        (max(@timestamp) - min(@timestamp)) / 1000 as duration_seconds
  by sid
| sort started desc
```

A row with `duration_seconds` near zero is a session still open, or one whose
`TerminateSession` fell outside the query window.

### Scope of the audit rule

Session targets are instance IDs the Auto Scaling group assigns at launch, so
they cannot be matched in a static EventBridge pattern. The rule therefore
records SSM sessions to **every instance in the region**, not only this
bastion's. That is a wider net rather than a narrower one; the `instance` field
identifies which host each session went to.

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
| Stale tunnels after laptop sleep | `pkill -f session-manager-plugin; pkill -f 'haproxy -f'`, then re-run `tunnel.sh`. |
| HAProxy will not bind 443 | Something else owns the port. `sudo lsof -i :443`. |

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.5.0 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 5.83.0, < 7.0.0 |

## Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_aws"></a> [aws](#provider\_aws) | >= 5.83.0, < 7.0.0 |

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| <a name="module_bastion"></a> [bastion](#module\_bastion) | clouddrove/ec2-autoscaling/aws | 1.4.0 |
| <a name="module_dashboard"></a> [dashboard](#module\_dashboard) | clouddrove/cloudwatch-dashboard/aws | 1.0.1 |
| <a name="module_iam_role"></a> [iam\_role](#module\_iam\_role) | clouddrove/iam-role/aws | 1.4.0 |
| <a name="module_labels"></a> [labels](#module\_labels) | clouddrove/labels/aws | 1.3.1 |
| <a name="module_security_group"></a> [security\_group](#module\_security\_group) | clouddrove/security-group/aws | 2.0.3 |
| <a name="module_session_events"></a> [session\_events](#module\_session\_events) | clouddrove/cloudwatch-event-rule/aws | 1.0.2 |
| <a name="module_target_access"></a> [target\_access](#module\_target\_access) | clouddrove/security-group/aws | 2.0.3 |

## Resources

| Name | Type |
| ---- | ---- |
| [aws_cloudwatch_log_group.audit](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_cloudwatch_log_group.session](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_cloudwatch_log_resource_policy.events_to_audit_log](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_resource_policy) | resource |
| [aws_ssm_document.session_preferences](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ssm_document) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_ec2_instance_type.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/ec2_instance_type) | data source |
| [aws_iam_policy_document.events_to_audit_log](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.session_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.trust](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_attributes"></a> [attributes](#input\_attributes) | Additional name attributes, appended after the label\_order elements. Pass ["ssm"] for names ending in -ssm. | `list(string)` | `[]` | no |
| <a name="input_create_iam_role"></a> [create\_iam\_role](#input\_create\_iam\_role) | Set to false to use an externally managed IAM role instead of creating one. Requires iam\_role\_name. | `bool` | `true` | no |
| <a name="input_dashboard_enabled"></a> [dashboard\_enabled](#input\_dashboard\_enabled) | Create a CloudWatch dashboard showing recent sessions, sessions per<br/>principal, and bastion health. Has no effect when logging\_enabled is false,<br/>since most of the dashboard queries the connection audit log group. | `bool` | `true` | no |
| <a name="input_desired_capacity"></a> [desired\_capacity](#input\_desired\_capacity) | Number of bastion instances to run. Note that SSM sessions bind to an<br/>instance ID and cannot fail over, so a second instance does not keep an<br/>in-flight tunnel alive. What it buys is time to reconnect: immediate rather<br/>than waiting out an ASG replacement. | `number` | `1` | no |
| <a name="input_enabled"></a> [enabled](#input\_enabled) | Set to false to prevent the module from creating any resources. | `bool` | `true` | no |
| <a name="input_environment"></a> [environment](#input\_environment) | Environment name (for example dev, qa, prod). Second element of the generated resource name. | `string` | `""` | no |
| <a name="input_extra_egress_cidrs"></a> [extra\_egress\_cidrs](#input\_extra\_egress\_cidrs) | Extra CIDR blocks the bastion may reach on any port, beyond the VPC CIDR. Usually left empty. | `list(string)` | `[]` | no |
| <a name="input_extra_iam_policy_arns"></a> [extra\_iam\_policy\_arns](#input\_extra\_iam\_policy\_arns) | Additional managed IAM policy ARNs to attach to the bastion role, beyond AmazonSSMManagedInstanceCore. | `list(string)` | `[]` | no |
| <a name="input_extra_tags"></a> [extra\_tags](#input\_extra\_tags) | Additional tags applied to every resource. | `map(string)` | `{}` | no |
| <a name="input_iam_role_name"></a> [iam\_role\_name](#input\_iam\_role\_name) | Name of an existing IAM role to attach, used only when create\_iam\_role is<br/>false. The role must carry AmazonSSMManagedInstanceCore or the SSM agent<br/>cannot register. Note this is a role name, not an instance profile name:<br/>clouddrove/ec2-autoscaling builds the instance profile from it. | `string` | `null` | no |
| <a name="input_instance_type"></a> [instance\_type](#input\_instance\_type) | EC2 instance type. t4g.micro (arm64) or t3.micro (x86\_64). The AMI architecture follows the type. | `string` | `"t4g.micro"` | no |
| <a name="input_kms_key_id"></a> [kms\_key\_id](#input\_kms\_key\_id) | ARN of a customer-managed KMS key for the root volume. Leave null to use the<br/>AWS-managed aws/ebs key, which is free and adequate here: the volume holds<br/>only the Amazon Linux 2023 base image and the SSM agent, with no data and no<br/>credentials. Set this only when a compliance requirement mandates a<br/>customer-managed key, or when snapshots are shared across accounts. | `string` | `null` | no |
| <a name="input_label_order"></a> [label\_order](#input\_label\_order) | Order of elements in the generated resource name. | `list(any)` | <pre>[<br/>  "name",<br/>  "environment"<br/>]</pre> | no |
| <a name="input_log_kms_key_id"></a> [log\_kms\_key\_id](#input\_log\_kms\_key\_id) | ARN of a customer-managed KMS key encrypting both log groups. Leave null to<br/>use the AWS-owned key. A supplied key must carry a key policy allowing<br/>logs.<region>.amazonaws.com, or log group creation fails. | `string` | `null` | no |
| <a name="input_log_retention_days"></a> [log\_retention\_days](#input\_log\_retention\_days) | Retention in days for both the connection audit and the shell session log groups. 0 keeps logs forever. | `number` | `7` | no |
| <a name="input_logging_enabled"></a> [logging\_enabled](#input\_logging\_enabled) | Record every Session Manager connection to the bastion in CloudWatch Logs.<br/>Creates the connection audit log group, an EventBridge rule that writes<br/>StartSession, ResumeSession, and TerminateSession events into it, and the<br/>CloudWatch Logs permissions the instance role needs.<br/><br/>Requires a CloudTrail trail logging management events in this region.<br/>Session Manager emits no native EventBridge event, so the rule matches<br/>CloudTrail-sourced API call events, and those reach EventBridge only while a<br/>trail is logging them. Without a trail the log group stays empty. | `bool` | `true` | no |
| <a name="input_managedby"></a> [managedby](#input\_managedby) | ManagedBy tag value. | `string` | `"hello@clouddrove.com"` | no |
| <a name="input_max_size"></a> [max\_size](#input\_max\_size) | Maximum ASG size. | `number` | `1` | no |
| <a name="input_min_size"></a> [min\_size](#input\_min\_size) | Minimum ASG size. | `number` | `0` | no |
| <a name="input_name"></a> [name](#input\_name) | Name of the bastion, used as the first element of the generated resource name. | `string` | `"bastion"` | no |
| <a name="input_repository"></a> [repository](#input\_repository) | Repository tag value. | `string` | `"https://github.com/clouddrove/terraform-aws-bastion"` | no |
| <a name="input_root_volume_size"></a> [root\_volume\_size](#input\_root\_volume\_size) | Root volume size in GiB. | `number` | `8` | no |
| <a name="input_schedule_enabled"></a> [schedule\_enabled](#input\_schedule\_enabled) | Attach start and stop schedules to the ASG to save cost outside working hours. | `bool` | `false` | no |
| <a name="input_schedule_time_zone"></a> [schedule\_time\_zone](#input\_schedule\_time\_zone) | Time zone for the schedule cron expressions. | `string` | `"UTC"` | no |
| <a name="input_scheduler_down"></a> [scheduler\_down](#input\_scheduler\_down) | Cron expression for scaling down to zero. Used only when schedule\_enabled is true. | `string` | `"0 19 * * *"` | no |
| <a name="input_scheduler_up"></a> [scheduler\_up](#input\_scheduler\_up) | Cron expression for scaling up to desired\_capacity. Used only when schedule\_enabled is true. | `string` | `"0 7 * * MON-FRI"` | no |
| <a name="input_session_idle_timeout_minutes"></a> [session\_idle\_timeout\_minutes](#input\_session\_idle\_timeout\_minutes) | Minutes an interactive session may sit idle before Session Manager ends it. Written into the session document. | `number` | `20` | no |
| <a name="input_session_preferences_managed"></a> [session\_preferences\_managed](#input\_session\_preferences\_managed) | Create the SSM-SessionManagerRunShell document so interactive shell sessions<br/>stream their full terminal output to CloudWatch Logs. Also creates the<br/>session log group.<br/><br/>Off by default because that document is an account and region SINGLETON:<br/>turning this on changes shell logging for every SSM session in the region,<br/>not only this bastion's, and two deployments in one account collide on it.<br/>If the document already exists, import it before enabling:<br/><br/>  terraform import 'module.bastion.aws\_ssm\_document.session\_preferences[0]' SSM-SessionManagerRunShell<br/><br/>Port forwarding sessions produce no terminal output, so this setting does<br/>not affect what client/tunnel.sh records. Those are covered by<br/>logging\_enabled. | `bool` | `false` | no |
| <a name="input_subnet_ids"></a> [subnet\_ids](#input\_subnet\_ids) | Private subnet IDs for the Auto Scaling Group. The bastion is pinned to no<br/>public IP regardless, but private subnets are still the intended placement.<br/><br/>The VPC must reach AWS Systems Manager, either through the ssm, ssmmessages,<br/>and ec2messages interface endpoints or through NAT. Without one of those the<br/>SSM agent cannot register and the bastion stays invisible to Session Manager. | `list(string)` | n/a | yes |
| <a name="input_target_ingress_rules"></a> [target\_ingress\_rules](#input\_target\_ingress\_rules) | Security groups of the resources the bastion must reach, each with the port<br/>to open. The module attaches an ingress rule to every listed security group<br/>allowing that port from the bastion security group, closing the inbound side<br/>without editing the targets' own modules. Leave empty for a greenfield<br/>deploy with no targets yet. | <pre>list(object({<br/>    security_group_id = string<br/>    port              = number<br/>    description       = optional(string, "From SSM bastion")<br/>  }))</pre> | `[]` | no |
| <a name="input_user_data"></a> [user\_data](#input\_user\_data) | Optional cloud-init user data. Empty by default, since the base AL2023 SSM agent is all that is needed. | `string` | `""` | no |
| <a name="input_vpc_cidr"></a> [vpc\_cidr](#input\_vpc\_cidr) | VPC CIDR block. The bastion is allowed egress to this range so it can reach in-VPC resources. | `string` | n/a | yes |
| <a name="input_vpc_id"></a> [vpc\_id](#input\_vpc\_id) | ID of the VPC the bastion is deployed into. | `string` | n/a | yes |

## Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_audit_log_group_arn"></a> [audit\_log\_group\_arn](#output\_audit\_log\_group\_arn) | ARN of the connection audit log group. Null when logging\_enabled is false. |
| <a name="output_audit_log_group_name"></a> [audit\_log\_group\_name](#output\_audit\_log\_group\_name) | Log group holding one record per Session Manager connection: principal, target, and time. Null when logging\_enabled is false. |
| <a name="output_autoscaling_group_name"></a> [autoscaling\_group\_name](#output\_autoscaling\_group\_name) | Auto Scaling Group name. |
| <a name="output_dashboard_arn"></a> [dashboard\_arn](#output\_dashboard\_arn) | ARN of the bastion CloudWatch dashboard. Null when dashboard\_enabled is false. |
| <a name="output_dashboard_url"></a> [dashboard\_url](#output\_dashboard\_url) | Console URL of the bastion CloudWatch dashboard. Null when dashboard\_enabled is false. |
| <a name="output_iam_role_arn"></a> [iam\_role\_arn](#output\_iam\_role\_arn) | ARN of the bastion IAM role. Null when create\_iam\_role is false. |
| <a name="output_iam_role_name"></a> [iam\_role\_name](#output\_iam\_role\_name) | Name of the bastion IAM role. Null when create\_iam\_role is false. |
| <a name="output_launch_template_id"></a> [launch\_template\_id](#output\_launch\_template\_id) | Launch template ID. |
| <a name="output_name"></a> [name](#output\_name) | Generated name of the bastion resources. The tunnel client discovers instances by the Name tag carrying this value. |
| <a name="output_security_group_id"></a> [security\_group\_id](#output\_security\_group\_id) | Security group ID attached to the bastion. Reference this from the targets you want it to reach. |
| <a name="output_session_log_group_arn"></a> [session\_log\_group\_arn](#output\_session\_log\_group\_arn) | ARN of the shell transcript log group. Null when session\_preferences\_managed is false. |
| <a name="output_session_log_group_name"></a> [session\_log\_group\_name](#output\_session\_log\_group\_name) | Log group holding interactive shell transcripts. Null when session\_preferences\_managed is false. |
| <a name="output_session_log_policy_json"></a> [session\_log\_policy\_json](#output\_session\_log\_policy\_json) | IAM policy granting the CloudWatch Logs writes Session Manager needs to<br/>stream shell transcripts. The module attaches this to the role it creates.<br/>Attach it yourself when create\_iam\_role is false, since the module cannot<br/>edit a role it does not own. |
| <a name="output_tags"></a> [tags](#output\_tags) | Tag map applied to every resource. |
| <a name="output_tunnel_config"></a> [tunnel\_config](#output\_tunnel\_config) | JSON fragment to paste into the environment block of client/tunnel.json.<br/>Carries the tags the client discovers the bastion by, so the module and the<br/>client cannot drift. |
<!-- END_TF_DOCS -->

## License

See [LICENSE](LICENSE).
