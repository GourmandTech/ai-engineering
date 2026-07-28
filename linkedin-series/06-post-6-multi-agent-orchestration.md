# Post 6 — Multi-Agent Orchestration

**Status:** ✅ Scheduled — posting Tue, Aug 4, 2026 at 12:00 PM Mountain Daylight Time via LinkedIn's native scheduler
**Series:** ContextForge AI Engineering LinkedIn Series (Post 6 of 8)

## Caption

A manager doesn't personally have write access to every system their team touches. They delegate to the person who does — and that boundary is a feature, not a limitation.

I built the same structure for AI agents. A LangGraph coordinator routes tasks dynamically to two specialist agents — `sre-agent` and `dev-agent` — over the A2A (Agent-to-Agent) protocol. The coordinator itself is scoped to a narrow virtual server exposing only the specialists' delegate tools, not the 86 underlying tools they can reach — it can't bypass delegation and call Kubernetes or GitHub directly, even if the model tried.

Verified live: two different tasks, routed to two different specialists, each chaining its own tool calls and reporting back correctly.

Standing this up surfaced another silent failure — a theme that keeps repeating here. `dev-agent` is owned by a different RBAC team than the coordinator; attaching it as a delegate returned success from the API, but the coordinator's tool list silently didn't include it. No error, no warning — the same shape as last post's hallucination bug, one layer deeper.

Root cause: a team-scoped virtual server checks RBAC twice — once at the server level, once per tool. The attachment call only satisfied the first check. Fixing it meant setting visibility on the A2A registration *and* its linked tool separately — the API doesn't cascade one to the other.

"It returned success" and "it actually works" keep turning out to be two different claims on this project.

This delegation pattern isn't a novelty, either. Google created A2A for exactly this problem and handed it to the Linux Foundation, where it's now backed by 150+ organizations including AWS, Cisco, IBM, Microsoft, Salesforce, SAP, and ServiceNow — Microsoft has already built it into Azure AI Foundry and Copilot Studio, AWS into Bedrock AgentCore Runtime. The coordinator/specialist boundary I built by hand here is the same shape multi-agent systems are standardizing on industry-wide.

Post 7: the CI/CD pipeline this all deploys through — and two agents that handled being told "you're already approved" very differently.

Repo: github.com/GourmandTech/ai-engineering

#MultiAgent #AIEngineering #LangGraph #RBAC #SRE #A2A

---

**Length check:** ~2,226 characters, ~347 words — above the standard ~1,300–1,900 char range after adding the industry-validation paragraph (2026-07-28). Same tradeoff as Post 3: kept for the "this is where the industry is going" evidence. Trim if you'd rather stay strictly under 1,900.

## Visuals

### 1. Multi-agent architecture diagram — original SVG
**File:** `linkedin-series/assets/post6-multi-agent.svg` (source) / `linkedin-series/assets/post6-multi-agent.png` (2400×1440, exported for LinkedIn)
**Placement:** First and only planned image for this post (the master plan's brief for Post 6 calls for a single architecture diagram, no second visual).
**Alt text:** "Diagram showing a task routed to a LangGraph coordinator scoped to a narrow delegate-only virtual server, which delegates via the A2A protocol to two specialist agents — sre-agent, owned by sre-team with 86-tool access across five MCP servers, and dev-agent, owned by dev-team with 62-tool access to GitHub and Azure DevOps. A callout marks the real bug: a cross-team tool attachment that returned success but stayed invisible until visibility was set independently on both the A2A registration and its linked tool."
**Source of truth:** Phase 5.2 and Phase 6.1.1/6.1.2 in `CLAUDE.md` — coordinator-delegate virtual server (id `ed47e8c660dd4e529cefa48826b6cd1d`, single associated tool `a2a-sre-agent`), the `dev-agent` cross-team visibility bug (finding 4 in Phase 6.1.1), and confirmed live dynamic routing (Phase 6.1.2).

## Hashtag suggestions

`#MultiAgent` `#AIEngineering` `#LangGraph` `#RBAC` `#SRE` `#A2A`

## Fact-check notes (sourced from `CLAUDE.md`)

- Coordinator: `agents/coordinator-agent/coordinator.py`, LangGraph, delegates via ContextForge's A2A integration — not a direct function call (Phase 5.2).
- Coordinator's own RBAC boundary: `coordinator-delegate` virtual server, `associated_tools` initially exactly one tool (`a2a-sre-agent`) — "rather than give the coordinator the full 87-tool `sre-full` server... created a second, narrower virtual server" (Phase 5.2).
- Dynamic routing across both specialists confirmed live: "the coordinator asked for both an AKS node-pool check and a Prometheus alert summary; both delegated through the gateway" (Phase 5.2, sre-agent only) and "two different tasks correctly reaching two different specialists in the same session" (Phase 6.1.2, both agents).
- `dev-agent`: `id-dev-agent` workload identity, scoped to `dev-tools` virtual server (62 tools, GitHub + Azure DevOps), owned by `dev-team` — a different RBAC team than `sre-agent`/coordinator's `sre-team` (Phase 6.1.1).
- The cross-team bug, quoted directly: "a team-visibility virtual server enforces two independent RBAC layers (server-level team match, and *separately* a per-tool team match), so `a2a-dev-agent`'s tool, inheriting `dev-team` ownership, was silently filtered from the `sre-team`-owned coordinator's `tools/list` with no error. Fixed by setting `visibility: 'public'` independently on **both** the A2A agent registration and its linked tool (`PUT /a2a/{id}` does not cascade visibility to the linked tool — a second, separate `PUT /tools/{tool_id}` is required)." (Phase 6.1.1, finding 4).
- `sre-agent`'s multi-hop capability (mentioned in the diagram) is Phase 6.1.3 — confirmed complete in `CLAUDE.md`, included as accurate context for what the architecture supports, not claimed as this post's own subject (that's implicitly covered by "delegation" framing without over-claiming Phase 6.1.3/6.1.4 specifics, which aren't part of this post's brief).

## Open items / still missing

- No screenshot was specified in the master plan's brief for this post — none flagged as missing.
