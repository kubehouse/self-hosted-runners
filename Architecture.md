# Architecture

## Overview

This platform provisions ephemeral, auto-scaling GitHub Actions runners on AWS using:

```sh
| Layer | Technology | Role |
|---|---|---|
| Container orchestration | Amazon EKS (Kubernetes 1.35) | Runs runner pods |
| Node autoscaling | Karpenter | Provisions / deprovisions EC2 instances on demand |
| Runner lifecycle | Actions Runner Controller (ARC) | Watches GitHub job queue; creates/destroys runner pods |
| Networking | AWS VPC (private subnets + NAT gateway) | Isolates workloads from the public internet |
| State management | S3 + native S3 lockfile | Remote Terraform state with concurrent-write protection |
| CI/CD | GitHub Actions + OIDC | Keyless AWS authentication for plan and apply |
```

---

## System Diagram

```sh
┌─────────────────────────────────────────────────────────────────────────────────┐
│                               GitHub.com                                        │
│                                                                                 │
│  ┌──────────────────┐    webhook / polling     ┌───────────────────────────┐    │
│  │  Workflow YAML   │ ──────────────────────▶  │  GitHub Actions API       │    │
│  │  runs-on:        │                          │  (job queue per label)    │    │
│  │  linux-k8s       │                          └─────────────┬─────────────┘    │
│  └──────────────────┘                                        │                  │
└──────────────────────────────────────────────────────────────│──────────────────┘
                                                               │ HTTPS long-poll
                ┌──────────────────────────────────────────────▼────────────────────────┐
                │                        AWS eu-west-2                                  │
                │                                                                       │
                │  ┌─────────────────────────────────────────────────────────────────┐  │
                │  │                    VPC  10.0.0.0/16                             │  │
                │  │                                                                 │  │
                │  │  ┌──────────────────────────────────────────────────────────┐   │  │
                │  │  │              EKS Control Plane (AWS managed)             │   │  │
                │  │  │  Kubernetes API server · etcd · scheduler · controllers  │   │  │
                │  │  └───────────────────────────┬──────────────────────────────┘   │  │
                │  │                              │                                  │  │
                │  │           Private subnets (eu-west-2a/b/c)                      │  │
                │  │                              │                                  │  │
                │  │  ┌───────────────────────────┴─────────────────────────────┐    │  │
                │  │  │           System Node Group  (t3.medium × 1-2)          │    │  │
                │  │  │           On-Demand · taint: CriticalAddonsOnly         │    │  │
                │  │  │                                                         │    │  │
                │  │  │  ┌──────────────────┐   ┌──────────────────────────┐    │    │  │
                │  │  │  │    Karpenter     │   │   ARC Scale Set          │    │    │  │
                │  │  │  │    Controller    │   │   Controller             │    │    │  │
                │  │  │  │  (karpenter ns)  │   │   (arc-systems ns)       │    │    │  │
                │  │  │  └────────┬─────────┘   └────────────┬─────────────┘    │    │  │
                │  │  └───────────│──────────────────────────│──────────────────┘    │  │
                │  │              │ provision EC2            │ create runner pod     │  │
                │  │              ▼                          ▼                       │  │
                │  │  ┌──────────────────────────────────────────────────────────┐   │  │
                │  │  │      Karpenter-managed Nodes  (EC2 Spot → On-Demand)     │   │  │
                │  │  │      NodePool: linux-runners · taint: github-runner=linux│   │  │
                │  │  │                                                          │   │  │
                │  │  │  ┌──────────────────────────────────────────────────┐    │   │  │
                │  │  │  │                  Runner Pod                      │    │   │  │
                │  │  │  │                (arc-runners ns)                  │    │   │  │
                │  │  │  │                                                  │    │   │  │
                │  │  │  │  ┌──────────────────────┐  ┌──────────────────┐  │    │   │  │
                │  │  │  │  │  init-dind-externals │  │      dind        │  │    │   │  │
                │  │  │  │  │  (copies runner bins │  │  (privileged     │  │    │   │  │
                │  │  │  │  │   to shared volume)  │  │   Docker daemon) │  │    │   │  │
                │  │  │  │  └──────────────────────┘  └────────┬─────────┘  │    │   │  │
                │  │  │  │                                     │ /var/run   │    │   │  │
                │  │  │  │  ┌──────────────────────────────────▼─────────┐  │    │   │  │
                │  │  │  │  │              runner container              │  │    │   │  │
                │  │  │  │  │  executes workflow steps · DOCKER_HOST=    │  │    │   │  │
                │  │  │  │  │  unix:///var/run/docker.sock               │  │    │   │  │
                │  │  │  │  └────────────────────────────────────────────┘  │    │   │  │
                │  │  │  └──────────────────────────────────────────────────┘    │   │  │
                │  │  │                                                          │   │  │
                │  │  │  (node terminates within 30 s of becoming idle)          │   │  │
                │  │  └──────────────────────────────────────────────────────────┘   │  │
                │  └─────────────────────────────────────────────────────────────────┘  │
                └───────────────────────────────────────────────────────────────────────┘
```

