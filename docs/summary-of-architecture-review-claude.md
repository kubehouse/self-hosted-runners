# Self-Hosted Runner Architecture Review

**Reviewer:** Staff Platform Engineer
**Date:** 2026-04-14
**Scope:** EKS + Karpenter + ARC deployment, `terraform/arc.tf` as the primary implementation reference
**Prior reviews read:** `docs/architecture-review.md`, `docs/summary-of-architecture-review-gemini.md`

---

## 1. Executive Summary

The current implementation — ARC ephemeral pods with a Docker-in-Docker (DinD) sidecar — is a reasonable starting point and the right structural choice for a team that needs Docker Compose compatibility and does not want to rewrite CI pipelines on day one. ARC with Karpenter is genuinely the correct orchestration model for this problem; that choice is not in question.

What *is* in question is the DinD internals. At low job volumes the implementation works. At scale — hundreds of concurrent jobs, mixed image sizes, aggressive Karpenter churn — three problems compound: every job cold-pulls all Docker layers from public registries (slow, costly, rate-limited), the privileged daemon gives any compromised workflow step a path to the underlying EC2 node, and the unpinned `docker:dind` and `actions-runner:latest` images mean a supply-chain change upstream can silently alter runner behaviour between two runs of the same commit. None of these are blockers today. All three become blockers within six to twelve months of serious use.

The recommended direction is to keep DinD in the short term but eliminate the three compounding problems in order: (1) add an ECR pull-through cache to kill the cold-pull cost, (2) pin both images to digest, (3) migrate new pipelines to a rootless BuildKit sidecar as the team's appetite allows, preserving DinD for workflows that genuinely need a full daemon.

---

## 2. Architecture Comparison

### Scoring model

Each dimension is scored 1–5. Higher is better.

| Dimension | Weight | Rationale |
|---|---|---|
| Security | High | Shared Karpenter nodes mean blast radius matters |
| Performance | High | Cold-start latency directly affects developer feedback loop |
| Cost | Medium | Karpenter mostly handles this; internal efficiency still matters |
| Scalability | Medium | Must handle burst to 100+ concurrent jobs without redesign |
| Reliability | High | Flaky runners erode trust faster than anything else |
| Operability | Medium | Small platform team; debugging cost is real |

### Summary scores

| Architecture | Security | Performance | Cost | Scalability | Reliability | Operability | **Total /30** |
|---|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| DinD — current | 2 | 3 | 3 | 4 | 3 | 4 | **19** |
| DooD (host socket) | 1 | 5 | 4 | 2 | 2 | 4 | **18** |
| Kaniko | 5 | 2 | 4 | 5 | 4 | 2 | **22** |
| BuildKit rootless sidecar | 4 | 4 | 3 | 5 | 4 | 3 | **23** |
| BuildKit centralised | 4 | 4 | 5 | 4 | 3 | 2 | **22** |
| VM-per-job (Firecracker) | 5 | 3 | 1 | 3 | 4 | 1 | **17** |

---

## 3. Deep Dive Per Architecture

---

### 3.1 Docker-in-Docker (DinD) — current

**What it does:** A privileged `docker:dind` container runs `dockerd` as a sidecar. The socket is shared with the runner container via an `emptyDir` volume mounted at `/var/run`. The runner executes workflow steps that call `docker` normally.

**Scores**

