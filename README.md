# GitHub Self-Hosted Runners on EKS

Ephemeral, auto-scaling GitHub Actions runners for the **kubehouse** organisation, running on Amazon EKS with Karpenter. Nodes spin up on demand when a job is queued and are terminated within 30 seconds of going idle — you pay only for active CI time.

---

## Why This Matters

### Cost efficiency

GitHub-hosted runners are convenient but expensive at scale. An `ubuntu-latest` runner costs roughly $0.008 per minute. A team running 500 CI minutes per day spends ~$1,200/month on runner compute alone — before any data transfer or storage.

This platform replaces those runners with EC2 **Spot instances** (up to 90 % cheaper than On-Demand) that exist only for the duration of each job. The system nodes that run the controllers are always-on, but they are tiny (`t3.medium`) and represent a negligible fraction of the total cost.

### Scale to zero

`minRunners = 0` means no runner pods — and no EC2 nodes — are running when there are no queued jobs. There is no "warm pool" to pay for overnight or at weekends.

### Ephemeral by design

Each runner pod handles exactly one job and is then destroyed. There is no state carried between jobs, no leftover files from a previous build, and no way for a compromised job to poison the runner environment for the next one. This matches — and improves on — the security model of GitHub-hosted runners.

### Scalability

Karpenter launches new EC2 nodes in 60–90 seconds (vs 3–5 minutes for an EC2 Auto Scaling group). ARC can scale a runner set from 0 to `maxRunners` pods in a single reconciliation loop. The platform can handle sudden bursts without pre-provisioning capacity.

---

## How It Works

```
GitHub workflow queued (runs-on: linux-k8s)
          │
          ▼
ARC Scale Set Controller  ──  polls GitHub Actions API
          │                   detects pending job
          ▼
Runner Pod created in arc-runners namespace
          │
          ▼  (Pod is Unschedulable — no matching node)
Karpenter Controller
          │  evaluates NodePool constraints
          │  selects cheapest available Spot instance
          │  calls EC2 CreateFleet
          ▼
EC2 node boots with Amazon Linux 2023 (~90 s)
          │
          ▼
Runner Pod scheduled → job executes
          │
          ▼
Job completes → Pod exits → node idle → Karpenter terminates (~30 s)
```

**Runner pod topology (Docker-in-Docker):**

```
init-dind-externals  ──  copies runner binaries to shared volume
runner               ──  executes workflow steps, uses dind socket
dind                 ──  privileged Docker daemon on /var/run/docker.sock
```

This gives workflows full Docker support (build, run, compose) identical to GitHub-hosted `ubuntu-latest`.

For a deeper breakdown including network, IAM, and trade-off analysis, see [Architecture.md](Architecture.md).

---

## Repository Structure

```
.
├── .github/
│   └── workflows/
│       ├── ci.yaml          # PR checks: fmt, validate, lint, Checkov, Gitleaks, plan, Infracost
│       └── release.yaml     # Merge to main: plan → approval gate → apply
├── docker/
│   ├── linux/Dockerfile     # Custom Linux DinD runner image (optional)
│   └── windows/Dockerfile   # Custom Windows runner image (build required)
├── karpenter/
│   ├── ec2nodeclass-linux.yaml.tpl    # AL2023 node class template
│   ├── ec2nodeclass-windows.yaml.tpl  # Windows Server 2022 node class template
│   ├── nodepool-linux.yaml            # Spot/On-Demand Linux runner node pool
│   └── nodepool-windows.yaml          # On-Demand Windows runner node pool
├── terraform/
│   ├── tests/
│   │   └── main.tftest.hcl  # Terraform native tests (mock providers)
│   ├── arc.tf               # ARC controller + Linux/Windows runner scale sets
│   ├── backend.hcl.example  # Template for local backend config (gitignored)
│   ├── backend.tf           # Partial S3 backend declaration
│   ├── data.tf              # Data sources (AZs)
│   ├── eks.tf               # EKS cluster + system node group + add-ons
│   ├── iam.tf               # GitHub OIDC provider + CI/CD role
│   ├── karpenter.tf         # Karpenter Helm release + CRD manifests
│   ├── locals.tf            # Shared local values (name, region, tags)
│   ├── outputs.tf           # Cluster endpoint, kubectl command, role ARNs
│   ├── providers.tf         # AWS, Kubernetes, Helm, kubectl provider config
│   ├── terraform.tfvars     # All variable values (non-sensitive defaults)
│   ├── variables.tf         # Variable declarations with descriptions
│   ├── versions.tf          # Provider version constraints + lock file
│   └── vpc.tf               # VPC, subnets, NAT gateway
├── .gitignore
├── .pre-commit-config.yaml  # Local git hooks: fmt, tflint, checkov, gitleaks
├── .tflint.hcl              # TFLint rules: AWS ruleset, naming, documentation
├── Architecture.md          # ASCII diagrams + trade-off analysis
├── CODEOWNERS               # @francescowang owns all files
├── destroy.sh               # Ordered teardown script
└── Makefile                 # Developer workflow: init, plan, apply, lint, test, debug
```

