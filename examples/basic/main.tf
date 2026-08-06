##############################################################################
# Basic example: bastion in a VPC you already have.
#
# The shape most consumers need. Point it at an existing VPC and private
# subnets and you get an SSM-only bastion with connection auditing and a
# dashboard, on defaults.
#
# The VPC must already reach Systems Manager, either through the ssm,
# ssmmessages, and ec2messages interface endpoints or through NAT. Without one
# of those the SSM agent cannot register and the bastion never appears in
# Session Manager. See examples/complete for a VPC built with those endpoints.
##############################################################################

module "bastion" {
  source = "../../"

  name        = var.name
  environment = var.environment
  attributes  = ["ssm"]

  vpc_id     = var.vpc_id
  vpc_cidr   = var.vpc_cidr
  subnet_ids = var.subnet_ids
}
