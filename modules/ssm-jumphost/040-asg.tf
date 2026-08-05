##############################################################################
# Auto Scaling Group.
#
# desired_capacity = 1 keeps exactly one jump host alive and self-heals if the
# instance is terminated. The client discovers it by the Name tag, which MUST
# match the pattern the tunnel script expects: "<project>-<env>-ssm-bastion".
##############################################################################
resource "aws_autoscaling_group" "this" {
  name = "${local.name}-asg"

  launch_template {
    id      = aws_launch_template.this.id
    version = "$Latest"
  }

  min_size         = 0
  max_size         = 1
  desired_capacity = 1

  vpc_zone_identifier  = var.subnet_ids
  termination_policies = ["OldestInstance"]

  # The Name tag is how the client tunnel script finds this instance.
  tag {
    key                 = "Name"
    value               = local.name
    propagate_at_launch = true
  }

  dynamic "tag" {
    for_each = local.common_tags
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
  for_each = var.schedule_enabled ? { for s in var.asg_schedules : s.name => s } : {}

  autoscaling_group_name = aws_autoscaling_group.this.name
  scheduled_action_name  = each.value.name
  min_size               = each.value.min_size
  max_size               = each.value.max_size
  desired_capacity       = each.value.desired_capacity
  recurrence             = each.value.recurrence
  time_zone              = "UTC"
}
