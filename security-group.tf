##############################################################################
# Bastion security group, via clouddrove/security-group/aws.
#
# INBOUND: none. new_sg_ingress_rules is empty and stays empty. SSM Session
#          Manager needs no open ports because the agent dials out.
# OUTBOUND: the VPC CIDR, so the bastion can reach EKS, RDS, Redis, and
#           internal load balancers, plus 443 for the SSM endpoints, plus any
#           extra CIDRs the consumer asks for.
##############################################################################
locals {
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

module "security_group" {
  source  = "clouddrove/security-group/aws"
  version = "2.0.3"

  enable      = var.enabled
  name        = var.name
  environment = var.environment
  label_order = var.label_order
  managedby   = var.managedby
  tags        = var.extra_tags

  vpc_id         = var.vpc_id
  sg_description = "Bastion: no inbound, egress to the VPC and HTTPS"

  # The module's central guarantee. Do not populate this.
  new_sg_ingress_rules = []

  new_sg_egress_rules = local.egress_rules
}
