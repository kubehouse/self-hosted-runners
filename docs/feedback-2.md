⏺ Now to answer your actual question properly.

  ---
  No, you should never need the CLI. Terraform can sequence this entirely.

  The reason you hit the problem is that the terraform-aws-eks module conflates two different kinds of addons into one block:

  - vpc-cni — must exist before nodes join (it installs the CNI that kubelet waits for)
  - coredns, kube-proxy — must exist after nodes join (they need a running node to schedule pods)

  Because both categories sit in the same addons = {} block, the module applies the safest single rule: create all of them after the node group. That is correct for
  coredns but wrong for vpc-cni.

  Terraform's sequencing mechanism is its dependency graph. You control what waits for what through three tools:

  1. Implicit reference   →  resource "B" { x = resource_A.output }
                             B waits for A, and only A

  2. Module output ref    →  resource "B" { x = module.foo.some_output }
                             B waits for whichever resource inside foo
                             produces that specific output — not the whole module

  3. Explicit depends_on  →  depends_on = [module.foo]
                             B waits for every single resource inside foo
                             (nuclear option — avoid unless necessary)

  The fixed vpc_cni_addon.tf uses tool #2:

  module.eks.cluster_name
      │
      └── comes from aws_eks_cluster.this[0].name
              │
              └── does NOT depend on aws_eks_node_group ← correct

  So Terraform's graph now looks like this:

  EKS Control Plane (ACTIVE) ────────────────────────────────────┐
          │                                                      │
          │  [implicit ref to cluster_name]                      │  [module dependency]
          ▼                                                      ▼
  aws_eks_addon.vpc_cni              module.eks.module.eks_managed_node_group
  (created in parallel ─────────────────► DaemonSet schedules on node)
  with node group)                                               │
          │                                                      ▼
          └──────────────────────────────────► Node Ready → ACTIVE
                                                                 │
                                              ┌──────────────────┘
                                              ▼
                                coredns, kube-proxy addons
                                Karpenter Helm release
                                ARC Helm release

  vpc-cni and the node group are created in parallel. By the time the node boots (~5 min), vpc-cni's DaemonSet is already deployed and waiting. The node initialises
  CNI instantly and becomes Ready. No manual steps, no CLI intervention, no deadlock.
