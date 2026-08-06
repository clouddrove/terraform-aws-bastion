output "bastion_name" {
  description = "Generated bastion name, carried as the Name tag."
  value       = module.bastion.name
}

output "bastion_security_group_id" {
  description = "Reference this from the targets you want the bastion to reach."
  value       = module.bastion.security_group_id
}

output "tunnel_config" {
  description = "Paste into client/tunnel.json."
  value       = module.bastion.tunnel_config
}
