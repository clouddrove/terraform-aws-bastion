##############################################################################
# Complete example: VPC, private subnets, SSM interface endpoints, bastion.
#
# Everything is built from published CloudDrove modules.
#
# No NAT gateway and no public subnets. The bastion reaches Systems Manager
# through the interface endpoints, which costs less than NAT and leaves the
# private subnets with no route to the internet.
##############################################################################

data "aws_availability_zones" "available" {
  state = "available"
}

module "vpc" {
  source  = "clouddrove/vpc/aws"
  version = "2.0.5"

  name        = var.name
  environment = var.environment
  cidr_block  = var.vpc_cidr

  # The SSM endpoints are what let a private bastion register with Session
  # Manager when there is no NAT gateway.
  interface_vpc_endpoints = {
    ssm = {
      subnet_ids         = module.subnet.private_subnet_id
      security_group_ids = [module.endpoint_sg.security_group_id]
    }
    ssmmessages = {
      subnet_ids         = module.subnet.private_subnet_id
      security_group_ids = [module.endpoint_sg.security_group_id]
    }
    ec2messages = {
      subnet_ids         = module.subnet.private_subnet_id
      security_group_ids = [module.endpoint_sg.security_group_id]
    }
  }

  gateway_vpc_endpoints = {
    s3 = {
      route_table_ids = module.subnet.private_route_tables_id
    }
  }
}

module "subnet" {
  source  = "clouddrove/subnet/aws"
  version = "2.0.3"

  name        = var.name
  environment = var.environment
  vpc_id      = module.vpc.vpc_id
  type        = "private"
  cidr_block  = module.vpc.vpc_cidr_block

  availability_zones = slice(data.aws_availability_zones.available.names, 0, 2)
}

# The interface endpoints accept HTTPS from inside the VPC.
module "endpoint_sg" {
  source  = "clouddrove/security-group/aws"
  version = "2.0.3"

  name        = "${var.name}-vpce"
  environment = var.environment
  vpc_id      = module.vpc.vpc_id

  sg_description = "HTTPS from within the VPC to the SSM interface endpoints"

  new_sg_ingress_rules = [
    {
      key         = "https-from-vpc"
      ip_protocol = "tcp"
      from_port   = 443
      to_port     = 443
      cidr_ipv4   = var.vpc_cidr
      description = "HTTPS from the VPC"
    }
  ]
}

module "bastion" {
  source = "../../"

  name        = var.name
  environment = var.environment
  attributes  = ["ssm"]

  vpc_id     = module.vpc.vpc_id
  vpc_cidr   = module.vpc.vpc_cidr_block
  subnet_ids = module.subnet.private_subnet_id

  instance_type = var.instance_type

  # Open the targets you want the bastion to reach. Fill this in once the
  # EKS cluster, database, or cache exists.
  #
  # target_ingress_rules = [
  #   { security_group_id = "sg-0eks",    port = 443,  description = "EKS API from bastion" },
  #   { security_group_id = "sg-0aurora", port = 5432, description = "Aurora from bastion" },
  #   { security_group_id = "sg-0redis",  port = 6379, description = "Redis from bastion" },
  # ]
}
