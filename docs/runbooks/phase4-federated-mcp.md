# Phase 4 — Federated MCP: Multi-Server Registration, RBAC, and OAuth

## Overview

Phase 4 turns ContextForge from a single gateway into a true **federated MCP hub**: multiple upstream MCP servers registered, access controlled by RBAC teams, and Entra ID SSO layered on top. This is the phase that demonstrates production AI-assisted SRE capabilities to a hiring audience.

**Production gateway:** `https://contextforge.gourmandtech.com`

### Numbering scheme — two different lists, keep them straight

`CLAUDE.md`'s "Phase 4 sub-tasks" list (1-6) and this runbook's own `## Step
N` headings (0-9) count different things and don't line up 1:1 — a bare
"Phase 4 step N" is genuinely ambiguous between the two. Reference table:

| CLAUDE.md sub-task | This runbook |
|---|---|
| 1-3. Build/deploy/register SRE Toolbox | Step 1 |
| 4. Register remaining MCP servers (GitHub, ADO, K8s, Prometheus) | Steps 2, 3, 4, 5 (one server each) |
| — (implicit, not its own sub-task) | Step 6 — Verify All Gateways Registered |
| 5. Create RBAC teams + virtual servers | Step 7 |
| 6. Configure Entra ID SSO | Step 8 |
| — (implicit, not its own sub-task) | Step 9 — End-to-End Smoke Test |

When someone says "Phase 4 step N," check which list they mean before
acting on it — CLAUDE.md's numbering is the one tracked as the checklist of
record; this runbook's `## Step N` headings are a finer-grained breakdown of
CLAUDE.md sub-task 4 alone, plus the two cross-cutting sub-tasks 5-6.

---

## MCP Server Inventory

| Server | Source | Transport | Status |
|---|---|---|---|
| SRE Toolbox MCP | `services/sre-mcp-server/` (custom Python FastMCP) | SSE | ✅ Running in AKS + registered in ContextForge |
| GitHub MCP | `github/github-mcp-server` (official, self-hosted) | stdio via `mcpgateway.translate` wrapper | ✅ Running in AKS + registered in ContextForge |
| Azure DevOps MCP | `microsoft/azure-devops-mcp` (official) | stdio via `mcpgateway.translate` wrapper | ✅ Running in AKS + registered in ContextForge (40 tools) |
| Kubernetes MCP | `containers/kubernetes-mcp-server` (Red Hat/containers, native SSE — no wrapper) | SSE (native) | ✅ Running in AKS + registered in ContextForge (13 tools) |
| Prometheus MCP | `pab1it0/prometheus-mcp-server` (community, native SSE — no wrapper) | SSE (native) | ✅ Running in AKS + registered in ContextForge (6 tools) |

---

## Architecture

```
Claude / Copilot / agent
        │
        ▼
ContextForge Gateway (https://contextforge.gourmandtech.com)
  ├── RBAC: teams (sre-team, dev-team) + virtual servers (sre-full, dev-tools) ✅
  ├── Entra ID SSO (OIDC) ✅
  ├── API key auth for service accounts
        │
        ├── GitHub MCP ────────── (SSE → api.github.com)
        ├── Azure DevOps MCP ──── (stdio → dev.azure.com)
        ├── Kubernetes MCP ─────── (SSE native → AKS cluster)
        ├── Prometheus MCP ─────── (SSE native → in-cluster /metrics)
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

### Also export `GATEWAY_URL` — required for the raw `curl` reference commands, not just `make`

Every `make mcp-*` target works with no further setup because `GATEWAY_URL` is a
**Makefile** variable (`GATEWAY_URL ?= https://contextforge.gourmandtech.com`,
substituted by `make` itself before the recipe's shell command ever runs).
Every step in this runbook also shows an "equivalent direct `curl`" block for
reference — those use `$GATEWAY_URL` as a **shell** variable, which is a
different thing and is never set just by running `make`. Confirmed real
2026-07-03: `curl -s $GATEWAY_URL/tools -H "Authorization: Bearer $JWT_TOKEN"
| jq ...` silently produced no output at all in a shell where `GATEWAY_URL`
had never been exported — `-s` suppresses curl's own error message, `curl`
without a scheme (`$GATEWAY_URL` expanding to an empty string) fails
silently, and `jq` on empty stdin produces nothing either, so the whole
pipeline looks like it just... didn't happen, no error surfaced anywhere.
Export it once per shell session alongside `JWT_TOKEN` and every raw `curl`
snippet in this runbook works verbatim:

```bash
export GATEWAY_URL="https://contextforge.gourmandtech.com"
```

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

**Transport: upstream binary is stdio-only.** `github/github-mcp-server`'s own Dockerfile (`ENTRYPOINT ["/server/github-mcp-server"]`, `CMD ["stdio"]`) confirms there's no self-hostable HTTP/SSE mode — the only HTTP transport is GitHub's vendor-hosted endpoint. So this server needs the same `mcpgateway.translate` stdio→SSE bridge that Step 3 (Azure DevOps) also needs. Steps 4-5 (Kubernetes, Prometheus) turned out not to need it — both of those upstream binaries natively serve SSE — so the wrapper pattern ended up reused twice, not four times as originally planned here.

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

