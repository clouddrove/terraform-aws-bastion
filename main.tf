##############################################################################
# clouddrove/bastion/aws
#
# An EC2 bastion reachable only through AWS SSM Session Manager: no SSH key,
# no public IP, no inbound security group rules.
#
# Every AWS resource is created through a published CloudDrove module, with one
# documented exception: the session logging block declares four aws_* resources
# directly, because no published CloudDrove module covers a log group, an SSM
# document, or a log group resource policy. See docs/composition-tradeoffs.md.
# Data sources are reads, not resources, so the lookups below do not count.
#
# Reading order: naming, lookups, role, security group, bastion, target access,
# session logging, dashboard.
##############################################################################

module "labels" {
  source  = "clouddrove/labels/aws"
  version = "1.3.1"

  enabled     = var.enabled
  name        = var.name
  environment = var.environment
  label_order = var.label_order
  attributes  = var.attributes
  managedby   = var.managedby
  repository  = var.repository
  extra_tags  = var.extra_tags
}

##############################################################################
# Lookups.
#
# The AMI is resolved at launch from the SSM public parameter for the latest
# Amazon Linux 2023, matching the instance architecture. Switching between t4g
# (arm64) and t3 (x86_64) needs no other change.
##############################################################################
data "aws_ec2_instance_type" "this" {
  instance_type = var.instance_type
}

data "aws_region" "current" {}

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

