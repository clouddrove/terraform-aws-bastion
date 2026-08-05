terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.83.0"
    }
  }

  # Configure a remote backend for real use. Left local here for the example.
  # backend "s3" {
  #   bucket = "myorg-terraform-state"
  #   key    = "jump-host/dev/terraform.tfstate"
  #   region = "eu-west-1"
  # }
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}
