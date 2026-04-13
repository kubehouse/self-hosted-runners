# ── GitHub Actions OIDC provider ──────────────────────────────────────────────
# Allows GitHub Actions workflows to assume an AWS IAM role without static keys.
# The release.yaml pipeline uses this role to run terraform plan/apply.
#
# Bootstrap note: this role is itself created by Terraform, so the very first
# apply must be run locally with your own AWS credentials:
#   export GITHUB_PAT=ghp_...
#   make init && make plan && make apply
# After that, the CI/CD pipeline uses the role created here.

resource "aws_iam_openid_connect_provider" "github" {
  # Skip creation when an existing OIDC role (and therefore an existing provider)
  # is supplied. AWS allows only ONE OIDC provider per URL per account — attempting
  # to create a second one with the same URL returns EntityAlreadyExists.
  count = var.use_existing_oidc_role_arn == null ? 1 : 0

  url = "https://token.actions.githubusercontent.com"

  client_id_list = ["sts.amazonaws.com"]

  # GitHub's OIDC thumbprints (intermediate CA). GitHub rotates these
  # occasionally — check https://github.blog/changelog for updates.
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd",
  ]

  tags = local.tags
}

# ── Trust policy ───────────────────────────────────────────────────────────────
# Restricts which GitHub org/repos can assume this role.
# Change the StringLike condition to a specific repo for tighter control:
#   "repo:${var.github_org}/self-hosted-runners:ref:refs/heads/main"
#
# Guarded by the same count as the OIDC provider and the role below — when
# use_existing_oidc_role_arn is set, none of these three resources are created.
data "aws_iam_policy_document" "github_actions_assume_role" {
  count = var.use_existing_oidc_role_arn == null ? 1 : 0

  statement {
    sid     = "AllowGitHubOIDC"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github[0].arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      # Allow any branch/tag from any repo under the org.
      # Tighten to a specific repo + branch before production use.
      values = ["repo:${var.github_org}/*"]
    }
  }
}

resource "aws_iam_role" "github_actions_cicd" {
  # Skip if using existing role
  count = var.use_existing_oidc_role_arn == null ? 1 : 0

  name               = "${local.name}-github-actions-cicd"
  description        = "Assumed by GitHub Actions via OIDC to provision EKS runner infrastructure"
  assume_role_policy = data.aws_iam_policy_document.github_actions_assume_role[0].json

  # Prevent accidental deletion via console
  lifecycle {
    prevent_destroy = false
  }

  tags = local.tags
}

# ── Permissions ────────────────────────────────────────────────────────────────
# AdministratorAccess is broad but practical for bootstrapping.
# Replace with a tightly-scoped policy (EC2, EKS, IAM, VPC, SQS, ECR, SecretsManager)
# before production use.
resource "aws_iam_role_policy_attachment" "github_actions_admin" {
  # Skip if using existing role
  count = var.use_existing_oidc_role_arn == null ? 1 : 0

  role       = aws_iam_role.github_actions_cicd[0].name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}
