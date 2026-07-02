# syntax=docker/dockerfile:1
# GitHub MCP Server — stdio→SSE wrapper for in-cluster federation
#
# The official github/github-mcp-server binary only speaks stdio (see its own
# Dockerfile: ENTRYPOINT ["/server/github-mcp-server"], CMD ["stdio"]). GitHub's
# only HTTP/SSE transport is the vendor-hosted https://api.githubcopilot.com/mcp/,
# which is not self-hostable. To keep GitHub traffic inside the AKS network
# boundary (production requirement — no external MCP dependency, full control
# over image provenance/patching), this image bundles the upstream binary with
# ContextForge's own mcpgateway.translate bridge and re-exposes it as SSE on :8000,
# matching the same wrapper pattern used for Azure DevOps / Kubernetes / Prometheus
# MCP servers (see docs/runbooks/phase4-federated-mcp.md, Steps 3-5).
#
# Least privilege: --read-only + a scoped GITHUB_TOOLSETS keep this server from
# ever offering write tools, regardless of what the backing PAT is scoped to.
ARG GITHUB_MCP_VERSION=v1.0.4

FROM ghcr.io/github/github-mcp-server:${GITHUB_MCP_VERSION} AS ghmcp

FROM python:3.12-slim

WORKDIR /app

# mcpgateway.translate — package `mcp-contextforge-gateway` ships the
# mcpgateway/translate.py module used here. Pinned (not "latest install") on
# purpose: the CLI's flags have already changed shape once between what's
# described in third-party blog posts (--expose-sse, --expose-streamable-http)
# and what 0.1.1 — the actual latest release on PyPI as of this build —
# supports (--stdio, --port, --logLevel only; confirmed by installing 0.1.1
# and running --help directly, see Dockerfile history / runbook Step 2 incident
# notes). An unpinned install would silently pick up whatever's newest at
# build time and could break the CMD below again the same way.
RUN pip install --no-cache-dir mcp-contextforge-gateway==0.1.1

# Copy the upstream distroless binary in (statically linked Go binary, no libc deps)
COPY --from=ghmcp /server/github-mcp-server /usr/local/bin/github-mcp-server
RUN chmod +x /usr/local/bin/github-mcp-server

# Least-privilege defaults — override at deploy time via env if a broader
# toolset is genuinely needed. GITHUB_TOOLSETS is confirmed (used in upstream
# README docker examples); read-only is instead passed explicitly as a CMD
# flag below rather than via an env var, since the exact env var name for it
# was never independently confirmed and getting it wrong would silently do
# nothing — same failure class as the --expose-sse bug already hit once here.
ENV GITHUB_TOOLSETS="repos,issues,pull_requests,actions"

RUN useradd -m -u 1000 mcp && chown -R mcp:mcp /app
USER mcp

EXPOSE 8000

# GITHUB_PERSONAL_ACCESS_TOKEN is injected via the Key Vault CSI-synced
# `github-mcp-secrets` k8s Secret (see infra/k8s/github-mcp-secrets-provider.yaml)
# — never baked into this image or passed as a build arg.
#
# NOTE: verify the exact --read-only flag name against the pinned
# GITHUB_MCP_VERSION's `github-mcp-server --help` output before first deploy;
# confirmed present as of v1.0.4 (May 2026) per upstream README, but re-check
# on version bumps since this is a fast-moving upstream project.
#
# mcp-contextforge-gateway 0.1.1's actual CLI (confirmed by running it, not
# just reading docs): `python -m mcpgateway.translate --stdio "<cmd>" --port
# <port> [--logLevel ...]`. No --expose-sse / --expose-streamable-http flag
# exists in this release — an earlier build of this Dockerfile had those and
# they caused `error: unrecognized arguments`, exit code 2, from argparse.
#
# The --stdio command itself was ALSO wrong in an earlier build: it was
# missing the required `stdio` positional subcommand (github-mcp-server's own
# Dockerfile shows CMD ["stdio"] — running the binary without it just prints
# usage and exits). That made the wrapped process die near-instantly, so by
# the time ContextForge's first real POST /message arrived, translate.py's
# subprocess.stdin was already a closed pipe — surfaced as
# `ConnectionResetError('Connection lost')` in this container's own logs, not
# as anything from the Go binary itself (it exits too fast to log much).
# Fixed below by including `stdio` as the first token.
CMD ["python3", "-m", "mcpgateway.translate", \
     "--stdio", "github-mcp-server stdio --toolsets repos,issues,pull_requests,actions --read-only", \
     "--port", "8000"]
