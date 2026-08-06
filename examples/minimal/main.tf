##############################################################################
# Minimal example: bastion only, no logging, no dashboard.
#
# For accounts that already pipe CloudTrail somewhere central and do not want a
# second copy of the same events, or that keep observability in a separate
# stack. This creates the bastion, its role, and its security group, and
# nothing else.
#
# What you give up: the connection audit log group, the EventBridge rule, and
# the dashboard. Who connected and when is still recorded, in CloudTrail, but
# nothing in this module surfaces it. dashboard_enabled has no effect once
# logging_enabled is false, since most of the dashboard queries the audit log
# group, but it is set here to make the intent explicit.
##############################################################################

module "bastion" {
  source = "../../"

  name        = var.name
  environment = var.environment
  attributes  = ["ssm"]

  vpc_id     = var.vpc_id
  vpc_cidr   = var.vpc_cidr
  subnet_ids = var.subnet_ids

  logging_enabled   = false
  dashboard_enabled = false
}
