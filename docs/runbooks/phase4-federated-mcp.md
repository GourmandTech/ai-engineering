# Phase 4 — Federated MCP: Multi-Server Registration, RBAC, and OAuth

## Overview

Phase 4 turns ContextForge from a single gateway into a true **federated MCP hub**: multiple upstream MCP servers registered, access controlled by RBAC teams, and Entra ID SSO layered on top. This is the phase that demonstrates production AI-assisted SRE capabilities to a hiring audience.

**Production gateway:** `https://contextforge.gourmandtech.com`

---

## MCP Server Inventory

| Server | Source | Transport | Purpose |
|---|---|---|---|
| GitHub MCP | `github/github-mcp-server` (official) | SSE / Streamable HTTP | Repos, PRs, issues, Actions |
| Azure DevOps MCP | `microsoft/azure-devops-mcp` (official) | stdio via wrapper | Pipelines, work items, boards |
| Azure MCP | `azure/azure-mcp` (official Microsoft) | stdio via wrapper | AKS, Key Vault, ACR, resources |
| Kubernetes MCP | `mcp-server-kubernetes` (community) | stdio via wrapper | Pod health, deployments, logs |
| Prometheus MCP | `mcp-server-prometheus` (community) | stdio via wrapper | Natural language → PromQL |
| SRE Toolbox MCP | `services/sre-mcp-server` (**custom**) | SSE (FastMCP) | Healthchecks, alert summary, k8s + Azure stubs |

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
        ├── Azure MCP ─────────── (stdio → management.azure.com)
        ├── Kubernetes MCP ─────── (stdio → AKS cluster)
        ├── Prometheus MCP ─────── (stdio → /metrics endpoint)
        └── SRE Toolbox MCP ────── (SSE → AKS pod)
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

## Step 1 — Deploy the SRE Toolbox MCP Server to AKS

The custom Python MCP server lives at `services/sre-mcp-server/`. It exposes SRE-specific tools as a container inside AKS.

```bash
# Build and push to ACR
# NOTE: az acr build (ACR Tasks) is not permitted on this subscription.
# Build locally in the devcontainer and push directly instead.
ACR=$(az acr list -g rg-contextforge-dev --query '[0].loginServer' -o tsv)
az acr login --name acrcontextforgedev
# --platform linux/amd64 required: devcontainer on M1 builds arm64 by default; AKS nodes are amd64
docker build --platform linux/amd64 -t $ACR/sre-mcp-server:latest services/sre-mcp-server/
docker push $ACR/sre-mcp-server:latest

# Deploy to AKS
kubectl apply -f infra/k8s/sre-mcp-server.yaml -n mcp
kubectl rollout status deployment/sre-mcp-server -n mcp

# Verify the MCP server responds
kubectl port-forward svc/sre-mcp-server 8001:8000 -n mcp &
curl http://localhost:8001/sse   # should return SSE headers
kill %1
```

---

## Step 2 — Register GitHub MCP Server

GitHub's official MCP server runs as a remote server hosted by GitHub and is available at `https://api.githubcopilot.com/mcp/`. For self-hosting, use the Docker image.

### Option A — GitHub Remote MCP (easiest)

1. Create a GitHub Personal Access Token (or GitHub App) with scopes: `repo`, `read:user`, `workflow`, `read:org`
2. Register in ContextForge:

```bash
curl -sX POST $GATEWAY_URL/gateways \
  -H "Authorization: Bearer $JWT_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "github-mcp",
    "url": "https://api.githubcopilot.com/mcp/",
    "transport": "SSE",
    "auth_type": "bearer",
    "auth_token": "<GITHUB_PAT>",
    "description": "GitHub — repos, PRs, issues, Actions",
    "tags": ["github", "vcs", "ci-cd"],
    "visibility": "public"
  }' | jq .
```

### Option B — Self-hosted (inside AKS)

