##############################################################################
# Transcripts example: record what people type, not only that they connected.
#
# READ THIS BEFORE APPLYING.
#
# session_preferences_managed = true creates SSM-SessionManagerRunShell, which
# is an account and region SINGLETON. It governs shell logging for every SSM
# session in the region, not only this bastion's, and two deployments in one
# account collide on it. Apply this in an account where that is what you want.
#
# If the document already exists, import it first or the apply fails:
#
#   terraform import 'module.bastion.aws_ssm_document.session_preferences[0]' \
#     SSM-SessionManagerRunShell
#
# What this does NOT change: port forwarding sessions, which is what
# client/tunnel.sh opens, carry no terminal output and so produce no
# transcript. They are covered by the connection audit log group, which is on
# by default and needs none of this.
##############################################################################

module "bastion" {
  source = "../../"

  name        = var.name
  environment = var.environment
  attributes  = ["ssm"]

  vpc_id     = var.vpc_id
  vpc_cidr   = var.vpc_cidr
  subnet_ids = var.subnet_ids

  # Connection auditing, on by default. Needs a CloudTrail trail logging
  # management events in this region, since Session Manager publishes no native
  # EventBridge event.
  logging_enabled = true

  # Full terminal transcripts for interactive shells. See the warning above.
  session_preferences_managed  = true
  session_idle_timeout_minutes = 15

  # Transcripts hold whatever was typed, so they are worth keeping longer than
  # the 7 day default and worth a customer-managed key if your policy calls for
  # one. Log groups are always encrypted; a key changes who controls it.
  log_retention_days = 30
  log_kms_key_id     = var.log_kms_key_id
}