---

## Job Execution Flow

Step-by-step sequence of events from workflow trigger to job completion:

```sh
 1  Developer pushes a commit or opens a PR
        │
        ▼
 2  GitHub queues a job with label  runs-on: linux-k8s
        │
        ▼
 3  ARC Scale Set Controller (arc-systems) detects pending job
    via the GitHub Actions API long-polling loop
        │
        ▼
 4  ARC creates a runner Pod in the arc-runners namespace
        │
        ▼
 5  Kubernetes marks the Pod as Unschedulable
    (no available node matching nodeSelector + toleration)
        │
        ▼
 6  Karpenter detects the unschedulable Pod
    → evaluates NodePool constraints (OS, arch, instance types, capacity type)
    → selects the cheapest satisfying Spot instance type
    → calls EC2 CreateFleet API
        │
        ▼
 7  EC2 Spot node boots with Amazon Linux 2023 EKS-optimised AMI
    → kubelet registers with EKS control plane
    → Node becomes Ready (~90 seconds cold start)
        │
        ▼
 8  Pod is scheduled onto the new node
    init-dind-externals copies runner binaries → dind and runner start
        │
        ▼
 9  Runner registers with GitHub, picks up the job, executes steps
    Docker images are built/run via the dind sidecar
        │
        ▼
10  Job completes → runner Pod exits → ARC deregisters the runner
        │
        ▼
11  Node becomes empty → Karpenter consolidates within 30 seconds
    → EC2 Spot instance is terminated
    → No further cost incurred
```

---

## Network Architecture

```sh
VPC: 10.0.0.0/16
│
├── Public subnets  (10.0.48.0/24, 10.0.49.0/24, 10.0.50.0/24)
│   ├── NAT Gateway (one, shared — use three for production HA)
│   └── Internet Gateway
│
└── Private subnets (10.0.0.0/20, 10.0.16.0/20, 10.0.32.0/20)
    ├── EKS nodes (system node group + Karpenter-managed)
    ├── Runner pods
    └── Outbound internet via NAT Gateway
        (pulls GitHub API, Docker images, package managers)
```

Nodes and pods live entirely in **private subnets**. The EKS API server endpoint is public for operational convenience (kubectl access); restrict `endpoint_public_access_cidrs` to your office/VPN CIDR before production use.

---

## IAM Architecture (IRSA / Pod Identity)

```sh
GitHub Actions workflow
        │ AssumeRoleWithWebIdentity
        ▼
github_oidc_role  (AdministratorAccess — tighten before production)
        │
        └── terraform plan / apply

EKS Node (Karpenter-managed)
        │ EC2 instance profile
        ▼
karpenter_node_role
        │
        ├── AmazonEKSWorkerNodePolicy
        ├── AmazonEKS_CNI_Policy
        ├── AmazonEC2ContainerRegistryReadOnly
        └── AmazonSSMManagedInstanceCore  (enables Session Manager)

Karpenter Controller (EKS Pod Identity — no annotation required)
        │
        └── karpenter_controller_role
                ├── EC2 CreateFleet, DescribeInstances, TerminateInstances
                ├── SQS ReceiveMessage (interruption queue)
                └── IAM PassRole (to attach node role to new instances)
```

---

## Kubernetes Namespaces