data "aws_iam_policy_document" "trust" {
  statement {
    actions = ["sts:AssumeRole"]
    effect  = "Allow"

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

# AmazonSSMManagedInstanceCore does not grant CloudWatch Logs writes, so shell
# session streaming needs this on top of it. Published as an output too, for
# consumers that bring their own role.
data "aws_iam_policy_document" "session_logs" {
  statement {
    sid       = "DescribeLogGroups"
    actions   = ["logs:DescribeLogGroups"]
    effect    = "Allow"
    resources = ["*"]
  }

  statement {
    sid    = "WriteSessionTranscripts"
    effect = "Allow"

    actions = [
      "logs:CreateLogStream",
      "logs:DescribeLogStreams",
      "logs:PutLogEvents",
    ]

    resources = [
      "${local.session_log_group_arn_prefix}*",
      "${local.session_log_group_arn_prefix}*:log-stream:*",
    ]
  }
}

locals {
  is_arm           = contains(data.aws_ec2_instance_type.this.supported_architectures, "arm64")
  ami_architecture = local.is_arm ? "arm64" : "x86_64"
  ami_ssm_path     = "resolve:ssm:/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-${local.ami_architecture}"

  # clouddrove/ec2-autoscaling names this input iam_instance_profile_name, but
  # it feeds the "role" argument of the aws_iam_instance_profile it creates.
  # It therefore wants a ROLE name, not a profile name.
  instance_role_name = var.create_iam_role ? module.iam_role.name : var.iam_role_name

  # Connection auditing and shell transcript logging are gated separately: the
  # audit path needs nothing on the instance, while the transcript path takes
  # over an account-wide SSM document.
  audit_logging_enabled   = var.enabled && var.logging_enabled
  session_logging_enabled = local.audit_logging_enabled && var.session_preferences_managed
  dashboard_enabled       = local.audit_logging_enabled && var.dashboard_enabled

  audit_log_group_name   = "/aws/bastion/${module.labels.id}/connections"
  session_log_group_name = "/aws/ssm/session/${module.labels.id}"

  # Session Manager writes shell output under /aws/ssm/session/. The instance
  # role is scoped to that prefix rather than to the log group this module
  # creates, so the permission still holds when the account configures its own
  # session document and session_preferences_managed stays false.
  session_log_group_arn_prefix = "arn:${data.aws_partition.current.partition}:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/ssm/session/"

  egress_rules = concat(
    [
      {
        key         = "vpc-all"
        ip_protocol = "-1"
        cidr_ipv4   = var.vpc_cidr
        description = "All traffic to the VPC CIDR"
      },
      {
        key         = "https-out"
        ip_protocol = "tcp"
        from_port   = 443
        to_port     = 443
        cidr_ipv4   = "0.0.0.0/0"
        description = "HTTPS egress for the SSM interface endpoints and the AWS API"
      },
    ],
    [
      for cidr in var.extra_egress_cidrs : {
        key         = "extra-${replace(replace(cidr, "/", "-"), ".", "-")}"
        ip_protocol = "-1"
        cidr_ipv4   = cidr
        description = "Extra egress CIDR"
      }
    ],
  )
}

##############################################################################
# Instance role.
#
# The only managed policy is AmazonSSMManagedInstanceCore, which lets the SSM
# agent register with Systems Manager and serve Session Manager connections.
# The instance profile itself is created by clouddrove/ec2-autoscaling from
# this role's name.
##############################################################################
module "iam_role" {
  source  = "clouddrove/iam-role/aws"
  version = "1.4.0"

  enabled     = var.enabled && var.create_iam_role
  name        = var.name
  environment = var.environment
  label_order = var.label_order
  managedby   = var.managedby
  repository  = var.repository
  tags        = var.extra_tags

  description        = "Bastion instance role. SSM Session Manager access only."
  assume_role_policy = data.aws_iam_policy_document.trust.json

  managed_policy_arns = concat(
    ["arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"],
    var.extra_iam_policy_arns,
  )

  policy_enabled = local.audit_logging_enabled
  policy         = data.aws_iam_policy_document.session_logs.json
}

##############################################################################
# Bastion security group.
#
# INBOUND: none. new_sg_ingress_rules is empty and stays empty. SSM Session
#          Manager needs no open ports because the agent dials out.
# OUTBOUND: the VPC CIDR, so the bastion can reach EKS, RDS, Redis, and
#           internal load balancers, plus 443 for the SSM endpoints, plus any
#           extra CIDRs the consumer asks for.
##############################################################################
module "security_group" {
  source  = "clouddrove/security-group/aws"
  version = "2.0.3"

  enable      = var.enabled
  name        = var.name
  environment = var.environment
  label_order = var.label_order
  managedby   = var.managedby
  repository  = var.repository
  tags        = var.extra_tags

  vpc_id         = var.vpc_id
  sg_description = "Bastion: no inbound, egress to the VPC and HTTPS"

  # The module's central guarantee. Do not populate this.
  new_sg_ingress_rules = []

  new_sg_egress_rules = local.egress_rules
}

##############################################################################
# Launch template and Auto Scaling Group.
#
# The bastion is a single instance by default. Raising desired_capacity does
# not keep an in flight tunnel alive, because SSM sessions bind to an instance
# ID and cannot fail over. What it buys is time to reconnect: immediate rather
# than waiting out an ASG replacement.
#
# on_demand_enabled must stay true. Despite its description, it gates the
# launch template and the Auto Scaling Group themselves, not just the scaling
# policies. Setting it false creates no bastion at all. The scaling policies
# and CPU alarms, which a bastion has no use for, are disabled individually.
#
# IMDSv2, max_instance_lifetime, and instance_refresh cannot be set through
# this module. See docs/composition-tradeoffs.md for the workarounds.
##############################################################################
module "bastion" {
  source  = "clouddrove/ec2-autoscaling/aws"
  version = "1.4.0"

  enabled     = var.enabled
  name        = var.name
  environment = var.environment
  label_order = var.label_order
  managedby   = var.managedby
  repository  = var.repository
  tags        = var.extra_tags

  image_id      = local.ami_ssm_path
  instance_type = var.instance_type
  subnet_ids    = var.subnet_ids

  security_group_ids        = [module.security_group.security_group_id]
  instance_profile_enabled  = true
  iam_instance_profile_name = local.instance_role_name

  # Explicit, so the bastion never receives a public IP even when a consumer
  # passes a subnet with map_public_ip_on_launch enabled.
  associate_public_ip_address = false

  # No SSH key. Access is exclusively through SSM Session Manager.
  key_name = ""

  ebs_encryption = true
  kms_key_arn    = var.kms_key_id == null ? "" : var.kms_key_id
  volume_type    = "gp3"
  volume_size    = var.root_volume_size
  device_name    = "/dev/xvda"

  user_data_base64 = var.user_data != "" ? base64encode(var.user_data) : ""

  min_size             = var.min_size
  max_size             = var.max_size
  desired_capacity     = var.desired_capacity
  termination_policies = ["OldestInstance"]
  health_check_type    = "EC2"

  # Optional off hours schedule, disabled by default.
  schedule_enabled   = var.schedule_enabled
  scheduler_up       = var.scheduler_up
  scheduler_down     = var.scheduler_down
  time_zone          = var.schedule_time_zone
  min_size_scaleup   = var.min_size
  max_size_scaleup   = var.max_size
  scale_up_desired   = var.desired_capacity
  min_size_scaledown = 0
  max_size_scaledown = 0
  scale_down_desired = 0

  # A bastion is not a scaled fleet.
  on_demand_enabled                            = true
  spot_enabled                                 = false
  aws_autoscaling_policy_scale_up              = false
  aws_autoscaling_policy_scale_down            = false
  aws_cloudwatch_metric_alarm_enabled_cpu_high = false
  aws_cloudwatch_metric_alarm_enabled_cpu_low  = false
}

##############################################################################
# Optional: open the target resources' security groups to the bastion.
#
# The bastion security group already permits egress to the whole VPC, but each
# target (EKS control plane, Aurora, RDS Proxy, ElastiCache) must also permit
# INBOUND from the bastion security group. Rather than hand editing every
# target's own module, list them in target_ingress_rules.
#
# new_sg is false and existing_sg_id names the target, so the module adds rules
# to a security group it does not own.
##############################################################################
module "target_access" {
  source  = "clouddrove/security-group/aws"
  version = "2.0.3"

  for_each = var.enabled ? {
    for rule in var.target_ingress_rules :
    "${rule.security_group_id}:${rule.port}" => rule
  } : {}

  enable      = true
  name        = var.name
  environment = var.environment
  label_order = var.label_order
  managedby   = var.managedby
  repository  = var.repository
  tags        = var.extra_tags

  vpc_id = var.vpc_id

  # Attach rules to the target's own security group rather than creating one.
  new_sg         = false
  existing_sg_id = each.value.security_group_id

  existing_sg_ingress_rules = [
    {
      key                          = "from-bastion-${each.value.port}"
      ip_protocol                  = "tcp"
      from_port                    = each.value.port
      to_port                      = each.value.port
      referenced_security_group_id = module.security_group.security_group_id
      description                  = each.value.description
    }
  ]
}

##############################################################################
# Session logging.
#
# Two log groups, because the two access paths leave different traces.
#
# The audit group answers who connected, when, and to what. It is fed by an
# EventBridge rule matching CloudTrail-sourced ssm API calls, which is the only
# route available: Session Manager publishes no native EventBridge event. That
# also makes a CloudTrail trail logging management events a prerequisite. With
# no trail the rule never fires and the group stays empty.
#
# The session group holds full terminal transcripts, and only fills for
# interactive shells. Port forwarding sessions, which is what client/tunnel.sh
# opens, carry no terminal output to record.
#
# The four resources below are declared directly rather than composed, because
# no published CloudDrove module covers a log group, an SSM document, or a log
# group resource policy.
##############################################################################
resource "aws_cloudwatch_log_group" "audit" {
  count = local.audit_logging_enabled ? 1 : 0

  name              = local.audit_log_group_name
  retention_in_days = var.log_retention_days
  kms_key_id        = var.log_kms_key_id
  tags              = module.labels.tags
}

resource "aws_cloudwatch_log_group" "session" {
  count = local.session_logging_enabled ? 1 : 0

  name              = local.session_log_group_name
  retention_in_days = var.log_retention_days
  kms_key_id        = var.log_kms_key_id
  tags              = module.labels.tags
}

# EventBridge writes to a log group only when the group's own resource policy
# lets it. The SourceArn condition keeps that grant to this rule alone.
#
# Note the account and region quota of 10 log group resource policies. The name
# carries the label ID so parallel deployments do not overwrite each other, but
# they do each consume one.
data "aws_iam_policy_document" "events_to_audit_log" {
  count = local.audit_logging_enabled ? 1 : 0

  statement {
    sid    = "EventBridgeToCloudWatchLogs"
    effect = "Allow"

    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]

    resources = ["${aws_cloudwatch_log_group.audit[0].arn}:*"]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"

      # The module returns arn as a list, since its rule is count-gated.
      values = module.session_events.arn
    }
  }
}

