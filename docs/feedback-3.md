# Debugging Log and Fix Record

**Date:** 2026-04-13
**Cluster:** `github-runners` (EKS 1.35, eu-west-2)
**Outcome:** Full end-to-end runner test passed — Docker job completed successfully on `linux-k8s`

This document records every error encountered during the initial `terraform apply`, the debugging steps taken to diagnose each one, and the permanent fix applied. Ordered chronologically.

---

## Fix 1 — Karpenter deployed to wrong namespace

### Symptom
Karpenter controller started but all EC2 API calls returned `AccessDenied`. No nodes were provisioned despite pods being unschedulable.

### Root cause
The `terraform-aws-eks/karpenter` module creates an EKS Pod Identity Association with `namespace = "kube-system"` by default. The Helm release was deploying Karpenter to a separate `karpenter` namespace. Pod Identity grants permissions only when the service account namespace/name pair matches the Association exactly — so the Karpenter service account in the `karpenter` namespace had no IAM permissions at all.

### Debugging steps
1. `kubectl get pods -n karpenter` — controller pod Running but not provisioning nodes
2. `kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter` — `AccessDenied` on `ec2:CreateFleet`
3. `aws eks list-pod-identity-associations --cluster-name github-runners` — confirmed Association was bound to `kube-system/karpenter-sa`, not `karpenter/karpenter-sa`

### Fix
`terraform/karpenter.tf` — changed Helm release:
```hcl
# Before
namespace        = "karpenter"
create_namespace = true

# After
namespace        = "kube-system"
create_namespace = false
```

Also updated the Makefile `logs-karpenter` and `status` targets, and the `kube-system` namespace references in `Architecture.md`.

---

## Fix 2 — GitHub OIDC provider `EntityAlreadyExists`

### Symptom
```
Error: creating IAM OIDC Provider: EntityAlreadyExists: Provider with url
https://token.actions.githubusercontent.com already exists.
```

### Root cause
AWS allows exactly one OIDC provider per URL per account. The account already had a provider for `token.actions.githubusercontent.com` (created when the existing `github_oidc_role` was set up). Terraform was attempting to create a second one unconditionally.

### Debugging steps
1. `aws iam list-open-id-connect-providers` — confirmed existing provider `arn:aws:iam::573723531607:oidc-provider/token.actions.githubusercontent.com`
2. Checked `var.use_existing_oidc_role_arn` — set to the existing role ARN, meaning the provider already existed

### Fix
`terraform/iam.tf` — added `count` guard to the provider, trust policy data source, and role:
```hcl
resource "aws_iam_openid_connect_provider" "github" {
  count = var.use_existing_oidc_role_arn == null ? 1 : 0
  ...
}

data "aws_iam_policy_document" "github_actions_assume_role" {
  count = var.use_existing_oidc_role_arn == null ? 1 : 0
  ...
}
```
Updated all downstream references to use `[0]` indexing.

---

## Fix 3 — EKS node group stuck in `CREATING` for 25+ minutes (vpc-cni deadlock)

### Symptom
`module.eks.module.eks_managed_node_group["system"].aws_eks_node_group.this[0]: Still creating... [25m elapsed]`
EC2 instance visible in console as `running`. EKS node group health: `{"issues": []}`.

### Root cause
The `terraform-aws-eks` module gates all addons (including `vpc-cni`) on the managed node group completing first. But `vpc-cni` must exist *before* the kubelet can mark a node as Ready. This creates a circular dependency with no exit:

```
Terraform waits for node group ACTIVE
  → EKS waits for node Ready
    → kubelet waits for CNI initialised
      → CNI installed by vpc-cni DaemonSet
        → DaemonSet does not exist (addon not yet created)
          → Terraform has not created addon yet
            → Terraform is waiting for node group ACTIVE  ← deadlock
```

