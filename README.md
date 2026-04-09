# GitHub Self-Hosted Runners on EKS

Self-hosted GitHub Actions runners for the **kubehouse** organisation, running on AWS EKS with Karpenter autoscaling. Nodes spin up on demand when a job is queued and terminate when idle — you pay only for active CI time.

## Architecture

```
GitHub Actions job queued
        │
        ▼
  ARC Scale Set Controller  (arc-systems namespace, system node group)
        │  watches job queue via GitHub API
        ▼
  AutoscalingRunnerSet  ──► creates runner Pod
        │
        ▼
  Karpenter  (karpenter namespace, system node group)
        │  sees unschedulable Pod → provisions EC2 node
        ▼
  EC2 Node  (Karpenter-managed, terminates when idle)
        │
        ▼
  Runner Pod executes job steps
```

**Namespaces**

| Namespace | Contents |
|---|---|
| `karpenter` | Karpenter controller |
| `arc-systems` | ARC scale set controller |
| `arc-runners` | Runner pods + GitHub PAT secret |

**Workflows use**

| `runs-on` label | OS | Node type |
|---|---|---|
| `linux-k8s` | Amazon Linux 2023 | Spot → On-Demand fallback |
| `windows-k8s` | Windows Server 2022 | On-Demand → Spot fallback |

---

## Prerequisites

Install these tools before you start:

| Tool | Minimum version | Install |
|---|---|---|
| [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html) | v2 | `brew install awscli` |
| [Terraform](https://developer.hashicorp.com/terraform/downloads) | 1.14.8 | `brew install terraform` |
| [kubectl](https://kubernetes.io/docs/tasks/tools/) | 1.29 | `brew install kubectl` |
| [Helm](https://helm.sh/docs/intro/install/) | v3 | `brew install helm` |

Your AWS IAM identity needs permissions for: EKS, EC2, VPC, IAM, SQS, EventBridge, and ECR Public. Attaching `AdministratorAccess` is fine for a POC — tighten it up before production.

---

## Quick Start

### 1. Configure AWS credentials

```bash
aws configure
# or, if using SSO:
aws sso login --profile your-profile
```

Verify:

```bash
aws sts get-caller-identity
```

### 2. Create a GitHub Personal Access Token

1. Go to **github.com → Settings → Developer settings → Personal access tokens → Fine-grained tokens → Generate new token**
2. Set **Resource owner** to `kubehouse`
3. Set expiry (90 days is reasonable for a POC)
4. Under **Permissions → Organization permissions**, grant:
   - **Self-hosted runners** → Read and write
5. Copy the token — you will need it in the next step

> **Classic token alternative**: create a classic PAT with the `admin:org` scope if fine-grained tokens are not available on your plan.

### 3. Clone this repo and initialise Terraform

```bash
git clone https://github.com/kubehouse/<this-repo>.git
cd <this-repo>/terraform

terraform init
```

### 4. Deploy

```bash
terraform apply \
  -var="github_pat=ghp_YOUR_TOKEN_HERE"
```

`github_config_url` defaults to `https://github.com/kubehouse` so you only need to supply the PAT.

Terraform will:
- Create a VPC in `eu-west-2`
- Provision an EKS 1.35 cluster with a 2-node system node group
- Install Karpenter via Helm
- Install the ARC controller and two runner scale sets
- Register both scale sets with your GitHub org

This takes approximately **15–20 minutes** on the first run.

### 5. Configure kubectl

```bash
$(terraform output -raw configure_kubectl)
```

Or manually:

```bash
aws eks update-kubeconfig --region eu-west-2 --name github-runners
```

### 6. Verify runners are registered

```bash
# Check ARC controller is running
kubectl get pods -n arc-systems

# Check runner scale sets
kubectl get autoscalingrunnerset -n arc-runners

# Check no pods are running yet (scale-to-zero when idle)
kubectl get pods -n arc-runners
```

Then in GitHub: **github.com/organisations/kubehouse/settings/actions/runners**

You should see two runner groups — `linux-k8s` and `windows-k8s` — with a status of **Idle**.

---

## Using runners in your workflows

Replace `ubuntu-latest` or `windows-latest` in any workflow:

```yaml
jobs:
  build:
    runs-on: linux-k8s       # ← was ubuntu-latest

  build-windows:
    runs-on: windows-k8s     # ← was windows-latest
```

### Minimal example

```yaml
name: Hello from self-hosted runner

on: [push]

jobs:
  hello:
    runs-on: linux-k8s
    steps:
      - uses: actions/checkout@v4
      - run: echo "Running on $RUNNER_NAME ($RUNNER_OS)"
```

### CI workflow

See [`.github/workflows/ci.yaml`](.github/workflows/ci.yaml) — runs on every push and pull request. Includes Node.js install, lint, test, and build steps on both Linux and Windows runners.

### Release workflow

See [`.github/workflows/release.yaml`](.github/workflows/release.yaml) — triggered by a version tag.

```bash
git tag v1.0.0
git push origin v1.0.0
```

This builds a release artefact, runs tests, and publishes a GitHub Release with auto-generated release notes.

---

## Windows runners

> **Important**: GitHub does not publish an official Windows ARC runner image.

Before `windows-k8s` jobs will work you need to:

1. Build a Windows container image from the [actions/runner Dockerfiles](https://github.com/actions/runner/tree/main/images)
2. Push it to a registry Kubernetes can pull from (e.g. ECR, GHCR, Docker Hub)
3. Set the image in Terraform:

```bash
terraform apply \
  -var="github_pat=ghp_YOUR_TOKEN" \
  -var="windows_runner_image=ghcr.io/kubehouse/windows-runner:ltsc2022"
```

Until then, comment out the `test-windows` job in `ci.yaml` to avoid failed runs.

---

## Scaling

Runner counts are controlled by two Terraform variables. Karpenter automatically provisions the right number of EC2 nodes to match.

| Variable | Default | Description |
|---|---|---|
| `linux_runner_min_count` | `0` | Minimum idle Linux runners (0 = scale to zero) |
| `linux_runner_max_count` | `20` | Maximum concurrent Linux runners |
| `windows_runner_min_count` | `0` | Minimum idle Windows runners |
| `windows_runner_max_count` | `10` | Maximum concurrent Windows runners |

To increase the Linux cap to 50:

```bash
terraform apply \
  -var="github_pat=ghp_YOUR_TOKEN" \
  -var="linux_runner_max_count=50"
```

---

## Destroying all resources

Run the included script from the repo root. It handles teardown in the correct order so AWS does not block on dangling ENIs or load balancers.

```bash
./destroy.sh
```

**What it does, in order:**

1. Reads cluster name and region from Terraform state
2. Deletes Karpenter `NodePool` objects — Karpenter drains and terminates all runner EC2 nodes
3. Waits until every Karpenter-managed node is gone from Kubernetes
4. Deletes `EC2NodeClass` objects
5. Uninstalls Helm releases: runner scale sets → ARC controller → Karpenter
6. Runs `terraform destroy -auto-approve`
7. Scans for and removes any orphaned EC2 instances or load balancers

You will be asked to type `destroy` to confirm before anything is deleted.

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
```

**Node stuck in Pending**

```bash
kubectl describe pod <runner-pod> -n arc-runners
# Look for "no matching NodePool" or EC2 capacity errors
```

**terraform destroy fails with dependency error**

This usually means a Karpenter node is still running with an ENI in a subnet Terraform is trying to delete. Run:

```bash
aws ec2 describe-instances \
  --region eu-west-2 \
  --filters "Name=tag:Cluster,Values=github-runners" "Name=instance-state-name,Values=running" \
  --query "Reservations[].Instances[].InstanceId" \
  --output text
```

Then terminate those instances and re-run `terraform destroy`.