| Dimension | Score | Justification |
|---|:---:|---|
| Security | 2/5 | `privileged: true` on the dind container grants the process full `CAP_SYS_ADMIN` and effectively root on the node. A workflow step that exploits a Docker CVE, a malicious dependency, or a misconfigured `docker run --privileged` can mount the node's filesystem, read kubelet credentials, or reach the AWS instance metadata service. The runner NodePool taint (`github-runner=linux:NoSchedule`) provides some blast-radius containment by keeping runner workloads off system nodes, but it does not prevent lateral movement within the runner node pool. |
| Performance | 3/5 | `dockerd` initialisation adds 3–8 seconds per job cold start. More significantly, every runner pod starts with an empty layer cache — all base images are pulled from Docker Hub on every job. On a freshly Karpenter-provisioned node pulling a 2 GB image this is 30–90 additional seconds, plus Docker Hub rate limits at 100 pulls/6h per IP (NAT gateway IP is shared across all nodes in the VPC). At 50 concurrent jobs this becomes a real constraint. |
| Cost | 3/5 | The dind container requests 200m CPU and 256Mi memory but in practice a busy `dockerd` will spike to its 2 CPU limit during image pulls and layer extraction. On a t3.medium (2 vCPU / 4 GiB) this leaves little headroom for the runner container during peak. Karpenter bin-packing is efficient, but the dind overhead means each pod effectively consumes more node capacity than the job itself requires. |
| Scalability | 4/5 | Structurally excellent — each pod is fully isolated, ARC manages the lifecycle, Karpenter handles nodes. The constraint at scale is Docker Hub pull rate limits and the cumulative cost of pulling the same layers across hundreds of pods. Both are solvable with a registry mirror. |
| Reliability | 3/5 | Three failure modes worth noting: (1) the socket race condition between dind startup and the runner command — addressed by the command wrapper in the current implementation but inherent to the architecture; (2) if `dockerd` crashes mid-job (OOM, kernel bug, overlay2 corruption) the job fails with no graceful recovery; (3) Karpenter node consolidation or Spot interruption terminates the dind daemon with no checkpoint, losing any in-progress `docker build` layer work. |
| Operability | 4/5 | Developers do not need to change workflows. `docker build`, `docker run`, `docker compose` all work. Debugging is straightforward: `kubectl exec -it <runner-pod> -c dind -- docker ps`. The main operational burden is the socket race, which required a bespoke command wrapper rather than a clean solution. |

**Pros**
- Zero workflow changes required
- `docker compose`, multi-stage builds, `docker run` all work natively
- Per-pod daemon isolation — jobs cannot see each other's containers
- Familiar mental model for developers

**Cons**
- `privileged: true` is a hard security requirement with no workaround in standard DinD
- No layer cache persistence between jobs on the same node
- Docker Hub pull rate limits become a real operational problem above ~50 concurrent jobs
- Daemon crash = job failure; no recovery path
- Both images are currently unpinned (`docker:dind`, `ghcr.io/actions/actions-runner:latest`)

**Hidden risks**
- The `emptyDir` volume mounted at `/var/run` shadows the *entire* `/var/run` directory in the runner container, not just the Docker socket. Any tool in a workflow step that expects other sockets or files under `/var/run` (e.g. `systemd` socket, `containerd.sock`) will not find them.
- Docker Hub's rate limit applies per IP. All Karpenter-managed nodes in the VPC share the single NAT gateway IP. At scale, a burst of pod starts will exhaust the 100 unauthenticated or 200 authenticated pulls per 6 hours before workflows even begin executing job steps.
- `docker:dind` is a Docker Hub image. It is itself subject to pull rate limits during Karpenter scale-out, creating a self-referential bootstrapping problem.
- The `--group=1001` flag on `dockerd` assumes the runner user has GID 1001. If the runner image changes its user GID, the socket permission check silently fails and the runner cannot connect to the daemon.

**When it is the right choice**
- Workflows require `docker compose` or `docker run` with arbitrary flags
- The team cannot invest time in workflow migration
- Job volume is below ~50 concurrent jobs and Docker Hub rate limits are not yet a concern
- Security posture is acceptable to stakeholders (dedicated runner nodes, network policies in place)

**When it becomes a bad choice**
- Multi-tenant clusters where runner workloads share nodes with production services
- Job volumes that exhaust Docker Hub rate limits
- Security audits that flag `privileged: true` as a blocker
- Workflows that need reproducible builds (unpinned images mean two runs of the same commit can produce different results)

