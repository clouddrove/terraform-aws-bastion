mock_provider "aws" {}

# data.aws_iam_policy_document.trust is computed entirely inside the provider
# with no AWS API call, but mock_provider mocks it like every other data
# source, so its .json attribute comes back empty and fails the assume_role_policy
# JSON validation on aws_iam_role.this before any run-specific assertion is
# even reached. Override it with the real trust policy so every run below can
# plan.
override_data {
  target = data.aws_iam_policy_document.trust
  values = {
    json = jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Effect    = "Allow"
          Principal = { Service = "ec2.amazonaws.com" }
          Action    = "sts:AssumeRole"
        }
      ]
    })
  }
}

variables {
  name        = "bastion"
  environment = "test"
  vpc_id      = "vpc-00000000000000000"
  vpc_cidr    = "10.0.0.0/16"
  subnet_ids  = ["subnet-00000000000000001", "subnet-00000000000000002"]
}

run "no_public_ip" {
  command = plan

  assert {
    condition     = aws_launch_template.this[0].network_interfaces[0].associate_public_ip_address == "false"
    error_message = "Bastion must never receive a public IP, regardless of the subnet's map_public_ip_on_launch setting."
  }
}

run "root_volume_encrypted" {
  command = plan

  assert {
    condition     = aws_launch_template.this[0].block_device_mappings[0].ebs[0].encrypted == "true"
    error_message = "Root volume must be encrypted."
  }
}

run "no_ssh_key" {
  command = plan

  assert {
    condition     = aws_launch_template.this[0].key_name == null
    error_message = "Bastion must have no SSH key pair. Access is exclusively through SSM Session Manager."
  }
}

run "imdsv2_required" {
  command = plan

  assert {
    condition     = aws_launch_template.this[0].metadata_options[0].http_tokens == "required"
    error_message = "IMDSv2 must be required."
  }
}

run "no_ingress_rules_by_default" {
  command = plan

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.target) == 0
    error_message = "The module must create no ingress rules unless target_ingress_rules is populated."
  }
}
