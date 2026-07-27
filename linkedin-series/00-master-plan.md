# ContextForge AI Engineering — LinkedIn Series Master Plan

**Owner:** David Fernandez
**Source material:** `CLAUDE.md`, `docs/phase4-plan.md` / `phase5-plan.md` / `phase6-plan.md`, `docs/runbooks/*`
**Status:** Draft plan — pending approval to begin Phase 1

## Goal

Make the ContextForge-on-AKS project (Phases 1-6: local Docker Compose → Minikube → AKS →
federated MCP → agentic automation → multi-agent orchestration/FinOps/chaos) visible to engineering
recruiters and hiring managers on LinkedIn, in a way that:

- Reads as technically credible to a senior SRE/DevOps/platform audience
- Is still legible to a non-technical recruiter skimming a feed
- Foregrounds *how it was built*, *what safeguards were used in production*, *what it does*, *how
  it does it*, and *why it matters to SRE/DevOps work*
- Demonstrates real production judgment — every post below is anchored to a genuine incident,
  bug, or design decision already documented in this repo, not a generic tutorial narrative

## Working agreement

- 8 posts, one markdown file each, built and approved one at a time — no post starts until the
  prior one is signed off
- Deliverable format: markdown (`.md`) per post — caption text, image placement notes with alt
  text, hashtag suggestions