```bash
# Add to AKS via Helm or kubectl (image: ghcr.io/github/github-mcp-server)
kubectl apply -f infra/k8s/github-mcp-server.yaml -n mcp

# Register the in-cluster SSE endpoint
curl -sX POST $GATEWAY_URL/gateways \
  -H "Authorization: Bearer $JWT_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "github-mcp",
    "url": "http://github-mcp-server.mcp.svc.cluster.local:8000/sse",
    "transport": "SSE",
    "auth_type": "bearer",
    "auth_token": "<GITHUB_PAT>",
    "description": "GitHub MCP (self-hosted in AKS)",
    "tags": ["github", "vcs", "ci-cd"],
    "visibility": "public"
  }' | jq .
```

---

## Step 3 — Register Azure DevOps MCP Server

Microsoft's official Azure DevOps MCP server uses stdio transport. Use `mcpgateway.wrapper` (ContextForge's stdio bridge) to wrap it as an SSE endpoint, or deploy via the community HTTP wrapper.

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

## Step 6 — Register SRE Toolbox MCP Server

```bash
# Or use: make mcp-register-sre JWT_TOKEN=$JWT_TOKEN
curl -sX POST $GATEWAY_URL/gateways \
  -H "Authorization: Bearer $JWT_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "sre-toolbox",
    "url": "http://sre-mcp-server.mcp.svc.cluster.local:8000/sse",
    "transport": "SSE",
    "description": "Custom SRE toolbox — healthchecks, k8s pod status, Azure resource query",
    "tags": ["sre", "custom", "azure", "kubernetes"],
    "visibility": "public"
  }' | jq .
```

> **API path note (hard-won):** ContextForge's gateway registration is at `POST /gateways`, NOT `POST /v1/gateways`. There is no `/v1/` prefix on any REST management endpoint. Confirmed from source: `gateway_router = APIRouter(prefix="/gateways")` mounted directly on the app. Same applies to `/tools`, `/teams`, `/servers`.

---

## Step 7 — Verify All Gateways Registered

```bash
# List all registered gateways (response is a bare JSON array)
make mcp-list-gateways JWT_TOKEN=$JWT_TOKEN

# Or directly:
curl -s $GATEWAY_URL/gateways \
  -H "Authorization: Bearer $JWT_TOKEN" | jq '[.[] | {name, url, enabled}]'

# List all federated tools (also a bare array — no .tools wrapper)
make mcp-list-tools JWT_TOKEN=$JWT_TOKEN

# Or directly:
curl -s $GATEWAY_URL/tools \
  -H "Authorization: Bearer $JWT_TOKEN" | jq '{total: length, names: [.[].name]}'
```

---

## Step 8 — Configure RBAC

ContextForge ships with 4 built-in roles: `admin`, `manager`, `user`, `viewer`.

### 8a — Create Teams

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

### 8b — Create Virtual Servers with RBAC

Virtual servers (called "Servers" in ContextForge) let you expose a subset of gateways to specific teams. Endpoint: `POST /servers`.

```bash
# Get gateway IDs first
GATEWAY_IDS=$(curl -s $GATEWAY_URL/gateways -H "Authorization: Bearer $JWT_TOKEN" | jq -r '[.[] | .id]')

# SRE virtual server — all gateways
curl -sX POST $GATEWAY_URL/servers \
  -H "Authorization: Bearer $JWT_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "sre-full",
    "description": "Full SRE toolset — all registered gateways",
    "visibility": "team"
  }' | jq .

# Dev virtual server — GitHub + ADO only (add gateway_ids once you have them)
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

## Step 9 — Configure Entra ID SSO (OIDC)

### 9a — Create Entra ID App Registration

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
echo "Client Secret: $CLIENT_SECRET"
# → Store this in Key Vault immediately:
az keyvault secret set --vault-name kv-contextforge-dev \
  --name entra-client-secret --value "$CLIENT_SECRET"

# 4. Add API permissions: openid, profile, email
az ad app permission add --id $APP_ID \
  --api 00000003-0000-0000-c000-000000000000 \
  --api-permissions e1fe6dd8-ba31-4d61-89e7-88639da4683d=Scope \  # User.Read
                   37f7f235-527c-4136-accd-4a02d197296e=Scope \   # openid
                   14dad69e-099b-42c9-810b-d002981feec1=Scope     # profile
az ad app permission grant --id $APP_ID \
  --api 00000003-0000-0000-c000-000000000000
```

