# AI Engineering — Claude Code Context

## Mission
Personal SRE/DevOps learning platform. Goal: demonstrate self-advancement in AI-assisted engineering, agentic coding, and AI automation for job placement. Core background: Microsoft Azure, Azure DevOps, Bicep. Expanding into: AI/ML Ops, agentic infrastructure, federated MCP.

## Current State (updated 2026-07-02)

### Phase 4 — IN PROGRESS 🔄 (Federated MCP)
Full runbook: `docs/runbooks/phase4-federated-mcp.md`

**Goal:** Register multiple MCP servers into ContextForge, apply RBAC teams, and add Entra ID SSO.

**MCP Server Inventory:**
| Server | Source | Transport | Status |
|---|---|---|---|
| SRE Toolbox MCP | `services/sre-mcp-server/` (custom Python FastMCP) | SSE | ✅ Running in AKS + registered in ContextForge |
| GitHub MCP | `github/github-mcp-server` (official, self-hosted) | stdio via `mcpgateway.translate` wrapper | ✅ Running in AKS + registered in ContextForge |
| Azure DevOps MCP | `microsoft/azure-devops-mcp` (official) | stdio→SSE | ⬜ |
| Kubernetes MCP | community | stdio→SSE | ⬜ |
| Prometheus MCP | community | stdio→SSE | ⬜ |

**Phase 4 sub-tasks:**
1. ✅ Build + push SRE Toolbox MCP container to ACR (`make sre-mcp-build`)
2. ✅ Deploy SRE Toolbox to AKS (`make sre-mcp-deploy`) — pod `1/1 Running`
3. ✅ Register SRE Toolbox in ContextForge (`make mcp-register-sre`) — `status: active`, 5 tools federated
4. 🔄 Register remaining MCP servers (GitHub, Azure DevOps, Kubernetes, Prometheus)
   - GitHub: ✅ COMPLETE 2026-07-02 — pod `1/1 Running`, registered, `status: active`, `reachable: true`, 22 tools federated. Hit five real bugs on the way, all fixed (full writeup: runbook Step 2 incident log): (1) `AADSTS70025` — CSI SecretProviderClass pointed at the wrong identity, fixed with a dedicated per-workload identity (`infra/bicep/modules/workload-identity.bicep`, reusable for Steps 3-5); (2) `make bicep-deploy` reverted the node pool autoscaler — fixed, see Node pool note above; (3) `mcpgateway.translate` invoked with flags that don't exist in the published package (`--expose-sse`) — fixed, pinned to `mcp-contextforge-gateway==0.1.1`; (4) NetworkPolicy ingress label guessed wrong (`app.kubernetes.io/name: mcpgateway` vs actual `app: mcp-stack-mcpgateway`) — fixed; (5) wrapped binary invoked without its required `stdio` positional subcommand, silently exiting instantly — fixed. `make github-mcp-deploy` also now force-restarts the rollout, since a `:latest`-tagged image rebuild doesn't otherwise trigger one.
5. ⬜ Create RBAC teams (`sre-team`, `dev-team`) and virtual servers
6. ⬜ Configure Entra ID app registration + SSO in Helm values

**Key Phase 4 design decisions:**
- stdio MCP servers (GitHub, Azure DevOps MCP, Azure MCP) wrapped via `mcpgateway.translate` → SSE — GitHub's upstream binary is stdio-only (confirmed from its own Dockerfile), the vendor's only HTTP transport is the non-self-hostable `api.githubcopilot.com/mcp/`
- GitHub MCP self-hosted in-cluster rather than registered against GitHub's remote hosted endpoint — keeps the PAT and API traffic inside the AKS network boundary; the PAT is synced via Key Vault CSI directly into the `github-mcp-server` pod and never touches ContextForge's own gateway config
- GitHub App auth (short-lived installation tokens, no PAT rotation) is the stronger long-term auth pattern but is currently broken upstream — `github-mcp-server` forces a `GET /user` check that doesn't work with App auth ([issue #1610](https://github.com/github/github-mcp-server/issues/1610)). Using a fine-grained, repo-scoped PAT on a bot account as the interim approach; revisit when that's fixed.
- RBAC: API key auth for service accounts first, Entra ID OIDC SSO for human users second
- Virtual servers as the RBAC boundary — tools are `visibility=public` by default (set explicitly)
- Tool namespacing: ContextForge names tools as `<gateway-name>-<tool-name>` (hyphens, not `__`)
  - e.g. `sre-toolbox-sre-healthcheck` (underscores in tool names converted to hyphens)
