# Recommendations

**Date:** 2026-04-13
**Status:** POC complete and verified. The items below are improvements to make before treating this as production infrastructure.

Items are grouped by priority: security first, then reliability, then cost, then observability.

---

## Security

### 1. Replace `AdministratorAccess` on the CI/CD IAM role with a least-privilege policy

**Current state:** `aws_iam_role_policy_attachment.github_actions_admin` attaches `arn:aws:iam::aws:policy/AdministratorAccess` to the GitHub Actions OIDC role.

**Risk:** Any workflow in the `kubehouse` org that assumes this role has full AWS account access. A compromised workflow or a malicious pull request that can trigger CI could enumerate, exfiltrate, or destroy any resource in the account.

**Recommendation:** Replace with an inline policy scoped to the exact actions Terraform needs:
- `ec2:*` (VPC, subnets, NAT, security groups, instances for Karpenter)
- `eks:*` (cluster, node groups, addons, access entries)
- `iam:*` (roles, policies, OIDC providers, instance profiles)
- `kms:*` (key management for EKS secrets encryption)
- `s3:GetObject`, `s3:PutObject`, `s3:DeleteObject`, `s3:ListBucket` (Terraform state)
- `sqs:*` (Karpenter interruption queue)
- `ecr:GetAuthorizationToken`, `ecr:BatchGetImage` (if using private ECR images)
- `secretsmanager:GetSecretValue` (if secrets are stored there)

Start by running a `terraform plan` with `--generate-config-out` and reviewing the exact API calls in CloudTrail for one full apply cycle.

---

### 2. Tighten the OIDC trust policy to a specific repository and branch

**Current state:** `iam.tf` uses `repo:${var.github_org}/*` — any repository, any branch, any event in the `kubehouse` org can assume the CI/CD role.

**Risk:** A new repository created in the org (or a fork that triggers workflows) would immediately have the ability to assume the role.

**Recommendation:** Restrict to the specific repository and `main` branch only:
```hcl
values = ["repo:${var.github_org}/self-hosted-runners:ref:refs/heads/main"]
```
For `plan` (which runs on PRs), add a second condition for pull request events:
```hcl
values = [
  "repo:${var.github_org}/self-hosted-runners:ref:refs/heads/main",
  "repo:${var.github_org}/self-hosted-runners:pull_request",
]
```

---

### 3. Replace the GitHub PAT with a GitHub App

**Current state:** A personal access token (`ghp_...`) is stored as a Kubernetes Secret and used by ARC to authenticate with the GitHub Actions API.

**Risk:** PATs are tied to an individual user account. If that account is deactivated, all runners stop. PATs also have broader default permissions than a GitHub App installation token, and they do not expire by default.

**Recommendation:** Create a GitHub App for the `kubehouse` org with only `Actions: Read` and `Administration: Read/Write` permissions. ARC v0.10+ supports GitHub App authentication natively:
```yaml
githubConfigSecret:
  github_app_id: "..."
  github_app_installation_id: "..."
  github_app_private_key: "..."
```
Store the private key in AWS Secrets Manager and inject it via an External Secrets Operator rather than committing it to Terraform state.

---

### 4. Restrict the EKS public API endpoint to known CIDRs

**Current state:** `endpoint_public_access = true` with no CIDR restriction — the Kubernetes API server is reachable from any IP on the internet.

**Risk:** Exposes the API server to brute-force and credential-stuffing attacks. Although auth is required, the attack surface is unnecessarily wide.

**Recommendation:**
```hcl
endpoint_public_access_cidrs = ["<your-office-cidr>/32", "<your-vpn-cidr>/32"]
```
For CI/CD (which runs `kubectl` or `helm`), add the GitHub Actions IP ranges, or use a private endpoint with a VPC-based runner for Terraform operations.

---

### 5. Add network policies to restrict pod-to-pod traffic

**Current state:** No `NetworkPolicy` resources are defined. All pods in the cluster can communicate with each other freely.

**Risk:** A compromised runner pod could reach the Karpenter controller, ARC controller, or the EKS metadata endpoint.

**Recommendation:** Add default-deny policies for `arc-runners` and allow only egress to GitHub and Docker Hub:
```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: arc-runners
spec:
  podSelector: {}
  policyTypes: [Ingress]
```
vpc-cni supports Kubernetes network policies natively from EKS 1.25+ via `ENABLE_NETWORK_POLICY_CONTROLLER=true` on the addon.

