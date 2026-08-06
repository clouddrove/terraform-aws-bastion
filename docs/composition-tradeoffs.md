# What composing CloudDrove modules costs, and how to cover it

This module creates every AWS resource through a published CloudDrove module
rather than declaring `aws_*` resources itself, with one documented exception
covered at the end of this page. That is a deliberate choice. It also means the
module can only express what those modules expose.

Three properties the previous raw-resource version enforced cannot be set
through `clouddrove/ec2-autoscaling/aws` 1.3.4. Verified by reading the module
source, not its registry documentation.

## 1. IMDSv2 cannot be required

The module has no `metadata_options` block and no `http_tokens` input, so the
launch template it builds leaves instance metadata at the account default. On an
account that has never been configured, that default is IMDSv1 optional, which
is the weaker setting.

**Cover it at the account level.** AWS supports a region-wide default for new
instances, which is stronger than a per-launch-template setting because it also
catches anything launched outside this module:

```bash
aws ec2 modify-instance-metadata-defaults \
  --http-tokens required \
  --http-put-response-hop-limit 1 \
  --region eu-west-1
```

Confirm it took effect:

```bash
aws ec2 get-instance-metadata-defaults --region eu-west-1
```

Run this once per account and region before deploying. There is also a
`aws_ec2_instance_metadata_defaults` Terraform resource if you would rather
manage it as code, though that is a raw `aws_*` resource.

## 2. No automatic AMI rotation

The module has no `max_instance_lifetime` and no `instance_refresh` input, so a
bastion instance runs until something replaces it.

This matters more here than on a normal host. A bastion in a private subnet with
no NAT gateway cannot reach package repositories, so it cannot patch in place.
Replacing the instance from a newer AMI is the only patching route.

**Cover it operationally.** Either:

- Start an instance refresh on a schedule, from CI or an EventBridge rule:
  ```bash
  aws autoscaling start-instance-refresh \
    --auto-scaling-group-name "$(terraform output -raw autoscaling_group_name)" \
    --preferences MinHealthyPercentage=0
  ```
  `MinHealthyPercentage=0` is required at `desired_capacity = 1`. Any higher
  value deadlocks, because the group cannot hold a healthy instance while
  replacing its only one.

- Or enable the off hours schedule (`schedule_enabled = true`). The instance is
  destroyed and recreated daily, which picks up the latest AMI as a side effect
  and roughly halves the cost.

## 3. No rolling replacement on template change

Without `instance_refresh`, changing the instance type or user data updates the
launch template but leaves the running instance on the old version. Use the
`start-instance-refresh` command above, or terminate the instance and let the
Auto Scaling Group replace it.

## Two module quirks worth knowing

**`iam_instance_profile_name` takes a role name.** It feeds the `role` argument
of the `aws_iam_instance_profile` the module creates, so it wants the IAM role's
name and not a profile name. This module passes `module.iam_role.name`.

**`on_demand_enabled` must stay `true`.** Its description says it controls
whether scaling policies and CPU alarms are created. It does not: it gates the
launch template and the Auto Scaling Group themselves. Setting it `false`
creates no bastion at all. The scaling policies and alarms are disabled through
their own flags instead.

## The one exception: four raw resources for session logging

The CloudDrove registry has no module for a CloudWatch log group, an SSM
document, or a log group resource policy. Session logging therefore declares
four `aws_*` resources directly:

| Resource | Why no module |
| --- | --- |
| `aws_cloudwatch_log_group.audit` | No `clouddrove/cloudwatch-logs/aws` exists. The registry has `cloudwatch-alarms`, `cloudwatch-dashboard`, `cloudwatch-event-rule`, and `cloudwatch-synthetics`, but no log group module |
| `aws_cloudwatch_log_group.session` | Same |
| `aws_cloudwatch_log_resource_policy.events_to_audit_log` | Same. EventBridge cannot write to a log group without it |
| `aws_ssm_document.session_preferences` | No CloudDrove SSM document module |

Everything else in that feature is composed as usual: the EventBridge rule and
its target come from `clouddrove/cloudwatch-event-rule`, the dashboard from
`clouddrove/cloudwatch-dashboard`, and the instance role's CloudWatch Logs
permissions ride on the existing `clouddrove/iam-role` through its inline
`policy` input.

Publishing `clouddrove/terraform-aws-cloudwatch-logs` would close three of the
four. The SSM document is a single resource with no reusable surface worth a
module.

### Three quirks in `clouddrove/cloudwatch-event-rule` 1.0.2

**Its rule name ignores `attributes`.** It pins `clouddrove/labels/aws` 1.3.0
and does not pass `attributes` through, so the rule is named
`<name>-<environment>` while every other resource here carries the attribute
suffix, for example `myproject-dev` against `myproject-dev-ssm`. Cosmetic, but
it makes the rule sort away from the rest in the console.


**Its `arn` output is a list, not a string.** The rule is count-gated and the
output is `aws_cloudwatch_event_rule.default.*.arn`. The log group resource
policy passes it straight into the `aws:SourceArn` condition values rather than
wrapping it.

**It always renders an `input_transformer` block.** Leaving `input_template`
empty would be rejected by the API, so a transformer is not optional here. This
module supplies one that flattens the CloudTrail envelope into a single audit
record per event. Every placeholder in the template is quoted, because a path
absent from a given event, such as `requestParameters.target` on
`TerminateSession`, would otherwise leave a hole where valid JSON must be.

## If these gaps matter more than the composition

The alternative is declaring `aws_launch_template` and `aws_autoscaling_group`
directly, which restores all three properties. The trade is that the module then
owns those resources rather than composing them. Raising the missing inputs
against `clouddrove/terraform-aws-ec2-autoscaling` would fix it for every
consumer of that module, not just this one.
