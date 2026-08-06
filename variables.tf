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
# Session logging and audit.
##############################################################################
variable "logging_enabled" {
  type        = bool
  description = <<-EOT
    Record every Session Manager connection to the bastion in CloudWatch Logs.
    Creates the connection audit log group, an EventBridge rule that writes
    StartSession, ResumeSession, and TerminateSession events into it, and the
    CloudWatch Logs permissions the instance role needs.

    Requires a CloudTrail trail logging management events in this region.
    Session Manager emits no native EventBridge event, so the rule matches
    CloudTrail-sourced API call events, and those reach EventBridge only while a
    trail is logging them. Without a trail the log group stays empty.
  EOT
  default     = true
}

variable "log_retention_days" {
  type        = number
  description = "Retention in days for both the connection audit and the shell session log groups. 0 keeps logs forever."
  default     = 7

  validation {
    condition = contains(
      [0, 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653],
      var.log_retention_days,
    )
    error_message = "log_retention_days must be one of the retention periods CloudWatch Logs accepts."
  }
}

variable "log_kms_key_id" {
  type        = string
  description = <<-EOT
    ARN of a customer-managed KMS key encrypting both log groups. Leave null to
    use the AWS-owned key. A supplied key must carry a key policy allowing
    logs.<region>.amazonaws.com, or log group creation fails.
  EOT
  default     = null
}

variable "session_preferences_managed" {
  type        = bool
  description = <<-EOT
    Create the SSM-SessionManagerRunShell document so interactive shell sessions
    stream their full terminal output to CloudWatch Logs. Also creates the
    session log group.

    Off by default because that document is an account and region SINGLETON:
    turning this on changes shell logging for every SSM session in the region,
    not only this bastion's, and two deployments in one account collide on it.
    If the document already exists, import it before enabling:

      terraform import 'module.bastion.aws_ssm_document.session_preferences[0]' SSM-SessionManagerRunShell

    Port forwarding sessions produce no terminal output, so this setting does
    not affect what client/tunnel.sh records. Those are covered by
    logging_enabled.
  EOT
  default     = false
}

variable "session_idle_timeout_minutes" {
  type        = number
  description = "Minutes an interactive session may sit idle before Session Manager ends it. Written into the session document."
  default     = 20

  validation {
    condition     = var.session_idle_timeout_minutes >= 1 && var.session_idle_timeout_minutes <= 60
    error_message = "session_idle_timeout_minutes must be between 1 and 60."
  }
}

variable "dashboard_enabled" {
  type        = bool
  description = <<-EOT
    Create a CloudWatch dashboard showing recent sessions, sessions per
    principal, and bastion health. Has no effect when logging_enabled is false,
    since most of the dashboard queries the connection audit log group.
  EOT
  default     = true
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
