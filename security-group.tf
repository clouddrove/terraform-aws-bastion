##############################################################################
# Jump host security group.
#
# INBOUND: none. SSM Session Manager needs no open ports — the agent dials out.
# OUTBOUND: the VPC CIDR (to reach EKS/RDS/Redis/ALB) plus any extra CIDRs, and
#           443 to everything (SSM endpoints / optional NAT path).
##############################################################################
resource "aws_security_group" "this" {
  name_prefix = "${module.labels.id}-"
  description = "Jump host: no inbound, egress to VPC + HTTPS"
  vpc_id      = var.vpc_id

  tags = merge(module.labels.tags, { Name = "${module.labels.id}-sg" })

  lifecycle {
    create_before_destroy = true
  }
}

# Reach in-VPC resources (EKS apiserver, Aurora, RDS Proxy, Redis, internal ALB).
resource "aws_vpc_security_group_egress_rule" "vpc" {
  security_group_id = aws_security_group.this.id
  description       = "All traffic to the VPC CIDR"
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "-1"
}

# HTTPS out — SSM interface endpoints, and the AWS API path when NAT is enabled.
resource "aws_vpc_security_group_egress_rule" "https" {
  security_group_id = aws_security_group.this.id
  description       = "HTTPS egress (SSM endpoints / AWS API)"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "extra" {
  for_each          = toset(var.extra_egress_cidrs)
  security_group_id = aws_security_group.this.id
  description       = "Extra egress CIDR"
  cidr_ipv4         = each.value
  ip_protocol       = "-1"
}
