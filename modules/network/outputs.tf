output "vpc_id" {
  description = "ID of the created VPC."
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "CIDR block of the VPC."
  value       = aws_vpc.this.cidr_block
}

output "private_subnet_ids" {
  description = "IDs of the private subnets (feed these to the ssm-jumphost module)."
  value       = aws_subnet.private[*].id
}

output "public_subnet_ids" {
  description = "IDs of the public subnets (empty unless enable_nat = true)."
  value       = aws_subnet.public[*].id
}

output "availability_zones" {
  description = "AZs the subnets were spread across."
  value       = local.azs
}
