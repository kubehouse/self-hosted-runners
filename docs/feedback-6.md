# Self-hosted runner architectures — overview and trade-offs

This document describes common architectures for self-hosted CI runners, alternatives to Docker-in-Docker (DinD), when to use each, and the main trade-offs (security, performance, operational complexity, cost).

## Summary (quick)
- You currently use: Docker-in-Docker (DinD) — privileged sidecar creating `/var/run/docker.sock` inside the pod.
- Alternatives fall into categories: VM-based, container-based (non-DinD), remote/managed build services, microVMs/unikernels, and serverless.

---

## 1) Docker-in-Docker (DinD) — what you have
- Pattern: A privileged `docker:dind` daemon runs as a sidecar; runner connects to `unix:///var/run/docker.sock` (shared volume).
- When to use: Fast, minimal changes to existing workflows that expect a Docker daemon; good when you must support arbitrary Docker CLI usage (docker build, run, docker-compose) inside job steps.
- Pros:
  - Full Docker daemon feature-set (compat with existing `docker` CLI workflows).
  - Simple: developer workflows that call `docker` usually work unchanged.
  - Local, ephemeral daemons per runner pod: builds isolated from host image cache unless you share volumes.
- Cons / trade-offs:
  - Requires `privileged: true` → large security surface (container can escalate to host in some environments).
  - Resource heavy: dockerd uses more memory/CPU than build-only tools.
  - Potential for leftover privileged artifacts (ENIs, mounts) if not cleaned properly.
  - Hard to restrict network access for build artifacts pulled by dockerd.
- Suitable when: you need maximum compatibility and cannot modify CI steps, or when migration cost/time is high.

---

## 2) Host Docker socket (bind-mount `/var/run/docker.sock`) — host-daemon sharing
- Pattern: Runner container mounts host's `/var/run/docker.sock` into the container so `docker` talks to host dockerd.
- When to use: On single-tenant VMs or dedicated nodes where host-level daemon is acceptable; you want smaller pod surface (no dind sidecar)
- Pros:
  - No extra daemon per pod — lower memory/cpu overhead.
  - Reuses host cache (faster builds if cache warmed).
  - Simple to set up.
- Cons:
  - Grants container effective root on the host (even worse than DinD in many ways).
  - Multi-tenant risk: jobs can inspect/modify other containers/host filesystem.
  - Hard to scale securely on shared clusters.
- Suitable when: you fully trust runner workloads and run on isolated VMs/nodes (not recommended for multi-tenant clusters).

---

## 3) Build-only container builders (recommended alternatives)
3a) BuildKit remote builder / `docker buildx` with remote builder
- Pattern: Use a dedicated BuildKit instance (remote) or BuildKit as a sidecar but running unprivileged; runner uses `buildx` to push build work to a builder.
- Pros:
  - Unprivileged, more secure than DinD.
  - Supports advanced build features (cache export/import, inline cache, parallel build stages).
  - Can be centralized and autoscaled independently of runners.
- Cons:
  - Requires workflow changes to use `buildx` instead of raw `docker build`.
  - Operational overhead: manage BuildKit instances and caches.
- Suitable when: you want secure, fast builds and can update workflows to `buildx`.

3b) Kaniko / img / buildah (containerized, non-privileged builders)
- Pattern: Use tools that build OCI images without a privileged daemon by replaying filesystem changes.
- Pros:
  - No privileged daemon required; safe to run in multi-tenant clusters.
  - Well-suited to Kubernetes-based CI.
- Cons:
  - Some features may be missing (less parity with full docker daemon semantics, e.g., certain cache semantics, BuildKit features).
  - Requires workflow changes.
- Suitable when: security is a priority and you only need `docker build` semantics (no complex buildkit-only features).

3c) Kaniko + remote cache (for speed)
- Use remote cache backends (registry, s3-backed cache) to speed repeated builds.

---

## 4) Remote Docker daemon (TCP + TLS)
- Pattern: A remote host provides dockerd over TCP with TLS auth; runners connect over network.
- Pros:
  - Isolates daemon to builder hosts; can centralize build capacity.
  - Can be secured via mTLS and network controls.
- Cons:
  - Network dependency; needs robust auth and RBAC.
  - Still runs full dockerd (resource usage) and may allow lateral movement if auth is compromised.
