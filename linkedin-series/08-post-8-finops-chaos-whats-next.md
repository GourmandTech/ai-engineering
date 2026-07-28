# Post 8 — FinOps, Chaos Engineering & What's Next

**Status:** Draft — batch review pending (final post in the batch)
**Series:** ContextForge AI Engineering LinkedIn Series (Post 8 of 8 — capstone)

## Caption

The last agent I built for this project can't take a single destructive action. Not because I forgot to give it tools — because I deliberately gave it none.

`finops-agent` correlates real Azure Cost Management data against actual utilization and produces a written recommendation: downsize a VM SKU to a cheaper burstable tier (~$50/month), add a Spot pool for non-critical workloads, leave Log Analytics and Key Vault alone. That's it — no write-capable tools at all; it can only report findings, never act on them. The node-count/node-pool ban that's governed this whole project is hardcoded into its system prompt, not left as a convention it could forget.

The cost data behind it comes from a workload identity scoped to one role, confirmed against the actual role definition to contain zero write actions — full visibility into spend, provably no power to change any of it.

Chaos engineering got the same treatment: Chaos Mesh, with one non-negotiable rule — nothing ever touches node count or the node pool, since two earlier outages already came from exactly that. Every drill runs behind a dead-man's switch that auto-deletes the fault if the gateway's health check fails for more than 30 seconds. A pod-kill drill recovered in 15.4 seconds. A network-partition drill did something more useful than pass — it failed cleanly, exactly as an earlier fix from this series predicted, proving that fix holds under a real partition, not just in theory.

That's the throughline across all eight of these posts: least privilege by default, and never trusting a claim — mine, an agent's, or the system's — until it's verified against what's actually true.

What's next: deciding whether to act on my own agent's cost recommendation, and continuing to build in this direction. If any of this is relevant to a team you're hiring for, I'd like to talk.

Repo: github.com/GourmandTech/ai-engineering

#FinOps #ChaosEngineering #AIEngineering #Azure #SRE

---

**Length check:** 1,950 characters, 314 words — slightly above the standard ~1,300–1,900 char range, same tradeoff as Post 7: this is the capstone covering two pillars (FinOps + chaos) plus a closing hook, so a bit of extra length buys a stronger finish rather than a rushed one. Trim if you'd rather keep it strictly under 1,900.

## Visuals

### 1. Real cost-breakdown chart — original SVG, built from the project's own live report
**File:** `linkedin-series/assets/post8-cost-breakdown.svg` (source) / `linkedin-series/assets/post8-cost-breakdown.png` (2400×1520, exported for LinkedIn)
**Placement:** First image in the post (primary thumbnail).
**Alt text:** "Bar chart titled 'Where the money actually goes,' showing month-to-date Azure spend: AKS node pool virtual machines at $131.36 (72%), Log Analytics at $45.02 (25%), and everything else combined at $6.74 (3%) — virtual network, load balancer, storage, Key Vault, and container registry, all evaluated with no rightsizing action recommended. A callout below recommends changing the node pool VM SKU from Standard D2s v7 to the burstable Standard B2ms, saving approximately $50 per month while keeping the node pool minimum at 2."
**Source of truth:** **Not** from the master plan's placeholder data — pulled directly from the actual generated report, `docs/reports/finops-rightsizing-2026-07-22.md`, which has a complete, real spend table and recommendation section (a more complete and more current dataset than the two figures cited in `CLAUDE.md`'s Phase 6.2.1-6.2.2 summary, which came from an earlier verification call the same day). Used the report's numbers throughout for consistency.