---

### 3.2 Docker-outside-of-Docker (DooD / host socket)

**What it does:** The host node's `/var/run/docker.sock` is bind-mounted into the runner container. There is no sidecar; the runner talks to the node's own `dockerd`.

**Scores**

| Dimension | Score | Justification |
|---|:---:|---|
| Security | 1/5 | Anyone with access to the Docker socket has root on the host. This is not hyperbole — `docker run -v /:/host alpine chroot /host` gives an interactive shell as root on the EC2 instance. In a Karpenter-managed cluster where runner nodes also run the Karpenter daemonset and CNI pods, this means a compromised workflow step can read Karpenter's AWS credentials, modify network configuration, or exfiltrate kubelet bootstrap tokens. This is categorically not acceptable in a shared cluster. |
| Performance | 5/5 | No daemon startup cost. Shared host cache means subsequent jobs on the same node that use the same base image pay zero pull cost. Fastest possible Docker CLI experience. |
| Cost | 4/5 | No dind sidecar overhead. The host daemon is already running; runners are genuinely lightweight. |
| Scalability | 2/5 | All runner pods on a node share one daemon. A runaway build that saturates the daemon's goroutine pool or fills `/var/lib/docker` affects every other job on the node simultaneously. Karpenter consolidation is also complicated — you cannot drain a node while jobs are using its daemon. |
| Reliability | 2/5 | A single daemon crash takes down every job on the node. Node replacement by Karpenter for consolidation or Spot interruption terminates all in-progress jobs and their daemon state simultaneously. |
| Operability | 4/5 | Simple to configure. Familiar Docker CLI. Debugging is straightforward. |

**This architecture should not be used in this deployment.** It is included for completeness. The security score of 1/5 is disqualifying for a shared EKS cluster regardless of the other scores.

---

### 3.3 Kaniko

**What it does:** Kaniko is a tool that builds container images from a Dockerfile without a Docker daemon. It executes each `RUN` instruction in a user-space process, takes a filesystem snapshot after each step, and pushes the result directly to a registry. It runs unprivileged.

**Scores**

| Dimension | Score | Justification |
|---|:---:|---|
| Security | 5/5 | No privileged containers. No daemon. No socket. Fully compliant with `restricted` Pod Security Standards. The runner pod's blast radius is limited to its own filesystem and the registry credentials it holds — a significant reduction from DinD. |
| Performance | 2/5 | Kaniko does not support local layer caching. Without a registry-based cache (e.g. `--cache=true --cache-repo=<ecr-repo>`), every layer is rebuilt from scratch on every job. Even with registry cache, round-trip latency to ECR adds overhead versus a local daemon. Build speeds for large images with many layers are noticeably slower than DinD. |
| Cost | 4/5 | No daemon overhead. Kaniko itself is lightweight. Smaller instance types can be used. Registry cache reduces bandwidth cost over time. |
| Scalability | 5/5 | Fully stateless. Each pod is independent. No shared daemon, no rate-limit coupling between pods. Excellent Karpenter bin-packing. |
| Reliability | 4/5 | No daemon to crash. A failed build is a failed pod, not a failed node. Registry cache writes are idempotent. |
| Operability | 2/5 | This is the real cost. Every workflow that uses `docker build` must be rewritten to call `kaniko` or `executor`. Docker Compose workflows cannot be migrated — Kaniko only handles `docker build`, not `docker run` or multi-container orchestration. Debugging build failures is harder without an interactive daemon. |

**Hidden risks**
- Kaniko runs as root *inside* the container (though unprivileged on the host). This means a Dockerfile vulnerability that achieves RCE inside the build gets root inside the Kaniko container, and from there can potentially write to mounted volumes.
- Some `RUN` instructions that rely on kernel features (e.g. `mount`, certain `iptables` operations) will fail inside Kaniko because the container lacks the necessary capabilities.
- `--cache=true` requires a writable ECR repository that all runners have push access to. IAM scoping is important here; an over-permissioned node role could allow a compromised build to overwrite legitimate cache layers.

