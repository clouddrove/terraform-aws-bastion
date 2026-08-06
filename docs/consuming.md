# Consuming this module

Published on the Terraform Registry as
[`clouddrove/bastion/aws`](https://registry.terraform.io/modules/clouddrove/bastion/aws/latest).

## Existing VPC

The VPC must already reach Systems Manager, either through the `ssm`,
`ssmmessages`, and `ec2messages` interface endpoints or through NAT. Without one
of those the SSM agent cannot register and the bastion stays invisible to
Session Manager.

```hcl
module "bastion" {
  source  = "clouddrove/bastion/aws"
  version = "1.0.0"

  name        = "myproject"
  environment = "dev"
  attributes  = ["ssm"]

  vpc_id     = "vpc-0abc"
  vpc_cidr   = "10.60.0.0/16"
  subnet_ids = ["subnet-0a", "subnet-0b"]
}
```

Pin `version` to an exact release rather than a range. A bastion is security
infrastructure, and an unattended minor bump can change the launch template and
replace the instance underneath a running tunnel.

## Greenfield

[`examples/complete`](../examples/complete) builds the VPC, private subnets, and
SSM interface endpoints alongside the bastion, with no NAT gateway and no public
subnets.

```bash
cd examples/complete
terraform init
terraform apply
```

## Tracking an unreleased commit

Registry sources only serve tagged releases. To pick up something merged but not
yet released, use a git source pinned to a commit:

```hcl
source = "git::https://github.com/clouddrove/terraform-aws-bastion.git?ref=<sha>"
```

Find one with `git ls-remote https://github.com/clouddrove/terraform-aws-bastion.git master`.

Do not use `ref=master`. Terraform caches modules in `.terraform/modules`, so a
moving ref means two runs of the same configuration can build different
infrastructure with no diff to explain it.

## After applying

Point the tunnel client at the bastion this module created:

```bash
terraform output tunnel_config    # paste into client/tunnel.json
terraform output dashboard_url    # the CloudWatch dashboard
```

See [the client guide](client.md) for opening tunnels, and
[session logging](session-logging.md) for what gets recorded.
