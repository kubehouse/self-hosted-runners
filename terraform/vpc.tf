module "vpc" {
  source = "git::https://github.com/terraform-aws-modules/terraform-aws-vpc.git?ref=3ffbd46fb1c7733e1b34d8666893280454e27436"

  name = local.name
  cidr = var.vpc_cidr

  azs = local.azs

  # /20 private subnets (~4k IPs each) — EKS nodes + pods live here
  private_subnets = [for k, _ in local.azs : cidrsubnet(var.vpc_cidr, 4, k)]

  # /24 public subnets — NAT gateways and any public load balancers
  public_subnets = [for k, _ in local.azs : cidrsubnet(var.vpc_cidr, 8, k + 48)]

  enable_nat_gateway   = true
  single_nat_gateway   = true # set false for production HA
  enable_dns_hostnames = true
  enable_dns_support   = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
    # Karpenter uses this tag to discover which subnets to launch nodes into
    "karpenter.sh/discovery" = local.name
  }

  tags = local.tags
}
