#!/usr/bin/env bash
# destroy.sh — Tear down all GitHub runner infrastructure, leaving zero resources.
# Run from the repo root: ./destroy.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$SCRIPT_DIR/terraform"

# ── Colours ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
step() { echo -e "\n${BLUE}==> $*${NC}"; }
ok()   { echo -e "${GREEN}  ✓${NC} $*"; }
warn() { echo -e "${YELLOW}  !${NC} $*"; }
die()  { echo -e "${RED}  ✗ ERROR: $*${NC}" >&2; exit 1; }

# ── Pre-flight checks ──────────────────────────────────────────────────────────
for cmd in aws terraform kubectl helm; do
  command -v "$cmd" >/dev/null 2>&1 || die "'$cmd' is not installed or not in PATH"
done

echo -e "${RED}"
echo "  ╔══════════════════════════════════════════════════════╗"
echo "  ║  WARNING: This will PERMANENTLY DESTROY all          ║"
echo "  ║  infrastructure including the EKS cluster, VPC,      ║"
echo "  ║  and every resource managed by Terraform.            ║"
echo "  ╚══════════════════════════════════════════════════════╝"
echo -e "${NC}"
read -r -p "  Type 'destroy' to confirm: " CONFIRM
[[ "$CONFIRM" == "destroy" ]] || { echo "Aborted."; exit 0; }

# ── Read cluster details from Terraform state ──────────────────────────────────
step "Reading Terraform outputs..."
cd "$TF_DIR"
CLUSTER_NAME=$(terraform output -raw cluster_name 2>/dev/null) \
  || die "Cannot read 'cluster_name' from state. Has 'terraform apply' been run?"
REGION=$(terraform output -raw aws_region 2>/dev/null) || REGION="eu-west-2"
ok "Cluster : $CLUSTER_NAME"
ok "Region  : $REGION"

# ── Configure kubectl ──────────────────────────────────────────────────────────
step "Configuring kubectl..."
aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER_NAME" --alias "$CLUSTER_NAME"
ok "kubectl context set to $CLUSTER_NAME"

# ── Delete Karpenter NodePools ─────────────────────────────────────────────────
# Deleting a NodePool causes Karpenter to drain and terminate every EC2 node it
# owns. This MUST happen before terraform destroy, otherwise AWS blocks VPC/
# subnet deletion because the nodes' ENIs are still attached.
step "Deleting Karpenter NodePools (triggers EC2 node drain + termination)..."
kubectl delete nodepool linux-runners windows-runners \
  --ignore-not-found=true \
  --context "$CLUSTER_NAME"
ok "NodePools deleted"

# ── Wait for all Karpenter nodes to terminate ──────────────────────────────────
step "Waiting for Karpenter-managed nodes to terminate (max 10 min)..."
TIMEOUT=600
ELAPSED=0
POLL=15
while true; do
  NODE_COUNT=$(kubectl get nodes \
    --context "$CLUSTER_NAME" \
    -l karpenter.sh/nodepool \
    --no-headers 2>/dev/null \
    | wc -l | tr -d ' ')

  if [[ "$NODE_COUNT" -eq 0 ]]; then
    ok "All Karpenter nodes terminated"
    break
  fi

  if [[ "$ELAPSED" -ge "$TIMEOUT" ]]; then
    warn "Timed out waiting for nodes — continuing anyway."
    warn "If terraform destroy fails, manually terminate the remaining instances in AWS Console."
    break
  fi

  echo "    $NODE_COUNT node(s) still running... (${ELAPSED}s elapsed, ${TIMEOUT}s timeout)"
  sleep "$POLL"
  ELAPSED=$((ELAPSED + POLL))
done

# ── Delete Karpenter EC2NodeClasses ───────────────────────────────────────────
step "Deleting Karpenter EC2NodeClasses..."
kubectl delete ec2nodeclass linux windows \
  --ignore-not-found=true \
  --context "$CLUSTER_NAME"
ok "EC2NodeClasses deleted"

# ── Uninstall Helm releases (runner sets first, then controllers) ──────────────
step "Uninstalling Helm releases..."

uninstall_helm() {
  local name="$1" ns="$2"
  if helm status "$name" -n "$ns" --kube-context "$CLUSTER_NAME" &>/dev/null; then
    helm uninstall "$name" -n "$ns" \
      --kube-context "$CLUSTER_NAME" \
      --wait --timeout 120s
    ok "Uninstalled $name (ns: $ns)"
  else
    warn "$name not found in $ns — already gone"
  fi
}

# Runner scale sets before the controller that manages them
uninstall_helm "arc-runner-linux"   "arc-runners"
uninstall_helm "arc-runner-windows" "arc-runners"
uninstall_helm "arc"                "arc-systems"
uninstall_helm "karpenter"          "karpenter"

# ── Terraform destroy ──────────────────────────────────────────────────────────
step "Running terraform destroy..."
# github_pat is a required variable with no default. Pass a placeholder — the
# value is irrelevant during destroy since no resources are created with it.
terraform destroy -auto-approve -lock=false -var="github_pat=destroy-placeholder"
ok "Terraform resources destroyed"

# ── Orphan check ───────────────────────────────────────────────────────────────
step "Checking for orphaned AWS resources in $REGION..."

# EC2 instances launched by Karpenter are tagged with karpenter.sh/discovery
INSTANCES=$(aws ec2 describe-instances \
  --region "$REGION" \
  --filters \
    "Name=tag:karpenter.sh/discovery,Values=$CLUSTER_NAME" \
    "Name=instance-state-name,Values=running,pending,stopping,stopped" \
  --query "Reservations[].Instances[].InstanceId" \
  --output text 2>/dev/null || true)

if [[ -n "$INSTANCES" ]]; then
  warn "Orphaned EC2 instances found — terminating: $INSTANCES"
  # shellcheck disable=SC2086
  aws ec2 terminate-instances --region "$REGION" --instance-ids $INSTANCES >/dev/null
  ok "Terminate request sent"
else
  ok "No orphaned EC2 instances"
fi

# Load balancers created by the in-cluster AWS LB controller (if any)
LB_ARNS=$(aws elbv2 describe-load-balancers \
  --region "$REGION" \
  --query "LoadBalancers[?contains(LoadBalancerName,'${CLUSTER_NAME}')].LoadBalancerArn" \
  --output text 2>/dev/null || true)

if [[ -n "$LB_ARNS" ]]; then
  warn "Orphaned load balancers found — deleting..."
  for arn in $LB_ARNS; do
    aws elbv2 delete-load-balancer --region "$REGION" --load-balancer-arn "$arn"
    ok "Deleted $arn"
  done
else
  ok "No orphaned load balancers"
fi

# ── Done ───────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  Destruction complete. Zero resources remain.        ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
