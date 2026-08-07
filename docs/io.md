## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| attributes | Additional name attributes, appended after the label\_order elements. Pass ["ssm"] for names ending in -ssm. | `list(string)` | `[]` | no |
| create\_iam\_role | Set to false to use an externally managed IAM role instead of creating one. Requires iam\_role\_name. | `bool` | `true` | no |
| dashboard\_enabled | Create a CloudWatch dashboard showing recent sessions, sessions per<br>principal, and bastion health. Has no effect when logging\_enabled is false,<br>since most of the dashboard queries the connection audit log group. | `bool` | `true` | no |
| desired\_capacity | Number of bastion instances to run. Note that SSM sessions bind to an<br>instance ID and cannot fail over, so a second instance does not keep an<br>in-flight tunnel alive. What it buys is time to reconnect: immediate rather<br>than waiting out an ASG replacement. | `number` | `1` | no |
| enabled | Set to false to prevent the module from creating any resources. | `bool` | `true` | no |
| environment | Environment name (for example dev, qa, prod). Second element of the generated resource name. | `string` | `""` | no |
| extra\_egress\_cidrs | Extra CIDR blocks the bastion may reach on any port, beyond the VPC CIDR. Usually left empty. | `list(string)` | `[]` | no |
| extra\_iam\_policy\_arns | Additional managed IAM policy ARNs to attach to the bastion role, beyond AmazonSSMManagedInstanceCore. | `list(string)` | `[]` | no |
| extra\_tags | Additional tags applied to every resource. | `map(string)` | `{}` | no |
| iam\_role\_name | Name of an existing IAM role to attach, used only when create\_iam\_role is<br>false. The role must carry AmazonSSMManagedInstanceCore or the SSM agent<br>cannot register. Note this is a role name, not an instance profile name:<br>clouddrove/ec2-autoscaling builds the instance profile from it. | `string` | `null` | no |
| instance\_type | EC2 instance type. t4g.micro (arm64) or t3.micro (x86\_64). The AMI architecture follows the type. | `string` | `"t4g.micro"` | no |
| kms\_key\_id | ARN of a customer-managed KMS key for the root volume. Leave null to use the<br>AWS-managed aws/ebs key, which is free and adequate here: the volume holds<br>only the Amazon Linux 2023 base image and the SSM agent, with no data and no<br>credentials. Set this only when a compliance requirement mandates a<br>customer-managed key, or when snapshots are shared across accounts. | `string` | `null` | no |
| label\_order | Order of elements in the generated resource name. | `list(any)` | <pre>[<br>  "name",<br>  "environment"<br>]</pre> | no |
| log\_kms\_key\_id | ARN of a customer-managed KMS key encrypting both log groups. Leave null to<br>use the AWS-owned key. A supplied key must carry a key policy allowing<br>logs.<region>.amazonaws.com, or log group creation fails. | `string` | `null` | no |
| log\_retention\_days | Retention in days for both the connection audit and the shell session log groups. 0 keeps logs forever. | `number` | `7` | no |
| logging\_enabled | Record every Session Manager connection to the bastion in CloudWatch Logs.<br>Creates the connection audit log group, an EventBridge rule that writes<br>StartSession, ResumeSession, and TerminateSession events into it, and the<br>CloudWatch Logs permissions the instance role needs.<br><br>Requires a CloudTrail trail logging management events in this region.<br>Session Manager emits no native EventBridge event, so the rule matches<br>CloudTrail-sourced API call events, and those reach EventBridge only while a<br>trail is logging them. Without a trail the log group stays empty. | `bool` | `true` | no |
| managedby | ManagedBy tag value. | `string` | `"hello@clouddrove.com"` | no |
| max\_size | Maximum ASG size. | `number` | `1` | no |
| min\_size | Minimum ASG size. | `number` | `0` | no |
| name | Name of the bastion, used as the first element of the generated resource name. | `string` | `"bastion"` | no |
| repository | Repository tag value. | `string` | `"https://github.com/clouddrove/terraform-aws-bastion"` | no |
| root\_volume\_size | Root volume size in GiB. | `number` | `8` | no |
| schedule\_enabled | Attach start and stop schedules to the ASG to save cost outside working hours. | `bool` | `false` | no |
| schedule\_time\_zone | Time zone for the schedule cron expressions. | `string` | `"UTC"` | no |
| scheduler\_down | Cron expression for scaling down to zero. Used only when schedule\_enabled is true. | `string` | `"0 19 * * *"` | no |
| scheduler\_up | Cron expression for scaling up to desired\_capacity. Used only when schedule\_enabled is true. | `string` | `"0 7 * * MON-FRI"` | no |
| session\_idle\_timeout\_minutes | Minutes an interactive session may sit idle before Session Manager ends it. Written into the session document. | `number` | `20` | no |
| session\_preferences\_managed | Create the SSM-SessionManagerRunShell document so interactive shell sessions<br>stream their full terminal output to CloudWatch Logs. Also creates the<br>session log group.<br><br>Off by default because that document is an account and region SINGLETON:<br>turning this on changes shell logging for every SSM session in the region,<br>not only this bastion's, and two deployments in one account collide on it.<br>If the document already exists, import it before enabling:<br><br>  terraform import 'module.bastion.aws\_ssm\_document.session\_preferences[0]' SSM-SessionManagerRunShell<br><br>Port forwarding sessions produce no terminal output, so this setting does<br>not affect what client/tunnel.sh records. Those are covered by<br>logging\_enabled. | `bool` | `false` | no |
| subnet\_ids | Private subnet IDs for the Auto Scaling Group. The bastion is pinned to no<br>public IP regardless, but private subnets are still the intended placement.<br><br>The VPC must reach AWS Systems Manager, either through the ssm, ssmmessages,<br>and ec2messages interface endpoints or through NAT. Without one of those the<br>SSM agent cannot register and the bastion stays invisible to Session Manager. | `list(string)` | n/a | yes |
| target\_ingress\_rules | Security groups of the resources the bastion must reach, each with the port<br>to open. The module attaches an ingress rule to every listed security group<br>allowing that port from the bastion security group, closing the inbound side<br>without editing the targets' own modules. Leave empty for a greenfield<br>deploy with no targets yet. | <pre>list(object({<br>    security_group_id = string<br>    port              = number<br>    description       = optional(string, "From SSM bastion")<br>  }))</pre> | `[]` | no |
| user\_data | Optional cloud-init user data. Empty by default, since the base AL2023 SSM agent is all that is needed. | `string` | `""` | no |
| vpc\_cidr | VPC CIDR block. The bastion is allowed egress to this range so it can reach in-VPC resources. | `string` | n/a | yes |
| vpc\_id | ID of the VPC the bastion is deployed into. | `string` | n/a | yes |

