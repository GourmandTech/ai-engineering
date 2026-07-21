# Phase 6 Plan — Multi-Agent Orchestration, FinOps, and Chaos Engineering

Drafted 2026-07-06 by three parallel design leads (a2a-lead, finops-lead, chaos-lead), each grounded
in what's actually live: ContextForge at `https://contextforge.gourmandtech.com`, 86 tools federated
across 5 gateways, `sre-full`/`dev-tools` virtual servers, Entra ID SSO, and Phase 5's real,
already-shipped agent stack — `agents/sre-agent/` (Claude Agent SDK, wrapped by `a2a_server.py` for
A2A reachability) delegated to by `agents/coordinator-agent/` (LangGraph), routed through a
single-tool `coordinator-delegate` virtual server, plus Phase 5.3's gated `production` GitHub
Environment (required-reviewer CI/CD) already proven end-to-end. **Phase 5 itself is still in
progress in parallel** (5.4 observability stretch not started) — this plan does not assume it's
finished, and 6.1 explicitly folds in the un-started 5.4 scope rather than duplicating it later.

Each lead worked independently against live infra (Azure CLI authenticated, `kubectl` context
live, real Cost Management queries, real cluster state), then cross-checked their integration
points against the other two leads' actual reports (not just speculation) before finishing. Where
that cross-check changed a conclusion, it's called out below.

**Confirmed decisions (cross-team, 2026-07-06):**

- **The A2A specialist-integration shape is standardized project-wide.** All three leads
  independently converged, without seeing each other's reports first, on the same pattern for
  turning any capability into an A2A-delegatable specialist: a dedicated per-workload identity
  (`id-<name>`, the Phase 4 Steps 2-3 pattern), a narrow virtual server scoped to exactly that
  agent's tools, attached via `associated_tools` (not `associated_a2a_agents` alone — the Phase 5.2
  gotcha, where the latter creates the tool row but doesn't expose it over SSE), and its own RBAC
  team rather than riding `sre-team`. Independent convergence across three separate design
  exercises is treated as real confirmation this generalizes, not coincidence.
- **FinOps is the one deviation from that pattern, and it's contained, not avoided.** The cost MCP
  server's workload identity needs `Cost Management Reader` at **subscription** scope — broader
  than every other per-workload identity in the project (all of which are RG- or resource-scoped).
  The RBAC boundary still holds: the virtual-server/team scoping controls who can *reach* the cost
  tools, not what the underlying identity can read. Widening one identity's read scope is judged
  acceptable; widening the tool-reachability boundary would not be.
