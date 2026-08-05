# Terragrunt root config. Include from each unit with:
#   include "root" { path = find_in_parent_folders("root.hcl") }
#
# Layout:
#   examples/terragrunt/
#     root.hcl
#     010-network/terragrunt.hcl
#     020-jumphost/terragrunt.hcl
#
# Set these to your account before running.
locals {
  project_name = "myproject"
  environment  = "dev"
  aws_region   = "eu-west-1"
  aws_profile  = "myorg-dev-admin"
  account_id   = "111111111111"

  state_bucket = "myorg-terraform-state"
}

# Remote state in S3, one key per unit path.
# NOTE: use_lockfile (S3-native state locking) needs Terraform >= 1.10 /
# OpenTofu >= 1.10. On older versions, remove use_lockfile and add
# `dynamodb_table = "<lock-table>"` instead. The state bucket must already exist.
remote_state {
  backend = "s3"
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }
  config = {
    bucket       = local.state_bucket
    key          = "jump-host/${local.environment}/${path_relative_to_include()}/terraform.tfstate"
    region       = local.aws_region
    encrypt      = true
    use_lockfile = true
  }
}

# Generate the provider so units don't repeat it.
generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOF
    provider "aws" {
      region              = "${local.aws_region}"
      profile             = "${local.aws_profile}"
      allowed_account_ids = ["${local.account_id}"]

      default_tags {
        tags = {
          Project     = "${local.project_name}"
          Environment = "${local.environment}"
          ManagedBy   = "terragrunt"
        }
      }
    }
  EOF
}

# Values every unit can read via include.root.inputs.
inputs = {
  project_name = local.project_name
  environment  = local.environment
  aws_region   = local.aws_region
}
