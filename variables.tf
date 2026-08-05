variable "name" {
  type        = string
  description = "Name of the bastion, used as the first element of the generated resource name (for example \"bastion\")."
  default     = "bastion"
}

variable "environment" {
  type        = string
  description = "Environment name (for example dev, qa, prod). Second element of the generated resource name."
  default     = ""
}

variable "label_order" {
  type        = list(any)
  description = "Order of elements in the generated resource name."
  default     = ["name", "environment"]
}

variable "attributes" {
  type        = list(string)
  description = "Additional name attributes, appended after label_order elements. Pass [\"ssm\"] to get names ending in -ssm."
  default     = []
}

variable "managedby" {
  type        = string
  description = "ManagedBy tag value."
  default     = "hello@clouddrove.com"
}

variable "repository" {
  type        = string
  description = "Repository tag value."
  default     = "https://github.com/clouddrove/terraform-aws-bastion"
}

variable "extra_tags" {
  type        = map(string)
  description = "Additional tags applied to every resource."
  default     = {}
}

variable "vpc_id" {
  type        = string
  description = "ID of the VPC the jump host is deployed into."
}

variable "subnet_ids" {
  type        = list(string)
  description = "Private subnet IDs for the Auto Scaling Group. The jump host gets no public IP."
}

variable "instance_type" {
  type        = string
  description = "EC2 instance type. t3.micro (x86_64) / t4g.micro (arm64) are ample for tunneling."
  default     = "t4g.micro"
}

variable "extra_egress_cidrs" {
  type        = list(string)
  description = <<-EOT
    Extra CIDR blocks the jump host may reach on any port, beyond the VPC CIDR
    (which is always allowed so it can reach EKS/RDS/Redis). Usually left empty.
  EOT
  default     = []
}

variable "vpc_cidr" {
  type        = string
  description = "VPC CIDR block. The jump host is allowed egress to this range so it can reach in-VPC resources."
}

variable "extra_iam_policy_arns" {
  type        = list(string)
  description = "Additional managed IAM policy ARNs to attach to the jump host role (beyond AmazonSSMManagedInstanceCore)."
  default     = []
}

variable "target_ingress_rules" {
  type = list(object({
    security_group_id = string
    port              = number
    description       = optional(string, "From SSM jump host")
  }))
  description = <<-EOT
    Security groups of the resources the jump host must reach, each with the port
    to open. The module attaches an ingress rule to every listed SG allowing that
    port from the jump host SG — closing the inbound side without editing the
    targets' own modules. Leave empty for a greenfield deploy with no targets yet.
  EOT
  default     = []
}

variable "user_data" {
  type        = string
  description = "Optional cloud-init user-data. Empty by default — the base AL2023 SSM agent is all that is needed."
  default     = ""
}

variable "schedule_enabled" {
  type        = bool
  description = "Attach start/stop schedules to the ASG to save cost outside working hours."
  default     = false
}

variable "asg_schedules" {
  type = list(object({
    name             = string
    min_size         = number
    max_size         = number
    desired_capacity = number
    recurrence       = string # cron expression, UTC
  }))
  description = "ASG scheduled actions. Only used when schedule_enabled is true."
  default     = []
}

