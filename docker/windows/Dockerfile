# Windows GitHub Actions runner — Windows Server 2022 LTSC (ltsc2022)
#
# GitHub does not publish an official Windows ARC runner image, so this
# Dockerfile builds one that is compatible with the ARC scale set controller.
#
# The ARC controller injects a JIT registration token at pod startup; this image
# only needs the runner binary and tooling — no PAT or secrets baked in.
#
# Prerequisites: Docker Desktop switched to Windows containers mode.
#
# Build locally:  make docker-windows
# Push to GHCR:   docker tag github-runner-windows:latest ghcr.io/<org>/github-runner-windows:ltsc2022
#                 docker push ghcr.io/<org>/github-runner-windows:ltsc2022
# Then set:       var.windows_runner_image = "ghcr.io/<org>/github-runner-windows:ltsc2022"
#
# NOTE: Windows container images are large (15-20 GB). Build and push once, then
#       Kubernetes nodes pull and cache them locally. Cold-start for the very
#       first pod on a new node takes several minutes.

# syntax=docker/dockerfile:1
FROM mcr.microsoft.com/windows/servercore:ltsc2022

SHELL ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", \
       "$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue';"]

# ── Chocolatey (package manager) ───────────────────────────────────────────────
RUN Set-ExecutionPolicy Bypass -Scope Process -Force; \
    [System.Net.ServicePointManager]::SecurityProtocol = \
      [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; \
    iex ((New-Object System.Net.WebClient).DownloadString( \
      'https://community.chocolatey.org/install.ps1'))

# ── Common CI tools ────────────────────────────────────────────────────────────
RUN choco install -y --no-progress \
    git \
    7zip \
    jq \
    curl \
    nodejs-lts \
    awscli \
    kubectl \
    helm \
    terraform

# ── GitHub Actions runner binary ───────────────────────────────────────────────
ARG RUNNER_VERSION=2.322.0

RUN New-Item -ItemType Directory -Force -Path C:\actions-runner | Out-Null; \
    Invoke-WebRequest \
      -Uri "https://github.com/actions/runner/releases/download/v${env:RUNNER_VERSION}/actions-runner-win-x64-${env:RUNNER_VERSION}.zip" \
      -OutFile C:\actions-runner\runner.zip; \
    Expand-Archive -Path C:\actions-runner\runner.zip \
                   -DestinationPath C:\actions-runner \
                   -Force; \
    Remove-Item C:\actions-runner\runner.zip

WORKDIR C:\actions-runner

# ── Entrypoint ─────────────────────────────────────────────────────────────────
# ARC scale set injects these environment variables at pod startup:
#   ACTIONS_RUNNER_INPUT_JITCONFIG  — ephemeral JIT registration token
# The runner binary reads them automatically; no manual configure.cmd needed.
#
# run.cmd is the standard runner start script — it configures from the JIT
# config env var and starts listening for jobs.
ENTRYPOINT ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", \
            "-Command", "C:\\actions-runner\\run.cmd"]
