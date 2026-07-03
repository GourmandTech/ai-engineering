# Phase 4 — Federated MCP: Multi-Server Registration, RBAC, and OAuth

## Overview

Phase 4 turns ContextForge from a single gateway into a true **federated MCP hub**: multiple upstream MCP servers registered, access controlled by RBAC teams, and Entra ID SSO layered on top. This is the phase that demonstrates production AI-assisted SRE capabilities to a hiring audience.

**Production gateway:** `https://contextforge.gourmandtech.com`

---

## MCP Server Inventory

| Server | Source | Transport | Status |
|---|---|---|---|
| SRE Toolbox MCP | `services/sre-mcp-server/` (custom Python FastMCP) | SSE | ✅ Running in AKS + registered in ContextForge |
| GitHub MCP | `github/github-mcp-server` (official, self-hosted) | stdio via `mcpgateway.translate` wrapper | ✅ Running in AKS + registered in ContextForge |
| Azure DevOps MCP | `microsoft/azure-devops-mcp` (official) | stdio via `mcpgateway.translate` wrapper | ✅ Running in AKS + registered in ContextForge (40 tools) |
| Kubernetes MCP | `containers/kubernetes-mcp-server` (Red Hat/containers, native SSE — no wrapper) | SSE (native) | ✅ Running in AKS + registered in ContextForge (13 tools) |
| Prometheus MCP | `mcp-server-prometheus` (community) | stdio via wrapper | ⬜ |

---

## Architecture

```
Claude / Copilot / agent
        │
        ▼
ContextForge Gateway (https://contextforge.gourmandtech.com)
  ├── RBAC: teams (sre-team, dev-team, readonly)
  ├── Entra ID SSO (OIDC)
  ├── API key auth for service accounts
        │
        ├── GitHub MCP ────────── (SSE → api.github.com)
        ├── Azure DevOps MCP ──── (stdio → dev.azure.com)
        ├── Kubernetes MCP ─────── (SSE native → AKS cluster)
        ├── Prometheus MCP ─────── (stdio → /metrics endpoint)
        └── SRE Toolbox MCP ────── (SSE → AKS pod) ✅
```

In ContextForge terminology, each upstream server is a **Gateway**. Tools from all registered gateways are aggregated into a single MCP endpoint. A **Virtual Server** groups selected tools and applies RBAC.

---

## Step 0 — Prerequisites

```bash
# Confirm AKS is up and gateway is healthy
make aks-creds
curl https://contextforge.gourmandtech.com/health
```

### Auth token — important gotcha

The `platform-admin-password` secret in Key Vault holds the **initially generated** password from `make kv-populate`. If you changed your password on first login to the ContextForge admin UI, Key Vault is stale. Sync it before proceeding:

```bash
# If you changed your password on first login, update KV first:
az keyvault secret set \
  --vault-name kv-contextforge-dev \
  --name platform-admin-password \
  --value "YourCurrentPassword"
```

Then get the JWT — `make mcp-get-token` pulls email and password from Key Vault automatically:

```bash
# Auth endpoint: POST /auth/login — JSON body, must be an email address (not plain username)
export JWT_TOKEN=$(make mcp-get-token)
echo ${JWT_TOKEN:0:30}...   # non-empty = success
```

> ✅ **Confirmed working** (2026-07-02): JWT exported successfully after syncing KV password with current admin password.

---

## Step 1 — Deploy + Register SRE Toolbox MCP Server ✅ COMPLETE

> Confirmed 2026-07-02: pod `1/1 Running`, registered in ContextForge, `status: active`, 5 tools federated.

The custom Python MCP server lives at `services/sre-mcp-server/`. It exposes SRE-specific tools as a FastMCP SSE container inside AKS.

```bash
# Build and push to ACR
# NOTE: az acr build (ACR Tasks) is not permitted on this subscription.
# Build locally in the devcontainer and push directly instead.
# --platform linux/amd64 required: devcontainer on M1 builds arm64 by default; AKS nodes are amd64
make sre-mcp-build

# Deploy to AKS
make sre-mcp-deploy

# Verify the pod is running and healthy
kubectl get pods -n mcp -l app=sre-mcp-server
kubectl port-forward svc/sre-mcp-server 8001:8000 -n mcp &
curl http://localhost:8001/health   # {"status":"healthy","service":"sre-toolbox"}
kill %1

# Register with ContextForge
export JWT_TOKEN=$(make mcp-get-token)
make mcp-register-sre JWT_TOKEN=$JWT_TOKEN

# Verify: 5 tools should appear
make mcp-list-gateways JWT_TOKEN=$JWT_TOKEN
make mcp-list-tools JWT_TOKEN=$JWT_TOKEN
```

**Expected tool names after registration** (single-hyphen separator, underscores converted to hyphens):
- `sre-toolbox-sre-healthcheck`
- `sre-toolbox-sre-k8s-pod-status`
- `sre-toolbox-sre-azure-resource`
- `sre-toolbox-sre-prometheus-query`
- `sre-toolbox-sre-incident-summary`

---

## Step 2 — Register GitHub MCP Server ✅ COMPLETE

> Confirmed 2026-07-02: pod `1/1 Running`, registered in ContextForge, `status: active`, `reachable: true`, 22 tools federated (`sre-toolbox` + `github-mcp` = 27 tools total across both gateways).

**Decision: self-hosted in AKS, not GitHub's remote hosted MCP.** For a production/enterprise-style deployment this is the only one of the two that keeps GitHub API traffic and the credential inside the network boundary, avoids a runtime dependency on GitHub's own infrastructure, and lets us apply the same image-pinning, least-privilege, and NetworkPolicy controls used everywhere else in this cluster. The remote option (`https://api.githubcopilot.com/mcp/`) is genuinely the "easiest" path and is fine for a personal/dev setup, but an enterprise reviewer would flag routing GitHub credentials through an externally-hosted MCP endpoint outside the org's control plane.

