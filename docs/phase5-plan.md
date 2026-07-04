# Phase 5 Plan — Agent Automation

Drafted 2026-07-03, decisions confirmed 2026-07-04. Expands the Phase 5 outline in
`learning-path.md` into concrete sub-tasks, grounded in what's actually live: ContextForge at
`https://contextforge.gourmandtech.com`, 86 tools federated across 5 gateways, `sre-full`/
`dev-tools` virtual servers, Entra ID SSO, and a `Makefile` with no CI/CD targets yet (checked —
`.github/workflows/` doesn't exist).

**Confirmed decisions (2026-07-04):**
- **Agent runtime:** Claude Agent SDK for 5.1 (deepest native MCP integration, least boilerplate,
  fastest path to a working demo). LangGraph for 5.2's A2A delegation (explicit checkpointed
  state — the "what happens when a delegated call fails" problem is first-class there — and
  demonstrates the platform isn't locked to one model vendor).
- **CI/CD gating:** OIDC federated identity (no stored Azure secrets) scoped to a single resource
  group; PRs auto-run validate/lint/diff; the actual `bicep-deploy`/`helm-aks-secrets` step runs
  inside a GitHub Environment (`production`) with a required reviewer, so merge-to-main starts
  the pipeline but pauses for manual approval before touching Azure.
- **Code location:** new top-level `agents/` directory, kept separate from `services/` — the
  existing `services/` entries are things *registered into* ContextForge as MCP servers; the
  Phase 5 agent-runner is structurally the opposite, a *client* calling through the gateway.

**Goal:** A2A protocol + multi-agent orchestration + CI/CD, closing the loop from "gateway exists"
to "agents actually use it, and changes ship safely."

---

## 5.1 — Simple agent client against the gateway
**Goal:** Prove an agent can call federated tools through ContextForge, not just via `curl`.

- Build a minimal Python agent in `agents/sre-agent/` using the **Claude Agent SDK**, with an
  MCP server entry pointed at the gateway's SSE endpoint, authenticated via a scoped JWT (reuse
  `mcp-get-token` pattern, but issue a **team-scoped** token — not platform-admin — to actually
  exercise the RBAC boundary built in Phase 4).
- Pick a starter task that's genuinely useful for this project: e.g. "check AKS node pool health"
  or "summarize last 24h of Prometheus alerts" — something that chains 2-3 tools from `sre-full`.

## 5.2 — A2A: agent-to-agent delegation
**Goal:** One agent delegates a sub-task to another via the gateway, not via direct function call.

- ContextForge's A2A integration registers *agents* as a discoverable capability, structurally
  similar to how Phase 4 registered MCP *servers* — confirm this from
  `ibm.github.io/mcp-context-forge/latest/using/agents/a2a/` before assuming the pattern transfers
  1:1 from Step 4's gateway-registration Makefile targets.
- Minimal viable A2A demo: a "coordinator" agent (built on **LangGraph**, for its explicit
  checkpointed state — delegation failures should be a first-class, recoverable case, not an
  afterthought) receives a request and delegates a sub-task to the 5.1 Claude SDK agent as its
  "specialist," both routed through ContextForge so the delegation itself is observable in
  gateway logs/metrics. Lives in `agents/coordinator-agent/`.
- Open question: does A2A registration need its own workload identity / RBAC team, or does it
  ride on the existing `sre-team`? Decide after reading the actual A2A docs, not by assumption.

## 5.3 — CI/CD: GitHub Actions
**Goal:** Replace "run `make bicep-deploy` by hand" with a pipeline that catches regressions
before they reach AKS — directly relevant after this project's own history of drift incidents
(node-pool autoscaler reverts, IaC defaults silently overriding manual fixes).

- `.github/workflows/ci.yml`: on PR — `make lint` (already exists — lints Helm + Bicep), plus
  `helm-diff` against the live AKS release (target already exists: `make helm-diff`, currently
  minikube-only — needs an AKS-context variant) so reviewers see the actual diff, not just a
  green checkmark.
- `.github/workflows/deploy.yml`: on merge to `main` — auto-triggers `bicep-validate` →
  `bicep-deploy` → `helm-aks-secrets`, but the deploy job runs inside a GitHub **Environment**
  named `production` with a required reviewer, so the pipeline starts automatically but pauses
  for manual approval before it actually touches Azure. This is the confirmed pattern: automatic
  CI, deliberately gated CD — avoids both manual toil and the drift/outage risk already seen
  twice in this project's history (Phase 3/4 incident log in `CLAUDE.md`).
- Auth: Azure federated credential (OIDC) via `id-token: write` permission — no stored secret.
  Scope the app registration/role assignment to a single resource group
  (`rg-contextforge-dev`) to contain blast radius; set the federated credential's subject to
  `repo:<org>/<repo>:environment:production` so only runs targeting that Environment can mint a
  token. This is its own small Bicep/`az ad app` task, similar in shape to the Entra SSO app
  registration already done in Phase 4 Step 6.

## 5.4 — Observability tie-in (stretch)
**Goal:** OpenTelemetry is already in the project's stated tech stack but hasn't shown up in any
completed phase yet — Phase 5 is a natural place to close that gap.

- Instrument the Phase 5.1/5.2 agent(s) with OTel tracing, export to the Prometheus already
  deployed in-cluster (or a lightweight Tempo/Jaeger sidecar if traces don't fit Prometheus's
  model well — confirm before assuming Prometheus alone is sufficient for traces vs. metrics).
- This directly strengthens the resume story: "agent orchestration with distributed tracing,"
  not just "agents that call tools."

## 5.5 — Docs
- Runbook: `docs/runbooks/phase5-agent-automation.md`, same incident-log format as Phase 4's
  runbook (real bugs, root cause, fix — that format is what made the Phase 4 runbook valuable).
- `/resume-update` once 5.1–5.3 are live.

---

## Sequencing recommendation
5.1 → 5.2 → 5.3 → 5.4 (stretch). Reasoning: an agent that can't call the gateway (5.1) makes A2A
(5.2) meaningless to test; CI/CD (5.3) is independent of both and could run in parallel if you'd
rather context-switch, but doing it last means the new `agents/` directory (5.1/5.2) is also
covered by the same pipeline instead of being bolted on afterward.

## Remaining open question
Does A2A registration in ContextForge need its own workload identity / RBAC team, or can it ride
on the existing `sre-team`? Resolve by reading the live A2A docs
(`ibm.github.io/mcp-context-forge/using/agents/a2a/`) when starting 5.2 — don't assume.