resource "aws_cloudwatch_log_resource_policy" "events_to_audit_log" {
  count = local.audit_logging_enabled ? 1 : 0

  policy_name     = "${module.labels.id}-session-events"
  policy_document = data.aws_iam_policy_document.events_to_audit_log[0].json
}

##############################################################################
# Shell transcript preferences.
#
# SSM-SessionManagerRunShell is an account and region SINGLETON. Creating it
# here changes shell logging for every SSM session in the region, not only this
# bastion's, so it is opt in through session_preferences_managed. If the account
# already has the document, import it before enabling:
#
#   terraform import 'module.bastion.aws_ssm_document.session_preferences[0]' \
#     SSM-SessionManagerRunShell
#
# cloudWatchEncryptionEnabled must track whether a customer-managed key was
# supplied. Setting it true against an AWS-owned key blocks every session.
##############################################################################
resource "aws_ssm_document" "session_preferences" {
  count = local.session_logging_enabled ? 1 : 0

  name            = "SSM-SessionManagerRunShell"
  document_type   = "Session"
  document_format = "JSON"
  tags            = module.labels.tags

  content = jsonencode({
    schemaVersion = "1.0"
    description   = "Session Manager preferences for ${module.labels.id}. Streams shell output to CloudWatch Logs."
    sessionType   = "Standard_Stream"
    inputs = {
      cloudWatchLogGroupName      = aws_cloudwatch_log_group.session[0].name
      cloudWatchEncryptionEnabled = var.log_kms_key_id != null
      cloudWatchStreamingEnabled  = true
      s3BucketName                = ""
      s3KeyPrefix                 = ""
      s3EncryptionEnabled         = true
      idleSessionTimeout          = tostring(var.session_idle_timeout_minutes)
      maxSessionDuration          = ""
      runAsEnabled                = false
      runAsDefaultUser            = ""
      shellProfile = {
        linux   = ""
        windows = ""
      }
    }
  })
}

