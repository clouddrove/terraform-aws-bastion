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
  description = "CIDR of that VPC. The bastion is allowed egress to this range so it can reach in-VPC resources."
}

variable "subnet_ids" {
  type        = list(string)
  description = "Existing private subnet IDs for the Auto Scaling Group."
}
