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

variable "log_kms_key_id" {
  type        = string
  description = <<-EOT
    ARN of a customer-managed KMS key for both log groups. Leave null to use the
    AWS-owned key. A supplied key needs a key policy allowing
    logs.<region>.amazonaws.com, or log group creation fails.
  EOT
  default     = null
}
