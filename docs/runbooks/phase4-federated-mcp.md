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
| Azure DevOps MCP | `microsoft/azure-devops-mcp` (official) | stdio via wrapper | ⬜ |
| Kubernetes MCP | `mcp-server-kubernetes` (community) | stdio via wrapper | ⬜ |
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
        ├── Kubernetes MCP ─────── (stdio → AKS cluster)
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

Microsoft's official Azure DevOps MCP server uses stdio transport. Use `mcpgateway.translate` (ContextForge's stdio bridge) to wrap it as an SSE endpoint, or deploy via the community HTTP wrapper.

```bash
# Option: deploy npm package in a container wrapping stdio→SSE
# See: infra/k8s/azure-devops-mcp-server.yaml

# Register with ContextForge (once running as SSE in-cluster)
curl -sX POST $GATEWAY_URL/gateways \
  -H "Authorization: Bearer $JWT_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "azure-devops-mcp",
    "url": "http://azure-devops-mcp.mcp.svc.cluster.local:8000/sse",
    "transport": "SSE",
    "auth_type": "bearer",
    "auth_token": "<AZURE_DEVOPS_PAT>",
    "description": "Azure DevOps — pipelines, work items, repos",
    "tags": ["azure", "devops", "ci-cd", "iac"],
    "visibility": "public"
  }' | jq .
```

**Required env vars for the container:**
- `AZURE_DEVOPS_ORG_URL` — e.g. `https://dev.azure.com/yourorg`
- `AZURE_DEVOPS_PAT` — Personal Access Token

---

## Step 4 — Register Kubernetes MCP Server

```bash
# The kubernetes MCP server needs kubeconfig access.
# Deploy in-cluster with a ServiceAccount that has read access.
kubectl apply -f infra/k8s/kubernetes-mcp-server.yaml -n mcp

# Register
curl -sX POST $GATEWAY_URL/gateways \
  -H "Authorization: Bearer $JWT_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "kubernetes-mcp",
    "url": "http://kubernetes-mcp-server.mcp.svc.cluster.local:8000/sse",
    "transport": "SSE",
    "description": "Kubernetes — pod health, deployments, logs (read-only)",
    "tags": ["kubernetes", "aks", "observability", "sre"],
    "visibility": "public"
  }' | jq .
```

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
