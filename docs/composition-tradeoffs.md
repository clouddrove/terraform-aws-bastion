# What composing CloudDrove modules costs, and how to cover it

This module creates every AWS resource through a published CloudDrove module
rather than declaring `aws_*` resources itself. That is a deliberate choice.
It also means the module can only express what those modules expose.

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

## If these gaps matter more than the composition

The alternative is declaring `aws_launch_template` and `aws_autoscaling_group`
directly, which restores all three properties. The trade is that the module then
owns those resources rather than composing them. Raising the missing inputs
against `clouddrove/terraform-aws-ec2-autoscaling` would fix it for every
consumer of that module, not just this one.