## Outputs

| Name | Description |
|------|-------------|
| audit\_log\_group\_arn | ARN of the connection audit log group. Null when logging\_enabled is false. |
| audit\_log\_group\_name | Log group holding one record per Session Manager connection: principal, target, and time. Null when logging\_enabled is false. |
| autoscaling\_group\_name | Auto Scaling Group name. |
| dashboard\_arn | ARN of the bastion CloudWatch dashboard. Null when dashboard\_enabled is false. |
| dashboard\_url | Console URL of the bastion CloudWatch dashboard. Null when dashboard\_enabled is false. |
| iam\_role\_arn | ARN of the bastion IAM role. Null when create\_iam\_role is false. |
| iam\_role\_name | Name of the bastion IAM role. Null when create\_iam\_role is false. |
| launch\_template\_id | Launch template ID. |
| name | Generated name of the bastion resources. The tunnel client discovers instances by the Name tag carrying this value. |
| security\_group\_id | Security group ID attached to the bastion. Reference this from the targets you want it to reach. |
| session\_log\_group\_arn | ARN of the shell transcript log group. Null when session\_preferences\_managed is false. |
| session\_log\_group\_name | Log group holding interactive shell transcripts. Null when session\_preferences\_managed is false. |
| session\_log\_policy\_json | IAM policy granting the CloudWatch Logs writes Session Manager needs to<br>stream shell transcripts. The module attaches this to the role it creates.<br>Attach it yourself when create\_iam\_role is false, since the module cannot<br>edit a role it does not own. |
| tags | Tag map applied to every resource. |
| tunnel\_config | JSON fragment to paste into the environment block of client/tunnel.json.<br>Carries the tags the client discovers the bastion by, so the module and the<br>client cannot drift. |

