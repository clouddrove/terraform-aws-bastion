output "name" {
  description = "Generated name of the bastion resources. The tunnel client discovers instances by the Name tag carrying this value."
  value       = module.labels.id
}

output "tags" {
  description = "Tag map applied to every resource."
  value       = module.labels.tags
}

output "security_group_id" {
  description = "Security group ID attached to the bastion. Reference this from the targets you want it to reach."
  value       = module.security_group.security_group_id
}

output "iam_role_arn" {
  description = "ARN of the bastion IAM role. Null when create_iam_role is false."
  value       = var.create_iam_role ? module.iam_role.arn : null
}

output "iam_role_name" {
  description = "Name of the bastion IAM role. Null when create_iam_role is false."
  value       = var.create_iam_role ? module.iam_role.name : null
}

output "autoscaling_group_name" {
  description = "Auto Scaling Group name."
  value       = module.bastion.autoscaling_group_name
}

output "launch_template_id" {
  description = "Launch template ID."
  value       = module.bastion.launch_template_id
}

output "audit_log_group_name" {
  description = "Log group holding one record per Session Manager connection: principal, target, and time. Null when logging_enabled is false."
  value       = local.audit_logging_enabled ? aws_cloudwatch_log_group.audit[0].name : null
}

output "audit_log_group_arn" {
  description = "ARN of the connection audit log group. Null when logging_enabled is false."
  value       = local.audit_logging_enabled ? aws_cloudwatch_log_group.audit[0].arn : null
}

output "session_log_group_name" {
  description = "Log group holding interactive shell transcripts. Null when session_preferences_managed is false."
  value       = local.session_logging_enabled ? aws_cloudwatch_log_group.session[0].name : null
}

output "session_log_group_arn" {
  description = "ARN of the shell transcript log group. Null when session_preferences_managed is false."
  value       = local.session_logging_enabled ? aws_cloudwatch_log_group.session[0].arn : null
}

output "dashboard_arn" {
  description = "ARN of the bastion CloudWatch dashboard. Null when dashboard_enabled is false."
  value       = local.dashboard_enabled ? module.dashboard.dashboard_arn : null
}

output "dashboard_url" {
  description = "Console URL of the bastion CloudWatch dashboard. Null when dashboard_enabled is false."
  value = local.dashboard_enabled ? format(
    "https://%s.console.aws.amazon.com/cloudwatch/home?region=%s#dashboards:name=%s",
    data.aws_region.current.region,
    data.aws_region.current.region,
    module.labels.id,
  ) : null
}

output "session_log_policy_json" {
  description = <<-EOT
    IAM policy granting the CloudWatch Logs writes Session Manager needs to
    stream shell transcripts. The module attaches this to the role it creates.
    Attach it yourself when create_iam_role is false, since the module cannot
    edit a role it does not own.
  EOT
  value       = data.aws_iam_policy_document.session_logs.json
}

output "tunnel_config" {
  description = <<-EOT
    JSON fragment to paste into the environment block of client/tunnel.json.
    Carries the tags the client discovers the bastion by, so the module and the
    client cannot drift.
  EOT
  value = jsonencode({
    region = data.aws_region.current.region
    bastion = {
      tags = { Name = module.labels.id }
    }
  })
}