**Takeaways for Steps 3-5** (Azure DevOps, Kubernetes, Prometheus — only Azure DevOps ended up actually using the `mcpgateway.translate` stdio→SSE wrapper pattern; Kubernetes and Prometheus both natively serve SSE): where the wrapper pattern does apply (Azure DevOps, and GitHub above), instantiate `modules/workload-identity.bicep` per server rather than sharing the CSI add-on's identity; include the wrapped binary's required subcommand (check its own Dockerfile `CMD`, don't assume flags alone are enough); pin `mcp-contextforge-gateway`'s version and confirm its CLI directly rather than trusting secondary docs; and remember `kubectl apply` alone won't roll out a rebuilt `:latest` image without a `rollout restart`. The NetworkPolicy-ingress-label lesson (verify against the live gateway pod — `app=mcp-stack-mcpgateway`, not `app.kubernetes.io/name`) applies to every server regardless of wrapper.

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

**Status (2026-07-03): COMPLETE ✅.** Pod `1/1 Running`, registered in
ContextForge — `status: active`, `reachable: true`, 6 tools federated
(matches the local prediction exactly). Two real bugs hit and fixed along
the way — see the incident logs below. The prerequisite check below turned
out to be a real gap: `kubectl
get svc -n monitoring | grep prometheus-operated` came back empty, confirming
kube-prometheus-stack was never installed. Installed via `helm install
kube-prom prometheus-community/kube-prometheus-stack -n monitoring
--create-namespace` — confirmed `svc/prometheus-operated` (ClusterIP: None,
`9090/TCP`) now exists in the `monitoring` namespace, exactly matching the
Service-naming assumption this runbook made below (the CR is named
`prometheus`, not `kube-prom`-prefixed, for this specific object).

### Incident: `make prometheus-mcp-deploy` failed on the ServiceAccount object

`kubectl apply` created the Deployment, Service, and NetworkPolicy
successfully but rejected the ServiceAccount:

```
Error from server (BadRequest): error when creating
"infra/k8s/prometheus-mcp-server.yaml": ServiceAccount in version "v1"
cannot be handled as a ServiceAccount: strict decoding error: unknown field
"metadata.automountServiceAccountToken"
```

**Root cause:** `automountServiceAccountToken` is a top-level field on the
`ServiceAccount` object, a sibling of `apiVersion`/`kind`/`metadata` — not a
field nested inside `metadata`. The manifest as originally drafted put it
under `metadata:`, which is invalid under the API server's strict decoding
(confirmed against `azure-devops-mcp-server.yaml`'s ServiceAccount, which
has always had this field placed correctly at the top level — the working
reference was sitting in the same repo the whole time). This slipped past
this runbook's own YAML validation because a `yaml.safe_load` pass only
checks that the file parses as YAML, not that each document matches its
Kubernetes API schema — syntactically valid, semantically wrong.

**Fixed:** moved `automountServiceAccountToken: false` out from under
`metadata:` to the ServiceAccount document's top level in
`infra/k8s/prometheus-mcp-server.yaml`. Since the Deployment/Service/
NetworkPolicy already applied cleanly before this error, `kubectl apply` is
safe to re-run — it will patch in the corrected ServiceAccount without
touching the three resources that already succeeded.

### Incident: `ImagePullBackOff` on re-deploy, once the ServiceAccount fix landed

`make prometheus-mcp-deploy` re-applied cleanly (`serviceaccount/
prometheus-mcp-server created`, the other three resources `unchanged`), but
`kubectl rollout status` timed out at 3m and the pod sat in
`ImagePullBackOff`:

```
NAME                                     READY   STATUS             RESTARTS   AGE
prometheus-mcp-server-677f64654d-l5xjz   0/1     ImagePullBackOff   0          50s
```

**Root cause:** the manifest pinned `ghcr.io/pab1it0/prometheus-mcp-server:
v1.6.1` — a `v`-prefixed tag that doesn't exist on GHCR. This project's other
pinned third-party images (`quay.io/containers/kubernetes_mcp_server:
v0.0.63`) do use a `v` prefix, and that convention was pattern-matched onto
this image without independently checking pab1it0/prometheus-mcp-server's
own tag list. Checked against the live GHCR package page
(`github.com/pab1it0/prometheus-mcp-server/pkgs/container/
prometheus-mcp-server`) after the failure: published tags are `1.6.1`,
`1.6.0`, `1.5.3`, `1.5.2`, `1.5.1`, `latest` — none `v`-prefixed. Exactly the
class of gap this section's own header comment already warned about
(verify a pin against the published artifact, not by analogy with another
image's convention) — the warning was written before the tag was actually
checked against the registry, and the untested guess turned out wrong.

**Fixed:** `infra/k8s/prometheus-mcp-server.yaml`'s image now reads
`ghcr.io/pab1it0/prometheus-mcp-server:1.6.1` (no `v`).

**Re-deploy after both fixes:**

```bash
make prometheus-mcp-deploy
kubectl get pods -n mcp -l app=prometheus-mcp-server -w
kubectl logs -n mcp deploy/prometheus-mcp-server | grep -i prometheus
```

### Prerequisite: Prometheus running in-cluster — CONFIRMED 2026-07-03 ✅

This server is a thin PromQL client — it has nothing to talk to unless a
real Prometheus is already deployed. The prerequisite check below caught a
real gap: `kubectl get svc -n monitoring | grep prometheus-operated` came
back empty before this, confirming kube-prometheus-stack had never been
installed on this cluster — only the ContextForge chart's *in-app* metrics
were on, and the ServiceMonitor CRD object had been left off because those
CRDs didn't exist yet.

**Resolved:** installed via

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm install kube-prom prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace
```

Confirmed afterward: `svc/prometheus-operated` (ClusterIP: None, `9090/TCP`)
now exists in the `monitoring` namespace, exactly matching this runbook's
naming assumption — the Prometheus Operator names the query-side Service
`<prometheus-CR-name>-operated`, and for the default kube-prometheus-stack
chart values that CR is named `prometheus` (not `kube-prom`-prefixed, even
though that's the Helm *release* name) — giving
`prometheus-operated.monitoring.svc.cluster.local:9090`, the same URL
`services/sre-mcp-server/server.py`'s `PROMETHEUS_URL` default already
assumed. Worth knowing this held on the first real try rather than assuming
it always will: a different chart version or custom `prometheus.name`
value could still produce a different Service name on some future
redeploy — re-check with `kubectl get svc -n monitoring` if this ever needs
to be rebuilt from scratch.

ContextForge's own ServiceMonitor is also already re-enabled
(`mcpContextForge.metrics.serviceMonitor.enabled: true` in
`infra/helm/values.azure.yaml`, confirmed live via `helm status mcp-stack -n
mcp` showing a `v1/ServiceMonitor` resource for `mcp-stack-mcpgateway`) — no
further action needed there.

### Server choice: `pab1it0/prometheus-mcp-server`

Chosen over `giantswarm/mcp-prometheus`, `freepik-company/prometheus-mcp`,
and the AWS-managed-Prometheus-specific `awslabs` server: it's the most
widely adopted general-purpose option, ships an official multi-arch image
on GHCR plus its own Helm chart (a second source of truth for the
Deployment shape, cross-checked against `charts/prometheus-mcp-server/
values.yaml`), supports `stdio`/`http`/`sse` transport natively via
`PROMETHEUS_MCP_SERVER_TRANSPORT`, and exposes a real HTTP `/health`
endpoint (confirmed from the project's own Dockerfile `HEALTHCHECK`
instruction) rather than requiring a `tcpSocket`-only probe.

Like Kubernetes MCP (Step 4), this deploys straight from the upstream
public image — no `services/prometheus-mcp-wrapper/` directory, no ACR
build step, no `mcpgateway.translate` bridge (the binary natively serves SSE
via `PROMETHEUS_MCP_SERVER_TRANSPORT=sse`). Pinned to `v1.6.1`
(`pyproject.toml`'s version on the `main` branch as of 2026-07-03) rather
than `latest` — **confirm this tag actually exists on
`ghcr.io/pab1it0/prometheus-mcp-server` before applying**
(`docker manifest inspect ghcr.io/pab1it0/prometheus-mcp-server:v1.6.1`);
this was checked against the source repo's version string only, not against
a live GHCR pull, so treat it the same way Step 3's incident 4 (a Dockerfile
`ARG` pin that silently didn't apply) treats any unverified pin — confirm it
against the actual artifact, not just where it's declared.

Port 8000 (not the image's own default 8080) to match every other MCP
workload in this project — overridden via `PROMETHEUS_MCP_BIND_PORT`, a
supported env var per the upstream README's Configuration Options table.

**No Key Vault CSI / workload identity, no `bicep-deploy` prerequisite.**
kube-prometheus-stack's Prometheus has no auth in front of it by default —
trust boundary is NetworkPolicy only, same class of decision Kubernetes MCP
(Step 4) made for its own, different reason. If Prometheus is ever put
behind basic auth or a bearer token, the image natively supports
`PROMETHEUS_USERNAME`/`PROMETHEUS_PASSWORD` or `PROMETHEUS_TOKEN` — wire
those through the same CSI pattern `github-mcp-secrets-provider.yaml` /
`azure-devops-mcp-secrets-provider.yaml` already use, don't invent a third
pattern.

**NetworkPolicy egress label confirmed correct on first try.** The manifest
assumed kube-prometheus-stack's standard `app.kubernetes.io/name: prometheus`
pod label in the `monitoring` namespace — unlike Step 2's NetworkPolicy
incident (guessed `app.kubernetes.io/name: mcpgateway`, actually
`app: mcp-stack-mcpgateway`), this guess held: the pod's own startup log
showed `"Prometheus configuration validated"` against the real
`prometheus-operated` endpoint, and registration reached the SSE handshake
without a `ConnectTimeout`, so egress worked end to end. Not independently
re-verified with `kubectl get pods -n monitoring --show-labels` — the
successful connection is treated as sufficient confirmation here, since a
wrong label would have blocked the traffic outright.

**Confirmed working end-to-end 2026-07-03** after both incidents above
(ServiceAccount field placement, image tag): pod `1/1 Running`, registered
with `status: active`, `reachable: true`, **6 tools federated** — exactly
matching the tool list predicted below.

### Deploy and register

```bash
# Confirms svc/prometheus-operated exists in the monitoring namespace before
# doing anything else — fails fast with the install command if it doesn't.
make prometheus-mcp-deploy

# Confirm the pod is Running and can actually reach Prometheus
kubectl get pods -n mcp -l app=prometheus-mcp-server
kubectl logs -n mcp deploy/prometheus-mcp-server | grep -i prometheus

# Register with ContextForge — no credential to hide (see above), this call
# only tells the gateway the in-cluster SSE URL
export JWT_TOKEN=$(make mcp-get-token)
make mcp-register-prometheus JWT_TOKEN=$JWT_TOKEN

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
    "name": "prometheus-mcp",
    "url": "http://prometheus-mcp-server.mcp.svc.cluster.local:8000/sse",
    "transport": "SSE",
    "description": "Prometheus — PromQL queries, metric/target discovery (self-hosted, in-cluster, no auth — network-policy-scoped trust boundary)",
    "tags": ["prometheus", "metrics", "observability", "sre"],
    "visibility": "public"
  }' | jq .
```

**Confirmed federated tool names (6, 2026-07-03)** — matched the prediction
exactly: `prometheus-mcp-health-check`, `prometheus-mcp-execute-query`,
`prometheus-mcp-execute-range-query`, `prometheus-mcp-list-metrics`,
`prometheus-mcp-get-metric-metadata`, `prometheus-mcp-get-targets`.

**Files added for this step:**
- `infra/k8s/prometheus-mcp-server.yaml` — Deployment, ServiceAccount (no
  k8s API access, `automountServiceAccountToken: false`), Service,
  NetworkPolicy — no wrapper, no CSI, no workload identity (see rationale
  above)
- `Makefile` — `prometheus-mcp-deploy` (guards on `svc/prometheus-operated`
  existing first) and `mcp-register-prometheus` targets

---

## Step 6 — Verify All Gateways Registered ✅ COMPLETE

**Confirmed 2026-07-03, after the two gotchas below were fixed:** all 5
gateways registered and `enabled: true` (`sre-toolbox`, `github-mcp`,
`azure-devops-mcp`, `kubernetes-mcp`, `prometheus-mcp`), and `"total": 86`
tools federated — exactly matching 5 (SRE) + 22 (GitHub) + 40 (Azure DevOps)
+ 13 (Kubernetes) + 6 (Prometheus). Phase 4 sub-task 4 (register all MCP
servers) is fully done and verified end-to-end; next up is sub-tasks 5-6
(RBAC teams/virtual servers, then Entra ID SSO — Steps 7-8).

**Two real gotchas found running this step 2026-07-03, both fixed — see
below before assuming a bare "no output" or "only 50 tools" result means
something is actually broken.**

```bash
# List all registered gateways (response is a bare JSON array — no wrapper object)
make mcp-list-gateways JWT_TOKEN=$JWT_TOKEN

# Or directly (requires GATEWAY_URL exported per Step 0 — see gotcha #1 below):
curl -s "$GATEWAY_URL/gateways?limit=0" \
  -H "Authorization: Bearer $JWT_TOKEN" | jq '[.[] | {name, url, enabled}]'

# List all federated tools (also a bare array)
make mcp-list-tools JWT_TOKEN=$JWT_TOKEN

# Or directly:
curl -s "$GATEWAY_URL/tools?limit=0" \
  -H "Authorization: Bearer $JWT_TOKEN" | jq '{total: length, names: [.[].name]}'
```

Expected result once both gotchas below are accounted for: 5 gateways, all
`enabled: true`, and `"total": 86` tools (5 SRE Toolbox + 22 GitHub + 40
Azure DevOps + 13 Kubernetes + 6 Prometheus).

### Gotcha 1: raw `curl $GATEWAY_URL/...` silently returns nothing

Observed 2026-07-03: `make mcp-list-gateways`/`make mcp-list-tools` returned
real JSON, but the "or directly" `curl` commands right below them produced
no output at all — no data, no error, nothing. Root cause: `GATEWAY_URL` is
a **Makefile** variable, substituted by `make` itself before the recipe's
shell command runs — it was never exported as a **shell** variable, so in
the user's own shell `$GATEWAY_URL` expanded to an empty string. `curl -s`
against an empty/schemeless URL fails, and `-s` suppresses the error message
along with the progress bar; the empty result piped into `jq` then produces
no output either. Nothing crashed, nothing errored visibly — the whole
pipeline just silently did nothing. **Fixed:** export it once per shell
session, per the addition to Step 0 above:

```bash
export GATEWAY_URL="https://contextforge.gourmandtech.com"
```

### Gotcha 2: `GET /tools` (and `/gateways`) cap at 50 results by default

Observed 2026-07-03: `make mcp-list-tools` returned `"total": 50` even
though the five gateways' own `toolCount`s sum to 86 (5+22+40+13+6) — the
`names` array cut off mid-way through the Azure DevOps tool list, with no
GitHub or SRE Toolbox tool names appearing at all. **Root cause, confirmed
against ContextForge's own source/docs, not guessed:** the gateway's REST
list endpoints default to `PAGINATION_DEFAULT_PAGE_SIZE=50` and silently
return only the first page as a plain array unless told otherwise.
`limit=0` is the documented way to disable pagination and get every item
back in one plain-array response (an explicit numeric `limit` up to
`PAGINATION_MAX_PAGE_SIZE=500` also works, but `limit=0` doesn't need this
project's tool count tracked against that ceiling as it keeps growing).
**Fixed:** both `make mcp-list-gateways`/`make mcp-list-tools` (Makefile)
and the raw `curl` snippets above now append `?limit=0`. Re-run after
pulling this fix — the earlier 50-item results in this runbook's Step 5
"Known Issues" section undercounted, not the gateways themselves.

---

## Step 7 — Configure RBAC

**Status: ✅ COMPLETE 2026-07-04.** Teams `sre-team` and `dev-team` created,
virtual servers `sre-full` (86 tools, all 5 gateways) and `dev-tools` (62
tools, GitHub + Azure DevOps only) created and confirmed live via
`mcp-list-teams`/`mcp-list-servers`. Both open questions from the prior
draft of this section were resolved against the live `/openapi.json` before
anything was created:

1. **How does a virtual server attach to gateways/tools?** Not via gateways
   at all — `ServerCreate`'s `associated_tools` field takes a list of
   individual **tool IDs**. There is no gateway-level association field.
   Workflow: `GET /tools?limit=0` returns each tool's `id` and `gatewaySlug`
   (confirmed equal to the gateway's registered `name`, e.g. `github-mcp`);
   filter by `gatewaySlug` to build the tool-ID list for a given server.
2. **Does `visibility: "team"` require a `team_id`?** Yes — confirmed in
   both `Body_create_server_servers_post` (the top-level POST body wrapper,
   which also independently accepts `team_id`/`visibility` as query-style
   fields) and inside the nested `ServerCreate` object itself. Both places
   need the same `team_id` set, or the server does not end up scoped to
   the team.

Two more real bugs found while running this step for real (beyond the two
open questions above, which weren't bugs so much as unknowns):

3. **`POST /teams` (no trailing slash) does not exist** — only
   `POST /teams/` does. Confirmed from `/openapi.json`'s path list: no bare
   `/teams` key, only `/teams/`, `/teams/discover`, `/teams/{team_id}`, etc.
   Calling the bare path 404s.
4. **`GET /teams/` does not return a bare array** — unlike `/gateways`,
   `/tools`, and `/servers`, it returns `{"teams": [...], "total": N}`.
   `mcp-list-teams` treats the response accordingly (`.teams[]`, not
   `.[]`). A related pagination quirk: `/teams/`'s `limit` query param has
   a schema-enforced `minimum: 1` (max 500) — the `?limit=0`
   disable-pagination trick that works on `/gateways`/`/tools`/`/servers`
   **422s here instead**. `mcp-list-teams` uses `?limit=500` (the max)
   instead of `?limit=0`.

### 7a — Create Teams

```bash
export JWT_TOKEN=$(make mcp-get-token)

# SRE team — full gateway access
make mcp-create-team TEAM_NAME=sre-team TEAM_DESC="SRE engineers — full gateway access" JWT_TOKEN=$JWT_TOKEN
# → id 64be6990afc14d69890d7fb6a33c94a7

# Dev team — GitHub + ADO access only
make mcp-create-team TEAM_NAME=dev-team TEAM_DESC="Developers — GitHub and Azure DevOps access only" JWT_TOKEN=$JWT_TOKEN
# → id 555c6cf678884774a65ed7725488baf2

make mcp-list-teams JWT_TOKEN=$JWT_TOKEN
```

Equivalent direct `curl` (endpoint: `POST /teams/` — note the trailing slash, see finding 3 above):

```bash
curl -sX POST $GATEWAY_URL/teams/ \
  -H "Authorization: Bearer $JWT_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name": "sre-team", "description": "SRE engineers — full gateway access"}' | jq .
