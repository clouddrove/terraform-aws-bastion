variable "name_prefix" {
  type        = string
  description = "Prefix for all resource names, e.g. \"myproject-dev\"."
}

variable "vpc_cidr" {
  type        = string
  description = "CIDR block for the VPC (e.g. 10.60.0.0/16)."
  default     = "10.60.0.0/16"
}

variable "az_count" {
  type        = number
  description = "Number of Availability Zones to spread subnets across."
  default     = 2

  validation {
    condition     = var.az_count >= 1 && var.az_count <= 4
    error_message = "az_count must be between 1 and 4."
  }
}

variable "enable_nat" {
  type        = bool
  description = <<-EOT
    When true, creates public subnets, an Internet Gateway, and a NAT Gateway so
    the private subnets have outbound internet access. Left false, the jump host
    reaches AWS SSM purely through the VPC interface endpoints below (no internet
    exposure, lower cost). Enable only if the jump host itself needs outbound
    internet (e.g. to pull external packages).
  EOT
  default     = false
}

variable "single_nat_gateway" {
  type        = bool
  description = "When enable_nat is true, use a single NAT Gateway shared by all AZs instead of one per AZ."
  default     = true
}

variable "create_ssm_endpoints" {
  type        = bool
  description = <<-EOT
    Create the interface VPC endpoints (ssm, ssmmessages, ec2messages) plus the
    S3 gateway endpoint that let the SSM agent connect without internet access.
    Required when enable_nat is false. Set false only if the VPC already has
    equivalent endpoints.
  EOT
  default     = true
}

variable "tags" {
  type        = map(string)
  description = "Additional tags applied to every resource."
  default     = {}
}
