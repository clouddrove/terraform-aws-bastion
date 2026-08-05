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

variable "vpc_cidr" {
  type        = string
  description = "CIDR for the VPC this example creates."
  default     = "10.60.0.0/16"
}

variable "instance_type" {
  type        = string
  description = "Bastion instance type."
  default     = "t4g.micro"
}