```

### 7b — Create Virtual Servers with RBAC

Virtual servers (called "Servers" in ContextForge) expose a specific list
of **tools** — not gateways — to a team. Endpoint: `POST /servers`.
`mcp-create-server` takes `GATEWAYS` as a comma-separated list of gateway
names for convenience, but resolves it to individual tool IDs (via each
tool's `gatewaySlug`) before building the request body — see finding 1
above for why.

```bash
# SRE virtual server — all 5 gateways, 86 tools total
make mcp-create-server SERVER_NAME=sre-full \
  SERVER_DESC="Full SRE toolset — all registered gateways" \
  TEAM_ID=64be6990afc14d69890d7fb6a33c94a7 \
  GATEWAYS=sre-toolbox,github-mcp,azure-devops-mcp,kubernetes-mcp,prometheus-mcp \
  JWT_TOKEN=$JWT_TOKEN
# → id 7c7b4364c6214f089e847802819b7f2f, 86 tools attached, team: sre-team

# Dev virtual server — GitHub + ADO only, 62 tools total
make mcp-create-server SERVER_NAME=dev-tools \
  SERVER_DESC="Developer tools — GitHub and Azure DevOps only" \
  TEAM_ID=555c6cf678884774a65ed7725488baf2 \
  GATEWAYS=github-mcp,azure-devops-mcp \
  JWT_TOKEN=$JWT_TOKEN
