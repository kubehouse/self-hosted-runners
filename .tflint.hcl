plugin "aws" {
  enabled = true
  version = "0.40.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}

# ── Rules ──────────────────────────────────────────────────────────────────────

# Enforce that every aws_* resource declares at least one tag.
rule "aws_resource_missing_tags" {
  enabled  = true
  tags     = ["ManagedBy", "Project"]
  # Some data sources and ephemeral resources don't support tags.
  exclude = []
}

# Catch deprecated resource types before they break plans.
rule "terraform_deprecated_index" {
  enabled = true
}

rule "terraform_deprecated_interpolation" {
  enabled = true
}

# Require descriptions on all variables and outputs — makes the module
# self-documenting and helps reviewers understand the intent.
rule "terraform_documented_variables" {
  enabled = true
}

rule "terraform_documented_outputs" {
  enabled = true
}

# Ensure module sources pin to a specific version rather than "latest"
# so infrastructure is reproducible.
rule "terraform_module_pinned_source" {
  enabled = true
  style   = "semver"
}

# Naming conventions: snake_case for everything.
rule "terraform_naming_convention" {
  enabled = true

  variable {
    format = "snake_case"
  }

  output {
    format = "snake_case"
  }

  locals {
    format = "snake_case"
  }

  resource {
    format = "snake_case"
  }

  module {
    format = "snake_case"
  }

  data {
    format = "snake_case"
  }
}

# Warn on unused declarations that inflate the codebase.
rule "terraform_unused_declarations" {
  enabled = true
}
