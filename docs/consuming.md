# Consuming this module

### Usage

### Existing VPC

The VPC must already reach Systems Manager, either through the `ssm`,
`ssmmessages`, and `ec2messages` interface endpoints or through NAT. Without one
of those the SSM agent cannot register and the bastion stays invisible to
Session Manager.

```hcl
module "bastion" {
  # This repository is private and is not published to the Terraform Registry,
  # so `source = "clouddrove/bastion/aws"` does not resolve. Pin a tag.
  source = "git::https://github.com/clouddrove/terraform-aws-bastion.git?ref=1.0.0"

  name        = "myproject"
  environment = "dev"

  vpc_id     = "vpc-0abc"
  vpc_cidr   = "10.60.0.0/16"
  subnet_ids = ["subnet-0a", "subnet-0b"]
}
```

`ref` takes a tag. List what is available with:

```bash
git ls-remote --tags https://github.com/clouddrove/terraform-aws-bastion.git
```

A commit SHA works too, and is the right choice for pinning to something that
has no tag yet.

Do not use `ref=master`. Terraform caches modules in `.terraform/modules`, so a
moving ref means two runs of the same configuration can build different
infrastructure with no diff to explain it.

### Giving CI access to a private module

`terraform init` clones this repository over the network, so any runner needs
credentials. Without them it fails with `Repository not found`, which is a
permissions error rather than a missing repository.

**GitHub Actions**, using a token with read access to this repository:

```yaml
- name: Allow Terraform to clone private modules
  run: |
    git config --global url."https://oauth2:${{ secrets.MODULE_READ_TOKEN }}@github.com".insteadOf "https://github.com"
- run: terraform init
```

The default `GITHUB_TOKEN` is scoped to the calling repository alone and cannot
read this one. Use a fine-grained PAT, a GitHub App installation token, or make
the runner a member of a team with read access.

**Deploy key**, for CI outside GitHub Actions. Add the public half to this
repository's deploy keys, then switch the source to SSH:

```hcl
source = "git::ssh://git@github.com/clouddrove/terraform-aws-bastion.git?ref=1.0.0"
```

Watch for a global `insteadOf` rule rewriting HTTPS to SSH or the reverse. It
applies to Terraform's clones too, and silently overrides whichever protocol
the source specifies.

### Greenfield

[`examples/complete`](examples/complete) builds the VPC, private subnets, and
SSM interface endpoints from `clouddrove/vpc/aws` and `clouddrove/subnet/aws`,
then the bastion on top. No NAT gateway and no public subnets.

```bash
cd examples/complete
terraform init
terraform apply -var region=eu-west-1 -var name=myproject -var environment=dev
```

### Letting the bastion reach your resources

The bastion security group allows egress to the whole VPC CIDR, but each target
must also allow **inbound** from the bastion security group. List the target
security groups and ports and this module attaches the rules for you, without
editing the targets' own modules.

```hcl
target_ingress_rules = [
  { security_group_id = "sg-0eks",    port = 443,  description = "EKS API from bastion" },
  { security_group_id = "sg-0aurora", port = 5432, description = "Aurora from bastion" },
  { security_group_id = "sg-0redis",  port = 6379, description = "Redis from bastion" },
]
```

Leave it empty for a greenfield deploy and fill it in once the targets exist.

> **EKS `kubectl` access is separate.** Your own IAM or SSO principal also needs
> an EKS access entry on the cluster. That is a property of your identity, not
> of the bastion.