**When it is the right choice**
- The primary CI workload is `docker build` and push — no `docker run`, no Compose
- Security posture must satisfy `restricted` PSA (e.g. regulated industries, multi-tenant clusters)
- The team can invest in workflow migration

**When it becomes a bad choice**
- Workflows use `docker compose up` for integration testing
- Builds rely on kernel capabilities inside `RUN` instructions
- The team lacks time for workflow migration

---

### 3.4 BuildKit rootless sidecar

**What it does:** A `buildkitd` container runs as a sidecar in each runner pod. The runner communicates with it via a Unix socket (same `emptyDir` pattern as DinD, but the daemon is `buildkitd` not `dockerd`). BuildKit can run in rootless mode — no `privileged: true` required with appropriate kernel configuration. Workflows use `docker buildx` or `buildctl` instead of `docker build`.

**Scores**

| Dimension | Score | Justification |
|---|:---:|---|
| Security | 4/5 | Rootless BuildKit requires no privileged container. The sidecar runs as a non-root user with user namespace remapping. The blast radius is substantially reduced compared to DinD. Score is 4 rather than 5 because rootless BuildKit on EKS requires `sysctl net.ipv4.ping_group_range` and `user.max_user_namespaces` to be set on the node, which means a custom EC2NodeClass AMI or a privileged init container to set sysctls — adding back some operational complexity. |
| Performance | 4/5 | BuildKit's parallel execution of independent Dockerfile stages is significantly faster than sequential `docker build` for multi-stage images. Remote cache via ECR (inline cache or registry cache) means repeated builds pay only for changed layers. Local cache within a pod's lifetime is available. The main overhead is the sidecar startup (similar to dind, ~3–5s) and the `buildx` API surface. |
| Cost | 3/5 | `buildkitd` has comparable resource overhead to `dockerd`. The gain is in build efficiency: parallel stages and better cache hit rates mean jobs complete faster, meaning nodes are released sooner. Net cost impact is positive at scale but not dramatically different at low volumes. |
| Scalability | 5/5 | Per-pod sidecar with no shared state. Registry cache makes cache hits available across all pods and nodes — solving the cold-pull problem that DinD cannot solve without a registry mirror. |
| Reliability | 4/5 | Same daemon-crash risk as DinD, but BuildKit's failure modes are better isolated. `buildkitd` restart does not affect the runner process — the runner can attempt to reconnect. |
| Operability | 3/5 | `docker buildx build` is close enough to `docker build` that the migration is tractable. Developers need to replace `docker build -t foo .` with `docker buildx build --push -t foo .` or similar. Compose-based integration tests still require either a full Docker daemon sidecar or a migration to `docker compose` equivalents via BuildKit's Bake feature. Debugging is slightly harder than DinD but tooling exists. |

**Hidden risks**
- Rootless user namespaces are disabled by default on Amazon Linux 2023 EKS nodes. Enabling them requires setting `user.max_user_namespaces=15000` via a DaemonSet or custom AMI — adding a bootstrapping dependency before any runner pod can start.
- BuildKit's `--cache-from` / `--cache-to` with ECR inline cache embeds cache metadata in the image manifest. Very large dependency trees can produce manifests that exceed ECR's 10 MB limit.
- `docker buildx` in a runner pod requires the Docker CLI to be present even if `dockerd` is not. The ARC runner image includes the Docker CLI, so this is not an issue in practice — but it is worth confirming after any runner image upgrade.

**When it is the right choice**
- The team is willing to invest one sprint in workflow migration
- Pipelines are primarily `docker build` and push, possibly with multi-stage optimisation opportunity
- Security improvement from dropping `privileged: true` is a stated goal
- Remote cache is worth the ECR cost