### Debugging steps
1. `aws eks list-addons --cluster-name github-runners` → `{"addons": []}` — confirmed no addons existed
2. Connected to EC2 instance via SSM Session Manager
3. `journalctl -u kubelet -f` → repeated every 5 seconds: `NetworkPluginNotReady — cni plugin not initialized`
4. `ls /opt/cni/bin/` — empty (no CNI binary installed)
5. `ls /etc/cni/net.d/` — empty (no CNI config)

### Live fix (unblocking the apply)
While Terraform was still waiting, created the addon manually via AWS CLI:
```bash
aws eks create-addon \
  --region eu-west-2 \
  --cluster-name github-runners \
  --addon-name vpc-cni \
  --resolve-conflicts OVERWRITE
```
Within ~30 seconds: vpc-cni DaemonSet scheduled → CNI binaries installed → kubelet detected CNI → node became Ready → node group became ACTIVE → Terraform continued.

After the apply completed, imported the manually created addon into state:
```bash
cd terraform && terraform import aws_eks_addon.vpc_cni github-runners:vpc-cni
```

### Permanent fix
Removed `vpc-cni` from the `module "eks"` addons block in `eks.tf`. Created `terraform/vpc_cni_addon.tf` as a standalone resource that depends only on the EKS cluster being ACTIVE (via implicit reference to `module.eks.cluster_name`) — not on the node group completing.

Key detail: the file contains **no `depends_on = [module.eks]`**. Referencing `module.eks.cluster_name` creates an implicit dependency only on `aws_eks_cluster.this[0]` (the resource that exports that output). Adding `depends_on = [module.eks]` would wait for every resource in the module — including the node group — recreating the deadlock.

See `feedback-1.md` for the full incident report.

---

## Fix 4 — `most_recent` not a valid attribute on `aws_eks_addon`

### Symptom
IDE diagnostic: `An argument named "most_recent" is not expected here.`

### Root cause
`most_recent` is a convenience argument added by the `terraform-aws-eks` module wrapper around `aws_eks_addon`. It is not a native attribute of the underlying AWS provider resource.

### Fix
Replaced with the dedicated data source:
```hcl
data "aws_eks_addon_version" "vpc_cni" {
  addon_name         = "vpc-cni"
  kubernetes_version = module.eks.cluster_version
  most_recent        = true
}

resource "aws_eks_addon" "vpc_cni" {
  addon_version = data.aws_eks_addon_version.vpc_cni.version
  ...
}
```

---

## Fix 5 — Karpenter Helm release `cannot re-use a name that is still in use`

### Symptom
```
Error: cannot re-use a name that is still in use — karpenter in kube-system
```

### Root cause
A previous failed apply had left a broken Helm release named `karpenter` in the `kube-system` namespace. Terraform's Helm provider could not upgrade it because the release was in a failed state.

### Fix
Manually removed the failed release, then re-ran apply:
```bash
helm uninstall karpenter -n kube-system
terraform apply
```

---

## Fix 6 — KMS alias `AlreadyExistsException`

### Symptom
```
Error: creating KMS Alias: AlreadyExistsException: An alias with the name
arn:aws:kms:eu-west-2:573723531607:alias/eks/github-runners already exists
```

### Root cause
The KMS key created during a previous failed apply was in `PendingDeletion` state (7-day waiting period). The key's alias still existed. Terraform attempted to create a new key and a new alias with the same name — AWS rejected it because aliases are unique per account and the old one had not been deleted yet.

### Fix
1. Retrieved the key ID from the alias: `aws kms describe-key --key-id alias/eks/github-runners`
2. Cancelled pending deletion: `aws kms cancel-key-deletion --key-id <key-id>`
3. Re-enabled the key: `aws kms enable-key --key-id <key-id>`
4. Imported the key's alias into Terraform state:
   ```bash
   terraform import 'module.eks.module.kms.aws_kms_alias.this["cluster"]' \
     alias/eks/github-runners
   ```
5. Re-ran apply — Terraform detected the existing key and alias with no diff.

---

## Fix 7 — `aws eks update-kubeconfig` does not accept `--quiet`

### Symptom
```
Unknown options: --quiet
```

