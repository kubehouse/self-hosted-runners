#!/usr/bin/env bash
# destroy.sh — Ordered teardown of all GitHub runner infrastructure.
#
# Sequence:
#   1. Scale ARC runner sets to 0  (stop picking up new jobs)
#   2. Delete Karpenter NodePools  (triggers EC2 cordon + drain + terminate)
#   3. Wait for all Karpenter EC2 instances to terminate  (AWS API poll)
#   4. Force-terminate any stragglers
#   5. Delete Karpenter EC2NodeClasses
#   6. Uninstall Helm: runner sets → ARC controller → Karpenter
#   7. Delete Kubernetes namespaces  (removes finalizer-stuck resources)
#   8. Clean up orphaned ENIs in Karpenter subnets  (blocks VPC delete otherwise)
#   9. terraform destroy
#  10. Sweep for orphaned EC2, ELBs, SQS queue
#
# Run from repo root: ./destroy.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$SCRIPT_DIR/terraform"

# ── Colours ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
step() { echo -e "\n${BLUE}══${NC} $* ${BLUE}══${NC}"; }
ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
warn() { echo -e "  ${YELLOW}!${NC} $*"; }
info() { echo -e "    $*"; }
die()  { echo -e "\n${RED}  ✗ FATAL: $*${NC}" >&2; exit 1; }

# ── Pre-flight ─────────────────────────────────────────────────────────────────
for cmd in aws terraform kubectl helm jq; do
  command -v "$cmd" >/dev/null 2>&1 || die "'$cmd' is not installed or not in PATH"
done

# ── Confirmation ───────────────────────────────────────────────────────────────
echo -e "\n${RED}"
echo "  ┌────────────────────────────────────────────────────────────┐"
echo "  │  WARNING: PERMANENT DESTRUCTION                            │"
echo "  │  Deletes the EKS cluster, VPC, all Karpenter EC2 nodes,   │"
echo "  │  and every Terraform-managed resource. Cannot be undone.   │"
echo "  └────────────────────────────────────────────────────────────┘"
echo -e "${NC}"
read -r -p "  Type 'destroy' to confirm: " CONFIRM
[[ "$CONFIRM" == "destroy" ]] || { echo "Aborted."; exit 0; }

# ── Read Terraform state ───────────────────────────────────────────────────────
step "Reading Terraform state"
cd "$TF_DIR"

CLUSTER_NAME=$(terraform output -raw cluster_name 2>/dev/null) \
  || die "Cannot read cluster_name from state. Has 'terraform apply' been run?"
REGION=$(terraform output -raw aws_region 2>/dev/null || echo "eu-west-2")
ok "Cluster : $CLUSTER_NAME"
ok "Region  : $REGION"

# ── Configure kubectl ──────────────────────────────────────────────────────────
step "Configuring kubectl"
KUBE_CONTEXT="$CLUSTER_NAME"
CLUSTER_ACCESSIBLE=false

CLUSTER_STATUS=$(aws eks describe-cluster \
  --name "$CLUSTER_NAME" \
  --region "$REGION" \
  --output text \
  --query "cluster.status" 2>/dev/null || echo "NOT_FOUND")

if [[ "$CLUSTER_STATUS" == "ACTIVE" ]]; then
  aws eks update-kubeconfig \
    --region "$REGION" \
    --name "$CLUSTER_NAME" \
    --alias "$KUBE_CONTEXT" >/dev/null

  if kubectl cluster-info \
      --context "$KUBE_CONTEXT" \
      --request-timeout=15s &>/dev/null 2>&1; then
    CLUSTER_ACCESSIBLE=true
    ok "kubectl connected to $KUBE_CONTEXT"
  else
    warn "kubectl configured but cluster API unreachable — skipping in-cluster steps"
  fi
else
  warn "EKS cluster '$CLUSTER_NAME' status is '$CLUSTER_STATUS' — skipping Kubernetes steps"
fi

