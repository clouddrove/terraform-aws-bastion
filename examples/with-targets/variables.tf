variable "region" {
  type        = string
  description = "AWS region."
  default     = "eu-west-1"
}

variable "name" {
  type        = string
  description = "Name prefix for every resource."
  default     = "myproject"
}

variable "environment" {
  type        = string
  description = "Environment name."
  default     = "dev"
}

variable "vpc_id" {
  type        = string
  description = "ID of the existing VPC to place the bastion in."
}

variable "vpc_cidr" {
  type        = string
  description = "CIDR of that VPC."
}

variable "subnet_ids" {
  type        = list(string)
  description = "Existing private subnet IDs for the Auto Scaling Group."
}

variable "eks_security_group_id" {
  type        = string
  description = "Security group of the EKS control plane, opened on 443 to the bastion."
}

variable "aurora_security_group_id" {
  type        = string
  description = "Security group of the Aurora cluster, opened on 5432 to the bastion."
}

variable "redis_security_group_id" {
  type        = string
  description = "Security group of the ElastiCache cluster, opened on 6379 to the bastion."
}
