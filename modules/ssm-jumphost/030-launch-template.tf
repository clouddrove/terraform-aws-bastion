##############################################################################
# Launch template.
#
# - AMI resolved dynamically from the SSM public parameter for the latest
#   Amazon Linux 2023, matching the instance architecture (arm64 / x86_64).
# - IMDSv2 required (http_tokens = required).
# - No key pair, no public IP.
##############################################################################
data "aws_ec2_instance_type" "this" {
  instance_type = var.instance_type
}

locals {
  is_arm           = contains(data.aws_ec2_instance_type.this.supported_architectures, "arm64")
  ami_architecture = local.is_arm ? "arm64" : "x86_64"
  ami_ssm_path     = "resolve:ssm:/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-${local.ami_architecture}"
}

resource "aws_launch_template" "this" {
  name                   = local.name
  update_default_version = true

  image_id      = local.ami_ssm_path
  instance_type = var.instance_type

  iam_instance_profile {
    name = aws_iam_instance_profile.this.name
  }

  vpc_security_group_ids = [aws_security_group.this.id]

  user_data = var.user_data != "" ? base64encode(var.user_data) : null

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  dynamic "tag_specifications" {
    for_each = toset(["instance", "volume", "network-interface"])
    content {
      resource_type = tag_specifications.value
      tags          = merge(local.common_tags, { Name = local.name })
    }
  }

  tags = local.common_tags

  # No key_name and no network_interfaces with a public IP — SSM-only access.
}