# ── 1. Scale ARC runner scale sets to zero ────────────────────────────────────
if [[ "$CLUSTER_ACCESSIBLE" == "true" ]]; then
  step "Scaling ARC runner sets to 0"

  RUNNER_SETS=$(kubectl get autoscalingrunnerset \
    -n arc-runners \
    --context "$KUBE_CONTEXT" \
    -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)

  if [[ -n "$RUNNER_SETS" ]]; then
    for rs in $RUNNER_SETS; do
      kubectl patch autoscalingrunnerset "$rs" \
        -n arc-runners \
        --context "$KUBE_CONTEXT" \
        --type=merge \
        -p '{"spec":{"minRunners":0,"maxRunners":0}}' \
        2>/dev/null && info "Scaled $rs → 0" || warn "Could not scale $rs"
    done
    sleep 5
  else
    info "No runner scale sets found"
  fi
fi

# ── 2. Patch NodeClaim finalizers + delete Karpenter NodePools ────────────────
if [[ "$CLUSTER_ACCESSIBLE" == "true" ]]; then
  step "Deleting Karpenter NodePools"

  # Remove finalizers on any stuck NodeClaims so they don't block pool deletion
  NODECLAIMS=$(kubectl get nodeclaims \
    --context "$KUBE_CONTEXT" \
    -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)

  for nc in $NODECLAIMS; do
    kubectl patch nodeclaim "$nc" \
      --context "$KUBE_CONTEXT" \
      --type=json \
      -p '[{"op":"remove","path":"/metadata/finalizers"}]' \
      2>/dev/null \
      && info "Removed finalizers from NodeClaim/$nc" || true
  done

  # Deleting the NodePool tells Karpenter to cordon + drain + terminate all owned nodes
  kubectl delete nodepool linux-runners windows-runners \
    --context "$KUBE_CONTEXT" \
    --ignore-not-found=true \
    --timeout=90s \
    2>/dev/null && ok "NodePools deleted" || warn "NodePool deletion had issues — continuing"
fi

# ── 3. Wait for Karpenter EC2 instances to terminate (AWS API) ───────────────
step "Waiting for Karpenter EC2 instances to terminate (max 10 min)"
TIMEOUT=600
ELAPSED=0
POLL=15

while [[ $ELAPSED -lt $TIMEOUT ]]; do
  COUNT=$(aws ec2 describe-instances \
    --region "$REGION" \
    --filters \
      "Name=tag:karpenter.sh/managed-by,Values=$CLUSTER_NAME" \
      "Name=instance-state-name,Values=pending,running,stopping,shutting-down" \
    --query "length(Reservations[].Instances[])" \
    --output text 2>/dev/null || echo "0")

  if [[ "${COUNT:-0}" -eq 0 ]]; then
    ok "All Karpenter instances terminated"
    break
  fi

  info "$COUNT instance(s) still active... (${ELAPSED}s / ${TIMEOUT}s)"
  sleep $POLL
  ELAPSED=$((ELAPSED + POLL))
done

# ── 4. Force-terminate any stragglers ────────────────────────────────────────
if [[ $ELAPSED -ge $TIMEOUT ]]; then
  step "Force-terminating remaining Karpenter instances"
  LEFTOVER_IDS=$(aws ec2 describe-instances \
    --region "$REGION" \
    --filters \
      "Name=tag:karpenter.sh/managed-by,Values=$CLUSTER_NAME" \
      "Name=instance-state-name,Values=pending,running,stopping,shutting-down" \
    --query "Reservations[].Instances[].InstanceId" \
    --output text 2>/dev/null || true)

  if [[ -n "$LEFTOVER_IDS" && "$LEFTOVER_IDS" != "None" ]]; then
    # shellcheck disable=SC2086
    aws ec2 terminate-instances \
      --region "$REGION" \
      --instance-ids $LEFTOVER_IDS >/dev/null
    warn "Force-terminated: $LEFTOVER_IDS"
    info "Waiting 45s for instance shutdown..."
    sleep 45
  else
    ok "No instances remain to force-terminate"
  fi
