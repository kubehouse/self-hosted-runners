# ── Namespace + GitHub PAT secret ─────────────────────────────────────────────
resource "kubernetes_namespace_v1" "arc_runners" {
  metadata {
    name = "arc-runners"
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }

  depends_on = [module.eks]
}

resource "kubernetes_secret_v1" "github_pat" {
  metadata {
    name      = "github-pat-secret"
    namespace = kubernetes_namespace_v1.arc_runners.metadata[0].name
  }

  type = "Opaque"

  data = {
    github_token = var.github_pat
  }
}

# ── ARC Scale Set Controller ───────────────────────────────────────────────────
resource "helm_release" "arc_controller" {
  namespace        = "arc-systems"
  create_namespace = true
  name             = "arc"
  repository       = "oci://ghcr.io/actions/actions-runner-controller-charts"
  chart            = "gha-runner-scale-set-controller"
  version          = var.arc_version
  wait             = true
  timeout          = 300

  values = [
    yamlencode({
      tolerations  = [{ key = "CriticalAddonsOnly", operator = "Exists" }]
      nodeSelector = { role = "system" }
      resources = {
        requests = { cpu = "100m", memory = "128Mi" }
        limits   = { cpu = "500m", memory = "512Mi" }
      }
    })
  ]

  depends_on = [module.eks]
}

# ── Linux Runner Scale Set (Docker-in-Docker) ──────────────────────────────────
# Runs a DinD sidecar so workflow steps can build and run Docker images,
# identical to how github-hosted ubuntu-latest works for Docker jobs.
#
# Pod topology:
#   init-dind-externals  — copies runner binaries into the shared externals vol
#   runner               — executes workflow steps, connects to dind via socket
#   dind                 — privileged Docker daemon (socket on /var/run)
#
# Use in workflows: runs-on: linux-k8s
resource "helm_release" "arc_runner_linux" {
  namespace        = kubernetes_namespace_v1.arc_runners.metadata[0].name
  create_namespace = false
  name             = "arc-runner-linux"
  repository       = "oci://ghcr.io/actions/actions-runner-controller-charts"
  chart            = "gha-runner-scale-set"
  version          = var.arc_version
  wait             = true
  timeout          = 300

  values = [
    yamlencode({
      githubConfigUrl    = var.github_config_url
      githubConfigSecret = kubernetes_secret_v1.github_pat.metadata[0].name
      runnerScaleSetName = "linux-k8s"
      minRunners         = var.linux_runner_min_count
      maxRunners         = var.linux_runner_max_count

      template = {
        spec = {
          nodeSelector = {
            "kubernetes.io/os"      = "linux"
            "karpenter.sh/nodepool" = "linux-runners"
          }
          tolerations = [
            {
              key      = "github-runner"
              operator = "Equal"
              value    = "linux"
              effect   = "NoSchedule"
            }
          ]

          # Copies runner externals (node, python, etc.) into a shared volume
          # so the dind container can access them without needing the runner image.
          initContainers = [
            {
              name    = "init-dind-externals"
              image   = var.linux_runner_image
              command = ["cp", "-r", "-v", "/home/runner/externals/.", "/home/runner/tmpDir/"]
              volumeMounts = [
                { name = "dind-externals", mountPath = "/home/runner/tmpDir" }
              ]
            }
          ]

          containers = [
            {
              name    = "runner"
              image   = var.linux_runner_image
              command = ["/home/runner/run.sh"]
              env = [
                # Point the Docker CLI at the dind daemon socket
                { name = "DOCKER_HOST", value = "unix:///var/run/docker.sock" }
              ]
              resources = {
                requests = { cpu = "500m", memory = "512Mi" }
                limits   = { cpu = "2", memory = "4Gi" }
              }
              volumeMounts = [
                { name = "work", mountPath = "/home/runner/_work" },
                { name = "dind-sock", mountPath = "/var/run" },
              ]
            },
            {
              name  = "dind"
              image = "docker:dind"
              # Run dockerd on the shared /var/run socket; GID 1001 matches the
              # runner user so it can connect without root.
              args = [
                "dockerd",
                "--host=unix:///var/run/docker.sock",
                "--group=1001",
              ]
              securityContext = { privileged = true }
              resources = {
                requests = { cpu = "200m", memory = "256Mi" }
                limits   = { cpu = "2", memory = "4Gi" }
              }
              volumeMounts = [
                { name = "work", mountPath = "/home/runner/_work" },
                { name = "dind-sock", mountPath = "/var/run" },
                { name = "dind-externals", mountPath = "/home/runner/externals" },
              ]
            }
          ]

          volumes = [
            { name = "work", emptyDir = {} },
            # Shared Unix socket between runner and dind
            { name = "dind-sock", emptyDir = {} },
            # Runner tool cache copied in by the init container
            { name = "dind-externals", emptyDir = {} },
          ]
        }
      }
    })
  ]

  depends_on = [
    helm_release.arc_controller,
    kubernetes_secret_v1.github_pat,
  ]
}

# ── Windows Runner Scale Set ───────────────────────────────────────────────────
# Use in workflows: runs-on: windows-k8s
resource "helm_release" "arc_runner_windows" {
  namespace        = kubernetes_namespace_v1.arc_runners.metadata[0].name
  create_namespace = false
  name             = "arc-runner-windows"
  repository       = "oci://ghcr.io/actions/actions-runner-controller-charts"
  chart            = "gha-runner-scale-set"
  version          = var.arc_version
  wait             = true
  timeout          = 300

  values = [
    yamlencode({
      githubConfigUrl    = var.github_config_url
      githubConfigSecret = kubernetes_secret_v1.github_pat.metadata[0].name
      runnerScaleSetName = "windows-k8s"
      minRunners         = var.windows_runner_min_count
      maxRunners         = var.windows_runner_max_count

      template = {
        spec = {
          nodeSelector = {
            "kubernetes.io/os"      = "windows"
            "karpenter.sh/nodepool" = "windows-runners"
          }
          tolerations = [
            {
              key      = "os"
              operator = "Equal"
              value    = "windows"
              effect   = "NoSchedule"
            }
          ]
          containers = [
            {
              name    = "runner"
              image   = var.windows_runner_image
              command = ["pwsh", "-Command", "C:\\actions-runner\\run.cmd"]
              resources = {
                requests = { cpu = "1", memory = "2Gi" }
                limits   = { cpu = "4", memory = "8Gi" }
              }
              volumeMounts = [
                { name = "work", mountPath = "C:\\actions-runner\\_work" }
              ]
            }
          ]
          volumes = [
            { name = "work", emptyDir = {} }
          ]
        }
      }
    })
  ]

  depends_on = [
    helm_release.arc_controller,
    kubernetes_secret_v1.github_pat,
  ]
}
