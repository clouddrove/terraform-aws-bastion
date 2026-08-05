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
