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
    # All values injected via -backend-config flags at `terraform init` time.
    # See Makefile → init target, or release.yaml workflow.
    #
    # use_lockfile requires S3 Object Lock enabled at bucket creation, which the
    # bootstrap Makefile does not set. Removed to avoid silent lock failures;
    # DynamoDB locking is passed via -backend-config="dynamodb_table=..." instead.
  }
}
