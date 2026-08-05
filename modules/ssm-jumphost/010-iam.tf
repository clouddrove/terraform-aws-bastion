##############################################################################
# IAM role + instance profile for the jump host.
#
# The ONLY managed policy is AmazonSSMManagedInstanceCore, which lets the SSM
# agent register with Systems Manager and serve Session Manager connections.
# There are no other permissions and no SSH key — access is exclusively via SSM.
##############################################################################
locals {
  name = "${var.project_name}-${var.environment}-ssm-bastion"

  common_tags = merge(var.tags, {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
    Module      = "ssm-jumphost"
  })
}

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

resource "aws_iam_role" "this" {
  name               = "${local.name}-role"
  assume_role_policy = data.aws_iam_policy_document.trust.json
  tags               = local.common_tags
}

resource "aws_iam_instance_profile" "this" {
  name = "${local.name}-profile"
  role = aws_iam_role.this.name
  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "extra" {
  for_each   = toset(var.extra_iam_policy_arns)
  role       = aws_iam_role.this.name
  policy_arn = each.value
}
