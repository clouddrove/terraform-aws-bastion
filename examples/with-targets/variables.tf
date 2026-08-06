variable "region" {
  type        = string
  description = "AWS region."
  default     = "eu-west-1"
}

variable "name" {
  type        = string
  description = "Name prefix for every resource."
  default     = "myproject"
}

variable "environment" {
  type        = string
  description = "Environment name."
  default     = "dev"
}

variable "vpc_id" {
  type        = string
  description = "ID of the existing VPC to place the bastion in."
}

variable "vpc_cidr" {
  type        = string
  description = "CIDR of that VPC."
}

variable "subnet_ids" {
  type        = list(string)
  description = "Existing private subnet IDs for the Auto Scaling Group."
}

##############################################################################
# Targets. Every one is optional: leave it null and no rule is added.
##############################################################################
variable "eks_security_group_id" {
  type        = string
  description = "Security group of the EKS control plane, opened on 443."
  default     = null
}

variable "aurora_security_group_id" {
  type        = string
  description = "Security group of the Aurora cluster, opened on 5432."
  default     = null
}

variable "rds_postgres_security_group_id" {
  type        = string
  description = "Security group of a standalone RDS PostgreSQL instance, opened on 5432."
  default     = null
}

variable "rds_mysql_security_group_id" {
  type        = string
  description = "Security group of an RDS MySQL or MariaDB instance, opened on 3306."
  default     = null
}

variable "redis_security_group_id" {
  type        = string
  description = "Security group of the ElastiCache Redis or Valkey cache, opened on 6379."
  default     = null
}

variable "memcached_security_group_id" {
  type        = string
  description = "Security group of the ElastiCache memcached cluster, opened on 11211."
  default     = null
}

variable "documentdb_security_group_id" {
  type        = string
  description = "Security group of the DocumentDB cluster, opened on 27017."
  default     = null
}

variable "opensearch_security_group_id" {
  type        = string
  description = "Security group of the OpenSearch domain, opened on 443."
  default     = null
}

variable "msk_security_group_id" {
  type        = string
  description = "Security group of the MSK cluster, opened on 9094 for TLS brokers."
  default     = null
}