**When it becomes a bad choice**
- Compose-based integration tests are a significant part of the workload — BuildKit alone cannot replace a full Docker daemon for `docker compose up`
- The team cannot invest in node AMI customisation for user namespace support

---

### 3.5 BuildKit centralised (shared builder fleet)

**What it does:** Instead of a per-pod sidecar, a dedicated fleet of `buildkitd` instances runs as a Deployment (or a separate Karpenter NodePool). Runner pods connect to a shared builder over TCP (with mTLS). The runner does not run any build daemon itself.

**Scores**

| Dimension | Score | Justification |
|---|:---:|---|
| Security | 4/5 | Same rootless posture as 3.4 but the blast radius of a compromised builder is higher — a single builder serves many runners. Compensated by the fact that runners themselves have no daemon. Network path requires mTLS. |
| Performance | 4/5 | Shared builders accumulate a warm layer cache across all jobs — the first job pulls a base image, subsequent jobs hit the cache. This is the primary advantage over per-pod sidecars. High-parallelism builds benefit from the builder's dedicated CPU. |
| Cost | 5/5 | Builder nodes run at high utilisation rather than spinning up and down with each runner pod. Karpenter manages runner nodes for compute; a small static builder fleet handles build I/O. Net efficiency is better than paying for idle sidecar overhead in every runner pod. |
| Scalability | 4/5 | Builder fleet scales independently of runner count. Can be sized for peak build concurrency rather than peak job concurrency (most jobs do not build images). The shared builders become a bottleneck if all jobs are simultaneously building large images — requires careful capacity planning. |
| Reliability | 3/5 | A builder node failure or Spot interruption during a build fails the job with no recovery. With a fleet of ≥2 builders and a retry-aware client, this is manageable. More complex than per-pod sidecars. |
| Operability | 2/5 | Significant additional infrastructure: builder Deployment, Service, mTLS certificates (cert-manager or manual rotation), Karpenter NodePool for builders, network policies between runner and builder namespaces. When a build fails, is the problem in the runner, the builder, or the registry? The debugging graph has more nodes. |

**When it is the right choice**
- Job volume is high (hundreds per day) and build times are a significant fraction of job time
- Cache efficiency across jobs is a measurable cost and performance concern
- The platform team has capacity to operate and monitor the builder fleet

**When it becomes a bad choice**
- Small team, low job volume — the operational overhead does not pay off
- Builds are short and lightweight — shared cache advantage is minimal

---

### 3.6 VM-per-job (Firecracker / Kata Containers)

**What it does:** Each job runs inside a dedicated microVM with its own kernel. Kata Containers provides a Kubernetes-compatible interface; Firecracker is the VMM that GitHub uses internally for its own hosted runners.

**Scores**

| Dimension | Score | Justification |
|---|:---:|---|
| Security | 5/5 | Kernel-level isolation. A compromised job cannot affect the host kernel or other jobs. This is the only architecture where `docker run --privileged` inside a job is genuinely safe. |
| Performance | 3/5 | Firecracker boots in ~125ms but requires bare-metal or KVM-capable EC2 instances. EKS managed node groups with `.metal` instance types are expensive and slow to provision (Karpenter cannot use them from the standard node pool). |
| Cost | 1/5 | `.metal` instances (e.g. `i3.metal`, `m5.metal`) start at $4–5/hour. A fleet sized for 50 concurrent jobs would cost an order of magnitude more than equivalent Spot capacity with containers. |
| Scalability | 3/5 | ARC does not natively support VM-per-job orchestration. Custom tooling is required. Karpenter's fast-provisioning advantage is reduced because `.metal` instances have longer boot times. |
| Reliability | 4/5 | VM isolation means a crashed job does not affect the node. Boot reliability of Firecracker on EKS is well-established at GitHub scale but requires careful AMI and Kata version management. |
| Operability | 1/5 | Kata Containers on EKS requires a custom containerd shim, custom node AMI, and Kata-aware Karpenter NodeClass configuration. Debugging requires familiarity with Firecracker VMM internals. Upgrade path for both EKS and Kata versions is complex. |

