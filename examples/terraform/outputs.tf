output "vpc_id" {
  value = module.network.vpc_id
}

output "private_subnet_ids" {
  value = module.network.private_subnet_ids
}

output "bastion_name" {
  description = "Feed this (or the {project}-{env}-ssm-bastion pattern) into client/tunnel.json."
  value       = module.jumphost.bastion_name
}

output "jumphost_role_arn" {
  value = module.jumphost.iam_role_arn
}
