# Incident: EKS Managed Node Group Stuck in CREATING

**Date:** 2026-04-13
**Duration:** ~25 minutes of blocked apply
**Affected resource:** `module.eks.module.eks_managed_node_group["system"].aws_eks_node_group.this[0]`
**Resolution:** Manual `aws eks create-addon vpc-cni` to break the deadlock

---

## What Was Happening

The system node group EC2 instance booted successfully and was visible in the AWS console as `running`. However, Terraform reported it as still `CREATING` after 25 minutes, and the EKS node group status remained `CREATING` with no health issues.

Inspecting the kubelet logs via SSM revealed the node was stuck in a tight retry loop:

```
NetworkPluginNotReady — Network plugin returns error: cni plugin not initialized
```

The kubelet prints this every 5 seconds indefinitely. It will not mark the node as `Ready` until the CNI (Container Network Interface) plugin is installed and its configuration file is present in `/etc/cni/net.d/`.

Checking the CNI directories on the instance confirmed they were empty:

- `/opt/cni/bin/` — present but empty (no CNI binary)
- `/etc/cni/net.d/` — present but empty (no CNI config)

And listing the cluster's EKS addons returned nothing:

```json
{ "addons": [] }
```

The `vpc-cni` DaemonSet did not exist. There was nothing on the cluster to schedule the pod that installs the CNI binaries onto the new node.

---

## Root Cause: A Deadlock in the terraform-aws-eks Module

The `terraform-aws-eks` module (used via the `module "eks"` block in `eks.tf`) creates EKS managed addons with an **implicit dependency on the managed node group completing first**. This is intentional for addons like `coredns`, which requires a running node to schedule its pods and would fail if created against an empty cluster.

The problem is that `vpc-cni` was included in the same `addons` block as `coredns` and `kube-proxy`. Because all addons in the module share this dependency, vpc-cni also waited for the node group to complete before being created.

This produces a circular dependency with no exit:

```
┌─────────────────────────────────────────────────────────────────────┐
│                                                                       │
│   Terraform waits for node group ACTIVE                               │
│          │                                                            │
│          ▼                                                            │
│   EKS waits for node to reach Ready                                   │
│          │                                                            │
│          ▼                                                            │
│   kubelet waits for CNI to be initialised                             │
│          │                                                            │
│          ▼                                                            │
│   CNI is installed by vpc-cni DaemonSet pod                          │
│          │                                                            │
│          ▼                                                            │
│   vpc-cni DaemonSet does not exist (addon not created yet)           │
│          │                                                            │
│          ▼                                                            │
│   Terraform has not created vpc-cni addon yet                         │
│          │                                                            │
│          ▼                                                            │
│   Terraform is waiting for node group ACTIVE  ◄───── back to top ────┤
│                                                                       │
└─────────────────────────────────────────────────────────────────────┘
```

Neither side can proceed. The apply blocks until Terraform's 60-minute node group creation timeout fires and fails the apply.

---

## Why It Was Not Obvious

Several factors masked the root cause:

1. **The EC2 instance was running.** The AWS console and `aws ec2 describe-instances` both showed the node as healthy and `running`. There was nothing visually wrong.

2. **The EKS node group health check reported no issues.** `aws eks describe-nodegroup ... --query nodegroup.health` returned `{"issues": []}`. AWS considers the node group healthy — it's just waiting for the node to self-report as `Ready`.

