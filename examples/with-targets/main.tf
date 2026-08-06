##############################################################################
# Targets example: open the path from the bastion into existing resources.
#
# The bastion security group already permits egress to the whole VPC, but each
# target must also permit INBOUND from the bastion. target_ingress_rules adds
# that rule to every listed security group, so the targets' own modules stay
# untouched.
#
# The ports below are the usual set. Add or drop entries to match what you
# actually tunnel to.
##############################################################################

module "bastion" {
  source = "../../"

  name        = var.name
  environment = var.environment
  attributes  = ["ssm"]

  vpc_id     = var.vpc_id
  vpc_cidr   = var.vpc_cidr
  subnet_ids = var.subnet_ids

  target_ingress_rules = [
    {
      security_group_id = var.eks_security_group_id
      port              = 443
      description       = "EKS API from bastion"
    },
    {
      security_group_id = var.aurora_security_group_id
      port              = 5432
      description       = "Aurora from bastion"
    },
    {
      security_group_id = var.redis_security_group_id
      port              = 6379
      description       = "Redis from bastion"
    },
  ]
}