- Suitable when: you can centralize and tightly secure builder hosts (VPN, mTLS), and want to reuse caches.

---

## 5) VM-based runners (ephemeral or long-lived)
- Pattern: Each runner is a VM/EC2 instance (AMI) with docker/container engine installed; can be long-lived or ephemeral (create-per-job). Examples: self-hosted EC2 runners, Google Cloud VMs, Azure VMs.
- When to use: Need full VM isolation, privileged operations, or non-container workloads (nested virtualization, device access).
- Pros:
  - Strong isolation boundary (VM hypervisor), lower risk of cross-job escalation.
  - Full control over environment, kernel, drivers.
  - Good for Windows builds or workloads requiring special drivers.
- Cons:
  - Slow cold start for ephemeral VMs (minutes) unless using snapshot/fast provisioning.
  - Higher cost if instances kept warm/long-lived.
- Suitable when: strong isolation required, Windows or special hardware needed, or privileged host access necessary.

---

## 6) MicroVMs / Firecracker / gVisor
- Pattern: Small, fast microVMs (Firecracker, Kata Containers) provide near-VM isolation with faster startup than full VMs.
- Pros:
  - Strong isolation closer to VMs but faster startup than full VMs.
  - Good balance for multi-tenant environments.
- Cons:
  - More complex to operate; some integrations missing vs plain containers.
  - May require custom orchestration or platform support.
- Suitable when: multi-tenant security is essential and you want better startup time than traditional VMs.

---

## 7) Serverless / function-based runners (Lambda-style)
- Pattern: Use serverless functions (where possible) to run parts of CI that fit within runtime / filesystem constraints.
- Pros:
  - Zero-host management, cost-efficient for short fast tasks.
- Cons:
  - Runtime limits (duration, disk, memory); no Docker builds unless using remote builders.
- Suitable when: you only need scripting, tests, or short tasks that don't require Docker or long-running builds.

---

## 8) Orchestrator-specific options
- ECS / Fargate: Run runners as tasks — Fargate removes host management but has limited privileges; DinD is harder here. Use BuildKit or remote builders for Docker workloads.
- Nomad: Supports VM or container task drivers and can integrate Firecracker.

---

## Security and policy considerations
- Privileged containers (DinD) and host-socket mounts are the biggest risks — avoid in multi-tenant clusters.
- If you must run DinD, isolate runners on dedicated nodepools (taints/nodeSelectors) and protect those nodes with strict network policies and IAM restrictions.
- Use admission controllers and PodSecurityPolicy (or Pod Security Admission) to control privileges.
- Prefer unprivileged build tools (kaniko, buildkit remote) for multi-tenant clusters.

---

## Performance, cache, and cost trade-offs
- DinD and host-socket reuse host cache → faster cold builds if cache warm. Kaniko and BuildKit can also use remote caches (registry, S3) to reduce rebuild times.
- VM-based runners can warm caches locally but cost more when idle.
- Remote builders centralize cache and scale independently (good cost/perf balance for many runners).

---

## Migration options from DinD (recommended paths)
1. If you control runner images and can change workflows quickly: switch to `docker buildx` + BuildKit remote builder. Benefits: secure, feature-rich.
2. If you need minimal code change but want to avoid privileged: use BuildKit sidecar running unprivileged (or containerd-based builder) and call `buildx`.
3. If you cannot change builds now: isolate current DinD nodes using dedicated nodepools + network controls, and plan phased migration.
4. For pure image-build pipelines: consider `kaniko` or `img` with remote cache upload.

---

## Quick decision checklist
- Must run arbitrary Docker CLI commands unchanged and migration time is limited → keep DinD for now, but isolate nodes and plan migration.
- Multi-tenant cluster or strict security → use Kaniko / BuildKit remote / Firecracker microVMs.
- Need Windows support or kernel/device access → VM-based runners.
- Desire low operational overhead and can adapt workflows → remote BuildKit + `buildx`.

---

## Recommended reading / next steps
- Evaluate which build features you rely on (compose, privileged containers, docker daemon plugins).
- If you want, I can:
  - Generate migration steps from DinD → BuildKit `buildx` (CI changes + recommended infra), or
  - Add hardened pod/nodepool YAML snippets to keep DinD but reduce blast radius.

---

(Generated by repository audit on 14 Apr 2026.)