# → id 86c6565d348848f195d1b41640432a35, 62 tools attached, team: dev-team

make mcp-list-servers JWT_TOKEN=$JWT_TOKEN
```

Equivalent direct `curl` for one server (endpoint: `POST /servers`; body wraps `ServerCreate` under a `server` key, alongside top-level `team_id`/`visibility`):

```bash
curl -sX POST $GATEWAY_URL/servers \
  -H "Authorization: Bearer $JWT_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "server": {
      "name": "sre-full",
      "description": "Full SRE toolset — all registered gateways",
      "associated_tools": ["<tool-id-1>", "<tool-id-2>", "..."],
      "visibility": "team",
      "team_id": "64be6990afc14d69890d7fb6a33c94a7"
    },
    "team_id": "64be6990afc14d69890d7fb6a33c94a7",
    "visibility": "team"
  }' | jq .
```

See the ContextForge RBAC how-to: `https://ibm.github.io/mcp-context-forge/howto/rbac-tool-authorization/`

---

## Step 8 — Configure Entra ID SSO (OIDC)

**Status: ✅ COMPLETE 2026-07-04.** App registration, service principal,
Helm/Makefile wiring, and live deploy all done and verified against
production. The section below is the corrected, as-run version — the
original draft got several things wrong, caught only by reading
`.contextforge/mcpgateway/config.py` and `routers/sso.py` directly instead
of trusting the docs tutorial:

1. **No generic `SSO_PROVIDER`/`SSO_CLIENT_ID`/`SSO_TENANT_ID`/`SSO_REDIRECT_URI`.**
   ContextForge namespaces every SSO provider's config
   (`SSO_GITHUB_*`, `SSO_GOOGLE_*`, `SSO_OKTA_*`, `SSO_ENTRA_*`, ...). The
   real Entra vars, confirmed from `config.py`: `SSO_ENABLED` (master
   switch), `SSO_ENTRA_ENABLED`, `SSO_ENTRA_CLIENT_ID`,
   `SSO_ENTRA_CLIENT_SECRET`, `SSO_ENTRA_TENANT_ID`. There's no
   `SSO_ENTRA_REDIRECT_URI` either — see next point.
2. **The callback path is fixed by the app itself, not configurable.**
   `mcpgateway/routers/sso.py` mounts `sso_router` at prefix `/auth/sso`
   with a `/callback/{provider_id}` route — so the real callback URL is
   `/auth/sso/callback/entra` (provider id confirmed as `"entra"` from
   `sso_service.py`), not `/auth/callback` as drafted. Confirmed against
   the actual login page too: `mcpgateway/templates/login.html` builds
   `redirect_uri` client-side as
   `window.location.origin + "/auth/sso/callback/" + providerId` — this
   must exactly match the URI registered on the Entra app, or Microsoft
   rejects the request with `AADSTS50011` (redirect URI mismatch).
3. **`az ad app create` does not create a Service Principal.** Only the
   App Registration object. Entra requires the corresponding Service
   Principal ("Enterprise Application") to exist before `az ad app
   permission grant` (or any real sign-in) will work — attempting the
   grant first fails with `ERROR: Resource '' does not exist or one of
   its queried reference-property objects are not present.` Fix: `az ad
   sp create --id <appId>` before granting permissions.
4. **`az ad app permission grant` requires `--scope`.** The draft omitted
   it; running it as-drafted fails with `the following arguments are
   required: --scope`. Correct form:
   `az ad app permission grant --id <appId> --api
   00000003-0000-0000-c000-000000000000 --scope User.Read`.

### 8a — Create Entra ID App Registration

