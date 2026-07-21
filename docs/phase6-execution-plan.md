# Phase 6 Execution Plan — Waves, Prompts, and Rule Changes

Drafted 2026-07-06 by the planning session (outside the `claude` CLI), to hand `docs/phase6-plan.md`
to a Claude Code agent team for execution. Read `docs/phase6-plan.md` first — this document assumes
its sub-phase numbering (6.1/6.2/6.3) and cross-team decisions as given.

Two things this document does that the plan itself couldn't: closes several of the plan's own "verify
before building" open questions via desk research against the vendored ContextForge source
(`.contextforge/`) and public Azure docs, so the execution waves don't re-discover them; and sequences
the actual `claude` CLI sessions — which waves are solo, which are real agent teams, and which single
steps still need a human click no matter how "hands-off" the rest is.

---

## Research: open questions resolved before execution starts

### Resolved — `POST /a2a` accepts `team_id` directly (6.1's open question #2)

Confirmed at the code level, not just the docs. `mcpgateway/main.py:4785-4859` — the `create_a2a_agent`
handler takes `team_id` and `visibility` as top-level `Body(...)` fields, validates token/team
ownership, then passes `team_id=team_id, visibility=visibility` straight into
`A2AAgentService.register_agent()` (`mcpgateway/services/a2a_service.py:617-629`, which has `team_id`
and `visibility` as named params). This is exactly the Phase 4 Step 7 gateway/server team-scoping
pattern — no deviation. Use it as-is when registering `dev-agent` in 6.1.1.

### Resolved (with nuance) — multi-hop A2A delegation is architecturally supported (6.1.3's open question)

`a2a_service.py:2037-2079` implements a real, designed **federation hop-count guard**: every outbound
A2A call stamps an `X-Contextforge-UAID-Hop` header, and calls at or above
`settings.uaid_max_federation_hops` are rejected. The docstring is explicit that this exists to break
"A→B→A style federation ping-pong" and self-referential endpoint loops — meaning the gateway
anticipates multi-hop chains as a first-class scenario, not an edge case nobody thought about.

The nuance: that guard is built for *cross-gateway* federation (this ContextForge instance federating
agents from a peer ContextForge instance), which isn't this project's topology — there's one gateway.
For 6.1.3's actual scenario (sre-agent, itself an A2A specialist, delegating to dev-agent through the
*same* gateway), no code-level block was found. Mechanically it's an ordinary nested tool call: if
`a2a-dev-agent` is included in the `associated_tools` of whatever virtual server sre-agent's own
outbound MCP client is scoped to, sre-agent's Claude SDK client can call it exactly like any other
federated tool. The real open item going into 6.1.3 isn't "does the protocol allow this" (it does) —
it's "is sre-agent's own JWT scoped to a virtual server that includes `a2a-dev-agent`," which is a
five-minute token/virtual-server config check, not a research risk. Downgrade 6.1.3 from "high risk,
might not work" to "config task, verify with one live call."

### Resolved — Cost Management Query API rate limits (6.2's open question)

