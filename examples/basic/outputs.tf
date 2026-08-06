output "bastion_name" {
  description = "Generated bastion name, carried as the Name tag. The tunnel client discovers the instance by this."
  value       = module.bastion.name
}

output "bastion_security_group_id" {
  description = "Reference this from the targets you want the bastion to reach."
  value       = module.bastion.security_group_id
}

output "audit_log_group_name" {
  description = "Log group recording who connected, when, and to which target."
  value       = module.bastion.audit_log_group_name
}

output "dashboard_url" {
  description = "Console URL of the bastion dashboard."
  value       = module.bastion.dashboard_url
}

output "tunnel_config" {
  description = "Paste into client/tunnel.json."
  value       = module.bastion.tunnel_config
}