- Custom Python MCP uses `mcp[cli]` + FastMCP SSE transport, AKS pod with ClusterRole read-only access
- HPA disabled on gateway Deployment: chart has no `{{- if not .Values.hpa.enabled }}` guard on
  `spec.replicas`, causing Helm SSA conflict with kube-controller-manager; AKS node autoscaler handles capacity
- `make helm-aks-secrets` always runs `kubectl rollout restart` post-upgrade: chart uses `envFrom`
  (env snapshotted at container start), so ConfigMap-only changes require a pod restart to take effect
- SSRF allowlist scoped to cluster CIDRs: `10.1.0.0/16` (service CIDR) + `10.0.0.0/22` (pod subnet)
- Gateway registration API is at `POST /gateways` — no `/v1/` prefix on any management endpoint

---


### Phase 1 — COMPLETE ✅
- Docker Compose stack running locally at `http://localhost:4444/admin`
- Confirmed healthy on MacBook Pro M1 (2026-06-26): `make test` returns `{"status":"healthy"}`
- Key fix: `MCPGATEWAY_UI_ENABLED: "true"` and `MCPGATEWAY_ADMIN_API_ENABLED: "true"` required in env (default is False in latest image)
- Devcontainer: `mcr.microsoft.com/devcontainers/python:3.12-bookworm` base, **`docker-in-docker` feature** (switched from `docker-outside-of-docker` on 2026-06-29 — see Minikube note).
- NOTE: With `docker-in-docker` the Compose stack runs on the devcontainer's own daemon and publishes to the devcontainer's localhost, so `MCP_HOST=localhost:4444` works directly (the old `gateway-1:4444` container-routing hack is gone).

### Minikube on M1 + devcontainer — root cause & fix (2026-06-29)
- **Symptom:** `make minikube-start` failed with `DRV_CREATE_TIMEOUT` — minikube created the kicbase node, then powered it off and retried until timeout.
- **Root cause:** minikube's docker driver on Docker Desktop always SSHes to the node via the **host's `127.0.0.1:<forwarded-port>`** (libmachine log: `dial tcp 127.0.0.1:54525: connect: connection refused`). Under `docker-outside-of-docker`, the devcontainer shares the host daemon but `127.0.0.1` is the devcontainer's own loopback, not the Mac host where that port is published — so SSH never connects. Pre-creating the docker network and attaching the devcontainer made `192.168.49.2:22` reachable, but minikube never dials the container IP, so it couldn't fix this.
- **Fix:** switched the devcontainer to `docker-in-docker`. The Docker daemon is now local to the devcontainer, so kicbase's forwarded ports land on the devcontainer's own `127.0.0.1` and minikube works natively — no `--network`, no pre-create, no attach hacks. `make minikube-start` is back to a plain `minikube start`.
- Confirmed during debugging: container-to-container traffic on the bridge was fine (`192.168.49.2:22` reachable), and the host's forwarded port was reachable via `host.docker.internal` — the only broken path was minikube's hardcoded `127.0.0.1`.

### Phase 2 — COMPLETE ✅
Full Helm stack deployed to minikube (profile `mcpgw`) on MacBook Pro M1. Confirmed 2026-06-29: `make helm-install` → all pods `1/1 Running`, gateway healthy over ingress (`curl http://gateway.local/health` from inside the devcontainer returns `{"status":"healthy"}`).

**Working flow:**
1. `make chart-fetch` — clones IBM/mcp-context-forge to `.contextforge/` (run once)
2. `make minikube-start` — plain `minikube start` under DinD (see Minikube note above)
3. `minikube image load ghcr.io/ibm/mcp-context-forge:v1.0.4 --profile mcpgw` — pre-load arm64 image
4. `make helm-install` — deploys chart with `infra/helm/values.yaml` overrides
5. Verify (inside devcontainer): `echo "192.168.49.2  gateway.local" | sudo tee -a /etc/hosts` then `curl http://gateway.local/health`
6. Host browser: `make port-forward` → open `http://localhost:8080/admin` on the Mac. `gateway.local` does NOT work from the host (cluster is nested in DinD — see Host access below).

