include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  # Relative to this unit. Point at your published module registry in real use.
  source = "../../../modules/ssm-jumphost"
}

# Pull VPC + subnet IDs straight from the network unit's outputs.
dependency "network" {
  config_path = "../010-network"

  mock_outputs = {
    vpc_id             = "vpc-00000000000000000"
    vpc_cidr           = "10.60.0.0/16"
    private_subnet_ids = ["subnet-00000000000000001", "subnet-00000000000000002"]
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

inputs = {
  project_name  = include.root.inputs.project_name
  environment   = include.root.inputs.environment
  instance_type = "t4g.micro"

  vpc_id     = dependency.network.outputs.vpc_id
  vpc_cidr   = dependency.network.outputs.vpc_cidr
  subnet_ids = dependency.network.outputs.private_subnet_ids

  # Open target resources to the jump host once they exist:
  # target_ingress_rules = [
  #   { security_group_id = "sg-0eks...",    port = 443,  description = "EKS API from jump host" },
  #   { security_group_id = "sg-0aurora...", port = 5432, description = "Aurora from jump host" },
  #   { security_group_id = "sg-0redis...",  port = 6379, description = "Redis from jump host" },
  # ]

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
}