##############################################################################
# Connection audit rule.
#
# Session targets are instance IDs the Auto Scaling group assigns at launch, so
# they cannot be matched in a static event pattern. The rule therefore records
# SSM sessions to every instance in the region, not only this bastion's. That is
# a wider net rather than a narrower one, and the dashboard shows the target
# instance so bastion sessions stay identifiable.
##############################################################################
module "session_events" {
  source  = "clouddrove/cloudwatch-event-rule/aws"
  version = "1.0.3"

  enabled     = local.audit_logging_enabled
  name        = var.name
  environment = var.environment
  label_order = var.label_order
  managedby   = var.managedby
  repository  = var.repository

  description = "Session Manager connections: who, when, and which target."

  event_pattern = jsonencode({
    source        = ["aws.ssm"]
    "detail-type" = ["AWS API Call via CloudTrail"]
    detail = {
      eventSource = ["ssm.amazonaws.com"]
      eventName   = ["StartSession", "ResumeSession", "TerminateSession"]
    }
  })

  target_id = "audit-log-group"
  arn       = local.audit_logging_enabled ? aws_cloudwatch_log_group.audit[0].arn : ""

  # The module always renders an input_transformer block, so an empty template
  # would be rejected by the API. That is turned to advantage here: the raw
  # CloudTrail envelope is reshaped into one flat audit record per event, which
  # keeps the Logs Insights queries readable.
  #
  # Every placeholder is quoted in the template. A path that is absent from a
  # given event, such as requestParameters.target on TerminateSession, then
  # yields an empty string rather than breaking the JSON.
  input_paths = {
    time         = "$.time"
    account      = "$.account"
    awsRegion    = "$.region"
    event        = "$.detail.eventName"
    principal    = "$.detail.userIdentity.arn"
    principalId  = "$.detail.userIdentity.principalId"
    sourceIp     = "$.detail.sourceIPAddress"
    instance     = "$.detail.requestParameters.target"
    document     = "$.detail.requestParameters.documentName"
    targetHost   = "$.detail.requestParameters.parameters.host[0]"
    targetPort   = "$.detail.requestParameters.parameters.portNumber[0]"
    sessionId    = "$.detail.responseElements.sessionId"
    endedSession = "$.detail.requestParameters.sessionId"
    errorCode    = "$.detail.errorCode"
  }

  input_template = "{\"time\":\"<time>\",\"event\":\"<event>\",\"principal\":\"<principal>\",\"principalId\":\"<principalId>\",\"sourceIp\":\"<sourceIp>\",\"instance\":\"<instance>\",\"document\":\"<document>\",\"targetHost\":\"<targetHost>\",\"targetPort\":\"<targetPort>\",\"sessionId\":\"<sessionId>\",\"endedSession\":\"<endedSession>\",\"errorCode\":\"<errorCode>\",\"account\":\"<account>\",\"region\":\"<awsRegion>\"}"
}

