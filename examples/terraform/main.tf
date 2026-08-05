##############################################################################
# Plain-Terraform example: greenfield network + SSM jump host.
#
#   terraform init
#   terraform apply -var-file=terraform.tfvars
#
# Deploys a VPC with private subnets and SSM interface endpoints, then a single
# SSM-only jump host in those subnets. No NAT and no public IPs by default.
##############################################################################

module "network" {
  source = "../../modules/network"

  name_prefix = "${var.project_name}-${var.environment}"
  vpc_cidr    = var.vpc_cidr
  az_count    = 2
  enable_nat  = var.enable_nat

  # Interface endpoints are what let the private jump host reach SSM with no NAT.
  create_ssm_endpoints = true

  tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}

module "jumphost" {
  source = "../../modules/ssm-jumphost"

  # Force full network (incl. SSM VPC endpoints) to settle before the instance
  # launches, so the SSM agent can register on first boot with no NAT.
  depends_on = [module.network]

  project_name  = var.project_name
  environment   = var.environment
  instance_type = var.instance_type

  vpc_id     = module.network.vpc_id
  vpc_cidr   = module.network.vpc_cidr
  subnet_ids = module.network.private_subnet_ids

  # Open your target resources to the jump host. Greenfield: leave empty and
  # fill in once EKS/RDS/Redis exist (or manage from their own modules).
  # target_ingress_rules = [
  #   { security_group_id = "sg-0eks...",   port = 443,  description = "EKS API from jump host" },
  #   { security_group_id = "sg-0aurora...", port = 5432, description = "Aurora from jump host" },
  #   { security_group_id = "sg-0redis...",  port = 6379, description = "Redis from jump host" },
  # ]

  # Example off-hours schedule: run 07:00 UTC Mon-Fri, stop 19:00 UTC daily.
  schedule_enabled = true
  asg_schedules = [
    {
      name             = "start-weekday-morning"
      min_size         = 0
      max_size         = 1
      desired_capacity = 1
      recurrence       = "0 7 * * MON-FRI"
    },
    {
      name             = "stop-every-evening"
      min_size         = 0
      max_size         = 0
      desired_capacity = 0
      recurrence       = "0 19 * * *"
    },
  ]

  tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}
