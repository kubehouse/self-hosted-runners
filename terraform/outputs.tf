output "aws_region" {
  description = "AWS region the cluster was deployed into"
  value       = local.region
}

output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS cluster API server endpoint"
  value       = module.eks.cluster_endpoint
  sensitive   = true
}

output "configure_kubectl" {
  description = "Run this command to configure kubectl for this cluster"
  value       = "aws eks update-kubeconfig --region ${local.region} --name ${module.eks.cluster_name}"
}

output "karpenter_node_role_arn" {
  description = "IAM role ARN attached to Karpenter-managed EC2 instances"
  value       = module.karpenter.node_iam_role_arn
}

output "github_actions_cicd_role_arn" {
  description = "IAM role ARN for GitHub Actions OIDC — set as AWS_CICD_ROLE_ARN secret in GitHub"
  value       = var.use_existing_oidc_role_arn != null ? var.use_existing_oidc_role_arn : aws_iam_role.github_actions_cicd[0].arn
}

output "linux_runner_scale_set_name" {
  description = "Use in GitHub Actions: runs-on: linux-k8s"
  value       = "linux-k8s"
}

output "windows_runner_scale_set_name" {
  description = "Use in GitHub Actions: runs-on: windows-k8s"
  value       = "windows-k8s"
}
