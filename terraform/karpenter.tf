# ── Karpenter IAM + interruption queue ────────────────────────────────────────
module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 21.17.1"

  cluster_name = module.eks.cluster_name

  # Use EKS Pod Identity instead of IRSA (simpler, no annotation on SA needed)
  create_pod_identity_association = true

  # Allow SSM Session Manager on Karpenter-managed nodes (useful for debugging)
  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  tags = local.tags
}

# ── Karpenter Helm release ─────────────────────────────────────────────────────
resource "helm_release" "karpenter" {
  namespace        = "karpenter"
  create_namespace = true
  name             = "karpenter"
  repository       = "oci://public.ecr.aws/karpenter"
  chart            = "karpenter"
  version          = var.karpenter_version
  wait             = true
  wait_for_jobs    = true
  timeout          = 300

  values = [
    yamlencode({
      serviceAccount = {
        name = module.karpenter.service_account
      }
      settings = {
        clusterName       = module.eks.cluster_name
        clusterEndpoint   = module.eks.cluster_endpoint
        interruptionQueue = module.karpenter.queue_name
      }
      controller = {
        resources = {
          requests = { cpu = "1", memory = "1Gi" }
          limits   = { cpu = "1", memory = "1Gi" }
        }
      }
      # Run on the dedicated system node group
      tolerations  = [{ key = "CriticalAddonsOnly", operator = "Exists" }]
      nodeSelector = { role = "system" }
    })
  ]

  depends_on = [module.karpenter]
}

# ── EC2NodeClass: Linux (AL2023) ───────────────────────────────────────────────
resource "kubectl_manifest" "karpenter_ec2nodeclass_linux" {
  yaml_body = templatefile("${path.module}/../karpenter/ec2nodeclass-linux.yaml.tpl", {
    cluster_name   = module.eks.cluster_name
    node_role_name = module.karpenter.node_iam_role_name
  })

  depends_on = [helm_release.karpenter]
}

# ── EC2NodeClass: Windows (Server 2022) ───────────────────────────────────────
resource "kubectl_manifest" "karpenter_ec2nodeclass_windows" {
  yaml_body = templatefile("${path.module}/../karpenter/ec2nodeclass-windows.yaml.tpl", {
    cluster_name   = module.eks.cluster_name
    node_role_name = module.karpenter.node_iam_role_name
  })

  depends_on = [helm_release.karpenter]
}

# ── NodePool: Linux runners ────────────────────────────────────────────────────
resource "kubectl_manifest" "karpenter_nodepool_linux" {
  yaml_body = file("${path.module}/../karpenter/nodepool-linux.yaml")

  depends_on = [kubectl_manifest.karpenter_ec2nodeclass_linux]
}

# ── NodePool: Windows runners ──────────────────────────────────────────────────
resource "kubectl_manifest" "karpenter_nodepool_windows" {
  yaml_body = file("${path.module}/../karpenter/nodepool-windows.yaml")

  depends_on = [kubectl_manifest.karpenter_ec2nodeclass_windows]
}
