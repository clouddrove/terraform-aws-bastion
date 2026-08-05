include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  # Relative to this unit. Point at your published module registry in real use.
  source = "../../../modules/network"
}

inputs = {
  name_prefix          = "${include.root.inputs.project_name}-${include.root.inputs.environment}"
  vpc_cidr             = "10.60.0.0/16"
  az_count             = 2
  enable_nat           = false
  create_ssm_endpoints = true
}
