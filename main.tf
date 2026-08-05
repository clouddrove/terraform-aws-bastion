##############################################################################
# clouddrove/bastion/aws
#
# An EC2 bastion reachable only through AWS SSM Session Manager: no SSH key,
# no public IP, no inbound security group rules.
#
# Every AWS resource is created through a published CloudDrove module. This
# module composes them and declares no aws_* resources of its own. Data
# sources are reads, not resources, so the lookups below do not break that.
#
# Reading order: naming, lookups, role, security group, bastion, target access.
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
# Lookups.
#
# The AMI is resolved at launch from the SSM public parameter for the latest
# Amazon Linux 2023, matching the instance architecture. Switching between t4g
# (arm64) and t3 (x86_64) needs no other change.
##############################################################################
data "aws_ec2_instance_type" "this" {
  instance_type = var.instance_type
}

data "aws_region" "current" {}

data "aws_iam_policy_document" "trust" {
  statement {
    actions = ["sts:AssumeRole"]
    effect  = "Allow"

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

locals {
  is_arm           = contains(data.aws_ec2_instance_type.this.supported_architectures, "arm64")
  ami_architecture = local.is_arm ? "arm64" : "x86_64"
  ami_ssm_path     = "resolve:ssm:/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-${local.ami_architecture}"

  # clouddrove/ec2-autoscaling names this input iam_instance_profile_name, but
  # it feeds the "role" argument of the aws_iam_instance_profile it creates.
  # It therefore wants a ROLE name, not a profile name.
  instance_role_name = var.create_iam_role ? module.iam_role.name : var.iam_role_name

  egress_rules = concat(
    [
      {
        key         = "vpc-all"
        ip_protocol = "-1"
        cidr_ipv4   = var.vpc_cidr
        description = "All traffic to the VPC CIDR"
      },
      {
        key         = "https-out"
        ip_protocol = "tcp"
        from_port   = 443
        to_port     = 443
        cidr_ipv4   = "0.0.0.0/0"
        description = "HTTPS egress for the SSM interface endpoints and the AWS API"
      },
    ],
    [
      for cidr in var.extra_egress_cidrs : {
        key         = "extra-${replace(replace(cidr, "/", "-"), ".", "-")}"
        ip_protocol = "-1"
        cidr_ipv4   = cidr
        description = "Extra egress CIDR"
      }
    ],
  )
}

##############################################################################
# Instance role.
#
# The only managed policy is AmazonSSMManagedInstanceCore, which lets the SSM
# agent register with Systems Manager and serve Session Manager connections.
# The instance profile itself is created by clouddrove/ec2-autoscaling from
# this role's name.
##############################################################################
module "iam_role" {
  source  = "clouddrove/iam-role/aws"
  version = "1.4.0"

  enabled     = var.enabled && var.create_iam_role
  name        = var.name
  environment = var.environment
  label_order = var.label_order
  managedby   = var.managedby
  tags        = var.extra_tags

  description        = "Bastion instance role. SSM Session Manager access only."
  assume_role_policy = data.aws_iam_policy_document.trust.json

  managed_policy_arns = concat(
    ["arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"],
    var.extra_iam_policy_arns,
  )
}

##############################################################################
# Bastion security group.
#
# INBOUND: none. new_sg_ingress_rules is empty and stays empty. SSM Session
#          Manager needs no open ports because the agent dials out.
# OUTBOUND: the VPC CIDR, so the bastion can reach EKS, RDS, Redis, and
#           internal load balancers, plus 443 for the SSM endpoints, plus any
#           extra CIDRs the consumer asks for.
##############################################################################
module "security_group" {
  source  = "clouddrove/security-group/aws"
  version = "2.0.3"

  enable      = var.enabled
  name        = var.name
  environment = var.environment
  label_order = var.label_order
  managedby   = var.managedby
  tags        = var.extra_tags

  vpc_id         = var.vpc_id
  sg_description = "Bastion: no inbound, egress to the VPC and HTTPS"

  # The module's central guarantee. Do not populate this.
  new_sg_ingress_rules = []

  new_sg_egress_rules = local.egress_rules
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
#
# IMDSv2, max_instance_lifetime, and instance_refresh cannot be set through
# this module. See docs/composition-tradeoffs.md for the workarounds.
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

##############################################################################
# Optional: open the target resources' security groups to the bastion.
#
# The bastion security group already permits egress to the whole VPC, but each
# target (EKS control plane, Aurora, RDS Proxy, ElastiCache) must also permit
# INBOUND from the bastion security group. Rather than hand editing every
# target's own module, list them in target_ingress_rules.
#
# new_sg is false and existing_sg_id names the target, so the module adds rules
# to a security group it does not own.
##############################################################################
module "target_access" {
  source  = "clouddrove/security-group/aws"
  version = "2.0.3"

  for_each = var.enabled ? {
    for rule in var.target_ingress_rules :
    "${rule.security_group_id}:${rule.port}" => rule
  } : {}

  enable      = true
  name        = var.name
  environment = var.environment
  label_order = var.label_order
  managedby   = var.managedby
  tags        = var.extra_tags

  vpc_id = var.vpc_id

  # Attach rules to the target's own security group rather than creating one.
  new_sg         = false
  existing_sg_id = each.value.security_group_id

  existing_sg_ingress_rules = [
    {
      key                          = "from-bastion-${each.value.port}"
      ip_protocol                  = "tcp"
      from_port                    = each.value.port
      to_port                      = each.value.port
      referenced_security_group_id = module.security_group.security_group_id
      description                  = each.value.description
    }
  ]
}
