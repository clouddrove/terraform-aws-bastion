output "name" {
  description = "Generated name of the bastion resources. The client discovers instances by the Name tag carrying this value."
  value       = module.labels.id
}

output "tags" {
  description = "Tag map applied to every resource."
  value       = module.labels.tags
}

output "iam_role_arn" {
  description = "ARN of the jump host IAM role."
  value       = aws_iam_role.this.arn
}

output "iam_role_name" {
  description = "Name of the jump host IAM role."
  value       = aws_iam_role.this.name
}

output "security_group_id" {
  description = "Security group ID attached to the jump host."
  value       = aws_security_group.this.id
}

output "asg_name" {
  description = "Auto Scaling Group name."
  value       = aws_autoscaling_group.this.name
}

output "launch_template_id" {
  description = "Launch template ID."
  value       = aws_launch_template.this.id
}