**Phase 2 Helm override fixes** (full write-up: `docs/runbooks/helm-install-minikube.md`):
- `mcpContextForge.metrics.serviceMonitor.enabled: false` — minikube has no Prometheus Operator, so the chart's `ServiceMonitor` (`monitoring.coreos.com/v1`) is an unregistered kind and Helm can't render it.
- `migration.enabled: false` — the chart's migration Job is a Helm `post-install` hook that **deadlocks** against `--wait` (the gateway can't be Ready until the schema is migrated, but the hook only runs after Ready). With it off, the gateway self-migrates on boot (`MCPGATEWAY_SKIP_MIGRATIONS=false`), safe for single-replica. Re-enable for AKS.
- `mcpContextForge.ingress.annotations` → `ssl-redirect`/`force-ssl-redirect: "false"` — the chart hardcodes a forced HTTPS 308 even with TLS off, which 308s every request (incl. `/health`) to a dead `https://` scheme.

**Host access under DinD:** the minikube node IP (`192.168.49.2`) and `gateway.local` resolve/route only *inside* the devcontainer. From the Mac host browser, `gateway.local` fails with `DNS_PROBE_FINISHED_NXDOMAIN` — use `make port-forward` (gateway → `localhost:8080`, VS Code forwards to the host). See `docs/runbooks/minikube-devcontainer-dind.md`.

**M1/arm64 note:** ContextForge image (`ghcr.io/ibm/mcp-context-forge`) must support `linux/arm64`. Check with `docker manifest inspect ghcr.io/ibm/mcp-context-forge:v1.0.4` before pulling. If arm64 is missing, use `--platform linux/amd64` (Rosetta) in docker-compose.yml and Helm values extraEnv.

**Helm chart location:** `.contextforge/charts/mcp-stack` (upstream, not committed — listed in .gitignore)
**Our overrides:** `infra/helm/values.yaml` — 1 replica, pinned tag `v1.0.4`, ingress on `gateway.local`, TLS off, admin UI via extraEnv, ServiceMonitor off, migration off (self-migrate), ssl-redirect off.

### Phase 3 — COMPLETE ✅ (AKS)
Confirmed 2026-06-30: `curl https://contextforge.gourmandtech.com/health` → `{"status":"healthy"}` with valid Let's Encrypt TLS, TLSv1.3, HTTP/2, HSTS, and production security headers.

**Production URL:** `https://contextforge.gourmandtech.com`

**Node pool:** `system` — autoscaling enabled (min: 2, max: 10), configured 2026-07-02 via Azure Portal after single-node CPU exhaustion when sre-mcp-server was added alongside the gateway. This was Portal-only until 2026-07-02: a later `make bicep-deploy` (for the Phase 4 workload identity) silently reverted it back to a fixed 1-node pool via `infra/bicep/modules/aks.bicep`'s stale `enableAutoScaling: false` default, causing a second CPU-exhaustion-shaped outage (gateway pod `FailedScheduling`). Now fixed in IaC — `enableAutoScaling`/`minNodeCount`/`maxNodeCount` are real Bicep params defaulting to true/2/10, so `bicep-deploy` is safe to re-run. See `docs/runbooks/phase4-federated-mcp.md` Step 2 incident log.

**IaC files:**
- `infra/bicep/main.bicep` — subscription-scoped deployment, derives all resource names from params
- `infra/bicep/main.bicepparam` — 1 node, Standard_D2s_v7, eastus, maxPods=50, adminObjectId set
- `infra/bicep/modules/network.bicep` — VNet 10.0.0.0/16, AKS subnet 10.0.0.0/22
- `infra/bicep/modules/acr.bicep` — Standard ACR, admin disabled, managed identity pull
- `infra/bicep/modules/keyvault.bicep` — Standard KV, RBAC auth, soft-delete 7 days
- `infra/bicep/modules/aks.bicep` — AKS with CSI add-on, OIDC issuer, workload identity, Container Insights, AcrPull role, KV Secrets User role, maxPodsPerNode param
- `infra/bicep/modules/logworkspace.bicep` — PerGB2018, 30-day retention

**Helm / App files:**
- `infra/helm/values.azure.yaml` — 1 replica, Recreate strategy, HPA, TLS on `contextforge.gourmandtech.com`, cert-manager HTTP-01, strong security config, migration off (self-migrate)
- `infra/k8s/secret-provider-class.yaml` — CSI SecretProviderClass syncs KV → k8s Secret
- `infra/k8s/cluster-issuer.yaml` — Let's Encrypt prod ClusterIssuer (HTTP-01 via nginx)