---

## Prerequisites

| Tool | Minimum version | Install |
|---|---|---|
| [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html) | v2 | `brew install awscli` |
| [Terraform](https://developer.hashicorp.com/terraform/downloads) | 1.14.8 | `brew install terraform` |
| [kubectl](https://kubernetes.io/docs/tasks/tools/) | 1.29 | `brew install kubectl` |
| [Helm](https://helm.sh/docs/intro/install/) | v3 | `brew install helm` |
| [TFLint](https://github.com/terraform-linters/tflint#installation) | latest | `brew install tflint` |
| [Checkov](https://www.checkov.io/2.Basics/Installing%20Checkov.html) | latest | `pip install checkov` |

Your AWS identity needs: EKS, EC2, VPC, IAM, SQS, EventBridge, S3, and ECR Public. For a POC, `AdministratorAccess` is fine — tighten it before production.

---

## Step-by-Step Deployment

### 1. Configure AWS credentials

```bash
aws configure
# or, for SSO:
aws sso login --profile your-profile

# Verify:
aws sts get-caller-identity
```

### 2. Create a GitHub Personal Access Token

1. Go to **GitHub → Settings → Developer settings → Personal access tokens → Fine-grained tokens → Generate new token**
2. Set **Resource owner** to `kubehouse`
3. Set an expiry (90 days is reasonable for a POC)
4. Under **Permissions → Organisation permissions**, grant:
   - **Self-hosted runners → Read and write**
5. Copy the token — you will need it in step 4

> **Classic token alternative**: create a classic PAT with the `admin:org` scope if fine-grained tokens are unavailable on your plan.

### 3. Clone and initialise

```bash
git clone https://github.com/kubehouse/self-hosted-runners.git
cd self-hosted-runners

# Copy the backend config template and fill in your values
cp terraform/backend.hcl.example terraform/backend.hcl
# (terraform/backend.hcl is gitignored — never commit it)

# Create the S3 state bucket (once, ever)
make bootstrap

# Initialise Terraform with the S3 backend
make init
```

### 4. Review and apply

```bash
export GITHUB_PAT=ghp_your_token_here

make plan    # review what will be created
make apply   # provision everything
```

Terraform provisions, in order:
1. VPC with private/public subnets across 3 AZs
2. EKS cluster (control plane + system node group)
3. EKS add-ons: CoreDNS, kube-proxy, vpc-cni, eks-pod-identity-agent
4. Karpenter (Helm release + IAM + interruption queue + NodePool CRDs)
5. ARC controller (Helm release)
6. Linux runner scale set (Helm release, registered with GitHub)
7. GitHub OIDC provider + CI/CD IAM role (skipped if `use_existing_oidc_role_arn` is set)

This takes approximately **15–20 minutes** on the first run.

### 5. Configure kubectl

```bash
make kubeconfig
# equivalent to:
aws eks update-kubeconfig --region eu-west-2 --name github-runners
```

### 6. Verify

```bash
# Check system pods are running
kubectl get pods -n karpenter
kubectl get pods -n arc-systems

# Check runner scale sets registered (should show 0 runners — scale to zero)
kubectl get autoscalingrunnerset -n arc-runners

# Equivalent Makefile shortcut:
make status
```

In GitHub, go to **github.com/organisations/kubehouse/settings/actions/runners** — you should see `linux-k8s` registered as an Idle runner group.

### 7. Configure GitHub repository secrets and variables

In the repository **Settings → Secrets and variables → Actions**:

| Type | Name | Value |
|---|---|---|
| Secret | `RUNNER_GITHUB_PAT` | Your GitHub PAT |
| Secret | `INFRACOST_API_KEY` | From [infracost.io](https://www.infracost.io/) (free tier available) |
| Variable | `TF_DIR` | `terraform` |
| Variable | `TF_VERSION` | `1.14.8` |
| Variable | `AWS_REGION` | `eu-west-2` |
| Variable | `STATE_BUCKET` | `kubehouse-terraform-state` |
| Variable | `STATE_KEY` | `self-hosted-runners/terraform/terraform.tfstate` |
| Variable | `AWS_CICD_ROLE_ARN` | Value of `terraform output github_actions_cicd_role_arn` |

Also create a **`production` environment** (Settings → Environments → New environment → `production`) and add yourself as a Required reviewer. This gates `terraform apply` behind manual approval on every merge to main.

---

## Using the Runners in Workflows

Replace `ubuntu-latest` with `linux-k8s` in any workflow:

```yaml
jobs:
  build:
    runs-on: linux-k8s   # was: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - run: docker build -t myapp .  # Docker works via DinD sidecar
```

The first job after a period of inactivity will take ~90 seconds longer than usual (EC2 cold start). Subsequent jobs within the same burst are faster because Karpenter keeps the node running until it becomes idle.

---

## Scaling

| Variable | Default | Description |
|---|---|---|
| `linux_runner_min_count` | `0` | Idle runners kept alive (0 = scale to zero) |
| `linux_runner_max_count` | `5` | Maximum concurrent runners (cap for cost control) |
| `windows_runner_max_count` | `0` | Set > 0 to enable Windows runners |

To raise the Linux cap to 20:

```bash
# Edit terraform/terraform.tfvars:
linux_runner_max_count = 20

export GITHUB_PAT=ghp_...
make plan && make apply
```

The Karpenter NodePool `limits` in `karpenter/nodepool-linux.yaml` acts as a hard ceiling on total vCPU and memory regardless of `maxRunners`. Adjust both together when scaling up significantly.

---

## Local Development

```bash
make fmt          # auto-format all Terraform files
make fmt-check    # check formatting (what CI runs)
make validate     # terraform validate (no backend needed)
make lint         # TFLint with AWS ruleset
make security     # Checkov scan
make test         # Terraform native tests (mock providers — no AWS creds needed)
make ci           # run all of the above in sequence

make status       # show ARC pods, runner sets, and Karpenter nodes
make runners      # watch runner scale sets live (Ctrl-C to stop)
make logs-arc     # tail ARC controller logs
make logs-karpenter  # tail Karpenter controller logs
```

Install pre-commit hooks to catch issues before they reach CI:

```bash
pip install pre-commit
pre-commit install
pre-commit run --all-files  # run manually across the whole repo
```

---

## Destroying All Resources

Run the included script from the repository root. It handles teardown in the correct order so AWS does not block on dangling ENIs or load balancers.

```bash
./destroy.sh
```

The script: deletes Karpenter NodePools (terminates runner nodes) → waits for nodes to drain → deletes EC2NodeClasses → uninstalls Helm releases → runs `terraform destroy`. You will be asked to type `destroy` to confirm.

---

## Things to Keep in Mind

### EC2 Spot availability

Spot capacity is not guaranteed. If all configured instance types are unavailable simultaneously, Karpenter falls back to On-Demand. Broaden the instance type list in `karpenter/nodepool-linux.yaml` to improve Spot availability — the more diverse the list, the better the chances of finding cheap capacity.

### GitHub API rate limits

ARC polls the GitHub Actions API continuously. The polling interval is managed by ARC internally, but if you run many scale sets across many organisations, ensure you are not exhausting the 5,000 requests/hour rate limit for the PAT used. A GitHub App (higher rate limits, no expiry) is the recommended production alternative to PATs.

### IAM bootstrap chicken-and-egg

The GitHub OIDC IAM role is created by Terraform. On the very first apply, you must run locally with your own AWS credentials. After that, the CI/CD pipeline can assume the role created here. If you use an existing role (`use_existing_oidc_role_arn`), this is not a concern.

### EKS add-on conflicts (OVERWRITE)

All EKS add-ons are configured with `resolve_conflicts_on_create = "OVERWRITE"`. This is intentional — without it, a partial apply leaves add-ons in a `DEGRADED` state that blocks subsequent applies. It is safe for a fresh cluster; on an existing cluster, verify there are no custom add-on configurations before applying.

### State lock and concurrent applies

The backend uses S3 native state locking (`use_lockfile = true`, Terraform ≥ 1.10). If `terraform apply` is interrupted, the lock file remains. Release it with:

```bash
make unlock LOCK_ID=<lock-id-from-error-message>
```

### Service quota limits

Before scaling past ~20 concurrent runners, check your EC2 service quotas in `eu-west-2`:
- **Running On-Demand Standard instances** — default 32 vCPU
- **Running Spot Instance Requests** — default 32 vCPU (separate quota per instance family)

Request a quota increase via the AWS Service Quotas console before you hit the limit in production.

### Windows runner images

GitHub does not publish an official Windows ARC runner image. Before enabling Windows runners, build a custom image:

```bash
make docker-windows
docker tag github-runner-windows:latest <your-registry>/windows-runner:ltsc2022
docker push <your-registry>/windows-runner:ltsc2022

# Then update terraform.tfvars:
windows_runner_image     = "<your-registry>/windows-runner:ltsc2022"
windows_runner_max_count = 2
```

### Single NAT gateway

`single_nat_gateway = true` reduces NAT costs during a POC. For production, set it to `false` — a single NAT gateway is a regional availability risk. The extra ~$32/month per AZ is worthwhile for workloads that require high availability.

### Karpenter consolidation and disruption budgets

The NodePool `consolidateAfter: 30s` is aggressive. If your jobs take a long time to start but create bursts of short jobs, Karpenter may consolidate nodes between bursts and cause unnecessary cold starts. Tune this value to match your workload's inter-job gap.

---

## Troubleshooting

**Runners show as offline in GitHub**

```bash
kubectl describe autoscalingrunnerset linux-k8s -n arc-runners
kubectl logs -n arc-systems -l app.kubernetes.io/name=gha-runner-scale-set-controller
```

**Karpenter is not launching nodes**

```bash
kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter | grep -i error
kubectl describe nodepool linux-runners
# Look for: capacity unavailable, IAM permission denied, subnet not found
```

**Pod stuck in Pending**

```bash
kubectl describe pod <runner-pod-name> -n arc-runners
# Look for: "no matching NodePool", "0/1 nodes available", EC2 capacity errors
```

**terraform destroy fails with dependency error**

Karpenter-managed nodes may hold ENIs in subnets Terraform is trying to delete. Find and terminate them:

```bash
aws ec2 describe-instances \
  --region eu-west-2 \
  --filters \
    "Name=tag:Cluster,Values=github-runners" \
    "Name=instance-state-name,Values=running" \
  --query "Reservations[].Instances[].InstanceId" \
  --output text
```

Terminate the listed instances, then re-run `terraform destroy` or `./destroy.sh`.

**Stale Terraform state lock**

```bash
make unlock LOCK_ID=<id-from-error-output>
```

---

## References

- [Actions Runner Controller — official docs](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners-with-actions-runner-controller/about-actions-runner-controller)
- [Karpenter — getting started with EKS](https://karpenter.sh/docs/getting-started/getting-started-with-karpenter/)
- [Karpenter EC2NodeClass API reference](https://karpenter.sh/docs/concepts/nodeclasses/)
- [terraform-aws-eks module](https://github.com/terraform-aws-modules/terraform-aws-eks)
- [GitHub OIDC — configuring AWS](https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/configuring-openid-connect-in-amazon-web-services)
- [EC2 Spot best practices](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/spot-best-practices.html)
- [Infracost — CI/CD integration](https://www.infracost.io/docs/integrations/github_actions/)
- [EKS Kubernetes version support calendar](https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html)