```bash
# 1. Register app in Entra ID — redirect URI must match the fixed
#    /auth/sso/callback/{provider_id} path, not an arbitrary one.
az ad app create \
  --display-name "contextforge-sso" \
  --sign-in-audience AzureADMyOrg \
  --web-redirect-uris "https://contextforge.gourmandtech.com/auth/sso/callback/entra"

APP_ID=$(az ad app list --display-name contextforge-sso --query '[0].appId' -o tsv)
TENANT_ID=$(az account show --query tenantId -o tsv)
# → APP_ID  = 628f926c-f973-4959-808b-5a01d41f9097
# → TENANT_ID = c3754182-39f9-49ae-ada5-6aa91b4258a3

# 2. Create the Service Principal — REQUIRED, app create alone does not do this.
az ad sp create --id $APP_ID
# → SP object id: c87e9055-bbce-4475-9389-e8a84f1256bb

# 3. Create a client secret and store it in Key Vault immediately —
#    pipe directly, never let the plaintext value touch a file or the
#    shell's own scrollback/history.
az keyvault secret set --vault-name kv-contextforge-dev \
  --name entra-client-secret \
  --value "$(az ad app credential reset --id $APP_ID --display-name contextforge-sso-secret --query password -o tsv)"

# 4. Add Microsoft Graph User.Read (delegated) and grant admin consent.
#    --scope is required on the grant call — the earlier draft omitted it.
az ad app permission add --id $APP_ID \
  --api 00000003-0000-0000-c000-000000000000 \
  --api-permissions e1fe6dd8-ba31-4d61-89e7-88639da4683d=Scope   # User.Read
az ad app permission grant --id $APP_ID \
  --api 00000003-0000-0000-c000-000000000000 \
  --scope User.Read
```

### 8b — Add SSO Config to Helm Values (AKS)

Non-secret config goes in `infra/helm/values.azure.yaml` under
`mcpContextForge.config:` (maps to the ConfigMap via `envFrom`); the
secret placeholder goes under `mcpContextForge.secret:` (maps to the
Secret, populated at deploy time — see 8c):

```yaml
mcpContextForge:
  config:
    # ... existing config vars ...
    SSO_ENABLED: "true"
    SSO_ENTRA_ENABLED: "true"
    SSO_ENTRA_CLIENT_ID: "628f926c-f973-4959-808b-5a01d41f9097"
    SSO_ENTRA_TENANT_ID: "c3754182-39f9-49ae-ada5-6aa91b4258a3"
  secret:
    # ... existing secrets ...
    SSO_ENTRA_CLIENT_SECRET: "" # from KV `entra-client-secret` at helm-aks-secrets time
```

One subtlety verified via `helm template` before deploying for real: the
chart's own `secret-gateway.yaml` template independently defaults
`SSO_ENABLED`/`SSO_ENTRA_ENABLED` to `"false"` in the Secret object (since
our override lives in `config:`, not `secret:`), so the rendered Secret
and ConfigMap disagree on these keys. This is not a bug in practice —
`deployment-mcpgateway.yaml`'s `envFrom` lists `secretRef` **before**
`configMapRef`, and Kubernetes' `envFrom` merge takes the *last* source's
value on a duplicate key, so the ConfigMap's `"true"` correctly wins. Ran
`helm template` locally to confirm this before trusting it against
production — worth re-checking any time a new `SSO_*` key is split across
`config:`/`secret:` like this one is.

### 8c — Deploy and Verify SSO

```bash
make helm-aks-secrets KV_NAME=kv-contextforge-dev
# → adds --set "mcpContextForge.secret.SSO_ENTRA_CLIENT_SECRET=$(az keyvault secret show \
#     --vault-name kv-contextforge-dev --name entra-client-secret --query value -o tsv)"
#   to the existing helm upgrade call (see Makefile) — no CSI wiring needed since
#   this project's real deploy flow is Method B (--set from KV), not CSI sync.
```

Verified 2026-07-04, all against the live gateway:

```bash
curl -s https://contextforge.gourmandtech.com/health | jq .
# → {"status": "healthy", ...} — pod rolled out clean, 1/1 Running

curl -s https://contextforge.gourmandtech.com/auth/sso/providers | jq .
# → [{"id":"entra","name":"entra","display_name":"Microsoft Entra ID","authorization_url":null}]
# `authorization_url: null` here is expected — it's only populated by the
# actual login-initiation endpoint below, not the static provider list.

curl -s "https://contextforge.gourmandtech.com/auth/sso/login/entra?redirect_uri=https%3A%2F%2Fcontextforge.gourmandtech.com%2Fauth%2Fsso%2Fcallback%2Fentra" | jq -r .authorization_url
# → https://login.microsoftonline.com/<tenant>/oauth2/v2.0/authorize?client_id=<app-id>&response_type=code
#     &redirect_uri=https%3A%2F%2Fcontextforge.gourmandtech.com%2Fauth%2Fsso%2Fcallback%2Fentra
#     &state=...&scope=openid+profile+email+User.Read&code_challenge=...&code_challenge_method=S256&nonce=...
# Confirms: correct client_id, correct tenant, redirect_uri matches the
# Entra app registration exactly, PKCE (code_challenge) present, correct
# OIDC scopes. NOTE: the first attempt at this check used an arbitrary
# test redirect_uri (.../admin) instead of the real callback path — that
# would have failed with AADSTS50011 if actually opened in a browser.
# The redirect_uri passed to this endpoint must be the exact
# /auth/sso/callback/{provider_id} URL, matching what login.html sends.

make mcp-get-token  # existing email/password (JWT) login still succeeds —
                     # SSO is additive, not a replacement; no regression.
```

### 8d — Interactive Browser Login: Two More Real Bugs

The API-level checks in 8c all passed, but the actual click-through at
`https://contextforge.gourmandtech.com/admin` (done manually, browser-side,
2026-07-04) surfaced two further issues invisible from the command line —
both now fixed:

**Bug 1 — missing `email` claim.** First login attempt redirected to
`/admin/login?error=user_creation_failed`. `authenticate_or_create_user`
(`sso_service.py`) hard-requires an `email` claim and returns `None`
immediately if absent — `sso.py` turns that into the generic
`user_creation_failed` redirect, with no detail surfaced to the browser.
Root cause, confirmed via `az ad signed-in-user show`: the signed-in Azure
AD user object had `mail: null`. This tenant is the auto-provisioned
"Default Directory" for a personal Microsoft account
(`djfernandez80@gmail.com`) — its user object has no `mail` attribute set,
and the app registration had no `optionalClaims` configured, so Microsoft's
ID token had nothing to put in an `email` claim and simply omitted it.
Fixed with two changes (kept together, not mutually exclusive):

```bash
# 1. Set the mail attribute directly via Graph (az ad user update has no --mail flag)
az rest --method PATCH \
  --uri "https://graph.microsoft.com/v1.0/users/<object-id>" \
  --headers "Content-Type=application/json" \
  --body '{"mail": "djfernandez80@gmail.com"}'

# 2. Request "email" as an optional ID-token claim on the app registration
cat > optional-claims.json <<'EOF'
{"idToken": [{"name": "email", "essential": false}], "accessToken": [], "saml2Token": []}
EOF
az ad app update --id 628f926c-f973-4959-808b-5a01d41f9097 --optional-claims @optional-claims.json
```

After this fix, server logs (`kubectl logs -n mcp
deployment/mcp-stack-mcpgateway`, logger `mcpgateway.services.sso_service`)
confirmed `Token exchange successful for provider entra` — the email claim
now arrives correctly.

