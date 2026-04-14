# Summary of Self-Hosted Runner Architecture Review

This document provides a comparative analysis of GitHub Actions self-hosted runner architectures, evaluated against the specific context of an **AWS EKS + Karpenter + Actions Runner Controller (ARC)** environment.

## 1. Executive Summary: The "Best" Architecture

While "best" is subjective, for an organization already committed to Kubernetes (EKS) and seeking high elasticity (Karpenter), **ARC with Ephemeral Pods** is the gold standard. However, the internal implementation (how Docker is handled) varies significantly.

| Ranking | Architecture | Best For... |
|:---|:---|:---|
| **Primary** | **ARC + DinD (Current)** | Maximum compatibility, "just works" for developers. |
| **Alternative** | **ARC + Rootless/BuildKit** | High-security environments, multi-tenant clusters. |
| **Niche** | **VM-per-job (Firecracker)** | Maximum isolation, kernel-level security requirements. |
| **Avoid** | **Static EC2 / DooD** | Scalability bottlenecks, poor security posture in K8s. |

---

## 2. Comparative Analysis

### Architecture 1: Docker-in-Docker (DinD) — *Current Setup*
Each runner pod contains a privileged sidecar running its own Docker daemon.

*   **Performance:** Medium. Cold starts are impacted by the daemon initialization (3–10s).
*   **Cost:** High Efficiency. Works perfectly with Karpenter's "scale-to-zero" model.
*   **Security:** **Low/Medium.** Requires `privileged: true`. A compromised job could potentially escape to the underlying EKS node.
*   **Scalability:** Excellent. ARC manages the pod lifecycle; Karpenter manages the node lifecycle.
*   **Trade-off:** You trade security (root on node) for developer convenience (everything works: `docker build`, `docker-compose`, etc.).

### Architecture 2: Rootless / Daemonless (Kaniko, BuildKit)
No Docker daemon is run. Images are built using unprivileged OCI tools.

*   **Performance:** Variable. Often slower for large builds because local layer caching is harder to maintain without a warm daemon.
*   **Cost:** Optimal. Same as DinD, but allows for smaller node types (no daemon overhead).
*   **Security:** **Highest (Container level).** No privileged containers required. Compliant with strict Pod Security Admissions (PSA).
*   **Scalability:** Excellent.
*   **Trade-off:** You gain security but lose compatibility. `docker-compose` and sidecar-container workflows will break.

### Architecture 3: VM-per-job (MicroVMs / Firecracker)
Each job runs in a dedicated, ephemeral microVM (e.g., via Kata Containers).

*   **Performance:** High. Near-instant boot (~125ms), but requires "metal" or Nitro instances.
*   **Cost:** **Highest.** Requires expensive bare-metal EC2 instances to support nested virtualization (KVM).
*   **Security:** **Highest (Kernel level).** Hardware-level isolation between jobs.
*   **Scalability:** Medium. Harder to orchestrate within a standard EKS cluster; often requires custom controllers.
*   **Trade-off:** The ultimate security posture, but at a 2x-5x cost premium and significantly higher operational complexity.

---

## 3. Detailed Metric Comparison

| Metric | DinD (Current) | Rootless (BuildKit) | VM-per-job | Static EC2 |
|:---|:---:|:---:|:---:|:---:|
| **Isolation** | Process | User Namespace | **Hardware (Hypervisor)** | Shared OS |
| **Karpenter Compatibility** | Perfect | Perfect | Complex | Poor |
| **Cold Start** | ~90s (Node) + 10s (Pod) | ~90s (Node) + 2s (Pod) | ~90s (Node) + <1s (VM) | **Instant** |
| **Maintenance** | Medium | Medium | **High** | Low |
| **Docker Compose Support**| Yes | No | Yes | Yes |

---

## 4. Recommendations & Roadmap

### Phase 1: Harden Current Setup (Short term)
Continue using **ARC + DinD** but implement "Security through Isolation":
*   **Dedicated Nodepools:** Ensure runner pods only run on specific Karpenter nodes using `taints` and `tolerations`.
*   **Network Policies:** Restrict the DinD pods so they cannot reach the EKS metadata service or other internal VPC resources.

### Phase 2: Pivot to Rootless (Medium term)
If your builds are primarily standard `docker build` (no complex compose/privileged steps):
*   Migrate to **BuildKit with remote caching (ECR)**. This removes the `privileged` requirement while maintaining decent performance.

### Phase 3: Evaluate VM-per-job (Long term)
Only if you move into highly regulated industries (FinTech, GovCloud) where "container escape" is a deal-breaker risk.

## 5. Decision Matrix: When to use what?

*   **Use DinD if:** You have 100+ different teams with varied CI needs and you don't want to support their specific "why doesn't my docker command work" tickets.
*   **Use Rootless if:** You are in a multi-tenant cluster where the "Runner" namespace lives alongside production applications.
*   **Use VM-per-job if:** You are running untrusted code (e.g., a public SaaS platform for builds) where kernel isolation is mandatory.
*   **Use Static EC2 if:** You have massive, 1-hour+ builds that need 100GB+ of local disk cache that *must* persist between runs to be viable.