**Working deploy flow (see full runbook: `docs/runbooks/aks-deploy.md`):**
1. `az account show` — confirm subscription
2. `make bicep-deploy` — provisions RG, VNet, ACR, Key Vault, AKS (uses `main.bicepparam`)
3. `make kv-populate KV_NAME=kv-contextforge-dev` — generate all secrets in KV
4. `make cluster-bootstrap` — installs nginx-ingress + cert-manager, applies ClusterIssuer + SecretProviderClass
5. `make helm-aks-secrets KV_NAME=kv-contextforge-dev` — deploy ContextForge with secrets from KV
6. Verify: `curl https://contextforge.gourmandtech.com/health`

**Critical Phase 3 lessons learned (see runbook for full detail):**

- **maxPods is immutable** — changing it requires AKS cluster deletion. Set `maxPodsPerNode: 50` in Bicep upfront (Azure CNI default of 30 is too low for observability add-ons like cert-manager).
- **Role assignment idempotency** — after AKS deletion, orphaned RG-scoped role assignments block redeployment with `RoleAssignmentUpdateNotPermitted`. Clean them before redeploying: `az role assignment list -g rg-contextforge-dev --query "[?principalName=='' || principalName==null].id" -o tsv | xargs -I {} az role assignment delete --ids {}`
- **BASIC_AUTH_PASSWORD** — gateway crashes even with `API_ALLOW_BASIC_AUTH: "false"` if the secret is weak. Must supply a strong value via `--set` from KV.
- **Migration Job deadlock** — `migration.enabled: true` + `helm --wait` deadlocks on single replica. Keep `migration.enabled: false`; gateway self-migrates on boot.
- **Azure Standard LB SNAT asymmetry** — the root cause of external port 80 timeouts. AKS creates two frontend IPs: one for the nginx ingress service (`a6e0a676...` = 52.226.253.79) and one for the system LB (`90989c11-...`). The `aksOutboundRule` only references the system frontend IP. With `DisableOutboundSnat: true` on the inbound rule, response packets are SNAT'd via the wrong public IP — clients drop them. **Fix:** `controller.service.externalTrafficPolicy: Local` on nginx-ingress. This bypasses kube-proxy SNAT entirely (direct pod→client path) and creates a health-check nodeport that returns 200 so the LB probe passes.
- **Let's Encrypt + `.nip.io`** — LE does not issue certificates for nip.io. Use a real domain.
- **Cloudflare proxy must be gray-cloud** for HTTP-01 ACME challenge — orange-cloud (proxy) breaks the challenge because LE sees Cloudflare's IP, not the LB IP.
- **kubelogin** — required for AKS with Azure AD RBAC. `make aks-creds` auto-installs arm64 binary and runs `kubelogin convert-kubeconfig -l azurecli`. Re-run after devcontainer restart.

---

## Active Project: IBM ContextForge MCP Gateway on AKS
Deploying IBM ContextForge — an open-source AI Gateway that federates MCP servers, REST APIs, gRPC services, and AI agents into a single unified endpoint — on Azure Kubernetes Service using Bicep IaC and Helm.

