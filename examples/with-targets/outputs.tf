output "bastion_name" {
  description = "Generated bastion name, carried as the Name tag."
  value       = module.bastion.name
}

output "bastion_security_group_id" {
  description = "The source security group in every ingress rule added to the targets above."
  value       = module.bastion.security_group_id
}

output "tunnel_config" {
  description = "Paste into client/tunnel.json."
  value       = module.bastion.tunnel_config
}