**Bug 2 (really: intended behavior) — account-linking refusal.** Second
login attempt hit `user_creation_failed` again, but for a different reason
— confirmed via the same log stream:

```
SSO authenticate_or_create_user: account-linking required for email
'djfernandez80@gmail.com' (existing provider='local', incoming='entra').
```

This is deliberate anti-account-takeover behavior, not a bug:
`authenticate_or_create_user` refuses to silently link an incoming SSO
identity to an existing `auth_provider='local'` account with the same
email (`sso_service.py` line ~2081). The platform-admin account created at
deploy time (`PLATFORM_ADMIN_EMAIL`) happens to share this email. There is
**no supported API to change `auth_provider`** on an existing user —
checked `AdminUserUpdateRequest` (`mcpgateway/schemas.py`), the schema
backing `PATCH /auth/email/admin/users/{email}`, and it only exposes
`full_name`, `is_admin`, `is_active`, `email_verified`,
`password_change_required`, `password` — not `auth_provider`. The only way
to flip that field is a raw, unsupported SQL `UPDATE` directly against
Postgres. (Separately confirmed this wouldn't have broken local
password login even if done — `email_auth_service.py`'s
`authenticate_user` checks `password_hash` directly and never gates on
`auth_provider` — but a raw DB mutation with zero app-level validation
behind it wasn't worth the risk for what's fundamentally a test scenario.)

Resolution: created a second, disposable Entra ID user purely for SSO
testing rather than fighting the account-linking guard:

```bash
az ad user create \
  --display-name "SSO Test Admin" \
  --user-principal-name "ssoadmin@djfernandez80gmail.onmicrosoft.com" \
  --password "<random, force-changed on first sign-in>" \
  --force-change-password-next-sign-in true

# Same missing-mail issue as Bug 1 hits every fresh Azure AD user by default:
az rest --method PATCH \
  --uri "https://graph.microsoft.com/v1.0/users/<new-object-id>" \
  --headers "Content-Type=application/json" \
  --body '{"mail": "ssoadmin@djfernandez80gmail.onmicrosoft.com"}'
```