### 9b — Add SSO Config to Helm Values (AKS)

Add to `infra/helm/values.azure.yaml` under `mcpContextForge.env`:

```yaml
mcpContextForge:
  env:
    # ... existing env vars ...
    SSO_ENABLED: "true"
    SSO_PROVIDER: "microsoft"
    SSO_CLIENT_ID: "<APP_ID>"
    SSO_TENANT_ID: "<TENANT_ID>"
    SSO_REDIRECT_URI: "https://contextforge.gourmandtech.com/auth/callback"
    # SSO_CLIENT_SECRET comes from Key Vault via CSI driver
```

Add the CSI secret sync for `entra-client-secret` in `infra/k8s/secret-provider-class.yaml`:

```yaml
- |
  objectName: entra-client-secret
  objectType: secret
  objectVersion: ""
```

And map it to an env var in the Helm deploy:

```bash
--set "mcpContextForge.secret.SSO_CLIENT_SECRET=$(az keyvault secret show \
  --vault-name kv-contextforge-dev --name entra-client-secret --query value -o tsv)"
```

### 9c — Deploy and Verify SSO

```bash
make helm-aks-secrets KV_NAME=kv-contextforge-dev

# Visit in browser — should show Microsoft login button:
# https://contextforge.gourmandtech.com/admin
```

Full tutorial: `https://ibm.github.io/mcp-context-forge/manage/sso-microsoft-entra-id-tutorial/`

---

## Step 10 — End-to-End Smoke Test

```bash
# 1. Health check
curl -s https://contextforge.gourmandtech.com/health | jq .

# 2. List all registered gateways
make mcp-list-gateways JWT_TOKEN=$JWT_TOKEN

# 3. List all federated tools (bare array response — no .tools wrapper)
make mcp-list-tools JWT_TOKEN=$JWT_TOKEN
# Expected: {"total": N, "names": ["sre-toolbox__sre_healthcheck", ...]}

# 4. Invoke a tool via MCP SSE protocol
# ContextForge has no REST POST /tools/call — tool invocation goes through
# the MCP SSE stream at /servers/{server_id}/sse or the default virtual server.
# Use the scripts/test-mcp.sh script or a Python MCP client:
python3 - <<'EOF'
import asyncio
from mcp import ClientSession
from mcp.client.sse import sse_client

async def test():
    async with sse_client("https://contextforge.gourmandtech.com/servers/default/sse",
                          headers={"Authorization": f"Bearer $JWT_TOKEN"}) as (r, w):
        async with ClientSession(r, w) as session:
            await session.initialize()
            result = await session.call_tool("sre-toolbox__sre_healthcheck",
                                             {"url": "https://contextforge.gourmandtech.com/health"})
            print(result)

asyncio.run(test())
EOF

# 5. Verify metrics reflect the tool calls
curl -s https://contextforge.gourmandtech.com/metrics | grep mcp_tool_calls_total
```

---

## Key Lessons / Gotchas

