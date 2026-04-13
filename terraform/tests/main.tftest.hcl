# Terraform native tests — run with: make test
#                                    OR: cd terraform && terraform test
#
# Requires Terraform >= 1.6 (available in >= 1.14.8 as used here).
#
# Mock providers allow the tests to plan without live AWS credentials or a
# remote backend. This validates conditional resource creation logic and
# catches variable constraint issues before any infrastructure is touched.
#
# What is tested:
#   1. A Linux-only configuration produces a valid plan.
#   2. Windows runner Helm release is omitted when max_count = 0.
#   3. Windows runner Helm release IS created when max_count > 0.
#   4. The GitHub Actions IAM role is not created when an existing OIDC role ARN
#      is supplied — avoids duplicate role conflicts on re-apply.

# ── Mock providers ─────────────────────────────────────────────────────────────
# These stubs replace real provider calls so the tests are fully offline.

mock_provider "aws" {
  # Return a realistic AZ list so cidrsubnet arithmetic in vpc.tf works.
  mock_data "aws_availability_zones" {
    defaults = {
      names    = ["eu-west-2a", "eu-west-2b", "eu-west-2c"]
      zone_ids = ["euw2-az1", "euw2-az2", "euw2-az3"]
      state    = "available"
    }
  }
}

mock_provider "kubernetes" {}
mock_provider "helm" {}
mock_provider "kubectl" {}

# ── Shared variable defaults ───────────────────────────────────────────────────
# Override individual variables inside each `run` block as needed.

variables {
  aws_region        = "eu-west-2"
  cluster_name      = "test-github-runners"
  cluster_version   = "1.35"
  vpc_cidr          = "10.0.0.0/16"
  github_config_url = "https://github.com/test-org"

  # Placeholder PAT — never use a real token in tests.
  github_pat = "ghp_placeholder_token_for_tests_only"

  linux_runner_min_count = 0
  linux_runner_max_count = 5
  linux_runner_image     = "ghcr.io/actions/actions-runner:latest"

  windows_runner_min_count = 0
  windows_runner_max_count = 0
  windows_runner_image     = "ghcr.io/actions/actions-runner:latest"

  github_org = "test-org"

  # Use an existing role ARN so the IAM creation path is skipped by default.
  use_existing_oidc_role_arn = "arn:aws:iam::123456789012:role/existing-oidc-role"

  karpenter_version = "1.3.3"
  arc_version       = "0.10.1"
}

# ── Test 1: base Linux-only configuration ─────────────────────────────────────

run "linux_only_config_produces_valid_plan" {
  command = plan

  assert {
    condition     = var.linux_runner_max_count > 0
    error_message = "linux_runner_max_count must be > 0 for the scale set to be useful"
  }

  assert {
    condition     = var.linux_runner_min_count >= 0
    error_message = "linux_runner_min_count must be >= 0 (0 = scale to zero)"
  }
}

# ── Test 2: Windows disabled when max_count = 0 ────────────────────────────────

run "windows_runner_omitted_when_max_count_zero" {
  command = plan

  variables {
    windows_runner_max_count = 0
  }

  # The helm_release.arc_runner_windows resource uses count = max_count > 0 ? 1 : 0.
  # When max_count = 0, the count is 0 and the resource list must be empty.
  assert {
    condition     = length(helm_release.arc_runner_windows) == 0
    error_message = "Windows Helm release must not be created when windows_runner_max_count = 0"
  }
}

# ── Test 3: Windows runner created when max_count > 0 ─────────────────────────

run "windows_runner_created_when_max_count_positive" {
  command = plan

  variables {
    windows_runner_max_count = 2
  }

  assert {
    condition     = length(helm_release.arc_runner_windows) == 1
    error_message = "Windows Helm release must be created when windows_runner_max_count > 0"
  }
}

# ── Test 4: existing OIDC role skips IAM role creation ────────────────────────

run "existing_oidc_role_skips_iam_creation" {
  command = plan

  variables {
    use_existing_oidc_role_arn = "arn:aws:iam::573723531607:role/github_oidc_role"
  }

  # aws_iam_role.github_actions_cicd uses count = existing_arn == null ? 1 : 0.
  # Supplying an ARN must result in an empty list (no new role).
  assert {
    condition     = length(aws_iam_role.github_actions_cicd) == 0
    error_message = "IAM role must not be created when use_existing_oidc_role_arn is set"
  }
}