Documented limits: **4 calls/minute per scope, 20 calls/minute per tenant, 2000 calls/minute per
`ClientType`** ([Microsoft Q&A](https://learn.microsoft.com/en-us/answers/questions/1340993/exception-429-too-many-requests-for-azure-cost-man),
[Azure/azure-rest-api-specs#24407](https://github.com/Azure/azure-rest-api-specs/issues/24407)).
Requests without a `ClientType` header share one pooled allowance with every other caller who also
omits it — so `services/cost-mcp-server/` must set a distinct `ClientType` header and must not poll
more than ~4x/minute per queried scope. Design implication for 6.2.1: the `cost_by_service`/
`cost_by_resource`/`cost_trend` tools should cache results (Cost Management data itself only refreshes
every 8-24h per the plan's own finding, so aggressive caching costs nothing in freshness) rather than
querying live on every agent call.

### Not resolvable by desk research — verify live, first thing in Wave 0

Two items only a live check against this actual subscription/registry can answer:

- **Can a managed identity be granted `Cost Management Reader` at subscription scope on this specific
  subscription?** General Azure docs confirm role assignment to service principals/managed identities
  at subscription scope is a supported, common pattern (including for Enterprise Agreement scenarios),
  and found no documented restriction specific to MCA or sandbox subscription types. No blocker found,
  but this is the one item where "no documented restriction" isn't the same as "confirmed works here."
  One `az role assignment create` + one query is the actual test.
- **ACR Standard tier's flat daily fee** — Azure's public pricing page renders prices client-side via
  JavaScript; the raw fetch returned blank placeholders, so the exact figure couldn't be confirmed by
  static fetch. Low-stakes either way (the plan already scores this "~$0 MTD, low priority") — pull it
  from `az acr show-usage` or the actual bill during 6.2.3 rather than blocking on it now.

---

## Rule changes — what changes, what doesn't, and why

`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` is already set in `.claude/settings.json`. Two more changes are
needed for the waves below to run with minimal interruption, plus one thing that deliberately does
**not** change.

**1. Scope the `git push` deny to protect only `main`, not every push.** Every wave below works on
feature branches and opens PRs — the current blanket `"Bash(git push:*)"` deny would stop that
entirely. Replace it with a deny targeted at the branch that actually needs protecting:

```json
"deny": [
  "Bash(git push origin main:*)",
  "Bash(git push origin main)",
  "Bash(git push --force:*)",
  "Bash(git push -f:*)"
]
```

and drop the old blanket `"Bash(git push:*)"` line. The **real** backstop for `main` is GitHub branch
protection (already relied on by Phase 5.3's whole gated-CD design) — confirm "Require a pull request
before merging" is still enabled on `main` before Wave 1 starts; that setting, not this file, is what
actually makes a direct push to `main` impossible even if a local deny rule were misconfigured.

**2. Add allow entries for the new read-only/build commands each wave needs**, following this
project's existing convention of allow-listing specific `make` targets and specific read-only `az`/
`kubectl` verbs rather than loosening whole command families:

```json
"allow": [
  "Bash(az costmanagement query:*)",
  "Bash(az acr show-usage:*)",
  "Bash(az role assignment list:*)",
  "Bash(kubectl get:*)",
  "Bash(make dev-agent-build)",
  "Bash(make dev-agent-deploy)",
  "Bash(make mcp-register-dev-agent)",
  "Bash(make cost-mcp-build)",
  "Bash(make cost-mcp-deploy)",
  "Bash(make mcp-register-cost)",
  "Bash(make finops-agent-build)",
  "Bash(make finops-agent-deploy)",
  "Bash(make chaos-mesh-install)",
  "Bash(make chaos-mesh-uninstall)",
  "Bash(make cost-mcp-identity-check)"
]
```

(`kubectl get:*` is already allowed — listed again only because it's load-bearing for every observe-only
step in 6.3.) Add each new `make <target>` line only once that target actually exists in the Makefile —
the agent team creates the targets in Wave 2/3 before those specific lines do anything.

**3. Deliberately NOT changed: `az * create:*`, `az role assignment create:*`, `helm install:*`/
`upgrade:*`, `kubectl apply:*`, and no allow-listing of `make bicep-deploy` / `make helm-aks-secrets`.**
This is the actual floor under "hands-off." Every one of these is either how the project already
routes mutating changes through the gated `production` GitHub Environment (Phase 5.3), or is a
one-time bootstrap step (`make chaos-mesh-install` wraps a Helm install of Chaos Mesh's controller —
allow-listing the Makefile target, not raw `helm install`, keeps the "never run raw Helm against AKS"
convention intact). The plan itself insists on this floor — chaos guardrail #1 ("human approval on
every fault-injecting run") and the cost guardrail ("recommend-only, gated apply") aren't limitations
this document is adding, they're Phase 6's own design. Expect a permission prompt at exactly those
points in Waves 2 and 3 below; that's correct behavior, not a bug in the setup.

---

## Execution waves

Each wave is a separate `claude` session (or a `/clear` in the same terminal) — don't chain them in
one long session, since teammates don't persist across `/resume` reliably yet (a documented Agent
Teams limitation) and each wave's prompt is written to be self-contained anyway. Paste the prompt,
let it run to completion, review its report, then move to the next wave's prompt.

### Wave 0 — the two live-only checks (solo session, no team)

```
Read CLAUDE.md and docs/phase6-plan.md and docs/phase6-execution-plan.md for context. Before any
Phase 6 build work starts, resolve the two open questions that desk research couldn't answer:

1. Can a managed identity be granted "Cost Management Reader" at subscription scope on this
   subscription? Create a throwaway test: check whether the role definition is assignable at
   subscription scope here (az role definition list, az role assignment list to see existing patterns),
   and if safe, do a real assignment test against a disposable identity or confirm via
   `az role assignment create --help`/a dry-run equivalent. Do not create any real production
   workload identity yet — this is a feasibility check only.
2. Confirm ACR's actual current Standard-tier cost via `az acr show-usage` and/or the real billing
   data already used to build the Phase 6 cost table, rather than the public pricing page (its prices
   are JS-rendered and couldn't be confirmed by static fetch).

Report both findings plainly: yes/no/blocked, with the actual command output. Do not proceed to
building anything in this session — this is a verification-only pass.
```

### Wave 1 — 6.1.1 second specialist (solo session, no team)

Nothing to parallelize yet; everything downstream depends on this proving the pattern generalizes.

```
Read CLAUDE.md and docs/phase6-plan.md for context, and docs/phase6-execution-plan.md's "Resolved —
POST /a2a accepts team_id directly" note before you start — that question is already answered, don't
re-derive it.

Implement Phase 6.1.1: add a second A2A specialist, dev-agent, scoped to the existing dev-tools
virtual server (GitHub + Azure DevOps, 62 tools, no new gateway infra needed). Follow the exact
pattern from agents/sre-agent/a2a_server.py and the Phase 4 Steps 2-3 workload-identity convention:
a new id-dev-agent identity via infra/bicep/modules/workload-identity.bicep, a new
agents/dev-agent/a2a_server.py wrapping a Claude Agent SDK client scoped to dev-tools, new Makefile
targets dev-agent-build/dev-agent-deploy/mcp-register-dev-agent mirroring sre-agent's, and register
it via POST /a2a with team_id set to dev-team (not sre-team) and associated_tools on
coordinator-delegate updated to include the new a2a-dev-agent tool (remember Phase 5.2's real bug #1:
associated_a2a_agents alone does not expose the tool over SSE — associated_tools must be updated too).

Verify live: the gateway's tool list actually includes a2a-dev-agent, and the coordinator can invoke
it and get a real response back — not just that the registration call returned 201. Open a PR, don't
push to main directly. Update docs/runbooks/phase6-orchestration-finops-chaos.md with what you find,
same incident-log format as the Phase 4/5 runbooks — real bugs, root cause, fix, even if nothing goes
wrong (say so explicitly if so).
```

### Wave 2 — the real team: three independent pillars in parallel

This is the one place Agent Teams earns its overhead — three genuinely independent workstreams,
none blocking the others per the plan's own sequencing section.

```
Read CLAUDE.md, docs/phase6-plan.md, and docs/phase6-execution-plan.md fully before spawning anyone —
in particular the "Resolved" research notes above (POST /a2a team_id, the Cost Management rate-limit
numbers, the multi-hop nuance) so your teammates don't waste time re-discovering what's already known.

Spawn 3 teammates to work in parallel — confirmed independent by the Phase 6 plan's own sequencing
section, none blocks the others:

- "routing-lead": Phase 6.1.2 — dynamic LangGraph routing in agents/coordinator-agent/coordinator.py.
  Extend the failure-handling edge (currently only re-prompts the same specialist, a2a-sre-agent) so
  it can choose between a2a-sre-agent and the new a2a-dev-agent based on the task, and fall back
  across specialists on failure. Verify live: send a task that should route to dev-agent and confirm
  it actually does, not just that sre-agent handles everything by default.

- "cost-lead": Phase 6.2.1-6.2.2 — build services/cost-mcp-server/ (Python FastMCP, native SSE, no
  wrapper — same shape as services/sre-mcp-server/), tools cost_by_service/cost_by_resource/
  cost_trend, hardcoded to subscription scope (not resource-group scope — confirmed in the Phase 6
  plan that RG scope misses ~91% of real spend). Respect the confirmed rate limits: max ~4 calls/min
  per queried scope, set a distinct ClientType header, cache aggressively since Cost Management data
  itself only refreshes every 8-24h. New id-cost-mcp-server identity via workload-identity.bicep
  granted Cost Management Reader at subscription scope — flag in the Bicep module's own comments that
  this is the widest-scoped identity in the project, per the Phase 6 plan's own design note. Require
  plan approval before implementing the Bicep/identity portion specifically — show me the identity
  scope before creating it.

- "chaos-lead": Phase 6.3.1-6.3.2 — install Chaos Mesh via a new make chaos-mesh-install target
  (wraps a Helm install, following the same pattern as make cluster-bootstrap for nginx-ingress/
  cert-manager — don't run raw helm install). Then build the observe-only baseline: an agent drill
  that reads gateway /health, /metrics, and Prometheus-MCP queries and records a healthy fingerprint.
  No fault injection in this wave — that's gated to a later wave. Require plan approval before
  implementing — this touches the production cluster's namespace list even in observe-only mode.

Each teammate works in their own new directory/files (services/cost-mcp-server/,
agents/dev-agent/ already done in Wave 1, chaos manifests under infra/) — no shared file edits except
the Makefile. Have each teammate report back the exact Makefile target lines they need rather than
editing the Makefile directly; you (the lead) append them yourself to avoid three teammates editing
the same file. Each teammate opens their own PR. Update
docs/runbooks/phase6-orchestration-finops-chaos.md incrementally as each teammate finishes, not
batched at the end.
```

### Wave 3 — team of two: the gated-apply steps

Both are "prove the guardrail holds under a real gate" steps — independent of each other.

```
Read CLAUDE.md, docs/phase6-plan.md, and docs/phase6-execution-plan.md. Confirm Wave 2's PRs have
merged before starting — this wave builds on cost-mcp-server, dev-agent, and the Chaos Mesh
observe-only baseline all being live.

Spawn 2 teammates:

- "finops-lead": Phase 6.2.3-6.2.4 — build agents/finops-agent/, chaining the new cost tools with the
  already-federated kubernetes-mcp-*/prometheus-mcp-* utilization tools in one context. Produce
  resource-specific rightsizing recommendations in this priority order: (1) node pool — correlate VM
  spend against the confirmed <5% CPU utilization, recommend a burstable B-series SKU first, a Spot
  pool for non-critical MCP pods second, and explicitly refuse to ever recommend min<2 on the
  autoscaler — encode the Phase 3/5.2 incident history as a hard rule the agent must not cross, the
  same node-count ban as 6.1/6.3; (2) ACR Standard-to-Basic downgrade, flagged low-priority; (3) no
  action on Log Analytics/Key Vault, stated explicitly. The agent's output is a report/PR only — it
  never resizes anything itself. Require plan approval before writing any code that could apply a
  change automatically; the deliverable is recommend-only by design, confirm your implementation
  actually enforces that before reporting done.

- "drill-lead": Phase 6.3.3-6.3.5 — the actual fault-injection drills. Non-negotiable guardrails from
  the Phase 6 plan, all must be implemented, not just described: human approval gate on every
  fault-injecting run via the existing production Environment; pod-scoped allowlist limited to the 5
  MCP pods + sre-agent, explicitly excluding the gateway/postgres/redis/cert-manager/ingress-nginx/any
  node or node-pool resource; every fault bounded to 60 seconds and auto-reverting; a dead-man's-switch
  that deletes the chaos CR if gateway /health is non-200 for more than 30 seconds; a pre-drill check
  against gateway /metrics that aborts if the system is actively serving; one fault at a time, never
  compound/parallel. Before running the actual pod-kill or NetworkPolicy drill against production,
  first test the dead-man's-switch itself in isolation — trigger a synthetic non-200 /health condition
  (not a real chaos fault) and confirm the abort logic actually deletes the CR within the bounded
  window. Only after that passes, run the real pod-kill drill on a single non-critical MCP pod
  (e.g. github-mcp-server), then the NetworkPolicy fault-injection drill re-exercising the exact
  egress path that broke twice by accident in Phase 4/5.2. Require plan approval before the first
  real fault-injecting run against production, no exceptions.

Update docs/runbooks/phase6-orchestration-finops-chaos.md incrementally, each teammate documenting
their own drills/reports as they go.
```

### Wave 4 — 6.1.3 multi-hop delegation (solo, highest empirical risk)

```
Read CLAUDE.md, docs/phase6-plan.md, and docs/phase6-execution-plan.md's "Resolved (with nuance) —
multi-hop A2A delegation" note before starting — the protocol-level question is already answered
(the gateway's uaid_max_federation_hops guard confirms multi-hop is a designed scenario, not an
unknown), so don't re-investigate that. What's actually unverified: whether sre-agent's own JWT/
virtual-server scope currently includes the a2a-dev-agent tool. Check first, widen the scope if not,
then have sre-agent delegate a real code-lookup sub-task to dev-agent through the gateway (not a
direct function call) and confirm the round trip actually works end to end. If it doesn't, the
mcpgateway/services/a2a_service.py invoke path (search for how create_a2a_agent's registered agents
get invoked) is the right place to look for why, not a black-box retry loop. Document the outcome
either way in docs/runbooks/phase6-orchestration-finops-chaos.md.
```

### Wave 5 — 6.1.4 delegation-chain observability, closing out 6.1 (solo)

```
Read CLAUDE.md and docs/phase6-plan.md. Implement 6.1.4: confirm MCPGATEWAY_A2A_METRICS_ENABLED,
scrape the a2aAgents metrics block, add a Grafana panel (Grafana is already live in the monitoring
namespace) for per-agent execution count/success rate/response time. Specifically chase the Phase 5.2
gap where totalInteractions read 0 despite confirmed-successful calls in the gateway logs — find out
whether it's fixed now that there's real multi-hop traffic, or root-cause it if not. Also add per-hop
Claude API token cost tracking (the SDK's ResultMessage.total_cost_usd, the source of 5.2's measured
$0.61/run) — this is the first point in the project where per-hop spend across a delegation chain
actually matters. Close out docs/runbooks/phase6-orchestration-finops-chaos.md's 6.1 section.
```

### Wave 6 — final verification (solo, deliberately not the same agent that built anything)

This is the pass that matters most given the production stakes — a skeptic, not a builder.

```
Read CLAUDE.md, docs/phase6-plan.md, and docs/phase6-execution-plan.md in full, plus
docs/runbooks/phase6-orchestration-finops-chaos.md as written by the previous waves. You did not
build any of Phase 6 — your job is to verify it, the same skepticism this project applied to its own
"Cross-checked, resolved" claims during planning.

Go through every "Cross-checked, resolved" line and every "Open questions" line in docs/phase6-plan.md
and confirm each was actually closed with a live check, not just assumed closed because code exists.
Specifically:

- 6.1: does dynamic routing actually choose between both specialists (send two different tasks, confirm
  different specialists handle them), not silently default to one? Did multi-hop delegation actually
  get exercised end to end, and is the outcome (worked / didn't, and why) documented? Is
  a2aAgents.totalInteractions actually incrementing now?
- 6.2: is the rightsizing agent's output actually a report/PR with zero auto-apply code path? Does any
  code path anywhere accept min<2 on the node pool autoscaler — grep for it, don't just read the
  agent's own claims. Was the managed identity's Cost Management Reader access actually confirmed live
  (Wave 0), not just assumed to work from general docs?
- 6.3: run the dead-man's-switch test again yourself if the drill-lead's own report is the only
  evidence it works. Confirm the pod-kill and NetworkPolicy drills' pass/fail criteria were actually
  met (other services stayed healthy, target auto-recovered) with real timestamps/logs, not narrative
  claims. Confirm node-count/autoscaler settings were genuinely never touched by grepping the actual
  drill code for any node-pool-scoped API call.
- Cross-cutting: confirm every PR actually went through the production Environment gate rather than
  being merged around it, and that main's branch protection is still intact.

Produce a plain pass/fail report per item, not a summary that assumes good faith. Anything that fails
gets flagged, not silently fixed by you — this session verifies, it doesn't patch.
```

---

## What still needs your click, wave by wave

Wave 0: none (read-only).
Wave 1: approve the PR merge.
Wave 2: approve each teammate's plan (cost identity scope, chaos cluster access) before it implements;
approve each PR merge.
Wave 3: approve both teammates' plans; the actual fault-injection runs prompt for the production
Environment's required reviewer — that's you, deliberately, per the plan's own non-negotiable
guardrail; approve each PR merge.
Wave 4-5: approve PR merges.
Wave 6: read the pass/fail report. Anything marked "fail" goes back to a targeted fix, not a new full
wave.

Everything else — research, building, self-testing, drilling, writing the runbook — is the agents'.
