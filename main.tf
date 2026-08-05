##############################################################################
# clouddrove/bastion/aws
#
# An EC2 bastion reachable only through AWS SSM Session Manager: no SSH key,
# no public IP, no inbound security group rules.
#
# Every AWS resource is created through a published CloudDrove module. This
# module composes them and declares no aws_* resources of its own.
#
#   clouddrove/labels/aws           naming and tagging       (this file)
#   clouddrove/ec2-autoscaling/aws  launch template and ASG  (this file)
#   clouddrove/iam-role/aws         instance role            (iam.tf)
#   clouddrove/security-group/aws   bastion SG, zero ingress (security-group.tf)
#   clouddrove/security-group/aws   target SG rules          (target-access.tf)
#
# Data sources are reads, not resources, so the AMI and instance type lookups
# below do not break that rule.
##############################################################################

module "labels" {
  source  = "clouddrove/labels/aws"
  version = "1.3.1"

  enabled     = var.enabled
  name        = var.name
  environment = var.environment
  label_order = var.label_order
  attributes  = var.attributes
  managedby   = var.managedby
  repository  = var.repository
  extra_tags  = var.extra_tags
}

##############################################################################
# AMI selection.
#
# Resolved at launch from the SSM public parameter for the latest Amazon Linux
# 2023, matching the instance architecture. Switching between t4g (arm64) and
# t3 (x86_64) needs no other change.
##############################################################################
data "aws_ec2_instance_type" "this" {
  instance_type = var.instance_type
}

data "aws_region" "current" {}

locals {
  is_arm           = contains(data.aws_ec2_instance_type.this.supported_architectures, "arm64")
  ami_architecture = local.is_arm ? "arm64" : "x86_64"
  ami_ssm_path     = "resolve:ssm:/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-${local.ami_architecture}"

  # clouddrove/ec2-autoscaling names this input iam_instance_profile_name, but
  # it feeds the "role" argument of the aws_iam_instance_profile it creates.
  # It therefore wants a ROLE name, not a profile name.
  instance_role_name = var.create_iam_role ? module.iam_role.name : var.iam_role_name
}

##############################################################################
# Launch template and Auto Scaling Group.
#
# The bastion is a single instance by default. Raising desired_capacity does
# not keep an in flight tunnel alive, because SSM sessions bind to an instance
# ID and cannot fail over. What it buys is time to reconnect: immediate rather
# than waiting out an ASG replacement.
#
# on_demand_enabled must stay true. Despite its description, it gates the
# launch template and the Auto Scaling Group themselves, not just the scaling
# policies. Setting it false creates no bastion at all. The scaling policies
# and CPU alarms, which a bastion has no use for, are disabled individually.
##############################################################################
module "bastion" {
  source  = "clouddrove/ec2-autoscaling/aws"
  version = "1.3.4"

  enabled     = var.enabled
  name        = var.name
  environment = var.environment
  label_order = var.label_order
  managedby   = var.managedby
  tags        = var.extra_tags

  image_id      = local.ami_ssm_path
  instance_type = var.instance_type
  subnet_ids    = var.subnet_ids

  security_group_ids        = [module.security_group.security_group_id]
  instance_profile_enabled  = true
  iam_instance_profile_name = local.instance_role_name

  # Explicit, so the bastion never receives a public IP even when a consumer
  # passes a subnet with map_public_ip_on_launch enabled.
  associate_public_ip_address = false

  # No SSH key. Access is exclusively through SSM Session Manager.
  key_name = ""

  ebs_encryption = true
  kms_key_arn    = var.kms_key_id == null ? "" : var.kms_key_id
  volume_type    = "gp3"
  volume_size    = var.root_volume_size
  device_name    = "/dev/xvda"

  user_data_base64 = var.user_data != "" ? base64encode(var.user_data) : ""

  min_size             = var.min_size
  max_size             = var.max_size
  desired_capacity     = var.desired_capacity
  termination_policies = ["OldestInstance"]
  health_check_type    = "EC2"

  # Optional off hours schedule, disabled by default.
  schedule_enabled   = var.schedule_enabled
  scheduler_up       = var.scheduler_up
  scheduler_down     = var.scheduler_down
  time_zone          = var.schedule_time_zone
  min_size_scaleup   = var.min_size
  max_size_scaleup   = var.max_size
  scale_up_desired   = var.desired_capacity
  min_size_scaledown = 0
  max_size_scaledown = 0
  scale_down_desired = 0

  # A bastion is not a scaled fleet.
  on_demand_enabled                            = true
  spot_enabled                                 = false
  aws_autoscaling_policy_scale_up              = false
  aws_autoscaling_policy_scale_down            = false
  aws_cloudwatch_metric_alarm_enabled_cpu_high = false
  aws_cloudwatch_metric_alarm_enabled_cpu_low  = false
}