Logging in via SSO with this new identity (in an incognito window, since
the existing session's cookies interfered) auto-created a fresh
ContextForge user with no email collision:

```bash
export JWT_TOKEN=$(make mcp-get-token)
curl -s "https://contextforge.gourmandtech.com/auth/email/admin/users/ssoadmin@djfernandez80gmail.onmicrosoft.com" \
  -H "Authorization: Bearer $JWT_TOKEN" | jq .
# → auth_provider: "entra", is_admin: false — confirms clean auto-create,
#   no account-linking conflict for a non-colliding email

# Promoted via the supported admin API — no DB edit needed for this part,
# since is_admin (unlike auth_provider) IS an exposed field on AdminUserUpdateRequest:
curl -s -X PATCH "https://contextforge.gourmandtech.com/auth/email/admin/users/ssoadmin@djfernandez80gmail.onmicrosoft.com" \
  -H "Authorization: Bearer $JWT_TOKEN" -H "Content-Type: application/json" \
  -d '{"is_admin": true}' | jq .
# → is_admin: true
```

Note also: the `email_auth_router` used above is mounted at prefix
`/auth/email` (confirmed from `main.py`'s `app.include_router(...)` call)
— not `/auth` as a first guess assumed; that first guess 404'd.

**End state:** SSO login is fully working end-to-end for any Entra
identity that doesn't collide with an existing local account's email.
`djfernandez80@gmail.com` specifically cannot use SSO login without either
a raw DB edit (not done, not recommended) or retiring the local admin
account — this is correct, intended security behavior, not something to
"fix" further.

Full tutorial: `https://ibm.github.io/mcp-context-forge/manage/sso-microsoft-entra-id-tutorial/`

---

## Step 9 — End-to-End Smoke Test

**Status: ✅ COMPLETE 2026-07-04**, with one confirmed upstream ContextForge
bug found and worked around (not fixed — it's vendored code, see below).
Items 1-3 passed cleanly. Item 4 initially failed with the admin JWT for a
real, confirmed reason unrelated to this project's own RBAC setup; item 5
uncovered two more inaccuracies in the original script. Full incident
detail below the script.

```bash
export JWT_TOKEN=$(make mcp-get-token)

# 1. Health check
curl -s https://contextforge.gourmandtech.com/health | jq .
# → {"status": "healthy", ...}

# 2. List all registered gateways
make mcp-list-gateways JWT_TOKEN=$JWT_TOKEN
# → all 5 gateways, enabled: true

# 3. List all federated tools (bare array — no wrapper object)
make mcp-list-tools JWT_TOKEN=$JWT_TOKEN
# → {"total": 86, "names": [...]} — 5+22+40+13+6, exact match

# 4. Invoke a tool via MCP SSE protocol
# There is no REST POST /tools/call endpoint — tool invocation goes through
# the MCP SSE stream at /servers/{server_id}/sse, where {server_id} is a
# real virtual server ID (from `make mcp-list-servers`) — there is no
# server literally named "default"; the lookup is by ID only.
#
# IMPORTANT: as of 2026-07-04, this call 404s with the platform-admin JWT
# above — this is a confirmed ContextForge bug (see below), not a config
# error. It succeeds with a session belonging to a real, non-admin member
# of the target server's team.
export SRE_FULL_SERVER_ID=$(curl -sf "$GATEWAY_URL/servers?limit=0" -H "Authorization: Bearer $JWT_TOKEN" | jq -r '.[] | select(.name == "sre-full") | .id')

pip install mcp --break-system-packages
python3 - <<'EOF'
import asyncio, os
from mcp import ClientSession
from mcp.client.sse import sse_client

JWT = os.environ["JWT_TOKEN"]
SERVER_ID = os.environ["SRE_FULL_SERVER_ID"]

async def test():
    async with sse_client(
        f"https://contextforge.gourmandtech.com/servers/{SERVER_ID}/sse",
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

# 5. Verify metrics — NOT a Prometheus-format grep as originally scripted.
# /metrics now requires auth (401 without a token) and returns a JSON
# aggregate-stats object, not Prometheus text — there is no
# `mcp_tool_calls_total` metric anywhere in the real Prometheus catalog
# (confirmed via /metrics/prometheus, which IS Prometheus text but has no
# tool-call counter — the closest thing is `tool_timeout_total`, a
# failure-only counter). Per-execution counts live in the JSON endpoint:
curl -s https://contextforge.gourmandtech.com/metrics -H "Authorization: Bearer $JWT_TOKEN" | jq .tools
# → {"totalExecutions": N, "successfulExecutions": N, ...}
```

### Incident: admin JWT 404s on `GET /servers/{id}/sse` — confirmed ContextForge bug

**Symptom:** Item 4 above returned `httpx.HTTPStatusError: Client error '404
Not Found'` for the platform-admin JWT (`djfernandez80@gmail.com`, `is_admin:
true` in the DB) against both `sre-full` and `dev-tools` — despite that same
token successfully listing both servers via `GET /servers` and successfully
listing all 86 tools via `GET /servers/{id}/tools`.

**Root cause, confirmed via the pod's own structured logs**
(`kubectl logs -n mcp deployment/mcp-stack-mcpgateway`, event
`server_access_denied`):

```json
{"user_email": "djfernandez80@gmail.com", "custom_fields": {"visibility": "team", "admin_bypass": false}, "resource_id": "7c7b4364c6214f089e847802819b7f2f"}
```

`admin_bypass: false` for a confirmed DB admin. Traced through
`server_service.py`'s `_check_server_access()`: bypass requires
`is_admin_bypass_granted()`, which requires `token_teams is None` — for
this admin's session, `token_teams` was resolving to `[]` at this
endpoint's call site (`get_scoped_resource_access_context()` in
`auth_context.py`), not `None`. An empty list short-circuits
`_check_server_access()` straight to denial (`is_public_only_token` check)
*before* it ever reaches the team-membership fallback check — even though
this admin is a genuine `owner`-role member of `sre-team` (team creation
auto-adds the creator; confirmed via `GET /teams/{id}/members`). The
**list** endpoint (`GET /servers`) and the **tools sub-endpoint**
(`GET /servers/{id}/tools`) clearly resolve this same admin's visibility
correctly — so the bug is isolated to `get_server()`'s single-object call
path (which the SSE endpoint also uses), not a general RBAC/auth failure.

**Confirmed this is scoped to the admin-bypass path, not team-based access
in general:** created a disposable, genuinely non-admin Entra test user
(`sretester@djfernandez80gmail.onmicrosoft.com` — `is_admin: false`,
confirmed via `GET /auth/email/admin/users/{email}`), added it to
`sre-team` as a plain `member` via `POST /teams/{team_id}/members`
(`TeamMemberAddRequest` — real endpoint, `email`+`role` body, distinct from
the admin-UI-only `/admin/teams/...` routes), then opened
`https://contextforge.gourmandtech.com/servers/{sre-full-id}/sse` directly
in that account's own logged-in browser tab. Result: a clean SSE handshake
—

```
event: endpoint
data: https://contextforge.gourmandtech.com/servers/.../message?session_id=...
event: keepalive
data: {}
: ping - ...
```

This conclusively shows the RBAC/team-membership access path works
correctly end-to-end for a real, properly-scoped team member — the bug is
narrowly isolated to how a DB-admin's session resolves `token_teams` at
this one endpoint family, not a broader dysfunction in Step 7's RBAC setup.

**Note on a dead end hit along the way:** first tried demoting a second
test account (`ssoadmin`, from Step 8d) back to non-admin to test with it
instead of creating a third identity — blocked by a real safety feature:
`PATCH /auth/email/admin/users/{email}` with `{"is_admin": false}` returned
`"Admin protection is enabled — cannot demote or deactivate any admin
user."` Confirms ContextForge has a deliberate admin-protection guard
against self-service demotion, not a bug — worth knowing about for anyone
trying to script account cleanup.

**Status:** confirmed, reproducible, upstream bug in vendored code
(`.contextforge/`) — not something this project patches per its own
convention ("never modify upstream ContextForge source"). Not filed
upstream as of this writing. Practical impact is low: the actual
production RBAC/SSO delivery (Steps 7-8) is unaffected and independently
verified — this only blocks a platform admin from using the SSE tool
stream directly against a team-visibility server by ID; real team members
using their own scoped sessions are unaffected, which is the realistic
usage pattern anyway.

---

## Key Lessons / Gotchas

- **HPA conflicts with `helm upgrade` on `spec.replicas`** — The ContextForge chart has a design flaw: `deployment-mcpgateway.yaml` unconditionally renders `replicas: {{ .Values.mcpContextForge.replicaCount }}` with no `{{- if not .Values.hpa.enabled }}` guard. When HPA is active, kube-controller-manager takes SSA ownership of `spec.replicas` and subsequent `helm upgrade` calls fail with `conflict with "kube-controller-manager" with subresource "scale"`. Neither `--force` (deprecated → `--force-replace`) nor `--force-replace` (incompatible with SSA mode) resolves it. **Fix**: `hpa.enabled: false` in `values.azure.yaml` — AKS node autoscaler handles capacity. The Makefile also surgically removes the stale managedField entry before `helm upgrade`.

- **Deleting HPA does NOT release its SSA field ownership** — The `managedFields` entry for kube-controller-manager persists on the Deployment even after the HPA object is deleted. Must be removed explicitly via JSON patch (`kubectl patch --type=json -p '[{"op":"remove","path":"/metadata/managedFields/N"}]'`). Use `kubectl get --show-managed-fields` — without that flag, `kubectl get -o json` strips `managedFields` since v1.21, making the field invisible. Use null-safe jq: `.metadata.managedFields // []`.

- **ConfigMap changes require a pod restart** — The chart uses `envFrom: configMapRef`, which snapshots env vars at container start. `helm upgrade` updates the ConfigMap but does NOT roll pods — the chart has no config-checksum annotation on the pod template. `make helm-aks-secrets` now runs `kubectl rollout restart` after every upgrade to close this gap. If you ever change a ConfigMap value outside of `make helm-aks-secrets`, restart manually: `kubectl rollout restart deployment/mcp-stack-mcpgateway -n mcp`.

- **SSRF protection blocks cluster-internal URLs** — Registering an in-cluster URL like `http://sre-mcp-server.mcp.svc.cluster.local:8000/sse` fails with `"Gateway URL contains private network address which is blocked by SSRF protection"`. Fix (already applied in `values.azure.yaml`): scope to cluster CIDRs only — `SSRF_ALLOW_PRIVATE_NETWORKS: "false"` + `SSRF_ALLOWED_NETWORKS: '["10.1.0.0/16", "10.0.0.0/22"]'` (service CIDR + pod subnet). Blanket `SSRF_ALLOW_PRIVATE_NETWORKS: "true"` works but allows all RFC 1918. Cloud metadata (`169.254.169.254`) stays blocked via `SSRF_BLOCKED_NETWORKS` regardless. This is a ConfigMap value — pod restart required for it to take effect (see above).

- **No `/v1/` prefix on any management REST endpoint** — All ContextForge REST management endpoints are at the root, not under `/v1/`. Correct paths: `POST /gateways`, `GET /tools`, `POST /teams/` (note: trailing slash required — `POST /teams` with no slash 404s, confirmed from `/openapi.json`'s path list, which has no bare `/teams` key), `POST /servers` (works with or without a trailing slash — both are separately registered routes with the same handler). Confirmed from source: each `APIRouter` defines its own prefix and is included directly on the app. `/v1/gateways` returns `{"detail": "Not Found"}`.

- **Tool naming uses hyphens, not double-underscores** — Confirmed from live output: ContextForge names federated tools as `<gateway-name>-<tool-name>` with underscores in tool names converted to hyphens. Example: `sre-toolbox-sre-healthcheck`, NOT `sre-toolbox__sre_healthcheck` as the docs suggest. Adjust any client-side tool-call strings accordingly.

- **Tool invocation is via SSE protocol, not a REST endpoint** — There is no `POST /tools/call`. Tools are invoked via the MCP SSE stream at `/servers/{server_id}/sse`, where `{server_id}` must be a real virtual server's ID from `GET /servers` — the lookup is a primary-key `db.get()` (`server_service.py`), not a name match, so there is no server literally named `default`. Use a Python `mcp` client or `scripts/test-mcp.sh`. The `toolCount: 0` in a fresh registration response is normal — tools are discovered asynchronously after the SSE connection is established.

- **Responses are bare JSON arrays** — `GET /gateways` and `GET /tools` return a JSON array directly, not `{"gateways": [...]}`. Use `jq 'length'` and `jq '.[].name'`, not `.tools | length`.

- **List endpoints paginate at 50 by default** — `GET /gateways` and `GET /tools` both default to `PAGINATION_DEFAULT_PAGE_SIZE=50` and silently return only the first page as a plain array — no `next`/`hasMore` field to tip you off, it just looks like a smaller result than reality. Confirmed 2026-07-03: `GET /tools` returned `"total": 50` when 86 tools were actually federated across 5 gateways. Append `?limit=0` to disable pagination entirely (or an explicit `limit` up to `PAGINATION_MAX_PAGE_SIZE=500`). `make mcp-list-gateways`/`make mcp-list-tools` and this runbook's raw `curl` references all append `?limit=0` now — see Step 6's gotcha #2 for the full incident.

- **`$GATEWAY_URL` is a Makefile variable, not a shell one** — every `make mcp-*` target works standalone because `make` substitutes `GATEWAY_URL ?= https://contextforge.gourmandtech.com` into the recipe itself. The "equivalent direct `curl`" reference blocks throughout this runbook use `$GATEWAY_URL` as a *shell* variable, which is never set just by running `make` — copy-pasting one of those blocks into a shell that never exported `GATEWAY_URL` produces a silent no-op (`curl -s` against an empty/schemeless URL fails quietly, and `-s` swallows the error). Export `GATEWAY_URL="https://contextforge.gourmandtech.com"` once per shell session (Step 0) before running any raw `curl` reference command in this doc.

- **`auth_token` for bearer auth, not `auth_value`** — `GatewayCreate` schema field is `auth_token`. For unauthenticated in-cluster gateways, omit `auth_type` entirely.

- **Gateways default to `visibility=public`** — Confirmed from `GatewayCreate` schema: `visibility` defaults to `"public"`, not `"private"`. Set `"visibility": "public"` explicitly to be clear; set `"visibility": "team"` to restrict to a specific team's virtual server.

- **SSO config goes under `mcpContextForge.config:`/`secret:`, not `env:`, and every provider is namespaced** — The chart injects `config:` values into a ConfigMap and `secret:` values into a Secret, both read via `envFrom`; there is no `mcpContextForge.env:` key. There is also no generic `SSO_PROVIDER`/`SSO_CLIENT_ID`/`SSO_TENANT_ID`/`SSO_REDIRECT_URI` — confirmed from `.contextforge/mcpgateway/config.py`, ContextForge namespaces every SSO provider's config independently (`SSO_ENTRA_ENABLED`, `SSO_ENTRA_CLIENT_ID`, `SSO_GITHUB_ENABLED`, `SSO_OKTA_ENABLED`, etc.) under one shared `SSO_ENABLED` master switch. Full detail: Step 8.

- **stdio → SSE wrapping** — Many MCP servers (Azure DevOps MCP) only support stdio transport. Use `mcpgateway.translate` (ContextForge's built-in bridge) or a thin container wrapper. See: `https://ibm.github.io/mcp-context-forge/using/mcpgateway-translate/`

- **Entra ID SSO callback path is fixed by the app, not configurable** — `mcpgateway/routers/sso.py` mounts the callback at `/auth/sso/callback/{provider_id}` (`entra` for this provider); there is no `SSO_ENTRA_REDIRECT_URI` setting. The Entra app registration's redirect URI must be set to this exact path (`https://<host>/auth/sso/callback/entra`), confirmed against `login.html`'s own client-side construction of the same URL. PKCE is auto-enabled by ContextForge. Two Entra-specific `az` CLI gaps to know about: `az ad app create` does **not** create the app's Service Principal (`az ad sp create --id <appId>` is a separate required step before permissions/sign-in work), and `az ad app permission grant` requires an explicit `--scope` argument. Full detail, plus two further gotchas only visible via an actual browser login (a tenant user with no `mail` attribute gets no `email` claim at all; ContextForge refuses to auto-link an SSO identity to an existing local-password account with the same email — intentional, not a bug): Step 8d.

- **Virtual servers attach to individual tool IDs, not gateway IDs** — `POST /servers`' `ServerCreate` schema has `associated_tools` (a list of tool IDs from `GET /tools`), with no gateway-level equivalent. `visibility: "team"` requires `team_id` in the same request, both in the outer body wrapper and inside the nested `ServerCreate` object. Full detail: Step 7.

- **`GET /teams/` has a different response shape and pagination floor than every other list endpoint** — Returns `{"teams": [...], "total": N}`, not a bare array like `/gateways`/`/tools`/`/servers`. Its `limit` param also has a schema-enforced minimum of 1 (max 500) — `?limit=0` 422s here, unlike the other list endpoints where it disables pagination. Use `?limit=500` instead. Full detail: Step 7.

- **Confirmed ContextForge bug: admin JWT 404s on `GET /servers/{id}/sse` for team-visibility servers** — A genuine DB admin's session resolves `token_teams` to `[]` (not `None`/bypass) specifically at this endpoint's visibility check, even though the same admin correctly sees the same server via `GET /servers` (list) and `GET /servers/{id}/tools`. Confirmed via the pod's own `server_access_denied` structured log (`"admin_bypass": false`) and by proving a genuinely non-admin real team member's session connects to the same SSE URL cleanly. Practical workaround: use a real, team-scoped (non-admin-bypass-dependent) session to invoke tools via SSE, not the platform-admin JWT. Vendored upstream code, not patched. Full detail: Step 9.

- **`/metrics` requires auth and is JSON, not Prometheus text; there is no `mcp_tool_calls_total` metric** — `/metrics` 401s without a bearer token and returns a JSON aggregate-stats object (`{"tools": {"totalExecutions": N, ...}, ...}`), not a Prometheus exposition. The actual Prometheus endpoint is `/metrics/prometheus` (confirmed from the chart's own `ServiceMonitor` scrape path) — it has no tool-call-count metric at all; the closest is `tool_timeout_total`, a failure-only counter. For tool-call counts, use the JSON `/metrics` endpoint's `.tools.totalExecutions`. Full detail: Step 9.

- **`az ad app credential reset --id ... --password` output includes a "protect this credential" warning** — expected `stderr` noise on every client-secret rotation, not an error.

- **Admin-protection blocks self-service demotion** — `PATCH /auth/email/admin/users/{email}` with `{"is_admin": false}` fails with `"Admin protection is enabled — cannot demote or deactivate any admin user."` Deliberate safety feature, not a bug — plan around it (e.g., create a fresh non-admin test identity rather than trying to demote an existing admin one) if scripting account cleanup or test scenarios.

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

### `GET /tools` capped at 50 results — RESOLVED 2026-07-03 ✅

**Was:** After all five gateways were registered (SRE 5 + GitHub 22 + Azure
DevOps 40 + Kubernetes 13 + Prometheus 6 = 86 tools expected),
`make mcp-list-tools` returned `"total": 50`.

**Root cause, confirmed (not just suspected) against ContextForge's own
pagination behavior:** `GET /tools` and `GET /gateways` both default to
`PAGINATION_DEFAULT_PAGE_SIZE=50` and silently return only the first page.
`?limit=0` disables pagination and returns everything as a plain array.

**Fixed:** `make mcp-list-gateways`/`make mcp-list-tools` (Makefile) and
every raw `curl` reference in this runbook now append `?limit=0`. Full
incident writeup: Step 6, gotcha #2. Also added as a permanent entry in
"Key Lessons / Gotchas" below, since it applies to any list endpoint, not
just this one verification pass.

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
