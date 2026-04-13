module "eks" {
  source = "git::https://github.com/terraform-aws-modules/terraform-aws-eks.git?ref=6bac707d5496f4b494ce8bf63bfc8d245aead592"

  name               = local.name
  kubernetes_version = var.cluster_version

  # Public endpoint is convenient; restrict to your CIDR in production via
  # endpoint_public_access_cidrs = ["x.x.x.x/32"]
  endpoint_public_access = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Required for Pod Identity / IRSA
  enable_irsa = true

  # Give the caller IAM identity cluster-admin access
  enable_cluster_creator_admin_permissions = true

  # vpc-cni is intentionally omitted here. The terraform-aws-eks module gates
  # all addons on the managed node group completing first (so coredns doesn't
  # fail on an empty cluster). vpc-cni must exist BEFORE the node is ready, so
  # keeping it in this block creates a deadlock:
  #   node group ACTIVE → node Ready → CNI installed → addon created → (waiting for node group)
  # Instead, vpc-cni is created as a standalone resource in vpc_cni_addon.tf
  # with an explicit depends_on on the EKS cluster only.
  addons = {
    coredns = {
      most_recent = true
      # OVERWRITE avoids a stall when resources already exist from a previous
      # partial apply. NONE (the default) causes the addon to sit in DEGRADED.
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "OVERWRITE"
    }
    # Required for EKS Pod Identity (used by Karpenter)
    eks-pod-identity-agent = {
      most_recent                 = true
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "OVERWRITE"
    }
    kube-proxy = {
      most_recent                 = true
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "OVERWRITE"
    }
  }

  # ── System node group ──────────────────────────────────────────────────────
  # These on-demand nodes run the Karpenter controller, ARC controller, and
  # cluster add-ons. They are intentionally tainted so only system workloads
  # (which tolerate CriticalAddonsOnly) schedule here.
  eks_managed_node_groups = {
    system = {
      # t3.medium (2 vCPU / 4 GiB) is sufficient for the system workloads
      # (Karpenter controller, ARC controller, CoreDNS, kube-proxy, vpc-cni).
      # Upgrade to m5.large or m5.xlarge for production.
      instance_types = ["t3.medium"]

      # Single node is fine for a POC and cuts the node-ready wait in half.
      # Raise min_size to 2 for production HA.
      min_size     = 1
      max_size     = 2
      desired_size = 1

      labels = {
        role = "system"
      }

      taints = {
        CriticalAddonsOnly = {
          key    = "CriticalAddonsOnly"
          value  = "true"
          effect = "NO_SCHEDULE"
        }
      }

      iam_role_additional_policies = {
        AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
      }
    }
  }

  # Tag the node security group so Karpenter can discover it
  node_security_group_tags = {
    "karpenter.sh/discovery" = local.name
  }

  tags = merge(local.tags, {
    "karpenter.sh/discovery" = local.name
  })
}