- **HPA conflicts with `helm upgrade` on `spec.replicas`** — The ContextForge chart has a design flaw: `deployment-mcpgateway.yaml` unconditionally renders `replicas: {{ .Values.mcpContextForge.replicaCount }}` with no HPA guard. When HPA is active, kube-controller-manager takes SSA ownership of `spec.replicas` and subsequent Helm upgrades fail with `conflict with "kube-controller-manager" with subresource "scale"`. Neither `--force` (deprecated → `--force-replace`) nor `--force-replace` (incompatible with SSA mode) resolves it. **Fix**: disable HPA (`hpa.enabled: false` in `values.azure.yaml`) — node-level autoscaling (AKS system pool) handles capacity. For the one-time transition, `make helm-aks-secrets` now surgically removes the stale kube-controller-manager `managedField` entry from the Deployment before running `helm upgrade`. Note: deleting the HPA object does NOT release its SSA field ownership — the `managedFields` entry on the Deployment persists until explicitly patched out.
- **SSRF protection blocks cluster-internal URLs by default** — Registering an in-cluster URL like `http://sre-mcp-server.mcp.svc.cluster.local:8000/sse` fails with `"Gateway URL contains private network address which is blocked by SSRF protection"`. Fix (in `values.azure.yaml`): scope allowlist to cluster CIDRs only — `SSRF_ALLOW_PRIVATE_NETWORKS: "false"` + `SSRF_ALLOWED_NETWORKS: '["10.1.0.0/16", "10.0.0.0/22"]'` (service CIDR + pod subnet). Blanket `SSRF_ALLOW_PRIVATE_NETWORKS: "true"` works but is broader than necessary. Cloud metadata (`169.254.169.254`) stays blocked via `SSRF_BLOCKED_NETWORKS` regardless.
- **ConfigMap changes require a pod restart** — The chart uses `envFrom: configMapRef`, which snapshots env vars at container start. `helm upgrade` updates the ConfigMap but does NOT roll pods unless the Deployment's pod template changes (the chart has no config-checksum annotation). Result: the running pod keeps stale env values even though `kubectl get configmap` shows the new values. `make helm-aks-secrets` now runs `kubectl rollout restart` after every upgrade to close this gap. If you ever apply a ConfigMap change outside of `make helm-aks-secrets`, restart manually: `kubectl rollout restart deployment/mcp-stack-mcpgateway -n mcp`.
- **No `/v1/` prefix on management REST APIs** — All ContextForge REST management endpoints are at the root, not under `/v1/`. Correct paths: `POST /gateways`, `GET /tools`, `POST /teams`, `POST /servers`. The `/v1/` path returns `{"detail": "Not Found"}`. Confirmed from source: each `APIRouter` defines its own prefix (e.g. `/gateways`) and is included directly on the app with no global version prefix.
- **Tool invocation is not a REST endpoint** — There is no `POST /tools/call`. Tools are invoked via the MCP SSE protocol stream at `/servers/{server_id}/sse`. Use an MCP client library (Python `mcp` package) or `scripts/test-mcp.sh`.
- **Responses are bare arrays** — `GET /gateways` and `GET /tools` return a JSON array directly, not `{"gateways": [...]}` or `{"tools": [...]}`. Use `jq 'length'` and `jq '.[].name'`, not `.gateways | length`.
- **Use `auth_token` for bearer auth** — `GatewayCreate` schema field is `auth_token`, not `auth_value`. Omit `auth_type` entirely (or don't set it) for unauthenticated internal-cluster gateways.
- **stdio → SSE wrapping**: Many MCP servers (Azure DevOps MCP, Azure MCP) only support stdio transport. Use `mcpgateway.translate` (ContextForge's built-in bridge) or a thin container wrapper to expose them as SSE. See: `https://ibm.github.io/mcp-context-forge/using/mcpgateway-translate/`
- **Token scoping**: ContextForge user-scopes OAuth tokens. For machine-to-machine tool calls (agent scenarios), prefer `client_credentials` grant type over `authorization_code`.
- **Virtual servers as the RBAC boundary**: New gateways are `visibility=private` by default. You must explicitly add them to a virtual server and assign team access.
- **Entra ID PKCE**: ContextForge auto-enables PKCE for auth code flows — no extra config needed, but your Entra redirect URI must exactly match (trailing slash matters).
- **Tool namespacing**: ContextForge namespaces federated tools as `<gateway_name>__<tool_name>`. This prevents collisions when multiple servers expose tools with the same name (e.g., `list_files`).

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