```sh
kube-system (shared with system add-ons)
  └── karpenter (Deployment)         — watches for unschedulable pods,
                                        provisions/decommissions EC2 nodes
                                        (deployed here to align with the
                                        EKS Pod Identity Association namespace)

arc-systems
  └── arc (Deployment)               — ARC Scale Set Controller,
                                        manages AutoscalingRunnerSet lifecycle

arc-runners
  ├── github-pat-secret (Secret)     — GitHub PAT for runner registration
  ├── arc-runner-linux (RunnerScaleSet)
  └── arc-runner-windows (RunnerScaleSet, count=0 unless enabled)
```

---

## Trade-off Analysis

### Karpenter vs Managed Node Groups

| Dimension | Karpenter | Managed Node Groups |
|---|---|---|
| **Provisioning speed** | ~60–90 s (direct EC2 CreateFleet) | ~3–5 min (autoscaling group) |
| **Instance diversity** | Any EC2 family and size in one NodePool | Fixed launch template per group |
| **Spot optimisation** | Picks cheapest available Spot type at launch | Constrained to the configured list |
| **Consolidation** | Bin-packs and terminates under-utilised nodes | Scale-in is slow (cooldown periods) |
| **Operational complexity** | NodePool + EC2NodeClass CRDs to maintain | Simpler AWS console experience |
| **Interruption handling** | Built-in SPOT interruption queue (SQS) | Requires separate handler (e.g. node-termination-handler) |

**Decision**: Karpenter is used for runner nodes. The system components (Karpenter controller, ARC controller) run on a small Managed Node Group to provide a stable foundation that is never subject to Spot interruption.

---

### Spot vs On-Demand

| Dimension | Spot | On-Demand |
|---|---|---|
| **Cost** | Up to 90 % cheaper | Full price |
| **Availability** | Can be reclaimed with 2-min warning | Always available |
| **Risk to CI jobs** | Job is lost if node is interrupted mid-run | None |
| **Mitigation** | Ephemeral runners — ARC re-queues the job | N/A |

**Decision**: Linux runners prefer Spot with On-Demand fallback. Because each runner pod handles exactly one job and then exits, a Spot interruption at most loses one job run. GitHub re-queues the job and a new runner picks it up. The cost saving justifies the occasional retry.

Windows nodes default to On-Demand because Windows Spot availability is lower and Windows node bootstrap time (~5 min) makes retries more expensive.

---

### ARC vs Alternatives

| Solution | Pros | Cons |
|---|---|---|
| **ARC (this project)** | Official GitHub tool, Kubernetes-native, fine-grained scaling, ephemeral by default | Requires Kubernetes; DinD adds privilege for Docker jobs |
| **EC2 self-hosted runners** | Simple; full EC2 VM capabilities | Slow cold start; hard to scale; long-lived = security risk |
| **Lambda-based runners** | Serverless; zero idle cost | 15-min timeout; limited disk/memory; no Docker support |
| **GitHub-hosted runners** | Zero ops | Expensive at scale; no caching persistence; network egress costs |

**Decision**: ARC on EKS gives the best balance of scale-to-zero economics, security (ephemeral pods), and Docker compatibility (DinD sidecar). The operational overhead of EKS is justified for organisations running hundreds of CI jobs per day.

---

### Single NAT Gateway vs One Per AZ

The current configuration uses a single NAT gateway (`single_nat_gateway = true`) to minimise cost during the POC phase. In production, set `single_nat_gateway = false` — a NAT gateway failure would otherwise make all private-subnet nodes unable to reach the internet (blocking Docker image pulls, GitHub API calls, and package installations).

---

## Assumptions and Constraints

| Item | Assumption |
|---|---|
| GitHub organisation | `kubehouse` (org-level runner registration) |
| EKS version | 1.35 — review the [EKS release calendar](https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html) and upgrade within the support window |
| Karpenter version | 1.3.3 — pin and test upgrades carefully; Karpenter CRD API version changed at v1.0 |
| Docker-in-Docker | Requires `privileged: true` on the dind container — ensure your security policy permits this |
| GitHub PAT | Stored as a Kubernetes Secret in `arc-runners`; consider migrating to GitHub App authentication for production |
| AdministratorAccess | The CI/CD IAM role has broad permissions for bootstrapping convenience; replace with a least-privilege policy before production |
| Single region | All resources deploy to `eu-west-2`; multi-region would require separate state keys and NodePool configurations |