**Key Documentation:**
- [ContextForge Docs](https://ibm.github.io/mcp-context-forge/latest/)
- [GitHub Source](https://github.com/IBM/mcp-context-forge)
- [Deployment Overview](https://ibm.github.io/mcp-context-forge/latest/deployment/)
- [Azure/AKS Deployment](https://ibm.github.io/mcp-context-forge/latest/deployment/azure/)
- [Helm Chart Guide](https://ibm.github.io/mcp-context-forge/latest/deployment/helm/)
- [Federated MCP / A2A](https://ibm.github.io/mcp-context-forge/latest/using/agents/a2a/)

---

## Tech Stack

| Layer | Technology |
|---|---|
| Cloud | Microsoft Azure (personal subscription) |
| IaC | Bicep (modular) |
| Container Orchestration | AKS — Azure Kubernetes Service |
| Helm | v3 — chart deployments |
| CI/CD | GitHub Actions |
| AI Gateway | IBM ContextForge MCP Gateway |
| Protocol | MCP (Model Context Protocol), A2A (Agent-to-Agent) |
| Backing Services | PostgreSQL, Redis |
| Observability | Prometheus, OpenTelemetry |
| Local Dev | Docker Compose, Minikube |
| Language | Python, YAML, Bicep, Bash |

---

## Repository Structure

```
.
├── CLAUDE.md                       # This file — Claude Code context
├── AGENTS.md                       # Agentic behavior guidelines
├── Makefile                        # Task automation shortcuts
├── .claude/
│   ├── settings.json               # Claude Code permissions
│   └── commands/                   # Custom slash commands (skills)
│       ├── deploy-local.md         # /deploy-local
│       ├── deploy-minikube.md      # /deploy-minikube
│       ├── deploy-aks.md           # /deploy-aks
│       ├── mcp-test.md             # /mcp-test
│       ├── k8s-debug.md            # /k8s-debug
│       └── resume-update.md        # /resume-update
├── .devcontainer/
│   └── devcontainer.json           # VS Code dev container (all tools pre-installed)
├── .vscode/
│   └── extensions.json             # Recommended extensions
├── infra/
│   ├── bicep/                      # Azure IaC
│   │   ├── main.bicep
│   │   ├── main.parameters.json
│   │   └── modules/                # aks.bicep, acr.bicep, keyvault.bicep, network.bicep
│   └── helm/                       # Helm values per environment
│       ├── values.yaml             # Base defaults
│       └── values.azure.yaml       # AKS-specific overrides
├── docs/
│   ├── learning-path.md            # Phase-by-phase progression
│   ├── resume-bullets.md           # Generated resume impact bullets
│   ├── runbooks/                   # Operational runbooks
│   └── architecture/               # Architecture diagrams and ADRs
└── scripts/
    ├── setup.sh                    # Local dev setup script
    └── test-mcp.sh                 # MCP endpoint smoke tests
```

---

## Learning Phases

| Phase | Focus | Status |
|---|---|---|
| 1 | Local Docker Compose — understand ContextForge fundamentals | ✅ |
| 2 | Minikube — deploy full Helm stack, learn k8s primitives | ✅ |
| 3 | AKS — deploy to Azure with Bicep IaC, production-grade config | ✅ |
| 4 | Federated MCP — register multiple MCP servers, RBAC + OAuth | ⬜ |
| 5 | Agent automation — A2A protocol, multi-agent orchestration | ⬜ |

---

## Common Commands

```bash
# ── Local Dev ───────────────────────
make up              # Start ContextForge via Docker Compose
make down            # Tear down
make logs            # Tail gateway logs
make test            # Smoke test MCP endpoints

# ── Minikube ────────────────────────
make minikube-start  # Start local k8s cluster
make helm-install    # Install chart to minikube
make helm-status     # Check release + pods

# ── Azure / AKS ─────────────────────
make az-login        # Authenticate to Azure
make bicep-deploy    # Deploy Azure infra via Bicep
make aks-creds       # Pull kubeconfig for AKS cluster
make helm-aks        # Deploy/upgrade to AKS
```

---

## Conventions

### Azure Resources
- All resources tagged: `environment`, `project=contextforge`, `owner=dfernandez`
- Resource group naming: `rg-contextforge-{env}`
- AKS cluster naming: `aks-contextforge-{env}`
- Primary region: `eastus`

### Bicep
- `@description()` decorator on every parameter
- Modular: one file per resource type under `infra/bicep/modules/`
- Use `existing` references — no hardcoded resource IDs
- Output resource IDs and endpoints, never secrets

### Helm
- Base values in `values.yaml`, environment overrides in `values.azure.yaml`
- Always set resource `requests` and `limits` on all containers
- Secrets via Azure Key Vault CSI driver — never literal values in values files
- Use `nameOverride` to keep release names predictable

### Git / Commits
- Conventional Commits: `feat:`, `fix:`, `docs:`, `chore:`, `infra:`
- Never commit `.env` files, `*.tfstate`, `kubeconfig`, or any credentials
- Branch naming: `feat/phase-2-minikube`, `fix/helm-postgres-pvc`

---

## MCP Gateway — Default Endpoints (local)

| Endpoint | URL |
|---|---|
| Admin UI | http://localhost:4444 |
| MCP (SSE) | http://localhost:4444/v1/ |
| Health | http://localhost:4444/health |
| Metrics | http://localhost:4444/metrics |
| Tools List | http://localhost:4444/v1/tools |

---

## What NOT To Do
- Never run `kubectl apply` raw manifests to AKS — use Helm
- Never use `latest` image tags in any Helm values for AKS
- Never modify upstream ContextForge source — override via Helm values only
- Never store secrets in environment variables unencrypted
- Never push directly to `main` — use PRs
