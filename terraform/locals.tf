locals {
  name   = var.cluster_name
  region = var.aws_region
  azs    = slice(data.aws_availability_zones.available.names, 0, 3)

  tags = {
    ManagedBy = "terraform"
    Project   = "github-runners"
    Cluster   = local.name
  }
}