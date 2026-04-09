# Linux GitHub Actions runner — extends the official ARC image with common
# CI tooling pre-installed so jobs don't need to reinstall them each run.
#
# Base: ghcr.io/actions/actions-runner (AL2023-based, maintained by GitHub)
# The ARC scale set controller injects registration credentials at runtime;
# this image contains only tooling, not secrets.
#
# Build locally:  make docker-linux
# Push to GHCR:   docker tag github-runner-linux:latest ghcr.io/<org>/github-runner-linux:latest
#                 docker push ghcr.io/<org>/github-runner-linux:latest
# Then set:       var.linux_runner_image = "ghcr.io/<org>/github-runner-linux:latest"

ARG RUNNER_VERSION=latest
FROM ghcr.io/actions/actions-runner:${RUNNER_VERSION}

# Switch to root for package installation
USER root

# ── System packages ────────────────────────────────────────────────────────────
RUN apt-get update -qq && apt-get install -y --no-install-recommends \
    # Archive / compression
    zip unzip tar \
    # Networking / download
    curl wget ca-certificates gnupg \
    # Build essentials
    make gcc g++ \
    # Scripting utilities
    jq gettext-base \
    # Git extras
    git-lfs \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# ── AWS CLI v2 ─────────────────────────────────────────────────────────────────
RUN curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip \
    && unzip -q /tmp/awscliv2.zip -d /tmp \
    && /tmp/aws/install \
    && rm -rf /tmp/awscliv2.zip /tmp/aws

# ── kubectl ────────────────────────────────────────────────────────────────────
RUN KUBECTL_VERSION=$(curl -fsSL https://dl.k8s.io/release/stable.txt) \
    && curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
       -o /usr/local/bin/kubectl \
    && chmod +x /usr/local/bin/kubectl

# ── Helm ───────────────────────────────────────────────────────────────────────
RUN curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# ── Terraform ─────────────────────────────────────────────────────────────────
ARG TERRAFORM_VERSION=1.14.0
RUN curl -fsSL "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip" \
       -o /tmp/terraform.zip \
    && unzip -q /tmp/terraform.zip -d /usr/local/bin \
    && rm /tmp/terraform.zip \
    && chmod +x /usr/local/bin/terraform

# ── Node.js (LTS via NodeSource) ──────────────────────────────────────────────
ARG NODE_MAJOR=20
RUN curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# ── Docker CLI (client only — daemon comes from DinD sidecar) ─────────────────
RUN curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker.gpg \
    && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
       > /etc/apt/sources.list.d/docker.list \
    && apt-get update -qq \
    && apt-get install -y --no-install-recommends docker-ce-cli \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# ── Restore runner user ────────────────────────────────────────────────────────
USER runner

# Verify key tools are in place
RUN aws --version \
    && kubectl version --client \
    && helm version --short \
    && terraform version \
    && node --version \
    && docker --version
