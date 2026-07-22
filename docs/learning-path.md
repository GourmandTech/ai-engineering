# Learning Path — IBM ContextForge MCP Gateway on AKS

## Phase 1: Local Docker Compose ✅ COMPLETE
**Goal:** Understand what ContextForge is before touching k8s.

Resources:
- [Quick Start](https://ibm.github.io/mcp-context-forge/latest/overview/quick_start/)
- [Docker Compose Deployment](https://ibm.github.io/mcp-context-forge/latest/deployment/compose/)

Tasks:
- [x] Clone IBM/mcp-context-forge
- [x] Run `make up`, explore Admin UI at http://localhost:4444
- [x] Register a sample MCP server through the UI
- [x] Call a tool through the federated endpoint
- [x] Read the architecture overview

Confirmed healthy 2026-06-26 (`make test` → `{"status":"healthy"}`). Full detail: `CLAUDE.md` Phase 1 section.

---

## Phase 2: Minikube ✅ COMPLETE
**Goal:** Get k8s reps, understand Helm chart structure.

Resources:
- [Minikube Deployment](https://ibm.github.io/mcp-context-forge/latest/deployment/minikube/)
- [Helm Chart Guide](https://ibm.github.io/mcp-context-forge/latest/deployment/helm/)

Tasks:
- [x] `make minikube-start`
- [x] Explore the Helm chart values (understand each key section)
- [x] `make helm-install` and verify pods come up healthy
- [x] Port-forward and run `/mcp-test` against Minikube
- [x] Use `/k8s-debug` to intentionally break and fix something

Confirmed 2026-06-29 on MacBook Pro M1 (profile `mcpgw`). Full detail + runbooks: `docs/runbooks/helm-install-minikube.md`, `docs/runbooks/minikube-devcontainer-dind.md`.

---

## Phase 3: Azure AKS ✅ COMPLETE
**Goal:** Production-grade deployment with Bicep IaC.

Resources:
- [Azure Deployment](https://ibm.github.io/mcp-context-forge/latest/deployment/azure/)
- [Scaling ContextForge](https://ibm.github.io/mcp-context-forge/latest/manage/scale/)

Tasks:
- [x] Write `infra/bicep/modules/aks.bicep`
- [x] Write `infra/bicep/modules/keyvault.bicep` for secrets
- [x] Write `infra/helm/values.azure.yaml` with AKS-specific overrides
- [x] `make bicep-deploy` → `make helm-aks`
- [x] Verify gateway is reachable via AKS LoadBalancer IP
- [x] Run `/resume-update`

Confirmed 2026-06-30 — live at `https://contextforge.gourmandtech.com` with valid Let's Encrypt TLS, TLSv1.3, HTTP/2, HSTS. 7 hard-won lessons documented in `docs/runbooks/aks-deploy.md` (immutable maxPods, LB SNAT asymmetry, migration Job deadlock, etc.).

---

## Phase 4: Federated MCP ✅ COMPLETE
**Goal:** Register multiple MCP servers, implement RBAC and OAuth.

Resources:
- [MCP Architecture Patterns](https://ibm.github.io/mcp-context-forge/latest/best-practices/mcp-architecture-patterns/)
- [RBAC Configuration](https://ibm.github.io/mcp-context-forge/latest/manage/rbac/)
- [Microsoft Entra ID SSO](https://ibm.github.io/mcp-context-forge/latest/manage/sso-microsoft-entra-id-tutorial/)

Tasks:
- [x] Register 3+ MCP servers behind the gateway — **5 registered**: SRE Toolbox (custom FastMCP), GitHub, Azure DevOps, Kubernetes, Prometheus. 86 tools federated total, verified exact match.
- [x] Configure RBAC: different teams get different tool access — `sre-team` (virtual server `sre-full`, all 86 tools) and `dev-team` (virtual server `dev-tools`, 62 tools: GitHub + Azure DevOps), scoped via `visibility: "team"` + `associated_tools`.
- [x] Set up Microsoft Entra ID (Azure AD) OIDC SSO — app `contextforge-sso` registered, SSO login confirmed end-to-end for non-colliding identities.
- [x] Test tool calls with scoped JWT tokens — live SSE handshake confirmed for a team-scoped, non-admin Entra user (`sretester@...`) added to `sre-team`.
- [x] Run `/resume-update`

Confirmed complete 2026-07-04, including end-to-end smoke test (health check, gateway list, tool list). Full runbook: `docs/runbooks/phase4-federated-mcp.md` (see its "Numbering scheme" section — the runbook's own Step 0-9 breakdown doesn't map 1:1 to this task list's 1-6). One confirmed upstream ContextForge bug found and documented (not patched, per project convention: never modify vendored `.contextforge/` source): admin-bypass 404 on `GET /servers/{id}` for team-visibility servers.

---

## Phase 5: Agent Automation 🔄 IN PROGRESS (5.1-5.3 done, 5.4 stretch pending)
**Goal:** A2A protocol, multi-agent orchestration, and CI/CD to close the loop on the whole platform.

Resources:
- [A2A Agent Integration](https://ibm.github.io/mcp-context-forge/latest/using/agents/a2a/)
- [LangGraph Integration](https://ibm.github.io/mcp-context-forge/latest/using/agents/langgraph/)
- [AutoGen Integration](https://ibm.github.io/mcp-context-forge/latest/using/agents/autogen/)

Tasks:
- [x] Build a simple agent that calls tools through ContextForge — `agents/sre-agent/` (Claude
  Agent SDK), team-scoped non-admin token against `sre-full`, chains kubernetes/prometheus/sre-toolbox
  tools for a real AKS+Prometheus health report.
- [x] Implement A2A: one agent delegates sub-tasks to another via the gateway — `agents/coordinator-agent/`
  (LangGraph) delegates to the sre-agent (deployed to AKS as a standing A2A endpoint) through
  ContextForge's A2A integration, verified end-to-end live.
- [x] Add GitHub Actions CI/CD: lint → helm diff → deploy on merge — `.github/workflows/ci.yml`
  (unguarded, Reader-only Azure OIDC) + `deploy.yml` (gated by a required-reviewer `production`
  GitHub Environment, Contributor+RBAC-Admin Azure OIDC, separate app registration from CI's).
- [x] Run `/resume-update`

Full write-up (architecture, every real bug hit and fixed): `docs/runbooks/phase5-agent-automation.md`.
Condensed status: `CLAUDE.md` Phase 5 section. Original plan: `docs/phase5-plan.md`.

**5.4 (stretch) — OTel tracing on the agents:** not started.

---

## Phase 6: Multi-Agent Orchestration, FinOps, Chaos Engineering 🔄 IN PROGRESS (6.1.1-6.1.2, 6.2.1-6.2.2, 6.3.1-6.3.2 done)
**Goal:** extend A2A delegation to real multi-specialist routing, add AI-assisted Azure cost
analysis, and stand up chaos-engineering readiness on the production cluster — three parallel
pillars designed together (`docs/phase6-plan.md`) and executed in waves (`docs/phase6-execution-plan.md`).

Resources:
- [A2A Agent Integration](https://ibm.github.io/mcp-context-forge/latest/using/agents/a2a/)
- [Azure Cost Management API](https://learn.microsoft.com/en-us/rest/api/cost-management/)
- [Chaos Mesh Documentation](https://chaos-mesh.org/docs/)

Tasks:
- [x] Add a second A2A specialist to prove the RBAC/A2A pattern generalizes — `agents/dev-agent/`
  (GitHub + Azure DevOps via `dev-tools`), registered team-scoped to `dev-team`; found and fixed a
  real two-layer cross-team RBAC gap (server-level team membership *and* a separate per-tool
  visibility check) before the coordinator could actually see it.
- [x] Build dynamic LangGraph routing across both specialists — `agents/coordinator-agent/coordinator.py`
  now chooses the correct specialist per task via a system prompt + native tool selection (not
  hardcoded branching), with an explicit fallback-to-other-specialist retry path on repeated failure;
  verified live with two different tasks correctly routed to two different agents in one run.
- [x] Build and deploy a FinOps MCP server — `services/cost-mcp-server/` exposes live Azure Cost
  Management data (by service, by resource, trend) via the project's first subscription-scope
  workload identity, confirmed necessary after an RG-scoped query was shown to miss ~91% of real
  spend (AKS node VMs live in the AKS-managed node resource group, not the app RG).
- [x] Install Chaos Mesh and prove an observe-only baseline drill — controller-only install (chart
  2.8.3, containerd runtime override, no dashboard) on the live AKS cluster with a data-driven
  CPU-headroom go/no-go check before and after, zero fault CRDs ever created; a health-fingerprint
  drill (`agents/sre-agent/baseline_drill.py`) proves the evaluation harness works before any future
  fault injection is allowed.
- [ ] 6.1.3 — multi-hop delegation (specialist → specialist) — not started.
- [ ] 6.1.4 — delegation-chain observability (A2A metrics, per-hop token cost) — not started.
- [ ] 6.2.3-6.2.4 — FinOps rightsizing agent, recommend-only — not started.
- [ ] 6.3.3+ — gated fault-injection drills (pod-kill, NetworkPolicy) — deliberately deferred, requires
  human approval on every run per the plan's own non-negotiable guardrails.
- [ ] Run `/resume-update`

Full write-up (every real bug/finding, including two real AI-agent trust incidents caught and
corrected during multi-agent delegation): `docs/runbooks/phase6-orchestration-finops-chaos.md`.
Design + execution plan: `docs/phase6-plan.md`, `docs/phase6-execution-plan.md`.