**When it is the right choice**
- Regulated industry where container escape is a legal or compliance risk (FinTech, defence, healthcare)
- Running untrusted third-party code as part of a public build service

**When it becomes a bad choice**
- Any context where cost and operational complexity matter — which is most contexts

---

## 4. Current System Critique

This section evaluates the *specific implementation* in this repository, not DinD as a concept.

### What is done well

**Structural choices are correct.** ARC ephemeral pods with Karpenter is the right architecture for GitHub-hosted-runner parity on EKS. The decision to use EKS Pod Identity over IRSA for Karpenter is correct and forward-looking. The vpc-cni bootstrapping fix (standalone resource, cluster-only dependency) demonstrates a solid understanding of Terraform dependency graphs.

**Ephemeral runners eliminate state leakage.** Each runner pod handles exactly one job. There is no risk of secrets, workspace files, or Docker layer history leaking between jobs on the same runner — a common problem with long-lived runner VMs.

**System node group isolation.** Karpenter controller, ARC controller, and ARC listener are kept on a dedicated on-demand node group with `CriticalAddonsOnly` taint. Runner workloads cannot be scheduled there. This prevents a misbehaving runner pod from evicting system components.

**Karpenter NodePool taint.** The `github-runner=linux:NoSchedule` taint on the runner NodePool means only pods that explicitly tolerate it land on runner nodes. This prevents accidental co-location of runner workloads with system services.

### What is risky

