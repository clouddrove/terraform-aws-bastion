##############################################################################
# Instance role, via clouddrove/iam-role/aws.
#
# The only managed policy is AmazonSSMManagedInstanceCore, which lets the SSM
# agent register with Systems Manager and serve Session Manager connections.
# There are no other permissions and no SSH key.
#
# The instance profile itself is created by clouddrove/ec2-autoscaling, which
# takes this role's NAME. See the note in main.tf.
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

module "iam_role" {
  source  = "clouddrove/iam-role/aws"
  version = "1.4.0"

  enabled     = var.enabled && var.create_iam_role
  name        = var.name
  environment = var.environment
  label_order = var.label_order
  managedby   = var.managedby
  tags        = var.extra_tags

  description        = "Bastion instance role. SSM Session Manager access only."
  assume_role_policy = data.aws_iam_policy_document.trust.json

  managed_policy_arns = concat(
    ["arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"],
    var.extra_iam_policy_arns,
  )
}
