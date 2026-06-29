# AI Engineering — Claude Code Context

## Mission
Personal SRE/DevOps learning platform. Goal: demonstrate self-advancement in AI-assisted engineering, agentic coding, and AI automation for job placement. Core background: Microsoft Azure, Azure DevOps, Bicep. Expanding into: AI/ML Ops, agentic infrastructure, federated MCP.

## Current State (updated 2026-06-29)

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

### Phase 3 — NEXT ⬜ (AKS)
Deploy to Azure with Bicep IaC. Re-enable the migration Job and `ServiceMonitor` where the platform provides a Prometheus Operator and externally-managed Postgres; restore TLS/HTTPS at the ingress. AKS overrides live in `infra/helm/values.azure.yaml`.

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
| 3 | AKS — deploy to Azure with Bicep IaC, production-grade config | ⬜ |
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