**`privileged: true` with no compensating controls.** The dind container runs fully privileged. There is no seccomp profile, no AppArmor profile, and no `CAP_DROP` list. Combined with the absence of network policies, a compromised runner pod on a Karpenter-managed node can reach the EC2 instance metadata service (IMDS), the Kubernetes API (via the node's kubelet credentials), and any endpoint in the VPC. The recommended IMDS hop-limit mitigation (`httpPutResponseHopLimit = 1` on the EC2NodeClass) is documented in `feedback-4.md` but not implemented.

**Both container images are unpinned mutable tags.**
```hcl
image = var.linux_runner_image  # default: ghcr.io/actions/actions-runner:latest
image = "docker:dind"           # hardcoded, no digest
```
`docker:dind` is particularly dangerous to leave unpinned. A new major version of Docker (e.g. 28.x → 29.x) could change default daemon behaviour, storage driver defaults, or socket permissions. Two runs of the same commit on different dates could use different Docker versions without any change in the Terraform configuration.

**No Docker Hub authentication or registry mirror.** The NAT gateway IP is shared across all Karpenter-managed nodes. Docker Hub's unauthenticated pull limit is 100 pulls per 6 hours per IP. At 50 concurrent jobs all pulling `ubuntu:22.04` (or any other base image), this limit is reached in minutes. Jobs will fail with `toomanyrequests` errors, which are indistinguishable from network failures at first glance. This is not a theoretical concern — it is a well-documented operational problem at any meaningful scale.

### What will break at scale

**Docker Hub rate limits.** Detailed above. At 100+ concurrent jobs this becomes a hard blocker. The fix is an ECR pull-through cache configured as the dind registry mirror — a one-time infrastructure addition, but it is not present and not in the current Terraform.

**Karpenter node churn and cold image pulls.** Karpenter's `consolidateAfter: 30s` (or equivalent) terminates nodes aggressively when runners are idle. This is correct for cost, but it means the next burst of jobs arrives on cold nodes with empty layer caches. Combined with Docker Hub rate limits, the first 60 seconds of a job burst at scale is dominated by image pulls rather than actual work.

**Single NAT gateway.** All outbound internet traffic (Docker Hub, GitHub API, package managers, ECR) routes through one NAT gateway in one AZ. NAT gateway failure or AZ degradation makes all private-subnet nodes unable to pull images or reach GitHub. Runner jobs will fail in a way that looks like Docker errors rather than network errors.

**ARC listener on a single system node.** The `listenerTemplate` pins the listener pod to `role=system` nodes. With `desired_size=1`, there is one system node. If that node is replaced (AMI update, Spot reclaim if system nodes were moved to Spot), the listener pod is evicted and all incoming GitHub jobs are undetected until the listener reschedules. Current configuration uses on-demand for system nodes which mitigates this, but a single node means there is no HA for the listener.

### What will cost more over time

**Image pull egress.** Every runner pod on every Karpenter node pulls its images from Docker Hub (for `docker:dind`) and GHCR (for the runner image). Data transfer out from the internet is free for inbound; Docker Hub does not charge for pulls. However, ECR charges for data transfer to EC2 within the same region if using ECR pull-through cache — this is negligible. The real cost is the *wasted time* pulling the same layers repeatedly rather than using a mirror.

**Oversized dind container limits.** The dind container has a 2 CPU / 4 GiB limit — identical to the runner container. On a t3.medium (2 vCPU / 4 GiB total), a single runner pod can theoretically claim the entire node. In practice both containers will not simultaneously peak, but the limits are not reflective of actual usage patterns and will cause Karpenter to provision larger nodes than necessary for the workload.

### What is "good enough" vs "needs redesign"

| Item | Assessment |
|---|---|
| ARC + Karpenter orchestration | Good enough — keep |
| DinD for Docker workflows | Good enough for now — migrate when time allows |
| Ephemeral runners | Good — correct choice |
| Socket-wait command wrapper | Acceptable workaround — a readinessProbe on the dind container is cleaner but more complex |
| Unpinned images | Needs fixing now — low effort, high impact on reproducibility |
| No registry mirror | Needs fixing before scale — rate limits will cause incidents |
| No IMDS hop-limit | Needs fixing — documented but not implemented |
| Single NAT gateway | Acceptable for POC, needs redesign before production |
| Single system node | Acceptable for POC, needs `desired_size=2` before production |

---

## 5. Recommended Direction

### Primary recommendation: harden DinD now, migrate to BuildKit rootless incrementally

Do not perform a wholesale architecture migration. The immediate priority is eliminating the operational risks in the current DinD setup so that it can run reliably at scale. The migration to BuildKit rootless should happen pipeline by pipeline, on new workflows first, over the following months.

**Rationale:** The other reviews in this repository correctly identify BuildKit rootless as the superior long-term choice. That conclusion is right. What they underweight is the migration cost and the risk of a half-migrated state where some workflows use DinD and some use BuildKit, with different debugging paths and different failure modes. A clean phased approach — fix the sharp edges in DinD first, then migrate — is lower risk than a parallel implementation.

### What "better" looks like at 1,000 jobs/day

At 1,000 jobs/day the architecture is the same. What changes is:
- Registry mirror is not optional — every cold node pull must hit ECR, not Docker Hub
- System node group runs 2–3 nodes across AZs — listener HA is required
- Three NAT gateways (one per AZ) — single-NAT failure is unacceptable
- Images are pinned to digest — reproducibility is required for debugging at scale
- BuildKit rootless is the default for new image-building workflows — DinD is the explicit opt-in for workflows that need `docker run`

---

## 6. Migration Strategy

### Phase 1: Harden DinD (1–2 weeks, no workflow changes required)

**6.1 Pin container image digests**

In `arc.tf` and the relevant variable defaults:
```hcl
# Replace
image = "docker:dind"
# With — obtain current digest: docker pull docker:dind && docker inspect docker:dind --format '{{index .RepoDigests 0}}'
image = "docker:dind@sha256:<digest>"
```
Same for `linux_runner_image`. Update the digest in a pull request with a clear commit message. Automate digest updates with Dependabot or Renovate.

**6.2 Add an ECR pull-through cache as a dind registry mirror**

Create an ECR pull-through cache rule for `registry-1.docker.io` and configure dind to use it:
```hcl
args = [
  "dockerd",
  "--host=unix:///var/run/docker.sock",
  "--group=1001",
  "--registry-mirror=https://<account>.dkr.ecr.eu-west-2.amazonaws.com",
]
```
This eliminates Docker Hub rate limits. Subsequent pulls from the same base image on any runner node will hit ECR (within-region, ~1 Gbit/s) rather than Docker Hub over NAT.

**6.3 Block IMDS access from runner pods**

Add to the `linux-runners` EC2NodeClass:
```yaml
spec:
  metadataOptions:
    httpPutResponseHopLimit: 1
    httpTokens: required
```
This prevents runner pods from obtaining the node IAM role credentials via `curl http://169.254.169.254`.

**6.4 Raise system node group to `desired_size = 2`**

Ensures the ARC listener and Karpenter second replica both have a home, and eliminates the single-point-of-failure for the listener pod.

**6.5 Add seccomp profile to dind**

```hcl
securityContext = {
  privileged = true
  seccompProfile = { type = "RuntimeDefault" }
}
```
`RuntimeDefault` blocks ~50 syscalls that are almost never needed in container builds, reducing the exploitable kernel surface area.

---

### Phase 2: Add BuildKit rootless for new image-building workflows (4–8 weeks)

**6.6 Enable user namespaces on runner nodes**

Add to the `linux-runners` EC2NodeClass user data (or a DaemonSet):
```bash
sysctl -w user.max_user_namespaces=15000
sysctl -w kernel.unprivileged_userns_clone=1
```

**6.7 Add a BuildKit sidecar option to the runner scale set**

Create a second `RunnerScaleSet` (e.g. `linux-k8s-buildkit`) that uses a BuildKit rootless sidecar instead of dind. New workflows that only need `docker buildx build` adopt the new label. Existing workflows that need `docker run` or `docker compose` stay on `linux-k8s`.

```yaml
# New workflows
runs-on: linux-k8s-buildkit

# Existing workflows (no change)
runs-on: linux-k8s
```

**6.8 Configure ECR as the BuildKit cache backend**

```yaml
- name: Build and push
  run: |
    docker buildx build \
      --cache-from type=registry,ref=$ECR_REPO:cache \
      --cache-to   type=registry,ref=$ECR_REPO:cache,mode=max \
      --push \
      -t $ECR_REPO:$GITHUB_SHA \
      .
```

This gives BuildKit the shared cache that DinD cannot have — the first build of a new node warms the cache in ECR; all subsequent builds across all nodes hit it.

---

### Phase 3: Evaluate — do not commit (6–12 months out)

**6.9 Assess VM-per-job only if:**
- A compliance audit specifically requires kernel-level job isolation
- The organisation moves into regulated industries where container escape is in the threat model
- The cost of `.metal` instances is acceptable relative to the security requirement

This should not be on the roadmap otherwise. The cost and operational complexity premium is not justified by the security improvement over a hardened DinD + network policies configuration for most organisations.

---

## Appendix: Key files reviewed

| File | Notes |
|---|---|
| `terraform/arc.tf` | Primary implementation — DinD sidecar spec, socket-wait command, listenerTemplate |
| `terraform/karpenter.tf` | NodePool and EC2NodeClass definitions |
| `terraform/eks.tf` | System node group sizing, addon placement |
| `terraform/vpc_cni_addon.tf` | Standalone vpc-cni resource — correctly avoids module dependency deadlock |
| `Architecture.md` | Accurate but does not reflect `kube-system` Karpenter namespace (now correct after fixes) |
| `docs/architecture-review.md` | Good overview, lacks implementation-specific critique |
| `docs/summary-of-architecture-review-gemini.md` | Structurally sound but scores are optimistic and hidden risks are understated |