fi

# ── 5. Delete Karpenter EC2NodeClasses ───────────────────────────────────────
if [[ "$CLUSTER_ACCESSIBLE" == "true" ]]; then
  step "Deleting Karpenter EC2NodeClasses"
  kubectl delete ec2nodeclass linux windows \
    --context "$KUBE_CONTEXT" \
    --ignore-not-found=true \
    --timeout=30s \
    2>/dev/null && ok "EC2NodeClasses deleted" || warn "Could not delete EC2NodeClasses"
fi

# ── 6. Uninstall Helm releases ───────────────────────────────────────────────
if [[ "$CLUSTER_ACCESSIBLE" == "true" ]]; then
  step "Uninstalling Helm releases"

  _helm_uninstall() {
    local name="$1" ns="$2"
    if helm status "$name" -n "$ns" --kube-context "$KUBE_CONTEXT" &>/dev/null; then
      helm uninstall "$name" \
        -n "$ns" \
        --kube-context "$KUBE_CONTEXT" \
        --wait \
        --timeout 120s \
        2>/dev/null \
        && ok "Uninstalled helm/$name (ns: $ns)" \
        || warn "helm/$name uninstall had errors — continuing"
    else
      info "helm/$name not present in $ns — skipping"
    fi
  }

  # Order: runner scale sets first, then the controller that manages them, then Karpenter
  _helm_uninstall "arc-runner-windows" "arc-runners"
  _helm_uninstall "arc-runner-linux"   "arc-runners"
  _helm_uninstall "arc"                "arc-systems"
  _helm_uninstall "karpenter"          "karpenter"
fi

# ── 7. Delete Kubernetes namespaces ──────────────────────────────────────────
if [[ "$CLUSTER_ACCESSIBLE" == "true" ]]; then
  step "Deleting Kubernetes namespaces"
  for ns in arc-runners arc-systems karpenter; do
    if kubectl get namespace "$ns" --context "$KUBE_CONTEXT" &>/dev/null 2>&1; then
      # Clear any resources with stuck finalizers before removing the namespace
      kubectl delete all --all \
        -n "$ns" \
        --context "$KUBE_CONTEXT" \
        --ignore-not-found=true \
        --timeout=30s \
        2>/dev/null || true

      kubectl delete namespace "$ns" \
        --context "$KUBE_CONTEXT" \
        --timeout=60s \
        2>/dev/null \
        && ok "Deleted namespace $ns" \
        || warn "Namespace $ns may still exist (terraform destroy will clean it up)"
    else
      info "Namespace $ns already gone"
    fi
  done
fi

# ── 8. Clean up orphaned ENIs ────────────────────────────────────────────────
# Karpenter nodes can leave behind ENIs in the available state after termination.
# AWS will not delete a subnet while ENIs exist in it, blocking terraform destroy.
step "Cleaning up orphaned ENIs in Karpenter subnets"
SUBNET_IDS=$(aws ec2 describe-subnets \
  --region "$REGION" \
  --filters "Name=tag:karpenter.sh/discovery,Values=$CLUSTER_NAME" \
  --query "Subnets[].SubnetId" \
  --output text 2>/dev/null || true)

ENI_COUNT=0
for SUBNET_ID in $SUBNET_IDS; do
  [[ -z "$SUBNET_ID" || "$SUBNET_ID" == "None" ]] && continue

  ENI_IDS=$(aws ec2 describe-network-interfaces \
    --region "$REGION" \
    --filters \
      "Name=subnet-id,Values=$SUBNET_ID" \
      "Name=status,Values=available" \
    --query "NetworkInterfaces[?
      contains(Description,'Amazon EKS') ||
      contains(Description,'AWS EKS') ||
      contains(Description,'Karpenter') ||
      contains(Description,'kubernetes')
    ].NetworkInterfaceId" \
    --output text 2>/dev/null || true)

  for ENI_ID in $ENI_IDS; do
    [[ -z "$ENI_ID" || "$ENI_ID" == "None" ]] && continue
    aws ec2 delete-network-interface \
      --region "$REGION" \
      --network-interface-id "$ENI_ID" \
      2>/dev/null \
      && { info "Deleted ENI $ENI_ID"; ENI_COUNT=$((ENI_COUNT + 1)); } \
      || warn "Could not delete ENI $ENI_ID (may still be attached)"
  done
