# syntax=docker/dockerfile:1
# Azure DevOps MCP Server — stdio→SSE wrapper for in-cluster federation
#
# Microsoft's official server (microsoft/azure-devops-mcp, npm package
# @azure-devops/mcp) only ships an stdio transport — confirmed from its own
# docs/GETTINGSTARTED.md, every documented client (VS Code, Claude Code,
# Cursor, etc.) launches it as a local stdio subprocess via `npx` or the
# `mcp-server-azuredevops` bin. There is no self-hostable HTTP/SSE mode (the
# "remote MCP server" Microsoft Learn mentions is a vendor-hosted Azure DevOps
# Services preview endpoint, not something this self-hosted image can point
# to). Same shape of problem as GitHub MCP (see
# services/github-mcp-wrapper/Dockerfile) — wrap the stdio binary with
# ContextForge's mcpgateway.translate bridge and re-expose it as SSE on :8000.
# One wrapper pattern, reused per docs/runbooks/phase4-federated-mcp.md Step 2
# takeaways for Steps 3-5.
#
# Auth: PAT (Personal Access Token), the CI/CD-appropriate option per upstream
# docs — NOT `interactive` (opens a browser, unusable headless in a pod) and
# NOT `azcli` (would require az login state inside the container, an ongoing
# operational burden with no benefit over a scoped PAT here). The PAT must be
# supplied as PERSONAL_ACCESS_TOKEN, base64-encoded as "<email>:<pat>" — this
# is Azure DevOps Basic-auth-shaped, not a raw bearer token; see
# entrypoint.sh and infra/k8s/azure-devops-mcp-secrets-provider.yaml for the
# encoding step. Getting this wrong (e.g. storing the raw PAT unencoded) fails
# auth rather than working with reduced scope, so it's confirmed here rather
# than assumed.
#
# ARG below pins the npm package version rather than `npx @azure-devops/mcp`
# (which would resolve "latest" fresh on every container start — silent
# version drift, and a network dependency at runtime instead of build time).
# Same pin-don't-float philosophy as mcp-contextforge-gateway==0.1.1 in the
# GitHub wrapper.
#
# 2.7.0 confirmed directly (not from secondary docs) via
# `npm view @azure-devops/mcp version` — was 2.7.0 at pin time. Verify this
# again before bumping, since a floating version here silently defeats the
# whole point of pinning.
#
# INCIDENT NOTE (2026-07-03): the first build of this Dockerfile declared
# this ARG *before* FROM and never redeclared it after — Docker scopes a
# pre-FROM ARG to the FROM line itself only (e.g. `FROM image:${ARG}`); it
# does NOT carry into the build stage below unless redeclared with a bare
# `ARG AZURE_DEVOPS_MCP_VERSION` line after FROM. Because of that,
# `npm install -g @azure-devops/mcp@${AZURE_DEVOPS_MCP_VERSION}` actually ran
# with an empty version suffix (`@azure-devops/mcp@`), which npm silently
# resolved to whatever "latest" was at build time (2.7.0) — not the intended
# pin. Confirmed by the fact that the previously-pinned value (2.4.0) doesn't
# even support `--authentication pat` (that choice was added between 2.4.0
# and 2.7.0 — verified by installing 2.4.0 locally and reading its own
# `--help` output), yet the deployed pod's own startup log showed
# `"authentication":"pat"` working and `"version":"2.7.0"`. Fixed below by
# redeclaring the ARG after FROM. Same "pin-then-verify-it-actually-pinned"
# lesson as the mcpgateway.translate `--expose-sse` and missing `stdio`
# subcommand bugs from the GitHub wrapper (runbook Step 2) — a value being
# declared correctly in the Dockerfile doesn't mean it's actually in scope
# where it's used.
ARG AZURE_DEVOPS_MCP_VERSION=2.7.0

# Node 20+ is a hard requirement (upstream docs, "Prerequisites" section) —
# node:20-slim, not node:latest, to avoid an unpinned major-version jump.
FROM node:20-slim

# Redeclare — see the incident note above. Required for the ARG to be usable
# in any RUN/CMD/ENTRYPOINT instruction after this point.
ARG AZURE_DEVOPS_MCP_VERSION

WORKDIR /app

# python3/pip for mcpgateway.translate — this base image is Node-first (unlike
# the GitHub wrapper's Python-first base with a copied-in static Go binary),
# because @azure-devops/mcp needs a live Node runtime at request time, not
# just at build time. --break-system-packages required on Debian
# bookworm-based images (PEP 668 externally-managed-environment guard).
RUN apt-get update \
    && apt-get install -y --no-install-recommends python3 python3-pip \
    && rm -rf /var/lib/apt/lists/* \
    && pip3 install --no-cache-dir --break-system-packages mcp-contextforge-gateway==0.1.1

# Global install (not npx at runtime) so the resolved version is fixed at
# image build time and every restart uses byte-identical code — npx without a
# pinned version would silently re-resolve "latest" on the pod's next crash
# loop or rollout restart.
#
# Bin name `mcp-server-azuredevops`: confirmed both from upstream docs AND
# directly by installing this exact package locally and running
# `ls node_modules/.bin/` — it's the package's own declared bin entry in
# package.json (`"bin": {"mcp-server-azuredevops": "dist/index.js"}`).
RUN npm install -g @azure-devops/mcp@${AZURE_DEVOPS_MCP_VERSION}

COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

# UID 1001, not 1000: unlike the GitHub wrapper's python:3.12-slim base,
# node:20-slim already ships its own `node` user at UID 1000 (confirmed by a
# real build failure — `useradd -u 1000` errored "UID 1000 is not unique").
# Kept as a dedicated `mcp` user rather than reusing the image's `node` user
# for consistency with the other wrapper images' explicit-user pattern.
# infra/k8s/azure-devops-mcp-server.yaml's securityContext.runAsUser must
# match this value exactly — a mismatch means the pod runs as a UID that
# doesn't own /app (permission denied on entrypoint.sh) or, worse, silently
# runs as the base image's own `node` user instead of this one.
RUN useradd -m -u 1001 mcp && chown -R mcp:mcp /app
USER mcp

EXPOSE 8000

# AZURE_DEVOPS_ORG and PERSONAL_ACCESS_TOKEN are required at runtime — set via
# the Deployment env (org, a plain non-secret value) and the Key Vault
# CSI-synced `azure-devops-mcp-secrets` k8s Secret (PAT, see
# infra/k8s/azure-devops-mcp-server.yaml and
# infra/k8s/azure-devops-mcp-secrets-provider.yaml). Never baked into this
# image or passed as a build arg.
ENTRYPOINT ["/app/entrypoint.sh"]