3. **The kubelet error message is misleading.** `cni plugin not initialized` sounds like a configuration problem. The actual cause (the DaemonSet that delivers the plugin doesn't exist yet) requires one additional step of investigation.

4. **The terraform-aws-eks module abstracts the dependency.** There is no visible `depends_on` in the user-facing module call. The ordering is enforced internally in the module source, so it is not obvious from reading `eks.tf` that addons are sequenced after node groups.

5. **`bootstrap_self_managed_addons = false`** was set on the EKS cluster. With this flag, EKS does not pre-install any default addons (vpc-cni, kube-proxy, coredns) during cluster bootstrapping. They are entirely the responsibility of the managed addon system. On older EKS configurations or without this flag, AL2023 nodes would have vpc-cni binaries baked into the AMI, making this a non-issue.

---

## How It Was Fixed (Live)

With the apply blocked, the vpc-cni addon was created manually via the AWS CLI while Terraform continued to wait:

```bash
aws eks create-addon \
  --region eu-west-2 \
  --cluster-name github-runners \
  --addon-name vpc-cni \
  --resolve-conflicts OVERWRITE
```

Within ~30 seconds, AWS deployed the vpc-cni DaemonSet. The pod scheduled on the blocked node (DaemonSet pods tolerate `node.kubernetes.io/not-ready`), installed the CNI binaries into `/opt/cni/bin/`, and wrote the config to `/etc/cni/net.d/`. The kubelet detected the CNI, the node reached `Ready`, the node group transitioned to `ACTIVE`, and Terraform continued.

After the apply completed, the manually created addon was imported into Terraform state:

```bash
cd terraform && terraform import aws_eks_addon.vpc_cni github-runners:vpc-cni
```

---

## Permanent Fix

`vpc-cni` has been moved out of the `module "eks"` addons block and into a standalone `aws_eks_addon` resource in `terraform/vpc_cni_addon.tf`. This resource depends only on the EKS cluster being `ACTIVE`, not on the node group completing.

**Before** (`eks.tf` — addons block inside the module):

```hcl
module "eks" {
  ...
  addons = {
    vpc-cni = {          # ← gated on node group completion by the module
      most_recent                 = true
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "OVERWRITE"
    }
    coredns    = { ... }
    kube-proxy = { ... }
  }
}
```

**After** (`vpc_cni_addon.tf` — standalone resource):

```hcl
data "aws_eks_addon_version" "vpc_cni" {
  addon_name         = "vpc-cni"
  kubernetes_version = module.eks.cluster_version
  most_recent        = true
}

resource "aws_eks_addon" "vpc_cni" {
  cluster_name  = module.eks.cluster_name
  addon_name    = "vpc-cni"
  addon_version = data.aws_eks_addon_version.vpc_cni.version

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = local.tags

  # Depend only on the cluster, not on the node group.
  # This is the fix: vpc-cni is created as soon as the control plane is ACTIVE,
  # before the node group even begins, so the DaemonSet exists when the first
  # node boots and can initialise the CNI immediately.
  depends_on = [module.eks]
}
```

The creation order on a fresh cluster is now:

```
1. EKS control plane becomes ACTIVE            (~10 min)
2. vpc-cni addon created → DaemonSet deployed  (~1 min, parallel with step 3)
3. System node group starts provisioning       (~5 min)
4. Node boots, vpc-cni DaemonSet schedules     (seconds)
5. CNI initialised → node Ready → ACTIVE       (seconds)
6. coredns, kube-proxy addons created          (~1 min)
7. Karpenter, ARC installed via Helm           (~3 min)
```

Total reduction in worst-case apply time: eliminates an indefinite block (previously up to Terraform's 60-minute timeout); the node group should now complete in the expected 5–8 minutes.

---

## Lessons Learned

| # | Lesson |
|---|---|
| 1 | Never include `vpc-cni` in the `terraform-aws-eks` module's `addons` block. It must always be a standalone resource with a cluster-only dependency. |
| 2 | When a node group is `CREATING` with no health issues and the EC2 instance is running, always check kubelet logs via SSM first — it reveals the exact blocker in seconds. |
| 3 | When using `bootstrap_self_managed_addons = false`, all networking addons become your responsibility and their creation order is critical. |
| 4 | For debugging EKS node bootstrapping issues, `AmazonSSMManagedInstanceCore` on the node role is essential — it removes the need for a bastion host or public SSH access. |