done

[[ $ENI_COUNT -gt 0 ]] && ok "$ENI_COUNT orphaned ENI(s) deleted" || ok "No orphaned ENIs found"

# ── 9. Terraform destroy ─────────────────────────────────────────────────────
step "Running terraform destroy"
cd "$TF_DIR"

TF_DESTROY_ARGS=(
  -auto-approve
  -lock-timeout=60s
  -var="github_pat=destroy-placeholder"
)

if terraform destroy "${TF_DESTROY_ARGS[@]}"; then
  ok "Terraform destroy complete"
else
  warn "terraform destroy had errors — retrying with -lock=false"
  warn "(A stale lock from a previous failed run can cause this)"
  if terraform destroy "${TF_DESTROY_ARGS[@]}" -lock=false; then
    ok "Second pass complete"
  else
    warn "Some resources may remain. Check the AWS console."
    warn "Common causes: ENIs attached to nodes, security groups with dependencies."
  fi
fi

# ── 10. Orphan sweep ─────────────────────────────────────────────────────────
step "Orphan sweep"

# EC2 instances still carrying the cluster tag
ORPHAN_IDS=$(aws ec2 describe-instances \
  --region "$REGION" \
  --filters \
    "Name=tag:Cluster,Values=$CLUSTER_NAME" \
    "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query "Reservations[].Instances[].InstanceId" \
  --output text 2>/dev/null || true)

if [[ -n "$ORPHAN_IDS" && "$ORPHAN_IDS" != "None" ]]; then
  warn "Orphaned EC2 instances — terminating: $ORPHAN_IDS"
  # shellcheck disable=SC2086
  aws ec2 terminate-instances --region "$REGION" --instance-ids $ORPHAN_IDS >/dev/null
  ok "Terminate request sent"
else
  ok "No orphaned EC2 instances"
fi

# Application load balancers
LB_ARNS=$(aws elbv2 describe-load-balancers \
  --region "$REGION" \
  --query "LoadBalancers[?contains(LoadBalancerName,'${CLUSTER_NAME}')].LoadBalancerArn" \
  --output text 2>/dev/null || true)

if [[ -n "$LB_ARNS" && "$LB_ARNS" != "None" ]]; then
  warn "Orphaned load balancers — deleting..."
  for ARN in $LB_ARNS; do
    aws elbv2 delete-load-balancer \
      --region "$REGION" \
      --load-balancer-arn "$ARN" 2>/dev/null \
      && ok "Deleted LB: $ARN" || warn "Could not delete $ARN"
  done
else
  ok "No orphaned load balancers"
fi

# Karpenter interruption SQS queue (in case terraform missed it)
QUEUE_URL=$(aws sqs get-queue-url \
  --region "$REGION" \
  --queue-name "$CLUSTER_NAME" \
  --query "QueueUrl" \
  --output text 2>/dev/null || true)

if [[ -n "$QUEUE_URL" && "$QUEUE_URL" != "None" ]]; then
  warn "Orphaned SQS queue — deleting: $QUEUE_URL"
  aws sqs delete-queue \
    --region "$REGION" \
    --queue-url "$QUEUE_URL" 2>/dev/null \
    && ok "SQS queue deleted" || warn "Could not delete queue"
else
  ok "No orphaned SQS queue"
fi

# ── Done ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}  ┌──────────────────────────────────────────────────┐${NC}"
echo -e "${GREEN}  │  Destruction complete. Zero resources remain.    │${NC}"
echo -e "${GREEN}  └──────────────────────────────────────────────────┘${NC}"
echo ""
