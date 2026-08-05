module "labels" {
  source  = "clouddrove/labels/aws"
  version = "1.3.1"

  name        = var.name
  environment = var.environment
  label_order = var.label_order
  attributes  = var.attributes
  managedby   = var.managedby
  repository  = var.repository
  extra_tags  = var.extra_tags
  enabled     = var.enabled
}

##############################################################################
# Launch template.
#
# - AMI resolved dynamically from the SSM public parameter for the latest
#   Amazon Linux 2023, matching the instance architecture (arm64 / x86_64).
# - IMDSv2 required (http_tokens = required).
# - No key pair, no public IP.
##############################################################################
data "aws_ec2_instance_type" "this" {
  instance_type = var.instance_type
}

locals {
  is_arm           = contains(data.aws_ec2_instance_type.this.supported_architectures, "arm64")
  ami_architecture = local.is_arm ? "arm64" : "x86_64"
  ami_ssm_path     = "resolve:ssm:/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-${local.ami_architecture}"
}

resource "aws_launch_template" "this" {
  count = var.enabled ? 1 : 0

  name                   = module.labels.id
  update_default_version = true

  image_id      = local.ami_ssm_path
  instance_type = var.instance_type

  iam_instance_profile {
    name = aws_iam_instance_profile.this[0].name
  }

  user_data = var.user_data != "" ? base64encode(var.user_data) : null

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  # Explicit, so the bastion never receives a public IP even if a consumer
  # passes a subnet with map_public_ip_on_launch enabled.
  network_interfaces {
    associate_public_ip_address = false
    delete_on_termination       = true
    security_groups             = [aws_security_group.this[0].id]
  }

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_type           = "gp3"
      volume_size           = var.root_volume_size
      encrypted             = true
      kms_key_id            = var.kms_key_id
      delete_on_termination = true
    }
  }

  dynamic "tag_specifications" {
    for_each = toset(["instance", "volume", "network-interface"])
    content {
      resource_type = tag_specifications.value
      tags          = module.labels.tags
    }
  }

  tags = module.labels.tags

  # No key_name and no network_interfaces with a public IP, SSM-only access.
}

##############################################################################
# Auto Scaling Group.
#
# desired_capacity = 1 keeps exactly one jump host alive and self-heals if the
# instance is terminated. The client discovers it by the Name tag, which
# module.labels sets to module.labels.id.
##############################################################################
resource "aws_autoscaling_group" "this" {
  count = var.enabled ? 1 : 0

  name = "${module.labels.id}-asg"

  launch_template {
    id      = aws_launch_template.this[0].id
    version = "$Latest"
  }

  min_size         = 0
  max_size         = 1
  desired_capacity = 1

  vpc_zone_identifier  = var.subnet_ids
  termination_policies = ["OldestInstance"]

  max_instance_lifetime = var.max_instance_lifetime

  dynamic "instance_refresh" {
    for_each = var.instance_refresh_enabled ? [1] : []
    content {
      strategy = "Rolling"
      preferences {
        min_healthy_percentage = 0
      }
    }
  }

  # The Name tag (set by module.labels) is how the client tunnel script finds
  # this instance.
  dynamic "tag" {
    for_each = module.labels.tags
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  # Schedules and manual scale actions may change size out of band.
  lifecycle {
    ignore_changes = [desired_capacity, min_size, max_size]
  }
}

resource "aws_autoscaling_schedule" "this" {
  for_each = var.enabled && var.schedule_enabled ? { for s in var.asg_schedules : s.name => s } : {}

  autoscaling_group_name = aws_autoscaling_group.this[0].name
  scheduled_action_name  = each.value.name
  min_size               = each.value.min_size
  max_size               = each.value.max_size
  desired_capacity       = each.value.desired_capacity
  recurrence             = each.value.recurrence
  time_zone              = "UTC"
}
