output "bastion_name" {
  description = "Generated bastion name, carried as the Name tag."
  value       = module.bastion.name
}

output "audit_log_group_name" {
  description = "Who connected, when, and to which target. Covers every session type, including port forwards."
  value       = module.bastion.audit_log_group_name
}

output "session_log_group_name" {
  description = "Interactive shell transcripts. The log stream name carries the session ID and the principal."
  value       = module.bastion.session_log_group_name
}

output "dashboard_url" {
  description = "Console URL of the bastion dashboard. Its transcript widget is populated in this configuration."
  value       = module.bastion.dashboard_url
}
