## Self-hosted GitHub Actions Runners on EKS
## ==========================================
## Prerequisites: aws-cli v2, terraform >= 1.14, kubectl, helm, docker, tflint, checkov
##
## Quick start:
##   export GITHUB_PAT=ghp_...
##   make bootstrap        # create S3 state bucket + DynamoDB table (once)
##   make init             # terraform init
##   make plan             # review changes
##   make apply            # provision everything

SHELL := /bin/bash
.DEFAULT_GOAL := help

TF_DIR       := terraform
REGION       ?= eu-west-2
CLUSTER_NAME ?= github-runners
AWS_ACCOUNT  ?= 573723531607
STATE_BUCKET ?= aws-terraform-state-files-$(AWS_ACCOUNT)-$(REGION)-an
STATE_KEY    ?= self-hosted-runners/terraform/terraform.tfstate

# ── Colours ────────────────────────────────────────────────────────────────────
BOLD  := \033[1m
RESET := \033[0m
GREEN := \033[0;32m
CYAN  := \033[0;36m
RED   := \033[0;31m

# ── Shared backend config flags (passed to all terraform init invocations) ─────
BACKEND_ARGS := \
  -backend-config="bucket=$(STATE_BUCKET)" \
  -backend-config="key=$(STATE_KEY)" \
  -backend-config="region=$(REGION)" \
  -backend-config="encrypt=true" \
  -backend-config="use_lockfile=true"

.PHONY: help bootstrap init plan plan-output apply apply-auto destroy \
        fmt fmt-check validate lint security \
        kubeconfig status runners logs \
        docker-linux docker-windows

## ─── Help ─────────────────────────────────────────────────────────────────────
help: ## Show this help
	@echo -e "\n$(BOLD)Self-hosted GitHub Actions Runners on EKS$(RESET)\n"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| sort \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  $(CYAN)%-18s$(RESET) %s\n", $$1, $$2}'
	@echo ""

## ─── One-time bootstrap ───────────────────────────────────────────────────────
bootstrap: ## Create S3 state bucket + DynamoDB lock table (run once, ever)
	@echo -e "\n$(BOLD)Bootstrapping Terraform state backend in $(REGION)...$(RESET)"
	@aws s3api create-bucket \
		--bucket $(STATE_BUCKET) \
		--region $(REGION) \
		--create-bucket-configuration LocationConstraint=$(REGION) \
		2>/dev/null && echo "  Created bucket $(STATE_BUCKET)" \
		|| echo "  Bucket $(STATE_BUCKET) already exists — skipping"
	@aws s3api put-bucket-versioning \
		--bucket $(STATE_BUCKET) \
		--versioning-configuration Status=Enabled
	@aws s3api put-bucket-encryption \
		--bucket $(STATE_BUCKET) \
		--server-side-encryption-configuration \
		  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}'
	@aws s3api put-public-access-block \
		--bucket $(STATE_BUCKET) \
		--public-access-block-configuration \
		  "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
	# No DynamoDB table is needed — using S3 lockfile (use_lockfile=true)
	@echo -e "\n$(GREEN)Bootstrap complete. Run 'make init' next.$(RESET)\n"

## ─── Terraform lifecycle ──────────────────────────────────────────────────────
init: ## terraform init (configure backend from Makefile flags)
	cd $(TF_DIR) && terraform init $(BACKEND_ARGS)

init-upgrade: ## terraform init -upgrade (refresh provider locks)
	cd $(TF_DIR) && terraform init -upgrade $(BACKEND_ARGS)

plan: ## terraform plan → saves tfplan (requires GITHUB_PAT env var)
	@test -n "$(GITHUB_PAT)" \
		|| (echo -e "$(RED)ERROR: export GITHUB_PAT=ghp_...$(RESET)" && exit 1)
	cd $(TF_DIR) && terraform plan \
		-lock=false \
		-var="github_pat=$(GITHUB_PAT)" \
		-out=tfplan \
 		-detailed-exitcode || true

plan-output: ## Convert tfplan to human-readable text output
	@test -f $(TF_DIR)/tfplan \
		|| (echo -e "$(RED)ERROR: no tfplan found — run 'make plan' first$(RESET)" && exit 1)
	cd $(TF_DIR) && terraform show -no-color tfplan > tfplan.txt
	@echo "Plan output saved to $(TF_DIR)/tfplan.txt"

apply: ## terraform apply from saved plan file
	@test -f $(TF_DIR)/tfplan \
		|| (echo -e "$(RED)ERROR: no tfplan found — run 'make plan' first$(RESET)" && exit 1)
	cd $(TF_DIR) && terraform apply -lock=false tfplan

apply-auto: ## terraform apply without plan file (auto-approve — use carefully)
	@test -n "$(GITHUB_PAT)" \
		|| (echo -e "$(RED)ERROR: export GITHUB_PAT=ghp_...$(RESET)" && exit 1)
	@echo -e "$(RED)WARNING: applying without a saved plan. Ctrl-C to abort.$(RESET)"
	@sleep 3
	cd $(TF_DIR) && terraform apply \
		-lock=false \
		-var="github_pat=$(GITHUB_PAT)" \
		-auto-approve

destroy: ## Safely destroy all infrastructure (runs destroy.sh)
	./destroy.sh

## ─── Code quality ─────────────────────────────────────────────────────────────
fmt: ## Auto-format all Terraform files in-place
	cd $(TF_DIR) && terraform fmt -recursive

fmt-check: ## Check formatting without modifying files (used in CI)
	cd $(TF_DIR) && terraform fmt -recursive -check -diff

validate: ## Validate configuration (no backend or credentials needed)
	cd $(TF_DIR) && terraform init -backend=false -reconfigure -input=false
	cd $(TF_DIR) && terraform validate

lint: ## Run TFLint with the AWS ruleset
	@command -v tflint >/dev/null 2>&1 \
		|| (echo "Install tflint: https://github.com/terraform-linters/tflint#installation" && exit 1)
	cd $(TF_DIR) && tflint --init
	cd $(TF_DIR) && tflint --recursive

security: ## Run Checkov security scan against the terraform directory
	@command -v checkov >/dev/null 2>&1 \
		|| (echo "Install checkov: pip install checkov" && exit 1)
	checkov -d $(TF_DIR) --framework terraform --compact --quiet

ci: fmt-check validate lint security ## Run all CI checks locally (fmt-check + validate + lint + security)

## ─── Cluster operations ───────────────────────────────────────────────────────
kubeconfig: ## Update ~/.kube/config for the EKS cluster
	aws eks update-kubeconfig --region $(REGION) --name $(CLUSTER_NAME)

status: ## Show ARC pods, runner scale sets, and Karpenter nodes
	@echo -e "\n$(BOLD)ARC controller (arc-systems):$(RESET)"
	@kubectl get pods -n arc-systems --no-headers 2>/dev/null || echo "  (not reachable)"
	@echo -e "\n$(BOLD)Runner pods (arc-runners):$(RESET)"
	@kubectl get pods -n arc-runners --no-headers 2>/dev/null || echo "  (not reachable)"
	@echo -e "\n$(BOLD)AutoscalingRunnerSets:$(RESET)"
	@kubectl get autoscalingrunnerset -n arc-runners -o wide 2>/dev/null || echo "  (not reachable)"
	@echo -e "\n$(BOLD)Karpenter-managed nodes:$(RESET)"
	@kubectl get nodes -l karpenter.sh/nodepool --show-labels 2>/dev/null || echo "  (not reachable)"
	@echo ""

runners: ## Watch runner scale sets (live, Ctrl-C to stop)
	kubectl get autoscalingrunnerset -n arc-runners -w

logs-arc: ## Tail ARC controller logs
	kubectl logs -n arc-systems -l app.kubernetes.io/name=gha-runner-scale-set-controller -f

logs-karpenter: ## Tail Karpenter controller logs
	kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter -f --max-log-requests 5

## ─── Docker images ────────────────────────────────────────────────────────────
docker-linux: ## Build the Linux DinD runner image locally
	docker build -t github-runner-linux:latest docker/linux/

docker-windows: ## Build the Windows runner image (requires Windows container mode)
	docker build -t github-runner-windows:latest docker/windows/