---

### 6. Block IMDS access from runner pods

**Current state:** Runner pods run on Karpenter-managed nodes with an EC2 instance profile (`karpenter_node_role`). By default, any pod on the node can reach the Instance Metadata Service (IMDS) and obtain the node's IAM credentials.

**Risk:** A malicious workflow step could call `curl http://169.254.169.254/latest/meta-data/iam/security-credentials/...` and obtain the node role's credentials, which include `AmazonEKSWorkerNodePolicy` and `AmazonEC2ContainerRegistryReadOnly`.

**Recommendation:** Set `httpPutResponseHopLimit = 1` on the `EC2NodeClass` to prevent pods from reaching IMDS (the default hop limit of 2 allows pods; hop limit of 1 restricts to the node itself):
```hcl
resource "kubectl_manifest" "karpenter_nodeclass_linux" {
  yaml_body = yamlencode({
    ...
    spec = {
      metadataOptions = {
        httpPutResponseHopLimit = 1
        httpTokens              = "required"  # enforce IMDSv2
      }
    }
  })
}
```

---

## Reliability

### 7. Raise system node group to `desired_size = 2` across two AZs

**Current state:** `desired_size = 1` — one t3.medium in a single AZ.

**Impact:** Karpenter's Helm chart deploys two replicas with a zone-based topology spread constraint. With one system node, the second replica is permanently `Pending`. If the single node fails or is replaced (e.g. during an AMI update), there is a brief window where Karpenter is unavailable and no new runner nodes can be provisioned.

**Recommendation:**
```hcl
min_size     = 2
max_size     = 3
desired_size = 2
```
Two nodes also ensures ARC controller and ARC listener are spread across zones.

---

### 8. Use three NAT gateways for production

**Current state:** `single_nat_gateway = true` in `vpc.tf`.

**Impact:** All private-subnet traffic (Docker image pulls, GitHub API, package installs) routes through a single NAT gateway in one AZ. A NAT gateway failure or AZ outage makes all nodes in the other two private subnets unable to reach the internet, blocking all running and new jobs.

**Recommendation:** Set `single_nat_gateway = false` (one NAT gateway per AZ). The cost increase (~$100/month for two additional NAT gateways in eu-west-2) is worth it for a production workload.

---

### 9. Pin runner image to a specific digest rather than `latest`

**Current state:** `linux_runner_image = "ghcr.io/actions/actions-runner:latest"` in `variables.tf`.

**Risk:** A breaking change in the upstream image can silently fail new runner pods after a registry push. `latest` is also not reproducible — two pods started an hour apart may run different versions.

**Recommendation:** Pin to a specific SHA digest:
```hcl
default = "ghcr.io/actions/actions-runner@sha256:<digest>"
```
Or pin to a semver tag (e.g. `2.333.1`) and update deliberately when a new version is tested.

---

### 10. Add a Pod Disruption Budget for the ARC controller

**Current state:** No PDB is defined for `arc-gha-rs-controller`.

**Impact:** During a system node group rolling update (e.g. AMI upgrade), Kubernetes may evict the ARC controller pod and listener simultaneously, causing a gap in job scheduling.

**Recommendation:** Add a PDB via the ARC controller Helm values:
```hcl
values = [yamlencode({
  ...
  podDisruptionBudget = { minAvailable = 1 }
})]
```

---

### 11. Add a Spot interruption handler for runner nodes

**Current state:** Karpenter is configured with an SQS interruption queue (the `karpenter` module creates it). However, there is no mechanism to drain runner pods gracefully when a Spot interruption notice arrives.

**Context:** Each runner pod handles exactly one job. A 2-minute Spot interruption warning is not enough for long-running jobs. ARC does not re-queue jobs automatically on interruption — the job fails and the workflow must be re-triggered manually.

**Recommendation:** Karpenter already handles Spot interruption drain events via the SQS queue — verify the queue ARN is passed correctly and that Karpenter's `featureGates.spotToSpotConsolidation` is enabled. For jobs that must not be interrupted, add `capacityType: on-demand` to the NodePool selector via a workflow-level label.

---

## Cost

### 12. Enable Karpenter consolidation

**Current state:** The `linux-runners` NodePool in `karpenter.tf` likely has default consolidation settings.

