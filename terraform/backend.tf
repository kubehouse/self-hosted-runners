# Partial S3 backend configuration.
#
# The bucket, key, region, and dynamodb_table values are supplied at init time
# via -backend-config flags (see Makefile → init target, or the release.yaml
# workflow). This avoids hard-coding account-specific identifiers in source.
#
# First-time setup:
#   make bootstrap          # creates the S3 bucket + DynamoDB table
#   make init               # terraform init with backend config
#
# CI/CD (release.yaml) injects these via BACKEND_* environment variables.

terraform {
  backend "s3" {
    # Configured via -backend-config flags during terraform init
    # (see Makefile or CI/CD pipeline)
    use_lockfile = true
  }
}
