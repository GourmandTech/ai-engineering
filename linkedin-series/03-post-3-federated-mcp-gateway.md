# Post 3 — Federated MCP Gateway

**Status:** ✅ Approved
**Series:** ContextForge AI Engineering LinkedIn Series (Post 3 of 8)

## Caption

One authenticated endpoint. Five different systems. 86 tools an AI agent can call safely — without me writing 86 one-off integrations.

That's what MCP (Model Context Protocol) federation buys you. Think of it as a universal adapter: instead of hand-wiring a custom connection between every AI agent and every tool it needs, each system speaks MCP once, and a gateway federates all of them behind a single, authenticated front door.

I built this with IBM ContextForge on AKS, federating five MCP servers: a custom Python toolbox I wrote myself, GitHub, Azure DevOps, Kubernetes, and Prometheus — 86 tools total, self-hosted, verified as an exact match against the sum of each server's own tool count, not just trusted at face value.

One decision I'd flag for anyone building on this stack: for the Kubernetes server, I passed on the most popular option (`Flux159/mcp-server-kubernetes`) for a less popular one (`containers/kubernetes-mcp-server`, Red Hat) specifically because the popular one had a real CVE — its read-only/allowlist restrictions were enforced when a client listed available tools, but not when it actually called one, meaning a client could invoke a restricted tool just by knowing its name. Star count isn't a security control.

Every stdio-only server (GitHub, Azure DevOps) gets wrapped into the gateway's SSE transport; the two that speak SSE natively (Kubernetes, Prometheus) don't need the wrapper at all. Five different vendors, five different transport assumptions, one consistent way for an agent to reach any of them.

Post 4: the RBAC layer that decides which of these 86 tools any given agent — or human — is actually allowed to touch.

Repo: github.com/GourmandTech/ai-engineering

#MCP #AIEngineering #Kubernetes #Azure #PlatformEngineering

---

**Length check:** 1,774 characters, 273 words — within the standard LinkedIn range (~1,300–1,900 chars).

## Visuals

### 1. Hub-and-spoke federation diagram — original SVG
**File:** `linkedin-series/assets/post3-federation-hub.svg` (source) / `linkedin-series/assets/post3-federation-hub.png` (2400×1420, exported for LinkedIn)
**Placement:** First image in the post (primary thumbnail).
**Alt text:** "Diagram showing an AI agent connecting through the ContextForge Gateway — one authenticated endpoint federating 86 tools — to five MCP servers: a custom SRE Toolbox, GitHub, Azure DevOps, Kubernetes, and Prometheus, each with its own transport (native SSE or a stdio-to-SSE wrapper)."
**Source of truth:** Phase 4's "MCP Server Inventory" table and "Key Phase 4 design decisions" in `CLAUDE.md`.

### 2. Tool-count breakdown chart — original SVG
**File:** `linkedin-series/assets/post3-tool-breakdown.svg` (source) / `linkedin-series/assets/post3-tool-breakdown.png` (2400×1400, exported for LinkedIn)
**Placement:** Second image in the post.
**Alt text:** "Horizontal bar chart of tool counts by federated MCP server: Azure DevOps 40, GitHub 22, Kubernetes 13, Prometheus 6, SRE Toolbox 5 — summing to 86 tools, confirmed as an exact match."
**Design note:** Single accent color (not a multi-color categorical palette) since this is one measure (tool count) across categories, not multiple simultaneous series — identity is carried by the direct server-name labels, per the dataviz skill's color-by-job rule, not by hue.
**Source of truth:** Phase 4 Step 6 verification note in `CLAUDE.md`: "all `enabled: true`, `"total": 86` tools federated (5+22+40+13+6), exact match."

### 3. `GET /tools` terminal screenshot — real output, captured live
**File:** `linkedin-series/assets/post3-tools-screenshot.svg` (source) / `linkedin-series/assets/post3-tools-screenshot.png` (2400×1640, exported for LinkedIn)
**Placement:** Third image (optional carousel slide).
**Alt text:** "Terminal screenshot of a real GET /tools API call against the live gateway, grouped by server: 5 from sre-toolbox, 22 from github-mcp, 40 from azure-devops-mcp, 13 from kubernetes-mcp, 6 from prometheus-mcp — 86 total across these five servers, an exact match — plus 4 more tools from cost-mcp and an A2A agent added later in Phase 6, for a live total of 90."
**How this was captured:** Run live on 2026-07-28 — briefly started the (currently cost-stopped) AKS cluster back up specifically to capture this and Post 5's screenshot, then stopped it again immediately after both were done. `curl "$GATEWAY_URL/tools?limit=0" -H "Authorization: Bearer $JWT_TOKEN"` against the real gateway, piped through the same `jq` filter as the `mcp-list-tools` Makefile target. The live total is now 90, not 86 — confirmed by breaking it down by tool-name prefix that exactly 86 come from the five servers this post covers, matching the caption precisely; the other 4 (`cost-mcp-*` ×3, `a2a-dev-agent` ×1) are later Phase 6 additions and are called out as such in the image rather than silently included in "86."

## Hashtag suggestions

`#MCP` `#AIEngineering` `#Kubernetes` `#Azure` `#PlatformEngineering`

## Fact-check notes (sourced from `CLAUDE.md`, Phase 4)

- Five servers, transports, and status: SRE Toolbox (custom Python FastMCP, native SSE), GitHub (official, self-hosted, stdio via `mcpgateway.translate`), Azure DevOps (official, stdio via `mcpgateway.translate`), Kubernetes (Red Hat/containers, native SSE), Prometheus (community, native SSE) — all "Running in AKS + registered in ContextForge" per the Phase 4 inventory table.
- Tool counts: SRE Toolbox 5, GitHub 22, Azure DevOps 40, Kubernetes 13, Prometheus 6 = 86, confirmed exact match in Phase 4 Step 6.
- Kubernetes MCP server choice: "Chose `containers/kubernetes-mcp-server` (Red Hat/containers, Go, native client-go) over the more popular `Flux159/mcp-server-kubernetes` specifically because of CVE-2026-46519 (CVSS 8.8, fixed upstream in v3.6.0) — Flux159's read-only/allowlist env vars were enforced at `tools/list` discovery but not `tools/call` execution."
- "Universal adapter" framing and one-authenticated-endpoint structure: matches the master plan's own non-technical framing note for this post, and Phase 4's "Key Phase 4 design decisions" (virtual servers as the RBAC boundary, gateway registration at `POST /gateways`, no `/v1/` prefix).

**Kept deliberately light:** RBAC/team-scoping/virtual-servers content is intentionally minimal here (just the one teaser line into Post 4) to avoid stealing Post 4's actual subject matter — Post 3 stays focused on federation itself, not access control.

## Open items / still missing

- ~~`GET /tools` output screenshot~~ — **resolved 2026-07-28.** Captured live (see visual #3). Nothing outstanding.
