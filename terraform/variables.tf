variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "eu-west-2"
}

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
  default     = "github-runners"
}

variable "cluster_version" {
  description = "Kubernetes version for the EKS cluster"
  type        = string
  default     = "1.35"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

# ─── GitHub ARC ───────────────────────────────────────────────────────────────

variable "github_config_url" {
  description = <<-EOT
    URL of the GitHub org or repository ARC should register runners against.
    Org-level:  https://github.com/kubehouse
    Repo-level: https://github.com/kubehouse/test-repo
  EOT
  type        = string
  default     = "https://github.com/kubehouse"
}

variable "github_pat" {
  description = <<-EOT
    GitHub Personal Access Token used by ARC to register runners.
    Required scopes (org-level):  admin:org
    Required scopes (repo-level): repo
  EOT
  type        = string
  sensitive   = true
}

# ─── Linux runners ────────────────────────────────────────────────────────────

variable "linux_runner_min_count" {
  description = "Minimum idle Linux runner replicas (0 = scale to zero)"
  type        = number
  default     = 0
}

variable "linux_runner_max_count" {
  description = "Maximum concurrent Linux runner replicas (lower for cost POC)"
  type        = number
  default     = 5
}

variable "linux_runner_image" {
  description = "Container image for Linux runners"
  type        = string
  default     = "ghcr.io/actions/actions-runner:latest"
}

# ─── Windows runners ──────────────────────────────────────────────────────────

variable "windows_runner_min_count" {
  description = "Minimum idle Windows runner replicas (0 = scale to zero)"
  type        = number
  default     = 0
}

variable "windows_runner_max_count" {
  description = "Maximum concurrent Windows runner replicas (set to 0 to disable — Windows nodes are expensive)"
  type        = number
  default     = 0
}

variable "windows_runner_image" {
  description = <<-EOT
    Container image for Windows runners.
    GitHub does not publish an official Windows ARC runner image; you will
    need to build and push your own based on
    mcr.microsoft.com/windows/servercore:ltsc2022 or nanoserver:ltsc2022.
    See: https://github.com/actions/runner/tree/main/images
  EOT
  type        = string
  default     = "ghcr.io/actions/actions-runner:latest-windows-ltsc2022"
}

# ─── CI/CD ────────────────────────────────────────────────────────────────────

variable "github_org" {
  description = <<-EOT
    GitHub organisation name. Used to scope the OIDC trust policy so only
    workflows from this org can assume the CI/CD IAM role.
  EOT
  type        = string
  default     = "kubehouse"
}

variable "use_existing_oidc_role_arn" {
  description = <<-EOT
    If provided, uses an existing OIDC role instead of creating a new one.
    This is useful when you already have the role configured in a different
    stack or AWS account.
  EOT
  type        = string
  default     = null
}

# ─── Helm chart versions ──────────────────────────────────────────────────────

variable "karpenter_version" {
  description = "Karpenter Helm chart version (check https://gallery.ecr.aws/karpenter/karpenter)"
  type        = string
  default     = "1.3.3"
}

variable "arc_version" {
  description = "Actions Runner Controller Helm chart version (check https://github.com/actions/actions-runner-controller/releases)"
  type        = string
  default     = "0.10.1"
}

