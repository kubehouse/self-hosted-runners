# vpc-cni is intentionally managed outside the EKS module's addons block.
#
# Why: the terraform-aws-eks module creates all addons after the managed node
# group completes. vpc-cni must be installed BEFORE a node can become Ready
# (its DaemonSet installs the CNI binaries that kubelet waits for). Leaving it
# inside the module block causes a deadlock on fresh clusters:
#
#   node group ACTIVE
#     └── requires node Ready
#           └── requires CNI initialised
#                 └── requires vpc-cni addon
#                       └── requires node group ACTIVE  ← deadlock
#
# By declaring vpc-cni here with depends_on only on the cluster, Terraform
# creates it as soon as the control plane is ACTIVE — before the node group
# even starts — giving the DaemonSet time to schedule and install the CNI.

# Look up the latest available vpc-cni version for this cluster's Kubernetes
# version. The standalone aws_eks_addon resource does not support most_recent
# directly (that is a convenience argument inside the terraform-aws-eks module
# wrapper); the equivalent here is a dedicated data source.
data "aws_eks_addon_version" "vpc_cni" {
  addon_name         = "vpc-cni"
  kubernetes_version = module.eks.cluster_version
  most_recent        = true
}

resource "aws_eks_addon" "vpc_cni" {
  cluster_name  = module.eks.cluster_name
  addon_name    = "vpc-cni"
  addon_version = data.aws_eks_addon_version.vpc_cni.version

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  # ENABLE_WINDOWS_IPAM forces the CNI to reconfigure its IPAM mode on first
  # install (~5 min delay). Enable only when Windows runner pods are needed.
  # configuration_values = jsonencode({ env = { ENABLE_WINDOWS_IPAM = "true" } })

  tags = local.tags
  # No explicit depends_on here — that is intentional.
  #
  # Referencing module.eks.cluster_name (line above) creates an implicit
  # dependency on the EKS *cluster* resource only, not on the entire module.
  # Adding depends_on = [module.eks] would wait for every resource inside the
  # module to complete — including the managed node group — recreating the
  # deadlock this file exists to prevent.
}
