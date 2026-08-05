##############################################################################
# Naming and tagging, passed through to clouddrove/labels/aws.
##############################################################################
variable "enabled" {
  type        = bool
  description = "Set to false to prevent the module from creating any resources."
  default     = true
}

variable "name" {
  type        = string
  description = "Name of the bastion, used as the first element of the generated resource name."
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
  description = "Additional name attributes, appended after the label_order elements. Pass [\"ssm\"] for names ending in -ssm."
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

##############################################################################
# Network placement.
##############################################################################
variable "vpc_id" {
  type        = string
  description = "ID of the VPC the bastion is deployed into."
}

variable "vpc_cidr" {
  type        = string
  description = "VPC CIDR block. The bastion is allowed egress to this range so it can reach in-VPC resources."
}

variable "subnet_ids" {
  type        = list(string)
  description = <<-EOT
    Private subnet IDs for the Auto Scaling Group. The bastion is pinned to no
    public IP regardless, but private subnets are still the intended placement.

    The VPC must reach AWS Systems Manager, either through the ssm, ssmmessages,
    and ec2messages interface endpoints or through NAT. Without one of those the
    SSM agent cannot register and the bastion stays invisible to Session Manager.
  EOT
}

##############################################################################
# Instance.
##############################################################################
variable "instance_type" {
  type        = string
  description = "EC2 instance type. t4g.micro (arm64) or t3.micro (x86_64). The AMI architecture follows the type."
  default     = "t4g.micro"
}

variable "root_volume_size" {
  type        = number
  description = "Root volume size in GiB."
  default     = 8
}

variable "kms_key_id" {
  type        = string
  description = <<-EOT
    ARN of a customer-managed KMS key for the root volume. Leave null to use the
    AWS-managed aws/ebs key, which is free and adequate here: the volume holds
    only the Amazon Linux 2023 base image and the SSM agent, with no data and no
    credentials. Set this only when a compliance requirement mandates a
    customer-managed key, or when snapshots are shared across accounts.
  EOT
  default     = null
}

variable "user_data" {
  type        = string
  description = "Optional cloud-init user data. Empty by default, since the base AL2023 SSM agent is all that is needed."
  default     = ""
}

##############################################################################
# Capacity.
##############################################################################
variable "min_size" {
  type        = number
  description = "Minimum ASG size."
  default     = 0
}

variable "max_size" {
  type        = number
  description = "Maximum ASG size."
  default     = 1
}

variable "desired_capacity" {
  type        = number
  description = <<-EOT
    Number of bastion instances to run. Note that SSM sessions bind to an
    instance ID and cannot fail over, so a second instance does not keep an
    in-flight tunnel alive. What it buys is time to reconnect: immediate rather
    than waiting out an ASG replacement.
  EOT
  default     = 1
}

##############################################################################
# Optional off hours schedule.
##############################################################################
variable "schedule_enabled" {
  type        = bool
  description = "Attach start and stop schedules to the ASG to save cost outside working hours."
  default     = false
}

variable "scheduler_up" {
  type        = string
  description = "Cron expression for scaling up to desired_capacity. Used only when schedule_enabled is true."
  default     = "0 7 * * MON-FRI"
}

variable "scheduler_down" {
  type        = string
  description = "Cron expression for scaling down to zero. Used only when schedule_enabled is true."
  default     = "0 19 * * *"
}

variable "schedule_time_zone" {
  type        = string
  description = "Time zone for the schedule cron expressions."
  default     = "UTC"
}

##############################################################################
# IAM.
##############################################################################
variable "create_iam_role" {
  type        = bool
  description = "Set to false to use an externally managed IAM role instead of creating one. Requires iam_role_name."
  default     = true
}

variable "iam_role_name" {
  type        = string
  description = <<-EOT
    Name of an existing IAM role to attach, used only when create_iam_role is
    false. The role must carry AmazonSSMManagedInstanceCore or the SSM agent
    cannot register. Note this is a role name, not an instance profile name:
    clouddrove/ec2-autoscaling builds the instance profile from it.
  EOT
  default     = null

  validation {
    condition     = var.create_iam_role || var.iam_role_name != null
    error_message = "iam_role_name is required when create_iam_role is false."
  }
}

variable "extra_iam_policy_arns" {
  type        = list(string)
  description = "Additional managed IAM policy ARNs to attach to the bastion role, beyond AmazonSSMManagedInstanceCore."
  default     = []
}

##############################################################################
# Connectivity to targets.
##############################################################################
variable "extra_egress_cidrs" {
  type        = list(string)
  description = "Extra CIDR blocks the bastion may reach on any port, beyond the VPC CIDR. Usually left empty."
  default     = []
}

variable "target_ingress_rules" {
  type = list(object({
    security_group_id = string
    port              = number
    description       = optional(string, "From SSM bastion")
  }))
  description = <<-EOT
    Security groups of the resources the bastion must reach, each with the port
    to open. The module attaches an ingress rule to every listed security group
    allowing that port from the bastion security group, closing the inbound side
    without editing the targets' own modules. Leave empty for a greenfield
    deploy with no targets yet.
  EOT
  default     = []
}