### Root cause
`--quiet` is not a valid flag for `aws eks update-kubeconfig`. It suppresses output for some AWS CLI commands but is not implemented for this subcommand.

### Fix
Remove the flag. The correct command is:
```bash
aws eks update-kubeconfig --region eu-west-2 --name github-runners
```

---

## Fix 8 — ARC listener pod stuck in `Pending`

### Symptom
After the full apply completed:
```
NAME                         READY   STATUS
linux-k8s-754b578d-listener  0/1     Pending
```

### Root cause
The `linux-k8s-listener` pod is created by the ARC controller to watch the GitHub job queue. It is a long-lived control-plane pod, not a runner. Because the `helm_release.arc_runner_linux` `template.spec` only configures *runner* pods, the listener pod had no `nodeSelector` or tolerations defined.

The system node group has a `CriticalAddonsOnly:NoSchedule` taint. Without a matching toleration the listener could not be scheduled there. Karpenter would not provision a runner node for it either — the listener does not match any NodePool's toleration requirements (`github-runner=linux:NoSchedule` or `os=windows:NoSchedule`).

### Debugging steps
1. `kubectl get pods -n arc-systems` — listener `0/1 Pending`
2. `kubectl describe pod -n arc-systems linux-k8s-754b578d-listener` → Events:
   ```
   0/1 nodes are available: 1 node(s) had untolerated taint(s) {CriticalAddonsOnly: true}.
   incompatible with nodepool "linux-runners": did not tolerate github-runner=linux:NoSchedule
   incompatible with nodepool "windows-runners": did not tolerate os=windows:NoSchedule
   ```

### Fix
Added `listenerTemplate` to the `helm_release.arc_runner_linux` values in `arc.tf`:
```hcl
listenerTemplate = {
  spec = {
    nodeSelector = { role = "system" }
    tolerations  = [{ key = "CriticalAddonsOnly", operator = "Exists" }]
    containers   = [{ name = "listener" }]  # required by AutoscalingRunnerSet CRD
  }
}
```

The `containers` field is mandatory in the `AutoscalingRunnerSet` CRD's pod spec — omitting it causes:
```
AutoscalingRunnerSet.actions.github.com "linux-k8s" is invalid:
spec.listenerTemplate.spec.containers: Required value
```
Specifying only `name = "listener"` satisfies the schema without overriding the image or command that the ARC chart injects.

---

## Post-apply sanity checks

The following checks were run after all fixes were applied and the apply completed:

```bash
# 1. Confirm system node is Ready
kubectl get nodes -o wide
# ip-10-0-33-112.eu-west-2.compute.internal   Ready   <none>   v1.35.2

# 2. Confirm Karpenter is running
kubectl get pods -n kube-system -l app.kubernetes.io/name=karpenter
# karpenter-695fbbdfc5-l7kpp   1/1   Running   (replica 2 Pending — expected, single system node)

# 3. Confirm ARC controller is running
kubectl get pods -n arc-systems
# arc-gha-rs-controller-797f76d9df-qdm6j   1/1   Running
# linux-k8s-754b578d-listener              1/1   Running  (after Fix 8)

# 4. Confirm runner scale set is registered
kubectl get autoscalingrunnersets -n arc-runners
# NAME        MINIMUM RUNNERS   MAXIMUM RUNNERS
# linux-k8s   0                 5

# 5. Confirm listener is connected to GitHub
kubectl logs -n arc-systems linux-k8s-754b578d-listener --tail=5
# refreshing token — no errors
# getting Actions tenant URL and JWT — success
# Getting next message {"lastMessageID": 0} — long-polling, waiting for jobs
```

---

## End-to-end test result

Workflow pushed to `kubehouse/hello-world` using `runs-on: linux-k8s`:

```
Runner name: linux-k8s-whswz-runner-bkml2
Run docker run --rm hello-world
  Hello from Docker!
  This message shows that your installation appears to be working correctly.
```

- Runner provisioned by Karpenter on a Spot EC2 instance
- Docker-in-Docker sidecar functional
- Job completed successfully
- Node terminated within 30 seconds of job completion
