# Post 5 — First AI Agent in Production

**Status:** Draft — batch review pending (building Posts 5-8 before review, per your instruction)
**Series:** ContextForge AI Engineering LinkedIn Series (Post 5 of 8)

## Caption

The scariest bug I've hit on this whole project didn't throw an error. It just lied confidently.

Phase 5 was the first time I let an AI agent actually touch this infrastructure — a Claude Agent SDK client connecting to the gateway's own SSE endpoint, chaining real federated tool calls in a single task: check AKS node-pool health, summarize the last 24 hours of Prometheus alerts. It authenticates with a team-scoped token minted for a non-admin service account, not standing admin credentials — the same least-privilege posture as everything else on this project, extended to the agent itself.

Here's the bug. The SDK's one-shot `query()` call sends the model's first prompt the instant you connect — but the MCP handshake to the gateway takes a couple of seconds to actually go from "pending" to "connected." On my first run, the model's turn executed during that window, with zero tools actually available. It didn't error. It didn't say "I can't check that yet." It just answered — a plausible-sounding, fully hallucinated report, formatted exactly like a real one would be. Nothing in the output told me it was fake.

The fix was to stop trusting "the call returned" as proof of anything, and explicitly poll the SDK's own connection-status check until it reports connected before sending the first real prompt.

For an SRE, this is the whole point: a tool that fails loudly is an inconvenience. A tool that fails silently while producing a confident, well-formatted answer is a liability — especially once agents start feeding each other's output. Verifying execution, not just plausibility, is the actual job.

Post 6: what happens when this agent isn't working alone anymore.

Repo: github.com/GourmandTech/ai-engineering

#AIEngineering #Agents #MCP #SRE #ClaudeAI

---

**Length check:** 1,776 characters, 285 words — within the standard LinkedIn range (~1,300–1,900 chars).

## Visuals

### 1. Race-condition timeline diagram — original SVG
**File:** `linkedin-series/assets/post5-race-condition.svg` (source) / `linkedin-series/assets/post5-race-condition.png` (2400×1520, exported for LinkedIn)
**Placement:** First image in the post (primary thumbnail).
**Alt text:** "Before/after timeline diagram. Before: query() is sent immediately after connect(), the model runs with zero tools available, and a hallucinated report is returned with no error — the real MCP connection doesn't complete until two seconds later, too late to matter. After: the agent polls get_mcp_status() and waits for a 'connected' status before sending query(), so the model makes real tool calls to kubernetes-mcp, prometheus-mcp, and sre-toolbox, and returns a real report."
**Source of truth:** Phase 5.1 in `CLAUDE.md` — the exact bug description, `get_mcp_status()` polling behavior, `pending`→`connected` transition timing (~2s), and the `_wait_for_mcp_connection` fix in `agent.py`.
**Design note:** framed as a before/after timeline to match the visual pattern already established in Post 2 (SNAT fix) — keeps the series' recurring "here's the failure mode, here's the fix" structure visually consistent.

### 2. Terminal screenshot of a real agent run — captured live
**File:** `linkedin-series/assets/post5-agent-run.svg` (source) / `linkedin-series/assets/post5-agent-run.png` (2400×1540, exported for LinkedIn)
**Placement:** Second image in the post.
**Alt text:** "Terminal screenshot of a real sre-agent run: seven tool calls against kubernetes-mcp and prometheus-mcp, completing successfully at a cost of $0.5726, followed by a combined health report showing three healthy nodes, zero pending or failed pods, and no actionable Prometheus alerts in the last 24 hours. A closing note explains that direct Kubernetes node listing was denied for this scoped token by design, so node status came from Prometheus instead — the agent narrated the RBAC boundary working, rather than the run failing."
**How this was captured:** Run live on 2026-07-28 against the real gateway, same default task and scoped non-admin token as the original Phase 5.1 run (briefly restarted the stopped cluster for this and Post 3's screenshot, stopped it again immediately after). Real cost: $0.5726, close to the $0.61 originally logged in `CLAUDE.md` — both real, independent runs, not the same number reused. One real difference from the original run worth calling out honestly: this run's `kubernetes-mcp-resources-list({'kind': 'Node'})` call came back RBAC-denied (cluster-scoped Node access is intentionally excluded from the SRE service account's Azure RBAC — a Phase 4 design decision, not a new bug), so the agent fell back to Prometheus/kube-state-metrics for node status and said so explicitly in its own report. No `sre-toolbox-*` tools fired this run (the task didn't need them) — the alt text was corrected to name only the tools that actually fired, rather than assuming the original run's exact tool mix would repeat.

## Hashtag suggestions

`#AIEngineering` `#Agents` `#MCP` `#SRE` `#ClaudeAI`

## Fact-check notes (sourced from `CLAUDE.md`, Phase 5.1)

- `agents/sre-agent/agent.py` uses `ClaudeSDKClient` (not the one-shot `query()`) to connect to the `sre-full` virtual server's SSE endpoint; verified live with 6+ tool calls across `kubernetes-mcp-*`, `prometheus-mcp-*`, and `sre-toolbox-*`, cost $0.61.
- Auth: minted via the Token Catalog API (`POST /tokens`), issued to the existing non-admin `sretester@djfernandez80gmail.onmicrosoft.com` (already a plain `sre-team` member from Phase 4 Step 9) — decoded JWT confirms `is_admin: false`, `auth_provider: "api_token"`.
- The race condition: "the SDK's one-shot `query()` sends the prompt immediately on connect, racing the SSE handshake — confirmed via `ClaudeSDKClient.get_mcp_status()` that the `contextforge` MCP server reports `pending` for ~2s after `connect()` before flipping to `connected`... the model's first turn can run during that ~2s window with zero tools injected — it silently answered with a *hypothetical* plan instead of calling anything, no error surfaced."
- Fix: switched to `ClaudeSDKClient` and explicitly polling `get_mcp_status()` until the named server reports `connected` before calling `client.query()` — `_wait_for_mcp_connection` in `agent.py`.

## Open items / still missing

- ~~Terminal/log screenshot of a real agent run~~ — **resolved 2026-07-28.** Captured live (see visual #2). Nothing outstanding.
