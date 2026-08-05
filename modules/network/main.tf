##############################################################################
# Availability Zones + CIDR math
##############################################################################
data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_region" "current" {}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  # Carve /20 private subnets and (if NAT) /24 public subnets out of the VPC CIDR.
  private_subnet_cidrs = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 4, i)]
  public_subnet_cidrs  = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 8, i + 240)]

  common_tags = merge(var.tags, {
    ManagedBy = "terraform"
    Module    = "network"
  })

  nat_gateway_count = var.enable_nat ? (var.single_nat_gateway ? 1 : var.az_count) : 0
}

##############################################################################
# VPC
##############################################################################
resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-vpc" })
}

##############################################################################
# Private subnets (where the jump host lives)
##############################################################################
resource "aws_subnet" "private" {
  count = var.az_count

  vpc_id            = aws_vpc.this.id
  cidr_block        = local.private_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-private-${local.azs[count.index]}"
    Tier = "private"
  })
}

resource "aws_route_table" "private" {
  count = var.az_count

  vpc_id = aws_vpc.this.id
  tags   = merge(local.common_tags, { Name = "${var.name_prefix}-private-rt-${local.azs[count.index]}" })
}

resource "aws_route_table_association" "private" {
  count = var.az_count

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

##############################################################################
# Optional public egress path (IGW + public subnets + NAT)
##############################################################################
resource "aws_internet_gateway" "this" {
  count = var.enable_nat ? 1 : 0

  vpc_id = aws_vpc.this.id
  tags   = merge(local.common_tags, { Name = "${var.name_prefix}-igw" })
}

resource "aws_subnet" "public" {
  count = var.enable_nat ? var.az_count : 0

  vpc_id                  = aws_vpc.this.id
  cidr_block              = local.public_subnet_cidrs[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = false

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-public-${local.azs[count.index]}"
    Tier = "public"
  })
}

resource "aws_route_table" "public" {
  count = var.enable_nat ? 1 : 0

  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this[0].id
  }

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-public-rt" })
}

resource "aws_route_table_association" "public" {
  count = var.enable_nat ? var.az_count : 0

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public[0].id
}

resource "aws_eip" "nat" {
  count      = local.nat_gateway_count
  domain     = "vpc"
  depends_on = [aws_internet_gateway.this]
  tags       = merge(local.common_tags, { Name = "${var.name_prefix}-nat-eip-${count.index}" })
}

resource "aws_nat_gateway" "this" {
  count = local.nat_gateway_count

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
  depends_on    = [aws_internet_gateway.this]

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-nat-${count.index}" })
}

# Default route out of each private subnet via NAT (shared or per-AZ).
resource "aws_route" "private_nat" {
  count = var.enable_nat ? var.az_count : 0

  route_table_id         = aws_route_table.private[count.index].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[var.single_nat_gateway ? 0 : count.index].id
}

##############################################################################
# SSM connectivity without internet — interface + gateway endpoints
##############################################################################
resource "aws_security_group" "endpoints" {
  count = var.create_ssm_endpoints ? 1 : 0

  name_prefix = "${var.name_prefix}-vpce-"
  description = "Allow HTTPS from within the VPC to the interface endpoints"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "HTTPS from VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-vpce-sg" })

  lifecycle {
    create_before_destroy = true
  }
}

locals {
  interface_endpoints = var.create_ssm_endpoints ? toset(["ssm", "ssmmessages", "ec2messages"]) : toset([])
}

resource "aws_vpc_endpoint" "interface" {
  for_each = local.interface_endpoints

  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${data.aws_region.current.region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.endpoints[0].id]
  private_dns_enabled = true

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-vpce-${each.key}" })
}

# S3 gateway endpoint — the SSM agent fetches some assets from S3.
resource "aws_vpc_endpoint" "s3" {
  count = var.create_ssm_endpoints ? 1 : 0

  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.private[*].id

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-vpce-s3" })
}