- **Chaos injection must never be A2A-reachable by the coordinator — and this is a hard mechanics
  constraint, not just a safety preference.** ContextForge's A2A registration is per-endpoint: one
  `POST /a2a` = one agent = one auto-created `a2a_<name>` tool that opaquely forwards to whatever
  the underlying HTTP endpoint does. There is no per-tool ACL *inside* a single A2A registration, so
  "one chaos agent, coordinator only sees the observe subset" is not achievable as stated. The
  resolved design: **only** register an observe/evaluate endpoint as `a2a-chaos-observe` (safe for
  the coordinator's virtual server). The fault-injection endpoint is never A2A-registered at all —
  it's invoked only from the gated CI deploy job — so the coordinator model has no tool handle for
  it, full stop.
- **Node-count / node-pool-level chaos is banned outright, project-wide, in any phase.** Two real
  prior outages (Phase 3 CPU exhaustion, Phase 5.2 "Real bug #2" near-miss) already came from
  touching node count. This is now a standing invariant, not just a Phase 6.3 guardrail.
- **Cost guardrails during chaos drills must be operational/real-time, not Cost-Management-API-based.**
  Cost Management data lags 8-24h, so it cannot gate a same-day drill. Resolved split: the
  **inline** guardrail is the autoscaler node-count delta, observed live via the already-federated
  `kubernetes-mcp-*` tools (a scale-out event is treated as the real-time cost-impact proxy); the
  FinOps day-after dollar figure is a **non-blocking** retrospective confirmation only, never a gate.
- **Per-hop Claude API token cost and Azure infrastructure cost are two non-overlapping concerns.**
  Delegation-chain token spend (the SDK's own `ResultMessage.total_cost_usd`, the source of 5.2's
  measured $0.61/run) belongs to 6.1's delegation-chain observability work, especially once
  multi-hop delegation (6.1.3) makes per-hop spend non-obvious. Azure infra cost (VM/ACR/KV via the
  Cost Management API) is 6.2's remit. Neither lead needs to track the other's number.
- **FinOps cost queries must run at subscription scope, not resource-group scope.** Confirmed live:
  a query scoped to `rg-contextforge-dev` shows ~$1/mo and misses ~91% of real spend, because the
  AKS node VMs live in the AKS-managed `MC_rg-contextforge-dev_aks-contextforge-dev_eastus` node
  resource group, not the app RG. Any cost tooling built in 6.2 must default to subscription scope.
- **FinOps is a hybrid: a thin federated MCP server for the data, a standalone agent for the
  reasoning** — not an either/or. The cost server is read-only and shaped exactly like
  `services/sre-mcp-server/` (justified the same way Prometheus MCP was: read-only query access is
  a genuinely reusable tool). But the actual rightsizing argument ("this $148/mo compute line runs
  at <5% CPU") requires cost data and utilization data in the *same* agent context — utilization
  already lives behind the gateway via `kubernetes-mcp-*`/`prometheus-mcp-*` — so federating cost
  data is what lets one agent correlate both, the same reason Phase 4 federated Prometheus at all.
- **Chaos tooling is Chaos Mesh (in-cluster CRDs), not Azure Chaos Studio.** Chaos Studio's real
  strength is VM/zone/service-level control-plane faults — exactly the node-level class this
  project has just banned. The fault classes that are actually safe here (pod-kill,
  network-policy disruption) are Chaos Mesh's native domain, and it's self-hosted with no new Azure
  control-plane RBAC to reason about.
- **Every resource-mutating or fault-injecting action added in Phase 6 routes through the existing
  Phase 5.3 gated `production` GitHub Environment / required-reviewer pattern.** No new approval
  mechanism is invented for cost-driven rightsizing or chaos drills — reuse what's already proven
  end-to-end.

---

## 6.1 — A2A Multi-Agent Orchestration

**Goal:** extend Phase 5.2's proven one-coordinator/one-specialist delegation into real multi-agent
routing, without duplicating what 5.2 already shipped.

**Subsumption verdict:** genuine extension, not a duplicate, if scoped deliberately. Phase 5.2
proved exactly one thing — one coordinator delegating to one specialist through the gateway,
RBAC-scoped by a single-tool virtual server, with LangGraph retry-on-failure. Three real capability
gaps remain: **fan-out** (the coordinator has a fleet of one specialist today, so it never actually
*chooses* — delegation is a passthrough, not a decision), **multi-hop** (a specialist delegating to
another specialist — the live A2A docs are silent on whether this is even supported, making it the
empirical-discovery frontier in the Phase 4/5 tradition), and **cross-chain observability** (5.2
itself left an unresolved `a2aAgents.totalInteractions: 0` metrics gap, and Phase 5.4's OTel stretch
is confirmed not started — this folds that gap in rather than letting it sit unaddressed twice).

1. **Add a second specialist (`dev-agent`) to force real routing.** Scope it to the existing
   `dev-tools` virtual server (GitHub + Azure DevOps, 62 tools — no new gateway infra needed). New
   `id-dev-agent` workload identity, `POST /a2a` registration mirroring `a2a_server.py`. This is the
   cheapest possible way to prove the RBAC/A2A pattern generalizes N-ways before building anything
   novel: the `coordinator-delegate` server's `associated_tools` grows 1→2.
2. **Dynamic LangGraph routing across specialists.** Extend `coordinator.py`'s failure-handling edge
   (currently only re-prompts the same specialist, `a2a-sre-agent`) so it can route to a *different*
   specialist based on the task and fall back across specialists on failure. This is where
   LangGraph's checkpointed state — the reason it was chosen over a simpler orchestrator in 5.2 —
   actually gets exercised for the first time.
3. **Multi-hop delegation (specialist → specialist) — treat as empirical, sequence last.** Let
   `sre-agent` delegate a code-lookup sub-task to `dev-agent`. The live A2A docs don't confirm this
   works; expect Phase 4-style discovery of whether the gateway loops cleanly or auth re-entry
   breaks. Highest risk, highest learning value — do this only after fan-out (6.1.1) and routing
   (6.1.2) are both proven, not before.
4. **Delegation-chain observability (folds in the un-started 5.4 stretch).** Confirm
   `MCPGATEWAY_A2A_METRICS_ENABLED`, scrape the `a2aAgents` metrics block, add a Grafana panel
   (Grafana already live in the `monitoring` namespace) for per-agent execution count/success
   rate/response time, and specifically chase the 5.2 `totalInteractions: 0` gap. Track **per-hop
   Claude API token cost** here too (see cross-team decision above) — multi-hop (6.1.3) is what
   makes that spend non-obvious.
5. **Runbook:** `docs/runbooks/phase6-orchestration-finops-chaos.md`, same incident-log format as
   Phase 4/5 (real bugs, root cause, fix).

**Cross-checked mechanics constraint (resolved 2026-07-06):** whether chaos should ever be
A2A-delegated resolves to "yes for observe, never for inject" — but only as **two separate A2A
registrations**, since ContextForge's A2A model has no per-tool ACL inside one registration (see
cross-team decisions above). This is now a hard design constraint for 6.3's own A2A integration,
not just a preference.

**Open questions:**
- Does A2A-calls-A2A (multi-hop, 6.1.3) actually work? Not addressed in the live docs — must be
  discovered empirically.
- Does `POST /a2a` accept `team_id` directly? The live docs list `visibility` but don't list
  `team_id` as a first-class registration field, unlike gateway/server registration. Verify against
  the live `/openapi.json` before assuming the Phase 4 Step 7 team-scoping pattern transfers as-is.

---

## 6.2 — Azure Cost Optimization / FinOps Automation

**Goal:** AI-assisted cost analysis and rightsizing recommendations for the real, currently-billing
`rg-contextforge-dev` resources — recommend-only, never autonomous.

**Live grounding (queried 2026-07-06, subscription scope, month-to-date):**

| Service | MTD | ~Monthly | Share |
|---|---|---|---|
| Virtual Machines (AKS nodes) | $29.59 | ~$148 | ~91% |
| Virtual Network | $1.34 | ~$6.70 | |
| Log Analytics | $0.96 | ~$4.80 | |
| Storage | $0.17 | ~$0.90 | |
| Load Balancer / Key Vault / ACR | <$0.10 each | ~$0 | |

The one material cost lever is the AKS node pool (2× `Standard_D2s_v7`, autoscale floor `min=2`),
and it's running at **<5% cluster CPU** (`kubectl top`: 1-9m actual per pod vs. 50m requested)
against ~$148/mo. That tension — near-idle compute that's nonetheless a deliberate reliability floor
from two real single-node CPU-exhaustion incidents — is the entire FinOps story here.

**Verdict:** hybrid — federated MCP server for the data, standalone agent for the reasoning (see
cross-team decision above). The MCP server is built exactly like `services/sre-mcp-server/`
(Python FastMCP, native SSE, no wrapper — same class of decision as choosing Kubernetes/Prometheus
MCP's no-wrapper pattern in Phase 4), federated as a 6th gateway.

1. **Cost MCP server** — `services/cost-mcp-server/`, tools `cost_by_service`/`cost_by_resource`/
   `cost_trend`, hardcoded to subscription scope (the RG-scope gotcha above is a correctness
   requirement, not a nice-to-have). `make cost-mcp-build`/`deploy`, registered via
   `mcp-register-cost`.
2. **Workload identity** — `id-cost-mcp-server` via the existing `workload-identity.bicep` module,
   granted built-in `Cost Management Reader` at **subscription** scope. Flag this explicitly in the
   Bicep module's own comments as the widest-scoped identity in the project, contained by the
   virtual-server RBAC boundary (`finops-full` server, `finops-team`), not by narrowing the role
   itself.
3. **Rightsizing agent** — `agents/finops-agent/`, chains the new cost tools with the
   already-federated `kubernetes-mcp-*`/`prometheus-mcp-*` utilization tools in one context.
   Concrete, resource-specific recommendations, priority order:
   - **Node pool (the only material lever):** correlate VM spend against <5% CPU; recommend, in
     order, (a) a burstable B-series SKU (the idle profile is the textbook burstable case), (b) a
     Spot pool for non-critical MCP pods, (c) explicitly refuse to recommend `min<2` — encode the
     incident history as a hard guardrail the agent must respect, matching 6.1/6.3's node-count ban.
   - **ACR Standard→Basic:** 0.88 GB used of Basic's 10 GB quota, no Standard-tier features (webhooks/
     tokens/scope-maps) in use — low priority given ~$0 MTD, but flag as correct-but-unused capacity.
   - **Log Analytics / Key Vault:** no action recommended today (KV correctly sized; Log Analytics
     under $5/mo) — stated explicitly so the report shows discrimination, not blanket cost-cutting.
4. **Recommend-only, gated apply.** The agent produces a report/PR, never resizes anything itself.
   Any accepted rightsizing change is a Bicep param change (`nodeVmSize`, node pool SKU) that flows
   through the existing Phase 5.3 gated `deploy.yml` / `production` Environment — the min-2 incident
   is the exact cautionary tale for why this can never be autonomous.

**Cross-checked, resolved:**
- FinOps's broader (subscription-scope) identity does not require deviating from the standardized
  A2A specialist pattern — see cross-team decision above.
- A cost agent is useless for real-time chaos-drill correlation (8-24h data lag); its role there is
  a non-blocking day-after report, not an inline guardrail.

**Open questions:**
- Confirmed the *logged-in user* can query Cost Management live; did **not** confirm a *managed
  identity* can be granted `Cost Management Reader` at subscription scope on this specific
  sandbox subscription (some MCA/sandbox subscriptions restrict this) — verify before building the
  workload identity.
- Cost Management Query API rate limits/throttling weren't characterized — verify before building
  any polling loop into the agent.
- ACR showed $0 MTD for Standard tier's flat daily fee — confirm the real run-rate before claiming
  a Basic-downgrade saving as material.

---

## 6.3 — Chaos Engineering / Resilience Testing

**Goal:** fault-injection and incident-response drills against the AKS cluster that an agent can
drive and evaluate, without risking the production outages this exact cluster has already had.

**Live grounding (queried 2026-07-06):** 2 nodes, both `Ready`. Real finding: 4 of 5 MCP server
pods **plus the gateway itself** all sit on one node (`vmss000002`); postgres/redis/sre-agent sit on
the other. Losing that one node is a near-total outage of the serving path, not a partial-degradation
test. All 8 expected NetworkPolicies (postgres, redis, 5 MCP servers, sre-agent) are present.

**Safety verdict:** do **not** let an agent autonomously drive fault injection here. This is a
single-node-pool, personal-subscription **production** cluster (real Let's Encrypt TLS, real
traffic), with zero blast-radius isolation and no staging peer. Its own incident history sets the
guardrails, not abstract best practice:

- **Node-count/node-level chaos is off the table entirely** — two real prior outages already came
  from touching node count (Phase 3 CPU exhaustion; Phase 5.2's near-miss `count: 2→1`). Given the
  uneven pod scheduling found above, draining the busy node isn't a graceful-degradation test, it's
  a self-inflicted repeat of the same incident.
- **NetworkPolicy egress is the one surface worth deliberately exercising** — it's already broken
  twice *by accident* (Phase 4 Kubernetes MCP apiserver egress, Phase 5.2 sre-agent port-4444
  egress), so it's proven-fragile and directly relevant, precisely why any test of it must be
  tightly scoped and auto-reverting.

**Non-negotiable guardrails:**
1. Human approval on every fault-injecting run, reusing the Phase 5.3 gated `production` Environment
   pattern exactly. Observe-only drills may run unattended.
2. Pod-scoped only — allowlist the 5 MCP pods + `sre-agent`; explicitly exclude the gateway,
   postgres, redis, cert-manager, ingress-nginx, and all nodes/node-pool/load-balancer resources.
3. Node count, autoscaler settings, and `min=2` are never touched — an explicit deny, consistent
   with the project-wide ban above.
4. Every fault is bounded (≤60s) and auto-reverting; a dead-man's-switch aborts (deletes the chaos
   CR) if gateway `/health` goes non-200 for >30s.
5. A live usage check (recent tool executions via gateway `/metrics`) aborts a drill if the system
   is actively serving — cheap and sufficient given the owner is the sole real user.
6. One fault at a time, serialized — no compound/parallel chaos.

1. **Tooling: Chaos Mesh, not Azure Chaos Studio** (see cross-team decision above) —
   namespace-scoped `PodChaos`/`NetworkChaos` CRDs fit the pod/network fault classes that are
   actually safe here.
2. **Observe-only baseline, no faults.** An agent drill reads steady-state (gateway `/health`,
   `/metrics`, Prometheus-MCP queries) and records a healthy fingerprint — prove evaluation works
   before anything is allowed to break.
3. **Pod-kill drill on a single non-critical MCP pod** (e.g. `github-mcp-server`). Agent verifies
   the gateway marks that gateway `reachable: false`/degrades gracefully while the other 4 keep
   serving, and the pod self-recovers within the bounded window.
4. **NetworkPolicy fault-injection drill.** Deliberately re-exercises the exact egress path that
   broke twice by accident (delay/partition on one MCP pod's egress) — validates the failure surfaces
   cleanly (a clear error) rather than hanging (the Phase 5.2 `status: pending` forever symptom).
5. **Agent evaluation harness — reuses existing federated tools, no new cluster access.**
   `kubernetes-mcp-*` (pod state, restart counts) + `prometheus-mcp-*` (alerts/metrics) + gateway
   `/health`/`/metrics`, all already live via `sre-full`. Pass/fail = other services stayed healthy
   AND the target auto-recovered within N seconds.
6. **Game-day runbook** (`docs/runbooks/phase6-orchestration-finops-chaos.md`, same file as 6.1/6.2
   incident logs) documenting each drill's abort conditions, deny-list, and human-gate procedure.

**Cross-checked, resolved:**
- The coordinator may only ever reach an `a2a-chaos-observe` registration; the fault-injection path
  is never A2A-registered at all, invoked only from the gated CI job — closes the mechanics gap
  6.1 flagged (see cross-team decision above).
- The cost-budget guardrail originally proposed for chaos drills is reframed: the inline,
  drill-time guardrail is the autoscaler node-count delta observed live via `kubernetes-mcp`
  (a scale-out event is the real-time cost-impact proxy); FinOps's actual dollar figure is a
  separate, non-blocking day-after confirmation only, given the 8-24h Cost Management data lag.

**Open questions:**
- Does Chaos Mesh's own DaemonSet (running on both nodes) add enough CPU pressure to risk
  re-triggering the historical CPU-exhaustion failure mode? Needs a resource-request check before
  install.
- The uneven pod scheduling found above (gateway + 4 MCP servers on one node) is a pre-existing
  resilience gap independent of chaos testing — should 6.3 add pod anti-affinity/topology spread as
  a fix *before* testing, or deliberately test-and-reveal it first as the first real drill finding?
- Can the dead-man's-switch reliably delete a chaos CR faster than a `NetworkChaos` partition would
  sever the agent's own path back to the gateway (a partition could theoretically block its own
  abort signal)?

---

## Cross-pillar integration summary

| Pillar | Becomes an A2A specialist? | Identity scope | Coordinator-reachable? |
|---|---|---|---|
| 6.1 (`dev-agent`) | Yes — the point of 6.1.1 | RG-scoped, per-workload (standard pattern) | Yes |
| 6.2 (`finops-agent`) | Yes — recommend-only | **Subscription-scoped** Cost Management Reader (the one deviation) | Yes — read-only recommendations only, no apply capability exposed |
| 6.3 (chaos) | Split in two | RG-scoped, per-workload | **Observe only** (`a2a-chaos-observe`); injection is never A2A-registered |

All three independently converged on the same base integration shape (per-workload identity +
narrow virtual server + `associated_tools`), which is treated as validation that this is the
project's standard way any future specialist joins A2A — not something to re-litigate per pillar.

---

## Sequencing recommendation

1. **6.1.1** (second specialist, `dev-agent`) first — cheapest proof the RBAC/A2A pattern
   generalizes, no dependency on anything else in this phase.
2. **6.2.1 → 6.2.2** (cost MCP server + its identity) and **6.3.1 → 6.3.2** (Chaos Mesh install +
   observe-only baseline) can run in parallel with each other and with 6.1.2 — none of these three
   blocks the others.
3. **6.1.2** (dynamic routing) before **6.3.3+** (fault-injection drills) — chaos's own
   `a2a-chaos-observe` integration reuses the exact pattern 6.1.1/6.1.2 prove out first.
4. **6.3.3 → 6.3.5** (fault injection, gated) and **6.2.3 → 6.2.4** (rightsizing agent, gated apply)
   next — both are the "prove the guardrailed-apply pattern actually holds under a real gate" steps
   for their respective pillars.
5. **6.1.3** (multi-hop delegation) last among the A2A work — highest risk, highest empirical
   uncertainty (the docs don't confirm it's even supported), so it should follow every other pattern
   being proven rather than lead them.
6. **6.1.4** (delegation-chain observability, including per-hop token cost) closes out 6.1 — most
   valuable once there's an actual multi-hop chain to observe.
7. **Runbook** (shared file, incident-log format) written incrementally alongside each sub-phase,
   not batched at the end — matches the Phase 4/5 convention of documenting bugs as they're found.

## Remaining open questions (carried from all three leads)

- Does A2A-to-A2A delegation (multi-hop, 6.1.3) actually work in ContextForge? Not addressed in the
  live docs — first real thing to discover empirically when 6.1.3 starts.
- Does `POST /a2a` accept `team_id` directly, the way gateway/server registration does? Verify
  against the live `/openapi.json` before assuming Phase 4 Step 7's team-scoping pattern transfers.
- Can a managed identity actually be granted `Cost Management Reader` at subscription scope on this
  specific sandbox subscription? Confirmed only that the logged-in user can query; not confirmed for
  a service principal / workload identity.
- Cost Management Query API rate limits weren't characterized — needed before building any polling
  logic into the FinOps agent.
- Should 6.3 fix the discovered pod-scheduling imbalance (gateway + 4/5 MCP pods co-located on one
  node) before or as a result of chaos testing?
- Whether the chaos dead-man's-switch can outrace a `NetworkChaos` partition that severs its own
  path back to the gateway — needs an empirical test of the abort mechanism itself before trusting
  it as a guardrail.