**Recommendation:** Explicitly configure consolidation to bin-pack nodes aggressively when runners are idle:
```yaml
disruption:
  consolidationPolicy: WhenEmptyOrUnderutilized
  consolidateAfter: 30s
```
`WhenEmptyOrUnderutilized` (available from Karpenter v1.0+) will also consolidate partially utilised nodes, not just empty ones. This can significantly reduce costs when runner pod density is low.

---

### 13. Add instance type diversity to the Karpenter NodePool

**Current state:** The `linux-runners` NodePool likely specifies a limited set of instance types or families.

**Recommendation:** Widen the instance type selection to maximise Spot availability and minimise the risk of `InsufficientInstanceCapacity` errors during peak demand:
```yaml
requirements:
  - key: karpenter.k8s.aws/instance-family
    operator: In
    values: [c5, c6i, c6a, m5, m6i, m6a, r5, r6i]
  - key: karpenter.k8s.aws/instance-size
    operator: In
    values: [large, xlarge, 2xlarge]
  - key: kubernetes.io/arch
    operator: In
    values: [amd64]
```
More instance families → more Spot pools → lower interruption rate and better price.

---

### 14. Set resource `requests` accurately on runner containers

**Current state:** Runner containers request `500m CPU / 512Mi memory`. These values determine how many runner pods Karpenter fits per node.

**Recommendation:** Profile actual job resource usage (check `kubectl top pod -n arc-runners` during a representative job) and tune requests to match the p95 usage. Oversized requests waste capacity; undersized requests cause CPU throttling and OOM kills.

---

## Observability

### 15. Enable EKS control plane logging

**Current state:** No `cluster_enabled_log_types` is set in `eks.tf`, so control plane logs are not shipped to CloudWatch.

**Recommendation:**
```hcl
cluster_enabled_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
```
`audit` logs are particularly valuable for diagnosing IAM/RBAC issues and detecting unexpected API calls. Note: CloudWatch log ingestion costs apply (~$0.50/GB in eu-west-2).

---

### 16. Add Prometheus metrics scraping for Karpenter and ARC

**Current state:** No metrics collection is configured.

**Recommendation:** Both Karpenter and ARC expose Prometheus metrics endpoints. Deploy the Prometheus Operator (or use Amazon Managed Prometheus) and scrape:
- `karpenter-metrics:8080` — node provisioning latency, Spot interruption rate, pod scheduling queue depth
- ARC controller metrics — job queue length, runner lifecycle events

Key Karpenter alerts to configure:
- `karpenter_nodes_total > 0` for longer than expected (nodes not terminating after jobs complete)
- `karpenter_pods_scheduling_errors_total` increasing (NodePool constraints too tight)

---

### 17. Tag all resources with a `cost-centre` or `team` tag for billing attribution

**Current state:** `local.tags` includes `project` and `managed-by` but no cost-centre identifier.

**Recommendation:** Add to `locals.tf`:
```hcl
tags = {
  project    = local.name
  managed-by = "terraform"
  team       = "platform"
  cost-centre = "ci-cd"
  environment = var.environment
}
```
Enable AWS Cost Explorer tag-based grouping to see exactly how much the runner infrastructure costs per month, broken down by EC2 (Karpenter nodes), EKS (control plane), NAT gateway, and data transfer.

---

### 18. Add a runbook for common failure scenarios

**Current state:** `feedback-1.md` documents the vpc-cni incident. `feedback-3.md` documents the initial setup fixes.

**Recommendation:** Create a `runbook.md` (or `docs/runbook.md`) covering the most likely production incidents:

| Scenario | First check | Recovery |
|---|---|---|
| Runners not starting | `kubectl get pods -n arc-systems` — is listener Running? | Restart listener pod; check PAT expiry |
| Jobs queued but no nodes provisioning | `kubectl logs -n kube-system -l app.kubernetes.io/name=karpenter` | Check NodePool constraints; check Spot capacity |
| Node stuck in `NotReady` | SSM → `journalctl -u kubelet` | Check vpc-cni DaemonSet: `kubectl get pods -n kube-system -l k8s-app=aws-node` |
| Apply fails with lock timeout | `terraform force-unlock <lock-id>` | Verify no concurrent apply is running |
| KMS key in PendingDeletion | `aws kms cancel-key-deletion` + `terraform import` | See `feedback-3.md` Fix 6 |
