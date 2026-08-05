##############################################################################
# Optional: open the target resources' security groups to the jump host.
#
# The jump host SG already permits egress to the whole VPC, but each target
# (EKS control plane, Aurora/RDS, RDS Proxy, ElastiCache) must also permit
# INBOUND from the jump host SG. Rather than hand-editing every target's own
# module, list them here and this module attaches the ingress rules for you.
#
# Example:
#   target_ingress_rules = [
#     { security_group_id = "sg-eks-cp",  port = 443,  description = "EKS API from jump host" },
#     { security_group_id = "sg-aurora",  port = 5432, description = "Aurora from jump host" },
#     { security_group_id = "sg-redis",   port = 6379, description = "Redis from jump host" },
#   ]
##############################################################################
resource "aws_vpc_security_group_ingress_rule" "target" {
  for_each = {
    for r in var.target_ingress_rules : "${r.security_group_id}:${r.port}" => r
  }

  security_group_id            = each.value.security_group_id
  referenced_security_group_id = aws_security_group.this.id
  from_port                    = each.value.port
  to_port                      = each.value.port
  ip_protocol                  = "tcp"
  description                  = each.value.description

  tags = merge(module.labels.tags, { Name = "${module.labels.id}-to-${each.value.port}" })
}
