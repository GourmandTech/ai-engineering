#!/bin/sh
# Azure DevOps MCP — stdio->SSE wrapper entrypoint
#
# Why a shell entrypoint instead of a static Dockerfile CMD (contrast with
# services/github-mcp-wrapper/Dockerfile, which bakes the full --stdio command
# into CMD as a literal string): the Azure DevOps MCP server's org name is
# per-deployment (AZURE_DEVOPS_ORG), not a build-time constant, and it was
# never independently confirmed whether mcpgateway.translate==0.1.1's --stdio
# parser does its own environment-variable expansion inside the quoted command
# string it's handed (translate.py may hand the string to shlex.split() and
# subprocess.Popen(shell=False), in which case a literal "$AZURE_DEVOPS_ORG"
# token would be passed through unexpanded to npx and fail). Rather than
# guessing — the same class of mistake that cost real debugging time on the
# GitHub MCP wrapper's --expose-sse / missing `stdio` subcommand bugs, see
# docs/runbooks/phase4-federated-mcp.md Step 2 incident log — this script lets
# POSIX sh do the substitution before python ever sees the string, so it works
# regardless of translate.py's internal parsing behavior.
set -eu

: "${AZURE_DEVOPS_ORG:?AZURE_DEVOPS_ORG is required — the org segment of https://dev.azure.com/<org>, e.g. 'contoso'}"
: "${PERSONAL_ACCESS_TOKEN:?PERSONAL_ACCESS_TOKEN is required — base64 of <email>:<pat>, injected via Key Vault CSI (see infra/k8s/azure-devops-mcp-secrets-provider.yaml). Raw unencoded PATs will authenticate as a different, wrong identity or fail outright — this is not optional formatting.}"

# Domain scoping (-d) is this server's only built-in tool-surface reduction —
# unlike github-mcp-server there is no --read-only flag (confirmed absent from
# the upstream GETTINGSTARTED.md authentication/CLI docs as of this build;
# re-check `mcp-server-azuredevops --help` on version bumps in case one is
# added). Read-only enforcement for this deployment instead comes from scoping
# the PERSONAL_ACCESS_TOKEN itself to Read-only permissions in Azure DevOps —
# see the PAT generation guidance in infra/k8s/azure-devops-mcp-secrets-provider.yaml.
#
# Domains selected: core, work-items, pipelines — NOT repositories, and this
# exclusion is load-bearing, not stylistic. mcpgateway.translate==0.1.1 reads
# the wrapped subprocess's stdout via asyncio.StreamReader.readline(), which
# has a hard 64 KiB (65,536-byte) per-line default limit with no CLI flag or
# newer pip package available to raise it (checked: 0.1.1 is the latest
# mcp-contextforge-gateway on PyPI, and `python3 -m mcpgateway.translate
# --help` exposes no buffer-size option). The tools/list JSON-RPC response is
# emitted as a single line, and measuring each domain directly (installing
# @azure-devops/mcp locally and driving it over stdio with a dummy PAT) gave:
#   core: 2,231 B (3 tools)   work-items: 25,385 B (23 tools)
#   repositories: 29,027 B (22 tools)   pipelines: 14,840 B (14 tools)
# All four together: 71,345 B — over the limit, and this is exactly what
# caused a real outage (2026-07-03): the bridge's stdout pump crashed
# mid-handshake with `asyncio.exceptions.LimitOverrunError: Separator is
# found, but chunk is longer than limit`, hanging the SSE connection, which
# in turn made ContextForge's POST /gateways registration call hang until
# nginx's own upstream timeout returned a 504 to the client — several layers
# away from the actual root cause, which is why this needed a from-scratch
# repro to find (see runbook Step 3 incident log for the full chain).
#
# core+work-items+pipelines measures 42,364 B (64.6% of the limit, 40
# tools) — comfortable headroom for upstream tool-schema growth. repositories
# (Azure Repos — Azure DevOps' own git hosting) was the one dropped, not
# work-items or pipelines, because this deployment's source code lives in
# GitHub (already federated via github-mcp-server, Step 2) — Azure DevOps
# here is deployments/releases/work-item-tracking only, so Azure Repos tools
# were never going to be used regardless of the size limit. If a future need
# genuinely requires `repositories` too, the only real fix is patching
# mcpgateway.translate's subprocess stream limit ourselves (not attempted
# here — modifying a pinned third-party library's internals without being
# able to fully verify the change against its source was judged riskier than
# scoping domains), or dropping `core` — which does NOT free enough headroom
# on its own (only 2,231 B) — combined with one of the two remaining big
# domains and accepting a much tighter margin. Full available domain list
# (from upstream docs): core, work, work-items, repositories, wiki,
# pipelines, search, test-plans, advanced-security.
exec python3 -m mcpgateway.translate \
  --stdio "mcp-server-azuredevops ${AZURE_DEVOPS_ORG} --authentication pat -d core work-items pipelines" \
  --port 8000
