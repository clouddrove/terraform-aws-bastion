##############################################################################
# IAM role + instance profile for the jump host.
#
# The ONLY managed policy is AmazonSSMManagedInstanceCore, which lets the SSM
# agent register with Systems Manager and serve Session Manager connections.
# There are no other permissions and no SSH key — access is exclusively via SSM.
##############################################################################
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
  count = var.enabled ? 1 : 0

  name               = "${module.labels.id}-role"
  assume_role_policy = data.aws_iam_policy_document.trust.json
  tags               = module.labels.tags
}

resource "aws_iam_instance_profile" "this" {
  count = var.enabled ? 1 : 0

  name = "${module.labels.id}-profile"
  role = aws_iam_role.this[0].name
  tags = module.labels.tags
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  count = var.enabled ? 1 : 0

  role       = aws_iam_role.this[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "extra" {
  for_each   = var.enabled ? toset(var.extra_iam_policy_arns) : toset([])
  role       = aws_iam_role.this[0].name
  policy_arn = each.value
}
