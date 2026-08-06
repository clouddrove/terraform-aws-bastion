##############################################################################
# Targets example: one bastion as the single way into every backing service.
#
# The bastion security group already permits egress to the whole VPC, but each
# target must also permit INBOUND from the bastion. target_ingress_rules adds
# that rule to every listed security group, so the targets' own modules stay
# untouched.
#
# Every service below is optional. Leave a variable null and it is skipped, so
# this example works whether you run one database or all of them. The ports
# match what client/tunnel.sh forwards.
##############################################################################

locals {
  # One entry per service that was actually given a security group.
  candidate_targets = [
    { id = var.eks_security_group_id, port = 443, description = "EKS API from bastion" },
    { id = var.aurora_security_group_id, port = 5432, description = "Aurora from bastion" },
    { id = var.rds_postgres_security_group_id, port = 5432, description = "RDS PostgreSQL from bastion" },
    { id = var.rds_mysql_security_group_id, port = 3306, description = "RDS MySQL or MariaDB from bastion" },
    { id = var.redis_security_group_id, port = 6379, description = "ElastiCache Redis or Valkey from bastion" },
    { id = var.memcached_security_group_id, port = 11211, description = "ElastiCache memcached from bastion" },
    { id = var.documentdb_security_group_id, port = 27017, description = "DocumentDB from bastion" },
    { id = var.opensearch_security_group_id, port = 443, description = "OpenSearch from bastion" },
    { id = var.msk_security_group_id, port = 9094, description = "MSK TLS brokers from bastion" },
  ]

  target_ingress_rules = [
    for t in local.candidate_targets : {
      security_group_id = t.id
      port              = t.port
      description       = t.description
    } if t.id != null
  ]
}

module "bastion" {
  source = "../../"

  name        = var.name
  environment = var.environment
  attributes  = ["ssm"]

  vpc_id     = var.vpc_id
  vpc_cidr   = var.vpc_cidr
  subnet_ids = var.subnet_ids

  target_ingress_rules = local.target_ingress_rules
}