### 2. Blast-radius boundary diagram — original SVG
**File:** `linkedin-series/assets/post8-blast-radius.svg` (source) / `linkedin-series/assets/post8-blast-radius.png` (2400×1180, exported for LinkedIn)
**Placement:** Second image in the post.
**Alt text:** "Two-column diagram. Allowed, gated one drill at a time: a pod-kill drill on github-mcp-server that passed, recovering in 15.4 seconds, and a network-partition drill from sre-agent to the gateway that passed by failing cleanly at 21.9 seconds, exactly as an earlier timeout fix predicted — both required a fresh, exact-match settings.json allow added before and reverted after. Permanently banned, no exceptions: node-count and node-pool chaos, enforced as a hard allow/deny list in code, because two earlier outages on the project already came from exactly that. Below both columns, a note that every drill runs behind a dead-man's switch that auto-deletes the fault if the gateway's health check stays unhealthy for more than 30 seconds."
**Source of truth:** Phase 6.3.1-6.3.4 in `CLAUDE.md` — the project-wide node-count/node-pool ban rationale, the dead-man's-switch mechanism in `scripts/chaos_drill_lib.py`, and the two drills' exact pass results (15.4s recovery; 21.9s clean failure tied back to the Phase 5.2 `CONNECT_TIMEOUT_S=20` fix, referenced in this series as Post 5).

### 3. Closing cover graphic — AI-generated (Gemini `gemini-2.5-flash-image`)
**File:** `linkedin-series/assets/post8-cover.png` (1344×768, 16:9)
**Placement:** Third image, or lead image if you'd rather open the capstone post visually before the data.
**Alt text:** "Abstract illustration of a glowing blue network of nodes converging into a calm, symmetric, settled formation against a dark navy background, visually echoing Post 1's cover but in a resolved, completed state rather than an ascending one."
**Design note:** deliberately bookends Post 1's ascending-network cover — same visual language, but converged/settled rather than climbing, to mark this as the closing post.

## Hashtag suggestions

`#FinOps` `#ChaosEngineering` `#AIEngineering` `#Azure` `#SRE`

## Fact-check notes

- `finops-agent`: "recommend-only A2A specialist (`tools=[]`, no write-capable federated tools; the node-count/node-pool/autoscaler-min-2 ban is hardcoded directly into its system prompt...)" — `CLAUDE.md`, Phase 6.2.3-6.2.4. Report's own header confirms: "zero write-shaped tool names across all 22 tools on the finops-full virtual server."
- Cost figures (VMs $131.36/72%, Log Analytics $45.02/25%, VNet $5.20, Load Balancer $0.70, Storage $0.67, Key Vault $0.17, ACR $0.00) and the recommendation (D2s_v7 → B2ms, ~$50/mo, ~30% of compute, node minimum stays at 2) — all directly from `docs/reports/finops-rightsizing-2026-07-22.md`'s spend table and Recommendation (a).
- `id-cost-mcp-server` workload identity: first in the project with no stored Key Vault secret, first needing a subscription-scope role (`Cost Management Reader`, "confirmed read-only via `az role definition list` — zero write actions, zero `dataActions`") — Phase 6.2.1-6.2.2.
- Chaos Mesh: "a hard, project-wide ban on node-count/node-pool chaos, no exceptions, given two real prior outages already came from touching node count" — Phase 6 intro summary.
- Drill results: pod-kill "Recovered in 15.4s; all 7 other watched apps and the gateway stayed healthy throughout" (6.3.3); network-partition "the during-partition call failed cleanly at 21.9s (HTTP 500), just past sre-agent's own 20s internal MCP-connect timeout — proving the Phase 5.2 fix (`_wait_for_mcp_connection`'s `CONNECT_TIMEOUT_S=20`) still holds under a real network partition" (6.3.4).
- Dead-man's switch: "a dead-man's-switch that deletes the fault CR if gateway `/health` stays unhealthy >30s" — Phase 6.3.3-6.3.4 shared mechanics, `scripts/chaos_drill_lib.py`.

**Corrected from the master plan's brief:** the brief's "what's next" pointed at "multi-hop delegation" and "real fault-injection drills" as future work. Checked against `CLAUDE.md`: both are now complete — multi-hop delegation shipped in Phase 6.1.3, and both fault-injection drills (6.3.3, 6.3.4) passed. The brief was written mid-Phase-6 and is now stale on this point. Replaced with a "what's next" that's actually still open: whether to act on `finops-agent`'s own cost recommendation (the report exists; nothing in `CLAUDE.md` indicates the SKU change has been applied yet) — which also ties back to the post's own "recommend, don't auto-act" theme better than restating already-finished work would have.

## Open items / still missing

- No screenshot was specified in the master plan's brief for this post beyond the cost chart, which is now covered by real report data rather than a placeholder. Nothing outstanding.
