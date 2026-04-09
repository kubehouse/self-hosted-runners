# Implementation Notes — Cost-Optimized POC Setup

## Changes Made

### 1. Remote State Backend (S3)

**File**: `terraform/backend.tf`

- Switched from local backend to S3 remote backend
- State bucket: `aws-terraform-state-files-573723531607-eu-west-2-anself-hosted-runners`
- DynamoDB lock table: `github-runners-tf-state-lock`
- Region: `eu-west-2`

**Why**: Remote state enables CI/CD pipelines to share infrastructure state across runs and teams.

**To initialize the remote backend locally:**
```bash
make init  # Automatically applies -backend-config flags
```

### 2. Existing OIDC Role Integration

**Files**: `terraform/iam.tf`, `terraform/variables.tf`, `terraform/outputs.tf`

- Added `use_existing_oidc_role_arn` variable to reference your existing role
- When set, skips IAM role creation and uses the provided ARN instead
- Reference: `arn:aws:iam::573723531607:role/github_oidc_role`

**Configuration in tfvars:**
```hcl
use_existing_oidc_role_arn = "arn:aws:iam::573723531607:role/github_oidc_role"
```

**Benefit**: Avoids creating redundant roles and maintains existing permissions.

### 3. Cost Optimizations for POC

#### Disabled Windows Runners
- **File**: `terraform/terraform.tfvars`
- `windows_runner_max_count = 0` (disabled by default)
- Windows EC2 instances run ~2x more expensive than Linux equivalents
- Can be re-enabled by setting `windows_runner_max_count > 0` when needed

#### Reduced Linux Runner Capacity
- **Default**: `max_count = 5` (was 20)
- All runners start with `min_count = 0` (scale to zero when idle)
- Karpenter automatically spins up instances only when jobs arrive

#### Spot Instance Priority
- **File**: `karpenter/nodepool-linux.yaml`
- Prefers Spot instances (~70% discount vs On-Demand)
- Falls back to On-Demand if Spot capacity unavailable
- Safe for CI/CD: Spot interruptions trigger pod rescheduling

#### Instance Type Selection
- **Types**: `t3.medium`, `t3.large`, `t3.xlarge`, `t3a.*`, `t2.*`
- Micro instances (`t*.nano`, `t*.small`) skipped (insufficient for build jobs)
- Burstable instances (t3) chosen for variable workloads
- Multiple families maximize Spot availability

#### System Node Group
- **Type**: `t3.medium` (single on-demand instance)
- **Role**: Runs Karpenter controller, ARC controller, CoreDNS only
- Tainted with `CriticalAddonsOnly=true` to prevent runner pods
- Size is appropriate for POC; production should use 2+ for HA

### 4. CI/CD Pipeline Updates

**File**: `.github/workflows/release.yaml`

- Updated S3 bucket and region for remote state
- Uses OIDC role to authenticate with AWS (no static credentials)
- Automatically applies `-backend-config` flags during init

**Required GitHub Secrets:**
```
AWS_CICD_ROLE_ARN    = arn:aws:iam::573723531607:role/github_oidc_role
RUNNER_GITHUB_PAT    = ghp_... (GitHub PAT with admin:org scope)
```

---

## EKS Managed Node Group Creation Time

**Current Status**: ~17m 50s for first node group (normal behavior)

### Why It Takes Long

1. **EKS Control Plane Initialization**: ~5-7 minutes
   - API server, scheduler, controller-manager startup
   - VPC CNI plugin configuration
   - CoreDNS pod scheduling
   
2. **EC2 Node Launch + Kubelet Registration**: ~5-10 minutes
   - Instance type availability determination
   - EC2 instance launch
   - EBS volume attachment
   - VPC CNI IPAM configuration
   - Kubelet bootstrap and TLS certificate generation
   - Node registration with API server

3. **Add-on Health Checks**: ~2-5 minutes
   - CoreDNS readiness probe
   - VPC CNI pod readiness (especially slow on first install)
   - EKS Pod Identity agent readiness
   - Karpenter controller deployment (on system node)

### Is This A Problem?

**For POC/Development**: Generally acceptable. This only happens once during initial provisioning.

**Optimization Options** (if re-provisioning regularly):

1. **Use smaller instance pool** (already done: t3.medium for system)
2. **Disable unnecessary add-ons** during initial creation (trades off functionality)
3. **Use Fargate** for control plane (not applicable here—need node-based controllers)
4. **Pre-create and snapshot AMIs** with Kubelet + CNI (requires custom tooling)

### After First Provisioning

- Subsequent `terraform apply` runs are much faster (~2-5 min)
- Karpenter-managed nodes scale up in ~2-3 minutes
- Pod startup is immediate once node is ready

**Recommendation**: Acceptable for POC. If you frequently destroy/rebuild, consider:
- Using a persistent EKS cluster with temporary ARC runner scale sets
- Pre-creating AMIs with dependencies baked in

---

## Next Steps

### Local Development
```bash
export GITHUB_PAT=ghp_...
make plan                    # Review changes
make apply                   # Provision infrastructure
make kubeconfig              # Configure kubectl
make status                  # Check pod and node status
```

### CI/CD Deployment

1. Push to `main` branch → `release.yaml` runs `terraform plan` automatically
2. Review plan in GitHub Actions output
3. Approve deployment via GitHub Environment gates
4. `terraform apply` runs automatically

### Cost Monitoring

Monitor AWS costs via:
- AWS Cost Explorer (filter by tag `ManagedBy=terraform`)
- Spot instance pricing dashboard
- Karpenter metrics (`kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter -f`)

**Expected Monthly Cost** (rough estimate):
- System node (1× t3.medium on-demand): ~$20-25
- Runner nodes (variable, Spot): ~$5-50 depending on activity
- **Total POC**: ~$30-80/month

---

## Rollback

To revert to local state or a different backend:

```bash
# Edit backend.tf to use "local" {} or different backend config
cd terraform
terraform init -migrate-state  # Migrate state back to new backend
```

To disable cost optimizations and re-enable Windows:
```hcl
windows_runner_max_count = 10  # Re-enable
linux_runner_max_count = 20    # Increase capacity
```

---

## Troubleshooting

### State Lock Errors
The local backend's lock file can get stuck. Fix with:
```bash
rm -f terraform/.terraform.tfstate.lock.info
killall terraform 2>/dev/null || true
```

### OIDC Role Issues
If GitHub Actions can't assume the role:
1. Verify role exists: `aws iam get-role --role-name github_oidc_role`
2. Check trust policy includes your GitHub org
3. Verify OIDC provider thumbprints are current (check `terraform/iam.tf`)

### Runner Pod CrashLoops
Check logs:
```bash
kubectl logs -n arc-runners -f                  # ARC controller
kubectl logs -n arc-runners -f -l app.kubernetes.io/name=gha-runner-scale-set  # Runner pods
```
