# Phase 5 Plan — Agent Automation (draft, pending review)

Drafted 2026-07-03. Expands the Phase 5 outline in `learning-path.md` into concrete sub-tasks,
grounded in what's actually live: ContextForge at `https://contextforge.gourmandtech.com`, 86
tools federated across 5 gateways, `sre-full`/`dev-tools` virtual servers, Entra ID SSO, and a
`Makefile` with no CI/CD targets yet (checked — `.github/workflows/` doesn't exist).

**Goal:** A2A protocol + multi-agent orchestration + CI/CD, closing the loop from "gateway exists"
to "agents actually use it, and changes ship safely."

---

## 5.1 — Simple agent client against the gateway
**Goal:** Prove an agent can call federated tools through ContextForge, not just via `curl`.

- Build a minimal Python agent (`services/agent-runner/` or similar) using an MCP client SDK
  pointed at the gateway's SSE endpoint, authenticated via a scoped JWT (reuse `mcp-get-token`
  pattern, but issue a **team-scoped** token — not platform-admin — to actually exercise the
  RBAC boundary built in Phase 4).
- Pick a starter task that's genuinely useful for this project: e.g. "check AKS node pool health"
  or "summarize last 24h of Prometheus alerts" — something that chains 2-3 tools from `sre-full`.
- Decision needed: LangGraph vs. plain MCP client vs. Claude Agent SDK for the agent runtime.
  LangGraph is explicitly in the existing resource list; Claude Agent SDK matches your
  Claude Code/Cowork experience more directly. Worth a short spike of both before committing.

## 5.2 — A2A: agent-to-agent delegation
**Goal:** One agent delegates a sub-task to another via the gateway, not via direct function call.

- ContextForge's A2A integration registers *agents* as a discoverable capability, structurally
  similar to how Phase 4 registered MCP *servers* — confirm this from
  `ibm.github.io/mcp-context-forge/latest/using/agents/a2a/` before assuming the pattern transfers
  1:1 from Step 4's gateway-registration Makefile targets.
- Minimal viable A2A demo: a "coordinator" agent receives a request, delegates a sub-task to a
  "specialist" agent (e.g., coordinator handles user intent, specialist is the Kubernetes-tool
  agent from 5.1) — both routed through ContextForge, so the delegation itself is observable in
  gateway logs/metrics.
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
- `.github/workflows/deploy.yml`: on merge to `main` — `bicep-validate` → `bicep-deploy` →
  `helm-aks-secrets` (or `helm-aks`), gated behind a manual approval environment in GitHub (this
  is a personal Azure subscription — an accidental auto-deploy is a real cost/outage risk, not
  hypothetical, per the Phase 3/4 incident history already in `CLAUDE.md`).
- Secrets: GitHub Actions needs an Azure federated credential (OIDC) to run `az login` without a
  long-lived secret — this is its own small Bicep/`az ad app` task, similar in shape to the Entra
  SSO app registration already done in Phase 4 Step 6.
- Decision needed: does this repo's Azure subscription risk tolerance justify auto-deploy on
  merge at all, or should `deploy.yml` stay manually-triggered (`workflow_dispatch`) indefinitely?
  Given it's a personal/learning subscription, manual-trigger-with-CI-gates may be the more
  defensible answer for the resume story ("CI-gated, deliberately manual production deploy")
  than a fully automatic pipeline that risks a surprise Azure bill.

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
rather context-switch, but doing it last means the new agent-runner service (5.1/5.2) is also
covered by the same pipeline instead of being bolted on afterward.

## Open questions for you before implementation starts
1. LangGraph, plain MCP client, or Claude Agent SDK for the agent runtime (5.1)?
2. Auto-deploy on merge, or manual-trigger CI-gated deploy (5.3)?
3. Any preference on where the new agent code lives — `services/agent-runner/` alongside the
   existing MCP wrapper services, or a separate top-level `agents/` directory?