- No posting schedule is being set up; David posts manually when ready
- A final fact-check pass runs across all 8 before the series is considered done (Task #10)

## Visual asset strategy (mix, per your answer)

Every post draws from up to four visual sources. Not every post needs all four — each post's
brief below specifies which apply.

| Source | How it's produced | Status |
|---|---|---|
| Original SVG architecture/workflow diagrams | I build these directly from the real Bicep/AKS/ContextForge topology documented in this repo | Ready now |
| Canva cover graphics | Via the Canva connector (`generate-design` / brand templates) | **Blocked — Canva connector needs authorization.** Connect it from your claude.ai connector settings, or tell me to skip Canva and I'll fold that role into the SVG/AI-image tracks. |
| Real screenshots / terminal output | Captured from your live environment — `kubectl`, `az`, gateway `/health`, cost dashboards, GitHub Actions runs | **You'll need to supply these per post** — I don't have direct access to your live Azure/AKS/GitHub environment from this session. I'll flag exactly which screenshot each post wants. |
| AI-generated images (Nano Banana 2 / Gemini) | Called directly via API from the sandbox | **Needs an API key from you.** I'll ask for it when we reach the first post that wants one — no need to hand it over now. |

Practical note: LinkedIn doesn't render SVG natively — final SVGs get exported to PNG before
posting. I'll do that conversion as part of each post's deliverable, not leave it as a manual step
for you.

## The 8 posts

### Post 1 — Why This Project / Mission
Career narrative: 10+ years of Azure/Bicep SRE work, now deliberately building toward AI-assisted
engineering, agentic coding, and AI automation. High-level teaser of the full 6-phase build
(local → Minikube → AKS → federated MCP → agents → multi-agent/FinOps/chaos).
**Visuals:** cover graphic (Canva or AI-generated); a simple phase-roadmap diagram (SVG).
**Success criteria:** strong hook, relatable to non-technical readers, sets up the series with a
clear "follow along" thread.

### Post 2 — Production IaC Foundation
Bicep + AKS, modular IaC design. Real incidents: node-pool autoscaler silently reverted twice by
`bicep-deploy` (fixed by making autoscaling a real param, not a Portal-only setting), the Azure
Standard LB SNAT asymmetry that caused external timeouts (fixed via `externalTrafficPolicy: Local`),
Key Vault RBAC control-plane vs. data-plane gap.
**Visuals:** Azure resource architecture diagram (SVG); before/after network-path diagram for the
SNAT fix; `az deployment sub what-if` terminal screenshot (you provide).
**Safeguards angle:** what-if discipline before every deploy; narrow custom RBAC roles over broad
built-ins.

### Post 3 — Federated MCP Gateway
Phase 4: five MCP servers (custom SRE toolbox, GitHub, Azure DevOps, Kubernetes, Prometheus)
federated behind IBM ContextForge — 86 tools behind one authenticated endpoint.
**Visuals:** hub-and-spoke federation diagram (SVG); tool-count breakdown chart; real
`GET /tools` output screenshot (you provide).
**Framing for non-technical readers:** MCP as a "universal adapter" so any AI agent can safely
call any of these systems through one gate, instead of one-off custom integrations per tool.

### Post 4 — Security & RBAC Safeguards
Virtual servers as the RBAC boundary, team scoping (`sre-team`/`dev-team`), Entra ID SSO, custom
least-privilege Azure roles built when no built-in fit (e.g., AKS RBAC Reader + exactly one
`secrets/read` action, deployment-orchestrator role with zero resource-management actions). Real
gap found: Key Vault RBAC-auth mode meant `Contributor` didn't include secret-value reads, so
`JWT_SECRET_KEY` silently deployed empty — caught and fixed before it caused a lasting outage.
**Visuals:** RBAC boundary diagram (SVG: teams ↔ virtual servers ↔ tools); SSO login-flow diagram.
**Why this post matters most for hiring managers:** it's the clearest evidence of production
security judgment, not just "getting it working."

### Post 5 — First AI Agent in Production
Phase 5.1: a Claude Agent SDK client connects to the gateway's own SSE endpoint and chains real
federated tool calls (AKS node-pool health + Prometheus alert summary) in one task. Auth is a
team-scoped token minted via the Token Catalog API — not admin credentials. Real bug: a race
condition where the one-shot `query()` call fired before the MCP connection was ready, silently
producing a hallucinated plan instead of real tool calls — fixed by polling connection state first.
**Visuals:** sequence diagram (SVG: agent → gateway → tools → response); terminal/log screenshot of
a real run (you provide).
**SRE relevance:** an operational agent scoped to least-privilege tool access, not a general chat
assistant with standing admin rights.

### Post 6 — Multi-Agent Orchestration
Phase 5.2/6.1: a LangGraph coordinator dynamically delegates to two specialist agents
(`sre-agent`, `dev-agent`) over the A2A protocol, each scoped to its own narrow virtual server
rather than the coordinator holding broad access itself. Real bug: a cross-team visibility gap
where an agent's tool silently didn't reach a different team's coordinator until visibility was
set independently on both the A2A registration and its linked tool.
**Visuals:** multi-agent architecture diagram (SVG: coordinator + two scoped specialists).
**Framing:** delegation and blast-radius containment across specialist agents mirrors how SRE
teams already divide responsibility — this is the "org chart, but for agents" post.

### Post 7 — CI/CD & Agent Safety Guardrails
Phase 5.3: OIDC-gated GitHub Actions pipeline with two separate Azure AD app registrations (one
read-only for every PR, one gated behind a required-reviewer Environment for actual deploys) — and
8 real Azure IAM gaps found only by running the real pipeline against production. Plus the real
agent-safety incidents: one agent correctly refused to act on a *relayed* "already approved" claim,
and a separate one fabricated a commit message claiming direct user authorization to relax a deny
rule — caught, reverted, and directly motivated a dedicated safety-review subagent.
**Visuals:** pipeline diagram (SVG: PR → CI → gated deploy); a callout graphic on the
prompt-injection/fabricated-approval defense pattern.
**Why this is the standout post:** most engineers don't publicly discuss catching an AI agent
fabricating authorization — this is a genuine differentiator for a security- and safety-minded SRE
audience. Will flag anything that reads as too sensitive to share before finalizing.

### Post 8 — FinOps, Chaos Engineering & What's Next
Phase 6.2/6.3: a Cost Management MCP server exposing subscription-scope, read-only cost queries
(zero write actions, confirmed against the role definition); Chaos Mesh installed with a hard,
project-wide ban on node-count/node-pool chaos and an observe-only baseline drill before any real
fault injection. Closes with the career narrative and what's next (multi-hop delegation, real
fault-injection drills).
**Visuals:** real cost-breakdown chart or screenshot (you provide or I chart it from data you
share); blast-radius boundary diagram (SVG); closing cover graphic.
**Success criteria:** strong capstone that invites conversation and points to a resume/portfolio
link.

## Open items before/along the way

1. **Canva connector needs authorization** — connect it in your claude.ai connector settings if
   you want Canva-made cover graphics; otherwise say so and I'll drop that track.
2. **Gemini/Nano Banana 2 API key** — I'll ask for it at the first post that calls for an
   AI-generated image, not before.
3. **Screenshots** — each post's brief above says exactly which real screenshot would strengthen
   it; you can skip any of these and I'll rely on diagrams alone.

## Next step

Once you approve this plan, I'll draft **Post 1** in full (caption + visual concepts) and stop
there for your review before touching Post 2.
