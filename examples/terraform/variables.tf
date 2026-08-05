variable "aws_region" {
  type        = string
  description = "AWS region to deploy into."
  default     = "eu-west-1"
}

variable "aws_profile" {
  type        = string
  description = "Named AWS profile (or SSO profile) used by Terraform to deploy."
  default     = "myorg-dev-admin"
}

variable "project_name" {
  type        = string
  description = "Project / product name."
  default     = "myproject"
}

variable "environment" {
  type        = string
  description = "Environment name."
  default     = "dev"
}

variable "vpc_cidr" {
  type        = string
  description = "CIDR block for the VPC created by this example."
  default     = "10.60.0.0/16"
}

variable "instance_type" {
  type        = string
  description = "Jump host instance type."
  default     = "t4g.micro"
}

variable "enable_nat" {
  type        = bool
  description = "Give the jump host outbound internet via NAT (default false; SSM endpoints are used instead)."
  default     = false
}
