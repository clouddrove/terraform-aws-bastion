##############################################################################
# Optional: open the target resources' security groups to the bastion.
#
# The bastion security group already permits egress to the whole VPC, but each
# target (EKS control plane, Aurora, RDS Proxy, ElastiCache) must also permit
# INBOUND from the bastion security group. Rather than hand editing every
# target's own module, list them here.
#
# clouddrove/security-group/aws runs in existing security group mode: new_sg is
# false and existing_sg_id names the target, so the module adds rules to a
# security group it does not own.
#
# Example:
#   target_ingress_rules = [
#     { security_group_id = "sg-0eks",    port = 443,  description = "EKS API from bastion" },
#     { security_group_id = "sg-0aurora", port = 5432, description = "Aurora from bastion" },
#     { security_group_id = "sg-0redis",  port = 6379, description = "Redis from bastion" },
#   ]
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