**Auth: fine-grained PAT via Key Vault + CSI, not a GitHub App.** GitHub App installation-token auth would be the stronger pattern (short-lived tokens, not tied to a human account, its own audit identity) — but it's currently broken in the upstream `github-mcp-server` binary: a forced `GET /user` check doesn't work with App auth (tracked at [github/github-mcp-server#1610](https://github.com/github/github-mcp-server/issues/1610), still open as of this writing). Until that lands, the production-forward compromise is a **fine-grained PAT** (not classic — classic PATs can't be repo-scoped), issued to a dedicated bot/machine account rather than a human's, stored only in Key Vault, and synced into the pod via the Secrets Store CSI driver — never passed to `make` as a plaintext arg, never touching ContextForge's own gateway config. Revisit GitHub App auth once #1610 is resolved upstream.

**Transport: upstream binary is stdio-only.** `github/github-mcp-server`'s own Dockerfile (`ENTRYPOINT ["/server/github-mcp-server"]`, `CMD ["stdio"]`) confirms there's no self-hostable HTTP/SSE mode — the only HTTP transport is GitHub's vendor-hosted endpoint. So this server needs the same `mcpgateway.translate` stdio→SSE bridge that Steps 3-5 (Azure DevOps, Kubernetes, Prometheus) already call for — one wrapper pattern reused four times rather than four bespoke integrations.

**Least privilege:** the wrapper image bakes in `--read-only` plus a scoped `GITHUB_TOOLSETS=repos,issues,pull_requests,actions` (verified flags, current as of `github-mcp-server` v1.0.4 / May 2026 — re-check `--help` output on version bumps, this project moves fast). Write tools are unavailable regardless of what the backing PAT is scoped to.

### Build the wrapper image

```bash
# services/github-mcp-wrapper/Dockerfile — bundles the pinned github-mcp-server
# binary (ARG GITHUB_MCP_VERSION, default v1.0.4) with mcpgateway.translate,
# exposing SSE on :8000. Mirrors the sre-mcp-build pattern (local build + push,
# az acr build/Tasks not permitted on this subscription).
make github-mcp-build
```

### Provision the PAT

```bash
# One-time, manual (can't be auto-generated like the other KV secrets):
#   1. https://github.com/settings/personal-access-tokens/new
#   2. Resource owner: a bot/machine account, not a personal account
#   3. Repository access: select specific repos only
#   4. Permissions: read-only (Contents, Issues, Pull requests, Actions)
#   5. Shortest expiration GitHub allows — set a rotation reminder
az keyvault secret set --vault-name kv-contextforge-dev \
  --name github-mcp-pat --value "<fine-grained PAT>"
```

### Deploy and register

```bash
# Provisions the dedicated github-mcp-server workload identity (UAMI +
# federated credential + vault-scoped Key Vault Secrets User) — see
# infra/bicep/modules/workload-identity.bicep. Additive/idempotent; safe to
# re-run against an existing deployment.
make bicep-deploy

# Applies infra/k8s/github-mcp-secrets-provider.yaml (CSI sync of the PAT into
# a dedicated github-mcp-secrets k8s Secret) then infra/k8s/github-mcp-server.yaml
# (Deployment + ServiceAccount + Service + NetworkPolicy). Both get the new
# identity's clientId substituted in automatically.
make github-mcp-deploy

# Verify the pod is running and the PAT synced
kubectl get pods -n mcp -l app=github-mcp-server
kubectl get secret github-mcp-secrets -n mcp -o jsonpath='{.data.GITHUB_PERSONAL_ACCESS_TOKEN}' | base64 -d | wc -c   # non-zero = synced

# Register the in-cluster SSE endpoint — note: no PAT passed here, ContextForge
# never holds the GitHub credential, it only knows the in-cluster URL
export JWT_TOKEN=$(make mcp-get-token)
make mcp-register-github JWT_TOKEN=$JWT_TOKEN

# Verify
make mcp-list-gateways JWT_TOKEN=$JWT_TOKEN
make mcp-list-tools JWT_TOKEN=$JWT_TOKEN
```

### Incident: FailedMount / AADSTS70025 on first deploy attempt (2026-07-02)

First `github-mcp-deploy` run failed. `kubectl get events -n mcp` (and the Azure Portal AKS Events export) showed repeated `FailedMount` warnings on the pod:

```
MountVolume.SetUp failed for volume "kv-secrets": ... failed to mount objects,
error: failed to get objectType:secret, objectName:github-mcp-pat, ...
ClientAssertionCredential authentication failed. FromAssertion(): ...
AADSTS70025: The client 'a11b37dd-...'(azurekeyvaultsecretsprovider-aks-contextforge-dev)
has no configured federated identity credentials.
```

**Root cause:** the original `infra/k8s/github-mcp-secrets-provider.yaml` set the SecretProviderClass `clientID` to the AKS Key Vault CSI add-on's own managed identity (`aks.outputs.csiDriverIdentityObjectId` / `addonProfiles.azureKeyvaultSecretsProvider.identity`) — the same identity `infra/k8s/secret-provider-class.yaml` was already scaffolded to use. That identity has never had a `Microsoft.ManagedIdentity/.../federatedIdentityCredentials` resource created for it anywhere in this repo (confirmed by grep across `infra/bicep/` — zero matches). AKS provisions this identity for the CSI driver's own internal use; it isn't something application ServiceAccounts are meant to federate against directly. AADSTS70025 specifically means zero federated credentials exist on that app registration at all (a subject mismatch, e.g. wrong namespace/ServiceAccount, throws a different error — AADSTS70021).

It also would have been the wrong fix even with a matching federated credential added: that identity already holds `Key Vault Secrets User` for the CSI driver's purposes, so any pod federating against it inherits ambient read access to *every* secret in the vault (`jwt-secret-key`, `platform-admin-password`, etc.), not just `github-mcp-pat`.

**Fix:** `infra/bicep/modules/workload-identity.bicep` — a reusable module creating one dedicated UAMI per workload, with a federated credential scoped to exactly that workload's `system:serviceaccount:<namespace>:<name>` subject, and `Key Vault Secrets User` scoped to the vault resource itself (tighter than the CSI add-on's own resource-group-scoped grant). Instantiated in `main.bicep` as `githubMcpIdentity`. `infra/k8s/github-mcp-server.yaml`'s ServiceAccount now carries the `azure.workload.identity/client-id` annotation and the pod template the `azure.workload.identity/use: "true"` label — both required for the workload-identity webhook to inject the token the CSI driver federates with; missing either produces the same symptom as a missing federated credential, worth knowing when debugging this class of failure on the Step 3-5 servers too, since they'll need the same pattern.

### Incident: gateway FailedScheduling + github-mcp-server never Ready (2026-07-02, second deploy attempt)

After the AADSTS70025 fix above, `make bicep-deploy` + `make github-mcp-deploy` surfaced two more, unrelated problems — both real, both worth the writeup.

**1. Gateway pod `FailedScheduling` — "Insufficient cpu", node count dropped 2→1.** `kubectl get events` showed the ContextForge gateway pod unable to schedule (`0/2 nodes are available: 1 Insufficient cpu` → shortly after, `0/1 nodes are available: 1 Insufficient cpu`). Root cause: `infra/bicep/modules/aks.bicep` had `enableAutoScaling: false` hardcoded with a fixed `count: nodeCount` (1) — but the *live* cluster had autoscaling enabled with min 2 / max 10, turned on manually via the Azure Portal after the CPU exhaustion incident noted in `CLAUDE.md` ("Node pool ... autoscaling enabled ... configured 2026-07-02 via Azure Portal"). That portal change was never reflected back into Bicep. Running `make bicep-deploy` — which this runbook told you to do, to provision the new workload identity — is an idempotent PUT against the whole `agentPoolProfiles` block, so it reconciled the live pool back to the Bicep-declared `enableAutoScaling: false` / 1 node, undoing the portal fix and scaling a node away out from under the gateway. Classic IaC drift: the source of truth and the running resource disagreed, and redeploying silently "fixed" the drift in the wrong direction.

Fixed by making autoscaling a real, non-defaulted-to-off parameter: `infra/bicep/modules/aks.bicep` now takes `enableAutoScaling` (default `true`), `minNodeCount` (default `2`), `maxNodeCount` (default `10`), threaded through `main.bicep` and set explicitly in `main.bicepparam` to match the live Portal config. `make bicep-deploy` is now safe to re-run — it converges to the actual production state instead of away from it. General lesson for this project: any manual Portal change needs to be back-ported into Bicep in the same sitting, or the next `bicep-deploy` reverts it.

**2. `github-mcp-server` pod stuck `Ready: False`, restarting every ~90s with clean `exitCode: 0`.** The CSI mount itself succeeded this time (no more FailedMount) — `kubectl get pod ... -o yaml` showed the `azure-identity-token` projected volume and `AZURE_TENANT_ID`/`AZURE_FEDERATED_TOKEN_FILE` env vars correctly injected by the workload-identity webhook, confirming the Step 2 fix above worked. But the container never became ready and cycled: alive for ~88 seconds (consistent with the liveness probe's `initialDelaySeconds: 10` + 3× `periodSeconds: 30` before kubelet kills it), then a clean exit.

Root cause, found by actually installing the real package rather than trusting docs: `services/github-mcp-wrapper/Dockerfile`'s `CMD` passed `--expose-sse` and (implicitly, from an earlier draft) `--expose-streamable-http` to `mcpgateway.translate`. Neither flag exists — `pip install mcp-contextforge-gateway` installs `0.1.1` (the actual latest on PyPI; verified with `pip index versions`), and that release's argparse only recognizes `--stdio`, `--port`, and `--logLevel` (verified by installing it locally and running `--help` / a real invocation). An earlier round of research had surfaced `--expose-sse` from a blog post describing a newer/different build than what's actually published — a reminder to verify CLI flags against the installed artifact, not secondary sources, especially for a project this early in its release cycle (0.1.x).

Fixed: `CMD` now uses `--stdio "<cmd>" --port 8000` only, and the `pip install` is pinned to `mcp-contextforge-gateway==0.1.1` so a future rebuild doesn't silently pick up a different CLI shape again. Verified the corrected command actually binds and serves `/sse` by running it in a sandbox before shipping the fix.

**3. `kubectl apply` reports everything "unchanged", `rollout status` times out.** Ran into this immediately when re-deploying after the two fixes above: `github-mcp-build` pushes a new image but `GITHUB_MCP_TAG` defaults to `latest`, so the Deployment YAML's `image:` string never changes text — `kubectl apply` correctly reports "unchanged" (the manifest genuinely didn't change) and never creates a new ReplicaSet, so the old, still-broken pod just sits there and `rollout status` times out waiting for a rollout that was never triggered. Same root cause CLAUDE.md already documents for the ContextForge Helm chart (`envFrom` snapshotting requiring an explicit `kubectl rollout restart`). Fixed: `make github-mcp-deploy` now always runs `kubectl rollout restart deployment/github-mcp-server` after applying, so a rebuilt `:latest` image is guaranteed to actually roll out.

### Incident: registration times out with 504, once the pod is finally Ready (2026-07-02, third deploy attempt)

With the pod healthy (`1/1 Running`) and the PAT confirmed synced, `make mcp-register-github` still failed — two more bugs, found from `kubectl logs` on both the ContextForge gateway pod and `github-mcp-server` itself, not guesswork.

**4. NetworkPolicy ingress label didn't match the real gateway pod → `ConnectTimeout`.** `infra/k8s/github-mcp-server.yaml`'s NetworkPolicy guessed `app.kubernetes.io/name: mcpgateway` for the allowed ingress source, flagged explicitly as unverified when written. `kubectl get pods -n mcp --show-labels | grep mcpgateway` showed the real label is `app=mcp-stack-mcpgateway` (the chart's plain Helm release-name label, no `app.kubernetes.io/name` key at all) — so the policy silently dropped every connection attempt from ContextForge, surfacing as `ConnectTimeout` on registration. Fixed: `matchLabels: { app: mcp-stack-mcpgateway }`. If `HELM_RELEASE` in the Makefile ever changes from `mcp-stack`, this label needs updating too.

**5. `github-mcp-server` accepted the connection but every `POST /message` returned `500` — `ConnectionResetError('Connection lost')` writing to the wrapped process's stdin.** With the NetworkPolicy fixed, `GET /sse` succeeded (`200 OK`) but the JSON-RPC handshake failed immediately after. `kubectl logs` on the `github-mcp-server` pod showed `mcpgateway.translate` failing to write to `stdio._stdin` — meaning the wrapped `github-mcp-server` process had already exited by the time the first real request arrived. Root cause: `services/github-mcp-wrapper/Dockerfile`'s `CMD` ran `github-mcp-server --toolsets ... --read-only` — missing the required `stdio` **positional subcommand**. The upstream binary's own Dockerfile (`CMD ["stdio"]`) confirms `stdio` isn't implied; without it the binary just prints usage and exits, closing its stdin pipe before `mcpgateway.translate` could use it. Fixed: `CMD` now runs `github-mcp-server stdio --toolsets ... --read-only`.

**Confirmed working end-to-end 2026-07-02** after fixes 1-5: pod `1/1 Running`, PAT synced, registered with `status: active`, `reachable: true`, **22 tools federated** (27 total across both gateways with `sre-toolbox`).

**Re-deploy after all five fixes:**
```bash
make bicep-deploy                 # converges node pool back to 2-10 autoscaling
make github-mcp-build             # rebuilds image with corrected stdio + translate flags
make github-mcp-deploy            # re-applies manifests (incl. corrected NetworkPolicy label), restarts the pod
kubectl get pods -n mcp -w        # watch for github-mcp-server going Ready, gateway staying scheduled
export JWT_TOKEN=$(make mcp-get-token)
make mcp-register-github JWT_TOKEN=$JWT_TOKEN
make mcp-list-tools JWT_TOKEN=$JWT_TOKEN
```

**Confirmed federated tool names** (22, `github-mcp-<tool-name>`, underscores converted to hyphens):
`github-mcp-search-repositories`, `github-mcp-search-pull-requests`, `github-mcp-search-issues`, `github-mcp-search-code`, `github-mcp-pull-request-read`, `github-mcp-list-tags`, `github-mcp-list-releases`, `github-mcp-list-pull-requests`, `github-mcp-list-issues`, `github-mcp-list-issue-types`, `github-mcp-list-commits`, `github-mcp-list-branches`, `github-mcp-issue-read`, `github-mcp-get-tag`, `github-mcp-get-release-by-tag`, `github-mcp-get-latest-release`, `github-mcp-get-label`, `github-mcp-get-job-logs`, `github-mcp-get-file-contents`, `github-mcp-get-commit`, `github-mcp-actions-list`, `github-mcp-actions-get`.

**Takeaways for Steps 3-5** (Azure DevOps, Kubernetes, Prometheus — all use the same `mcpgateway.translate` stdio→SSE wrapper pattern): instantiate `modules/workload-identity.bicep` per server rather than sharing the CSI add-on's identity; include the wrapped binary's required subcommand (check its own Dockerfile `CMD`, don't assume flags alone are enough); verify the NetworkPolicy ingress label against the live gateway pod (`app=mcp-stack-mcpgateway`, not `app.kubernetes.io/name`) before relying on it; pin `mcp-contextforge-gateway`'s version and confirm its CLI directly rather than trusting secondary docs; and remember `kubectl apply` alone won't roll out a rebuilt `:latest` image without a `rollout restart`.

---

## Step 3 — Register Azure DevOps MCP Server

**Status (2026-07-03): COMPLETE ✅.** Pod running (`1/1 Running`), registered
in ContextForge — `status: active`, `reachable: true`, `lastError: null`,
`toolCount: 40` (matches the local measurement exactly). Confirmed via:
```
curl -s $GATEWAY_URL/gateways/<id> -H "Authorization: Bearer $JWT_TOKEN" \
  | jq '{toolCount, reachable, status, lastError}'
# → {"toolCount": 40, "reachable": true, "status": "active", "lastError": null}
```
and pod logs showing a clean handshake (`GET /sse 200 OK`, three
`POST /message 202 Accepted`, no `LimitOverrunError` this time).

Microsoft's official server (`microsoft/azure-devops-mcp`, npm package
`@azure-devops/mcp`) is stdio-only — confirmed from its own
`docs/GETTINGSTARTED.md`: every documented client launches it as a local
stdio subprocess. There's no self-hostable HTTP/SSE mode (the Microsoft
Learn "remote MCP server" is a vendor-hosted Azure DevOps Services preview
endpoint, not something self-hostable). So this reuses the same
`mcpgateway.translate` stdio→SSE wrapper pattern as GitHub MCP (Step 2) —
see `services/azure-devops-mcp-wrapper/Dockerfile` for the full build.

**Auth method chosen: PAT (Personal Access Token)**, not `interactive`
(browser login, unusable headless) or `azcli` (would need a live `az login`
session inside the pod). The Azure DevOps server's PAT format is unusual and
worth calling out because getting it wrong fails silently into an auth
error, not a config error: `PERSONAL_ACCESS_TOKEN` must be **base64 of
`<email>:<pat>`**, not the raw token — see
`infra/k8s/azure-devops-mcp-secrets-provider.yaml` for the exact encoding
command and PAT scope guidance (`Project and Team (Read)`, `Work Items
(Read)`, `Build (Read)`).

Unlike `github-mcp-server`, this upstream binary has **no `--read-only`
flag** — tool-surface reduction is `-d`/domain scoping only
(`core work-items pipelines`, baked into `entrypoint.sh` — deliberately
excludes `repositories`; see incident 3 below for why), and actual
read-only enforcement comes entirely from the PAT's own scopes. Don't skip
the PAT scoping step assuming there's an app-layer safety net; there isn't
one here.

```bash
# 1. Build and push the wrapper image
make azure-devops-mcp-build

# 2. Generate the PAT (see infra/k8s/azure-devops-mcp-secrets-provider.yaml
#    for full scope guidance), base64-encode it, and store in Key Vault:
PAT_B64=$(printf '%s' "bot@example.com:<raw-pat>" | base64)
az keyvault secret set --vault-name kv-contextforge-dev \
  --name azure-devops-mcp-pat --value "$PAT_B64"

# 3. Deploy (bicep-deploy must have already provisioned id-azure-devops-mcp-server
#    via modules/workload-identity.bicep — same pattern as githubMcpIdentity)
make azure-devops-mcp-deploy AZURE_DEVOPS_ORG=yourorg

# 4. Register with ContextForge — the PAT never touches this call, it already
#    lives in the pod via Key Vault CSI (same in-cluster-only pattern as GitHub)
export JWT_TOKEN=$(make mcp-get-token KV_NAME=kv-contextforge-dev)
make mcp-register-azure-devops JWT_TOKEN=$JWT_TOKEN
```

Equivalent direct `curl` for step 4, for reference:

```bash
curl -sX POST $GATEWAY_URL/gateways \
  -H "Authorization: Bearer $JWT_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "azure-devops-mcp",
    "url": "http://azure-devops-mcp-server.mcp.svc.cluster.local:8000/sse",
    "transport": "SSE",
    "description": "Azure DevOps — pipelines, releases, work items, boards (self-hosted, in-cluster; repositories domain excluded, source lives in GitHub)",
    "tags": ["azure", "devops", "ci-cd", "iac"],
    "visibility": "public"
  }' | jq .
```

**Files added for this step:**
- `services/azure-devops-mcp-wrapper/Dockerfile`, `entrypoint.sh` — Node 20
  base, `@azure-devops/mcp` installed globally and pinned (not `npx` at
  runtime — avoids re-resolving "latest" on every pod restart)
- `infra/k8s/azure-devops-mcp-server.yaml` — Deployment, ServiceAccount
  (workload-identity annotated), Service, NetworkPolicy — same shape as
  `github-mcp-server.yaml`
- `infra/k8s/azure-devops-mcp-secrets-provider.yaml` — Key Vault CSI
  SecretProviderClass, syncs `azure-devops-mcp-pat` → the pod
- `infra/bicep/main.bicep` — `azureDevOpsMcpIdentity` module instance +
  `azureDevOpsMcpIdentityClientId` output (reuses `modules/workload-identity.bicep`,
  unchanged from Step 2)

**Incident log:**

1. **`useradd: UID 1000 is not unique`** (2026-07-02, first `make azure-devops-mcp-build`) —
   the Dockerfile's `useradd -m -u 1000 mcp` failed at build step 7/7.
   Root cause: `node:20-slim` (this wrapper's base image) ships its own
   built-in `node` user already at UID 1000 — unlike the GitHub wrapper's
   `python:3.12-slim` base, which has no such conflict. Fixed by moving the
   `mcp` user to UID 1001 in both places it's declared: the Dockerfile's
   `useradd -u` and the Deployment's `securityContext.runAsUser` in
   `infra/k8s/azure-devops-mcp-server.yaml` (they must match exactly — a
   mismatch means the pod can't read `/app`, owned by 1001, or silently runs
   as the base image's own `node` user at 1000 instead of the intended one).
   General lesson for Steps 4-5's wrappers: don't assume a base image's UID
   space is empty just because the previous wrapper's base image's was.

2. **`azure-devops-mcp-deploy` silently proceeded after "id-azure-devops-mcp-server not found"**
   (2026-07-02) — `make bicep-deploy` had not been run yet to provision the
   `azureDevOpsMcpIdentity` module, so `az identity show` returned empty and
   the recipe's guard (`test -n "$$IDENTITY_CLIENT_ID" || (echo ... && exit 1)`)
   printed the error — then kept going anyway, `sed`-substituting the
   placeholder with an **empty string** and `kubectl apply`-ing a
   SecretProviderClass and ServiceAccount with a blank `clientID`/`client-id`
   annotation. Root cause: `( ... && exit 1 )` runs in a subshell, so `exit 1`
   only terminates that subshell, not the outer recipe script; since the
   guard is chained to the rest of the recipe with `;` (not `&&`) inside one
   multi-line `\`-continued shell invocation, and there's no `set -e`, Make
   only checks the exit code of the *last* command in that chain (`kubectl
   apply`), not the failed `test` in the middle. This same pattern existed in
   `github-mcp-deploy` too but never triggered there, since that identity
   already existed by the time Step 2's deploy ran.
   **Fixed** in both targets: guards now use `{ echo ...; exit 1; }` (current
   shell, not a subshell) so `exit 1` actually terminates the recipe.
   **Remediation for a deploy that already ran with this bug:** run
   `make bicep-deploy` to provision the missing identity, then re-run
   `make azure-devops-mcp-deploy` — `kubectl apply` is idempotent and will
   patch the already-created resources with the real `clientID` this time,
   then the recipe's `rollout restart` picks it up. Any future Makefile
   target with a `test ... || (... && exit 1)` guard chained via `;` into a
   longer recipe should use `{ ...; exit 1; }` instead, not `( ... )`.

3. **`mcp-register-azure-devops` hung and returned a 504, root cause two layers
   deep** (2026-07-03) — `make azure-devops-mcp-deploy` succeeded, the pod's
   own log showed a clean startup (`"Starting Azure DevOps MCP Server"`,
   `GET /sse 200 OK`, several `POST /message 202 Accepted`), then
   `make mcp-register-azure-devops` returned `HTTP/2 504 Gateway Time-out`
   from nginx with a `jq` parse error on the (non-JSON, HTML) body — the
   registration call was hanging until the ingress's own upstream timeout
   killed it, not failing with an application error. The pod's logs held the
   real cause, several layers below the symptom:
   `asyncio.exceptions.LimitOverrunError: Separator is found, but chunk is
   longer than limit`, immediately followed by `mcpgateway.translate: stdout
   pump crashed - terminating bridge`.
   Root cause: `mcpgateway.translate==0.1.1` reads the wrapped subprocess's
   stdout via `asyncio.StreamReader.readline()`, which has a hard 64 KiB
   (65,536-byte) per-line default limit. ContextForge's gateway registration
   does a live `tools/list` handshake against the SSE URL to discover tools
   (this is how GitHub's 22 tools got federated in Step 2), and
   `mcp-server-azuredevops` emits that response as one JSON-RPC line. With
   all four domains enabled (`core work-items repositories pipelines`) that
   line is 71,345 bytes — over the limit — so the bridge's stdout pump
   crashed mid-handshake, the SSE connection hung, and the registration
   request never got a response until nginx's own timeout fired.
   Confirmed empirically, not guessed: installed `@azure-devops/mcp` locally
   in a sandbox, drove it over stdio with a dummy PAT, and measured each
   domain's `tools/list` response directly: `core` 2,231 B (3 tools),
   `work-items` 25,385 B (23 tools), `repositories` 29,027 B (22 tools),
   `pipelines` 14,840 B (14 tools). Also confirmed there's no fix available
   at the dependency level — `pip index versions mcp-contextforge-gateway`
   shows `0.1.1` is genuinely the latest on PyPI (no newer release raises the
   limit), and `python3 -m mcpgateway.translate --help` exposes no
   buffer-size flag.
   **Fixed** by dropping `repositories` from the domain list in
   `entrypoint.sh` (now `core work-items pipelines`, measured at 42,364
   bytes / 64.6% of the limit, 40 tools) — not picked arbitrarily: this
   deployment's source code lives in GitHub (already federated via
   `github-mcp-server`), so Azure Repos tools were never going to be used
   regardless of the size limit. PAT scope guidance in
   `azure-devops-mcp-secrets-provider.yaml` updated to drop `Code (Read)`
   accordingly (least privilege — don't grant a scope for a domain that
   isn't exposed). If a future deployment genuinely needs `repositories`
   too, the only real fix is patching `mcpgateway.translate`'s subprocess
   stream limit directly — not attempted here, since modifying a pinned
   third-party library's internals without being able to fully verify the
   change against its source was judged riskier than scoping domains.

4. **Dockerfile `ARG` pin silently didn't apply** (found while investigating
   incident 3, 2026-07-03) — `ARG AZURE_DEVOPS_MCP_VERSION=2.4.0` was
   declared *before* `FROM node:20-slim` and never redeclared after it.
   Docker scopes a pre-`FROM` `ARG` to the `FROM` line itself only; it does
   not carry into the build stage unless redeclared with a bare
   `ARG AZURE_DEVOPS_MCP_VERSION` line after `FROM`. So
   `npm install -g @azure-devops/mcp@${AZURE_DEVOPS_MCP_VERSION}` actually
   ran with an empty version suffix, which npm silently resolved to
   `latest` — the exact opposite of the pin-don't-float design this
   Dockerfile's own comments describe. Caught by installing the pinned
   version (2.4.0) locally and finding it doesn't even support
   `--authentication pat` (added between 2.4.0 and the actual latest,
   2.7.0) — yet the deployed pod's own startup log showed `"authentication":
   "pat"` working and `"version":"2.7.0"`, which only makes sense if the
   image built something other than 2.4.0. **Fixed**: re-pinned to 2.7.0
   (confirmed via `npm view @azure-devops/mcp version`) and added
   `ARG AZURE_DEVOPS_MCP_VERSION` again immediately after `FROM`. General
   lesson for Steps 4-5: a value declared correctly in a Dockerfile doesn't
   mean it's actually in scope where it's used — verify pins took effect
   (e.g. `docker run --rm <image> mcp-server-azuredevops --version`), don't
   just trust that the ARG line exists.

5. **`make mcp-list-tools ... | jq ...` failed with "Invalid numeric literal"
   + SIGPIPE (Error 141)** (2026-07-03, found during final verification) —
   `mcp-list-tools` and `mcp-list-gateways`'s `curl | jq` recipe lines weren't
   `@`-silenced, so Make echoed the raw shell command to stdout *before*
   running it. That's harmless on its own, but piping the whole `make`
   invocation into a further `| jq '[...]'` (to filter for just this
   gateway's tools) fed that echoed command text into the second `jq` as if
   it were the start of the JSON document, which failed to parse it and
   exited immediately — killing the pipe and SIGPIPE'ing everything upstream
   of it. Not a registration bug, purely a Makefile hygiene issue that only
   surfaces when composing these targets with further piping. **Fixed**: both
   targets' `curl | jq` lines are now `@`-silenced.

**Final verification (2026-07-03):**
```bash
curl -s $GATEWAY_URL/tools -H "Authorization: Bearer $JWT_TOKEN" \
  | jq '[.[] | select(.name | startswith("azure-devops-mcp")) | .name]'
```

---

## Step 4 — Register Kubernetes MCP Server

**Status (2026-07-03): COMPLETE ✅.** `make kubernetes-mcp-deploy` applied
cleanly (pod scheduled, image pulled, RBAC bound) but the container
CrashLoopBackOff'd 167 times before the root cause was found and fixed — see
the incident log below. After the fix: pod `1/1 Running`, `0` restarts,
registered with `status: active`, `reachable: true`, 13 tools federated.

### Server choice: `containers/kubernetes-mcp-server`, not `Flux159/mcp-server-kubernetes`

Flux159/mcp-server-kubernetes is the more widely-known community option (npm,
~20k weekly downloads) but was ruled out for a concrete reason:
**CVE-2026-46519** (CVSS 8.8, fixed upstream in v3.6.0) — the environment
variables operators use to restrict its tool access
(`ALLOW_ONLY_READONLY_TOOLS`, `ALLOW_ONLY_NON_DESTRUCTIVE_TOOLS`,
`ALLOWED_TOOLS`) were enforced at the `tools/list` discovery layer but not at
`tools/call` execution — any client that knew a tool name could invoke it
directly regardless of the configured read-only mode. It also shells out to
bundled `kubectl`/`helm` binaries as subprocesses rather than talking to the
API directly.

`containers/kubernetes-mcp-server` (Go, maintained by Red Hat under the
`containers` GitHub org, supports both Kubernetes and OpenShift) was chosen
instead: it's a native `client-go` implementation (no shelled-out binaries),
its `--read-only` flag is enforced by only exposing tools annotated
`readOnlyHint=true` (no discovery/execution split to exploit), and it
natively serves Streamable HTTP + SSE — which changes the shape of this step
relative to Steps 2-3, covered next.

### Architecture — three deliberate deviations from the Step 2-3 pattern

1. **No `mcpgateway.translate` stdio→SSE wrapper.** GitHub's and Azure
   DevOps's upstream binaries are stdio-only, which is why Steps 2-3 needed
   the wrapper. `containers/kubernetes-mcp-server` natively serves
   Streamable HTTP (`/mcp`) and SSE (`/sse`) when started with `--port`
   (confirmed from `docs/configuration.md`'s CLI options table, not
   inferred) — so this server is registered directly, no bridge process,
   no `services/kubernetes-mcp-wrapper/` directory.
2. **No Key Vault CSI / workload identity.** This server holds no external
   credential. It authenticates to the AKS API server using its own
   ServiceAccount's automounted token via `client-go`'s in-cluster config,
   auto-detected on startup (confirmed from the upstream "Cross-Cluster
   Access from a Pod" doc). Least privilege is enforced entirely by
   Kubernetes RBAC (the built-in `view` ClusterRole) plus the app-layer
   `--read-only` flag — two independent, redundant layers, see the
   manifest's header comment for the full reasoning.
3. **No image to build.** Deployed straight from the upstream public image,
   `quay.io/containers/kubernetes_mcp_server:v0.0.63` (note: underscored
   repository name, not the hyphenated repo name — easy typo) — pinned to
   the latest tagged release as of 2026-07-02, not `latest`. No
   `make kubernetes-mcp-build` target exists because there's nothing to
   build; `make bicep-deploy` is not a prerequisite either, since no Azure
   identity is involved.

**RBAC scope:** cluster-wide via the built-in `view` ClusterRole (the
upstream-recommended "Option A" in `docs/getting-started-kubernetes.md`),
not the namespace-scoped "Option B" — this tool's job (inventory table: "pod
health, deployments, logs") is cluster-wide AKS observability, not
single-namespace introspection. `view` already excludes Secret *data* by
Kubernetes's own design, which is the authoritative backstop even if the
app-layer `--read-only` flag were ever misconfigured.

**Network egress ended up narrower than Steps 2-3, but not for the reason
originally assumed** (see incident log below) — GitHub MCP and Azure DevOps
MCP both need broad public internet egress (`api.github.com`,
`dev.azure.com`); this server needs exactly one specific public IP for the
Kubernetes API server, plus cluster DNS. No `0.0.0.0/0` rule at all —
narrower than Step 2/3's `except RFC1918` blocks, because we could pin to
the one real address this workload needs instead of an entire public range.

**Toolsets:** `core,config` — deliberately excludes the default `helm`
toolset, since this deployment has no Helm-release-inspection use case.
Same reasoning Step 3 used to drop the `repositories` domain from Azure
DevOps MCP: don't expose a capability surface nothing here will use.

### Deploy and register

```bash
# No build step, no bicep-deploy prerequisite — see architecture notes above
make kubernetes-mcp-deploy

# Confirm the pod is Running and RBAC is scoped correctly
kubectl get pods -n mcp -l app=kubernetes-mcp-server
kubectl auth can-i list pods --as=system:serviceaccount:mcp:kubernetes-mcp-server --all-namespaces    # expect: yes
kubectl auth can-i delete pods --as=system:serviceaccount:mcp:kubernetes-mcp-server --all-namespaces  # expect: no
kubectl auth can-i get secrets --as=system:serviceaccount:mcp:kubernetes-mcp-server --all-namespaces  # expect: no (view excludes Secret data)

# Register with ContextForge — no credential to hide (see architecture
# notes above), this call only tells the gateway the in-cluster SSE URL
export JWT_TOKEN=$(make mcp-get-token)
make mcp-register-kubernetes JWT_TOKEN=$JWT_TOKEN

# Verify
make mcp-list-gateways JWT_TOKEN=$JWT_TOKEN
make mcp-list-tools JWT_TOKEN=$JWT_TOKEN
```

Equivalent direct `curl` for registration, for reference:

```bash
curl -sX POST $GATEWAY_URL/gateways \
  -H "Authorization: Bearer $JWT_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "kubernetes-mcp",
    "url": "http://kubernetes-mcp-server.mcp.svc.cluster.local:8000/sse",
    "transport": "SSE",
    "description": "Kubernetes — pod health, deployments, logs, generic resources (read-only, view ClusterRole, in-cluster AKS API access only)",
    "tags": ["kubernetes", "aks", "observability", "sre"],
    "visibility": "public"
  }' | jq .
```

**Files added for this step:**
- `infra/k8s/kubernetes-mcp-server.yaml` — Deployment (upstream image,
  no wrapper), ServiceAccount (default automount, unlike the ADO/GitHub
  ServiceAccounts which explicitly disable it), ClusterRoleBinding to the
  built-in `view` role, Service, NetworkPolicy (corrected apiserver egress,
  see incident below).
- `Makefile` — `kubernetes-mcp-deploy` and `mcp-register-kubernetes` targets.
  No `-build` target (nothing to build).

### Incident: CrashLoopBackOff, 167 restarts, `dial tcp 10.1.0.1:443: i/o timeout` (2026-07-03)

First `make kubernetes-mcp-deploy` scheduled the pod fine (image pulled, RBAC
bound, no security-context conflicts — `runAsNonRoot` was satisfied by the
image's own built-in UID 65532 with no override needed) but the container
never went Ready. `kubectl logs --previous` showed the same client-go
discovery error on every attempt:

```
E0703 15:08:42.410510 1 memcache.go:265] "Unhandled Error" err="couldn't get
current server API group list: Get \"https://kubernetes.default.svc/api\":
dial tcp 10.1.0.1:443: i/o timeout" logger="UnhandledError"
```

DNS resolution succeeded (`kubernetes.default.svc` → `10.1.0.1`, so the
port-53 egress rule was working) but the TCP dial to `10.1.0.1:443` timed
out — a silent drop, not a refusal, which pointed at NetworkPolicy rather
than RBAC or the app itself.

**Root cause:** the original NetworkPolicy scoped apiserver egress to the AKS
service CIDR (`10.1.0.0/16`) on the assumption that `kubernetes.default.svc`
was reachable as ordinary in-cluster/VNet traffic — the same assumption
implicit in this project's own `CLAUDE.md` SSRF-allowlist note about this
cluster. That assumption was wrong for *this* cluster specifically: it
doesn't use AKS API Server VNet Integration, so the control plane isn't in
the VNet at all. `kubectl get endpoints kubernetes -n default -o wide`
confirmed the Service's real backend is a public Azure IP
(`4.157.231.123:443`), not anything in the service or pod CIDR. kube-proxy
DNATs the ClusterIP (`10.1.0.1`) that client-go dials to that public IP —
a NetworkPolicy scoped only to the service CIDR never had a chance of
matching the actual destination.

Confirmed empirically before touching the manifest, not just theorized: with
the NetworkPolicy deleted entirely, the pod would be expected to reach
Ready (not re-tested after the real fix landed, since the point was to
isolate NetworkPolicy as the cause, which the endpoints lookup already
did more precisely).

**General lesson, worth remembering for anything future that needs
in-cluster API access (this project or otherwise):** on a non-VNet-integrated
managed Kubernetes control plane (this is not AKS-specific — same caveat
applies to EKS/GKE without their equivalent private-endpoint features),
reaching `kubernetes.default.svc` from a pod is real internet egress to a
specific, provider-owned IP, architecturally identical to reaching any other
external API — not intra-cluster traffic. Don't assume the apiserver is
inside the service/pod CIDR just because its ClusterIP is; verify with
`kubectl get endpoints kubernetes -n default -o wide` before writing the
NetworkPolicy, not after a crash loop surfaces the wrong assumption.

**Fixed:** `infra/k8s/kubernetes-mcp-server.yaml`'s egress rule now targets
`4.157.231.123/32:443` (the verified real endpoint) instead of
`10.1.0.0/16:443`. **Caveat carried forward in the manifest's own comments:**
Azure could in principle rotate this public frontend IP (cluster upgrade,
backend migration, etc.), which would silently reproduce the identical
failure signature. If this pod ever crash-loops again with the same
`dial tcp ...:443: i/o timeout` message, re-run the `get endpoints` command
first and diff against the manifest's `/32` before assuming anything else
changed.

**Re-deploy after the fix — confirmed working 2026-07-03:** pod
`1/1 Running`, `0` restarts (stable for 29+ minutes, vs. 167 restarts
before), registered with `status: active`, `reachable: true`, 13 tools
federated.

```bash
kubectl apply -f infra/k8s/kubernetes-mcp-server.yaml -n mcp   # picks up the corrected NetworkPolicy
kubectl rollout restart deployment/kubernetes-mcp-server -n mcp
kubectl get pods -n mcp -l app=kubernetes-mcp-server -w        # expect 1/1 Running
kubectl auth can-i list pods --as=system:serviceaccount:mcp:kubernetes-mcp-server --all-namespaces
export JWT_TOKEN=$(make mcp-get-token)
make mcp-register-kubernetes JWT_TOKEN=$JWT_TOKEN
make mcp-list-tools JWT_TOKEN=$JWT_TOKEN
```

**RBAC verification (2026-07-03):** all three checks matched expectations —
`list pods` → `yes`, `delete pods` → `no`, `get secrets` → `no`. The `delete`
and `get secrets` checks came back as `"no - Azure does not have opinion for
this user"` rather than a bare `no` — this cluster has Azure RBAC for
Kubernetes enabled (`enableAzureRBAC: true` in `aks.bicep`), so `auth can-i`
checks for an Azure role assignment first; since this ServiceAccount was
deliberately never given one (only the native `view` ClusterRoleBinding),
Azure RBAC "has no opinion" and falls through to standard Kubernetes RBAC,
which then correctly evaluates and denies both. Expected behavior on this
cluster, not a gap.

**Confirmed federated tool names** (13, `kubernetes-mcp-<tool-name>`,
underscores converted to hyphens — matches the `--toolsets=core,config`
scope chosen above):
`kubernetes-mcp-resources-list`, `kubernetes-mcp-resources-get`,
`kubernetes-mcp-pods-top`, `kubernetes-mcp-pods-log`,
`kubernetes-mcp-pods-list-in-namespace`, `kubernetes-mcp-pods-list`,
`kubernetes-mcp-pods-get`, `kubernetes-mcp-nodes-top`,
`kubernetes-mcp-nodes-stats-summary`, `kubernetes-mcp-nodes-log`,
`kubernetes-mcp-namespaces-list`, `kubernetes-mcp-events-list`,
`kubernetes-mcp-configuration-view`.

Note: the `POST /gateways` registration response itself showed
`"toolCount": 0` at the instant of creation — tool discovery runs
asynchronously right after registration, and `make mcp-list-tools` (run
immediately after in the same sequence) already showed all 13, so this is
expected timing, not a discovery failure — same as it would be for any
other gateway registered here.

---

## Step 5 — Register Prometheus MCP Server

```bash
# Assumes Prometheus is running in the cluster (or use Azure Monitor endpoint)
kubectl apply -f infra/k8s/prometheus-mcp-server.yaml -n mcp

curl -sX POST $GATEWAY_URL/gateways \
  -H "Authorization: Bearer $JWT_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "prometheus-mcp",
    "url": "http://prometheus-mcp-server.mcp.svc.cluster.local:8000/sse",
    "transport": "SSE",
    "description": "Prometheus — natural language to PromQL, alert summary",
    "tags": ["prometheus", "metrics", "observability", "sre"],
    "visibility": "public"
  }' | jq .
```

---

## Step 6 — Verify All Gateways Registered

```bash
# List all registered gateways (response is a bare JSON array — no wrapper object)
make mcp-list-gateways JWT_TOKEN=$JWT_TOKEN

# Or directly:
curl -s $GATEWAY_URL/gateways \
  -H "Authorization: Bearer $JWT_TOKEN" | jq '[.[] | {name, url, enabled}]'

# List all federated tools (also a bare array)
make mcp-list-tools JWT_TOKEN=$JWT_TOKEN

# Or directly:
curl -s $GATEWAY_URL/tools \
  -H "Authorization: Bearer $JWT_TOKEN" | jq '{total: length, names: [.[].name]}'
```

---

## Step 7 — Configure RBAC

ContextForge ships with 4 built-in roles: `admin`, `manager`, `user`, `viewer`.

### 7a — Create Teams

```bash
# Create an SRE team (endpoint: POST /teams)
curl -sX POST $GATEWAY_URL/teams \
  -H "Authorization: Bearer $JWT_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name": "sre-team", "description": "SRE engineers — full gateway access"}' | jq .

# Create a dev team with limited access
curl -sX POST $GATEWAY_URL/teams \
  -H "Authorization: Bearer $JWT_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name": "dev-team", "description": "Developers — GitHub and ADO access only"}' | jq .
```

### 7b — Create Virtual Servers with RBAC

Virtual servers (called "Servers" in ContextForge) expose a subset of gateways to specific teams. Endpoint: `POST /servers`.

```bash
# Get gateway IDs first
curl -s $GATEWAY_URL/gateways -H "Authorization: Bearer $JWT_TOKEN" | jq '[.[] | {name, id}]'

# SRE virtual server — all gateways
curl -sX POST $GATEWAY_URL/servers \
  -H "Authorization: Bearer $JWT_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "sre-full",
    "description": "Full SRE toolset — all registered gateways",
    "visibility": "team"
  }' | jq .

# Dev virtual server — GitHub + ADO only
curl -sX POST $GATEWAY_URL/servers \
  -H "Authorization: Bearer $JWT_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "dev-tools",
    "description": "Developer tools — GitHub and Azure DevOps only",
    "visibility": "team"
  }' | jq .
```

See the ContextForge RBAC how-to: `https://ibm.github.io/mcp-context-forge/howto/rbac-tool-authorization/`

---

## Step 8 — Configure Entra ID SSO (OIDC)

### 8a — Create Entra ID App Registration

```bash
# 1. Register app in Entra ID
az ad app create \
  --display-name "contextforge-sso" \
  --sign-in-audience AzureADMyOrg \
  --web-redirect-uris "https://contextforge.gourmandtech.com/auth/callback"

# 2. Note the appId (client ID) and tenantId
APP_ID=$(az ad app list --display-name contextforge-sso --query '[0].appId' -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)
echo "Client ID: $APP_ID"
echo "Tenant ID: $TENANT_ID"

# 3. Create a client secret
CLIENT_SECRET=$(az ad app credential reset --id $APP_ID --query password -o tsv)
# → Store this in Key Vault immediately:
az keyvault secret set --vault-name kv-contextforge-dev \
  --name entra-client-secret --value "$CLIENT_SECRET"

# 4. Add API permissions: openid, profile, email (User.Read)
az ad app permission add --id $APP_ID \
  --api 00000003-0000-0000-c000-000000000000 \
  --api-permissions e1fe6dd8-ba31-4d61-89e7-88639da4683d=Scope   # User.Read
az ad app permission grant --id $APP_ID \
  --api 00000003-0000-0000-c000-000000000000
```

### 8b — Add SSO Config to Helm Values (AKS)

Add to `infra/helm/values.azure.yaml` under `mcpContextForge.config:` (not `env:` — this maps to the ConfigMap via `envFrom`):

```yaml
mcpContextForge:
  config:
    # ... existing config vars ...
    SSO_ENABLED: "true"
    SSO_PROVIDER: "microsoft"
    SSO_CLIENT_ID: "<APP_ID>"
    SSO_TENANT_ID: "<TENANT_ID>"
    SSO_REDIRECT_URI: "https://contextforge.gourmandtech.com/auth/callback"
    # SSO_CLIENT_SECRET comes from Key Vault at deploy time (see below)
```

Add the client secret at Helm deploy time (or via CSI sync — add `entra-client-secret` to `infra/k8s/secret-provider-class.yaml`):

```bash
make helm-aks-secrets KV_NAME=kv-contextforge-dev \
  # Add to Makefile helm-aks-secrets target:
  # --set "mcpContextForge.secret.SSO_CLIENT_SECRET=$(az keyvault secret show \
  #   --vault-name kv-contextforge-dev --name entra-client-secret --query value -o tsv)"
```

### 8c — Deploy and Verify SSO

```bash
make helm-aks-secrets KV_NAME=kv-contextforge-dev

# Visit in browser — should show Microsoft login button:
# https://contextforge.gourmandtech.com/admin
```

Full tutorial: `https://ibm.github.io/mcp-context-forge/manage/sso-microsoft-entra-id-tutorial/`

---

## Step 9 — End-to-End Smoke Test

```bash
# 1. Health check
curl -s https://contextforge.gourmandtech.com/health | jq .

# 2. List all registered gateways
make mcp-list-gateways JWT_TOKEN=$JWT_TOKEN

# 3. List all federated tools (bare array — no wrapper object)
make mcp-list-tools JWT_TOKEN=$JWT_TOKEN
# Expected: {"total": N, "names": ["sre-toolbox-sre-healthcheck", ...]}
# Tool naming: <gateway-name>-<tool-name> (hyphens, underscores converted)

# 4. Invoke a tool via MCP SSE protocol
# There is no REST POST /tools/call endpoint — tool invocation goes through
# the MCP SSE stream at /servers/{server_id}/sse.
# Use a Python MCP client:
pip install mcp --break-system-packages
python3 - <<'EOF'
import asyncio, os
from mcp import ClientSession
from mcp.client.sse import sse_client

JWT = os.environ["JWT_TOKEN"]

async def test():
    async with sse_client(
        "https://contextforge.gourmandtech.com/servers/default/sse",
        headers={"Authorization": f"Bearer {JWT}"}
    ) as (r, w):
        async with ClientSession(r, w) as session:
            await session.initialize()
            tools = await session.list_tools()
            print(f"Tools available: {[t.name for t in tools.tools]}")
            result = await session.call_tool(
                "sre-toolbox-sre-healthcheck",
                {"url": "https://contextforge.gourmandtech.com/health"}
            )
            print(result)

asyncio.run(test())
EOF

# 5. Verify metrics reflect the tool calls
curl -s https://contextforge.gourmandtech.com/metrics | grep mcp_tool_calls_total
```

---

## Key Lessons / Gotchas

- **HPA conflicts with `helm upgrade` on `spec.replicas`** — The ContextForge chart has a design flaw: `deployment-mcpgateway.yaml` unconditionally renders `replicas: {{ .Values.mcpContextForge.replicaCount }}` with no `{{- if not .Values.hpa.enabled }}` guard. When HPA is active, kube-controller-manager takes SSA ownership of `spec.replicas` and subsequent `helm upgrade` calls fail with `conflict with "kube-controller-manager" with subresource "scale"`. Neither `--force` (deprecated → `--force-replace`) nor `--force-replace` (incompatible with SSA mode) resolves it. **Fix**: `hpa.enabled: false` in `values.azure.yaml` — AKS node autoscaler handles capacity. The Makefile also surgically removes the stale managedField entry before `helm upgrade`.

- **Deleting HPA does NOT release its SSA field ownership** — The `managedFields` entry for kube-controller-manager persists on the Deployment even after the HPA object is deleted. Must be removed explicitly via JSON patch (`kubectl patch --type=json -p '[{"op":"remove","path":"/metadata/managedFields/N"}]'`). Use `kubectl get --show-managed-fields` — without that flag, `kubectl get -o json` strips `managedFields` since v1.21, making the field invisible. Use null-safe jq: `.metadata.managedFields // []`.

- **ConfigMap changes require a pod restart** — The chart uses `envFrom: configMapRef`, which snapshots env vars at container start. `helm upgrade` updates the ConfigMap but does NOT roll pods — the chart has no config-checksum annotation on the pod template. `make helm-aks-secrets` now runs `kubectl rollout restart` after every upgrade to close this gap. If you ever change a ConfigMap value outside of `make helm-aks-secrets`, restart manually: `kubectl rollout restart deployment/mcp-stack-mcpgateway -n mcp`.

- **SSRF protection blocks cluster-internal URLs** — Registering an in-cluster URL like `http://sre-mcp-server.mcp.svc.cluster.local:8000/sse` fails with `"Gateway URL contains private network address which is blocked by SSRF protection"`. Fix (already applied in `values.azure.yaml`): scope to cluster CIDRs only — `SSRF_ALLOW_PRIVATE_NETWORKS: "false"` + `SSRF_ALLOWED_NETWORKS: '["10.1.0.0/16", "10.0.0.0/22"]'` (service CIDR + pod subnet). Blanket `SSRF_ALLOW_PRIVATE_NETWORKS: "true"` works but allows all RFC 1918. Cloud metadata (`169.254.169.254`) stays blocked via `SSRF_BLOCKED_NETWORKS` regardless. This is a ConfigMap value — pod restart required for it to take effect (see above).

- **No `/v1/` prefix on any management REST endpoint** — All ContextForge REST management endpoints are at the root, not under `/v1/`. Correct paths: `POST /gateways`, `GET /tools`, `POST /teams`, `POST /servers`. Confirmed from source: each `APIRouter` defines its own prefix and is included directly on the app. `/v1/gateways` returns `{"detail": "Not Found"}`.

- **Tool naming uses hyphens, not double-underscores** — Confirmed from live output: ContextForge names federated tools as `<gateway-name>-<tool-name>` with underscores in tool names converted to hyphens. Example: `sre-toolbox-sre-healthcheck`, NOT `sre-toolbox__sre_healthcheck` as the docs suggest. Adjust any client-side tool-call strings accordingly.

- **Tool invocation is via SSE protocol, not a REST endpoint** — There is no `POST /tools/call`. Tools are invoked via the MCP SSE stream at `/servers/{server_id}/sse`. Use a Python `mcp` client or `scripts/test-mcp.sh`. The `toolCount: 0` in a fresh registration response is normal — tools are discovered asynchronously after the SSE connection is established.

- **Responses are bare JSON arrays** — `GET /gateways` and `GET /tools` return a JSON array directly, not `{"gateways": [...]}`. Use `jq 'length'` and `jq '.[].name'`, not `.tools | length`.

- **`auth_token` for bearer auth, not `auth_value`** — `GatewayCreate` schema field is `auth_token`. For unauthenticated in-cluster gateways, omit `auth_type` entirely.

- **Gateways default to `visibility=public`** — Confirmed from `GatewayCreate` schema: `visibility` defaults to `"public"`, not `"private"`. Set `"visibility": "public"` explicitly to be clear; set `"visibility": "team"` to restrict to a specific team's virtual server.

- **SSO config goes under `mcpContextForge.config:`, not `env:`** — The chart injects all `config:` values into a ConfigMap which the gateway reads via `envFrom`. There is no `mcpContextForge.env:` key in the chart schema. Non-secret config (including SSO settings) goes under `config:`, secrets go under `secret:`.

- **stdio → SSE wrapping** — Many MCP servers (Azure DevOps MCP) only support stdio transport. Use `mcpgateway.translate` (ContextForge's built-in bridge) or a thin container wrapper. See: `https://ibm.github.io/mcp-context-forge/using/mcpgateway-translate/`

- **Entra ID PKCE** — ContextForge auto-enables PKCE for auth code flows. The Entra redirect URI must exactly match what's configured (trailing slash matters).

---

## Known Issues / Deferred

### CSRF validation failed on "Refresh Tools" in Admin UI
**Symptom:** Clicking "Refresh Tools" on a registered gateway in the ContextForge admin UI returns `"CSRF validation failed"`. Persists after logout + login and hard refresh (`Cmd+Shift+R`).

**When observed:** 2026-07-02, after pod was restarted twice during Phase 4 debugging (SSRF config change + managedFields patch).

**Impact:** Low — UI convenience only. Tool state is accurate via CLI (`make mcp-list-tools`). Gateway connectivity and tool federation are unaffected.

**Suspected causes to investigate:**
- ContextForge may require `CSRF_SECRET_KEY` to be set explicitly; if unset or regenerated between restarts, sessions become permanently invalid.
- The nginx ingress may be stripping or modifying `Origin` / `Referer` headers that ContextForge uses for CSRF origin validation. Check ingress annotation `nginx.ingress.kubernetes.io/configuration-snippet` and whether `X-Forwarded-*` headers reach the app correctly.
- `COOKIE_SAMESITE: "strict"` in `values.azure.yaml` — check whether the admin UI's POST requests are considered same-site by the browser in the context of the TLS termination chain (Cloudflare → nginx → pod).

**To investigate:**
1. Check ContextForge source for `CSRF_SECRET_KEY` usage: `grep -r CSRF .contextforge/`
2. Confirm the value is set in the running pod: `kubectl exec -n mcp deploy/mcp-stack-mcpgateway -- env | grep CSRF`
3. Review ContextForge CSRF middleware config in upstream docs / GitHub issues
4. Try `COOKIE_SAMESITE: "lax"` as a test (revert to `strict` once resolved)

---

## Reference Links

- [ContextForge Federated MCP Docs](https://ibm.github.io/mcp-context-forge/architecture/)
- [RBAC How-To](https://ibm.github.io/mcp-context-forge/howto/rbac-tool-authorization/)
- [RBAC Configuration Reference](https://ibm.github.io/mcp-context-forge/manage/rbac/)
- [OAuth 2.0 Integration](https://ibm.github.io/mcp-context-forge/manage/oauth/)
- [Microsoft Entra ID SSO Tutorial](https://ibm.github.io/mcp-context-forge/manage/sso-microsoft-entra-id-tutorial/)
- [GitHub MCP Server](https://github.com/github/github-mcp-server)
- [Azure DevOps MCP](https://github.com/microsoft/azure-devops-mcp)
- [ContextForge Transport Bridge](https://ibm.github.io/mcp-context-forge/using/mcpgateway-translate/)
- [Python MCP Server Best Practices](https://ibm.github.io/mcp-context-forge/best-practices/developing-your-mcp-server-python/)