##############################################################################
# Dashboard.
#
# Log widgets inherit the dashboard time picker, so their titles state no fixed
# window. The default range is 7 days, matching the default retention.
#
# Session duration is deliberately absent: it needs StartSession paired with
# TerminateSession on detail.responseElements.sessionId, which reads poorly at
# widget size. That query is in the README.
##############################################################################
locals {
  dashboard_region = data.aws_region.current.region

  # Field names come from the EventBridge input transformer on the rule below,
  # not from the raw CloudTrail envelope.
  recent_sessions_query = join(" | ", [
    "SOURCE '${local.audit_log_group_name}'",
    "fields @timestamp, principal, instance, targetHost, targetPort, sourceIp, sessionId",
    "filter event = \"StartSession\"",
    "sort @timestamp desc",
    "limit 50",
  ])

  sessions_by_principal_query = join(" | ", [
    "SOURCE '${local.audit_log_group_name}'",
    "filter event = \"StartSession\"",
    "stats count(*) as sessions by principal",
  ])

  session_count_query = join(" | ", [
    "SOURCE '${local.audit_log_group_name}'",
    "stats count(*) as count by event",
  ])

  transcript_query = join(" | ", [
    "SOURCE '${local.session_log_group_name}'",
    "fields @timestamp, @logStream, @message",
    "sort @timestamp desc",
    "limit 100",
  ])

  # Rendered in place of the transcript widget when the session document is not
  # managed here, so an empty panel never reads as "nobody ran anything".
  transcript_placeholder = join("\n", [
    "## Shell transcripts are not being recorded",
    "",
    "`session_preferences_managed` is `false`, so this module does not own the",
    "account's `SSM-SessionManagerRunShell` document and no terminal output is",
    "streamed to CloudWatch Logs.",
    "",
    "Connection auditing above is unaffected: it covers every session, including",
    "the port forwards `client/tunnel.sh` opens.",
  ])

  transcript_widget = local.session_logging_enabled ? {
    type   = "log"
    x      = 0
    y      = 20
    width  = 24
    height = 8
    properties = {
      query  = local.transcript_query
      region = local.dashboard_region
      title  = "Shell transcripts (log stream name carries the session ID and principal)"
      view   = "table"
    }
    } : {
    type   = "text"
    x      = 0
    y      = 20
    width  = 24
    height = 4
    properties = {
      markdown = local.transcript_placeholder
    }
  }

  dashboard_body = jsonencode({
    start          = "-P7D"
    periodOverride = "auto"
    widgets = [
      {
        type   = "log"
        x      = 0
        y      = 0
        width  = 24
        height = 8
        properties = {
          query  = local.recent_sessions_query
          region = local.dashboard_region
          title  = "Recent sessions: who connected, to which instance, and which target"
          view   = "table"
        }
      },
      {
        type   = "log"
        x      = 0
        y      = 8
        width  = 12
        height = 6
        properties = {
          query  = local.sessions_by_principal_query
          region = local.dashboard_region
          title  = "Sessions per principal"
          view   = "bar"
        }
      },
      {
        type   = "log"
        x      = 12
        y      = 8
        width  = 12
        height = 6
        properties = {
          query  = local.session_count_query
          region = local.dashboard_region
          title  = "Session events by type"
          view   = "table"
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 14
        width  = 8
        height = 6
        properties = {
          metrics = [["AWS/AutoScaling", "GroupInServiceInstances", "AutoScalingGroupName", module.bastion.autoscaling_group_name]]
          view    = "timeSeries"
          stacked = false
          region  = local.dashboard_region
          stat    = "Average"
          period  = 300
          title   = "Bastion instances in service"
        }
      },
      {
        type   = "metric"
        x      = 8
        y      = 14
        width  = 8
        height = 6
        properties = {
          metrics = [["AWS/EC2", "CPUUtilization", "AutoScalingGroupName", module.bastion.autoscaling_group_name]]
          view    = "timeSeries"
          stacked = false
          region  = local.dashboard_region
          stat    = "Average"
          period  = 300
          title   = "CPU utilization"
        }
      },
      {
        type   = "metric"
        x      = 16
        y      = 14
        width  = 8
        height = 6
        properties = {
          metrics = [
            ["AWS/EC2", "NetworkIn", "AutoScalingGroupName", module.bastion.autoscaling_group_name],
            ["AWS/EC2", "NetworkOut", "AutoScalingGroupName", module.bastion.autoscaling_group_name],
          ]
          view    = "timeSeries"
          stacked = false
          region  = local.dashboard_region
          stat    = "Sum"
          period  = 300
          title   = "Network in and out (bytes)"
        }
      },
      local.transcript_widget,
    ]
  })
}

module "dashboard" {
  source  = "clouddrove/cloudwatch-dashboard/aws"
  version = "1.0.1"

  enable      = local.dashboard_enabled
  name        = var.name
  environment = var.environment
  label_order = var.label_order
  managedby   = var.managedby
  repository  = var.repository

  dashboard_body = local.dashboard_body
}
