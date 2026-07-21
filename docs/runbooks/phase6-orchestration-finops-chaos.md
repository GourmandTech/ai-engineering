# Phase 6 Runbook — Orchestration, FinOps, Chaos

Incident-log format, same convention as `docs/runbooks/phase4-federated-mcp.md` and
`docs/runbooks/phase5-agent-automation.md`: real bugs, root cause, fix — documented
incrementally as each sub-phase lands, not batched at the end.

---

## 6.1.1 — Second A2A specialist: dev-agent

**Goal:** add `dev-agent`, scoped to the existing `dev-tools` virtual server (GitHub +
Azure DevOps, 62 tools), to prove the Phase 4/5 per-workload-identity + narrow virtual
server + `associated_tools` pattern generalizes to a second, independently-scoped
specialist before the coordinator gets real multi-specialist routing (6.1.2).

### Real finding #1 — local admin-created user instead of a second Entra/SSO test account

Phase 4 Step 9 / Phase 5.1 minted `sretester@djfernandez80gmail.onmicrosoft.com` as a
real Entra AD user, requiring an interactive browser SSO login to actually create its
ContextForge-side user row (`authenticate_or_create_user` only fires on a real login).
That round trip exists to prove the *real* SSO+RBAC path end-to-end — which matters for
a human-facing test identity, but dev-agent's underlying identity only ever needs to
**hold a minted API token** (`mcp-create-scoped-token`); nothing ever logs in as it
interactively.

Checked the live `/openapi.json` before assuming the sretester pattern was the only way:
`POST /auth/email/admin/users` (schema: `AdminCreateUserRequest` — email, password,
full_name, is_admin, is_active, password_change_required) creates a local
email/password ContextForge user directly, no Entra AD app, no browser click-through.
Used this instead for `devtester@contextforge.local` — same DB-row prerequisite
`mcp-create-scoped-token` needs, without reproducing Phase 4 Step 8d's interactive-login
and account-linking complexity for an identity that will never actually sign in.

### Real finding #2 — `mcp-attach-a2a-agent`'s existing Makefile target reproduced Phase 5.2's own bug #1

The target as it existed going into this wave only PUT `associated_a2a_agents` on the
target server — exactly the shape Phase 5.2's incident log already documented as
insufficient (the tool row is created but doesn't surface over the server's SSE
`tools/list`; `associated_tools` is a separate relationship). The comment above the old
target described the *partial-update* behavior correctly but didn't carry the actual
fix forward into reusable tooling — it would have silently reproduced the exact bug on
the very next agent that used it. Fixed in the Makefile itself (not just done ad hoc via
curl) so it can't regress a third time: `mcp-attach-a2a-agent` now reads the target
server's current `associated_tools` from the **list** endpoint (`GET /servers`, not
`GET /servers/{id}` — see finding #3), looks up the new agent's `a2a_<name>` tool id,
and PUTs both `associated_a2a_agents` and the merged `associated_tools` in one request.

### Real finding #3 (carried forward, re-confirmed) — `GET /servers/{id}` single-object 404

Reused Phase 4 Step 9's confirmed upstream bug (`admin_bypass: false` on this one
endpoint family for a genuine platform admin) rather than rediscovering it: the new
`mcp-attach-a2a-agent` target deliberately sources current `associated_tools` from
`GET /servers?limit=0` (list, confirmed working for admin) instead of `GET /servers/{id}`.

### Real finding #4 — cross-team tool attachment is accepted by the API but silently non-functional (the big one)

`dev-agent`'s A2A registration (`team_id=dev-team`, per this wave's design goal of proving
the pattern generalizes to a specialist owned by a *different* team than `coordinator-delegate`,
which `sre-team` owns) deployed and registered cleanly — pod healthy, `reachable: true`,
`mcp-attach-a2a-agent` correctly merged its tool id into `coordinator-delegate`'s
`associated_tools` (both ids showed up in `GET /servers`'s `associatedToolIds`, no API error).

But the coordinator's real, live `tools/list` (tested at the raw MCP protocol level via
`mcp.client.sse` directly — not just the langchain wrapper, to rule out a client-library
parsing bug) only ever returned `a2a-sre-agent`, never `a2a-dev-agent`, despite both being
genuinely attached. Root cause, confirmed by direct testing rather than reading source:
ContextForge enforces **two independent RBAC layers** for a team-visibility virtual server —
(1) can this token's team reach the *server* at all (confirmed: a `dev-team`-scoped token
and a no-team-claim token were both flatly `403`'d against `coordinator-delegate`, which
`sre-team` owns — team mismatch fails closed, no admin-style bypass), and (2), independently,
for a token that *does* reach the server, is each individual attached *tool* visible to that
token's team. `a2a-sre-agent`'s tool inherited `sre-team` ownership (matches the coordinator's
own team, passes); `a2a-dev-agent`'s tool inherited `dev-team` ownership (does not match,
silently filtered — no error, no partial-tools warning, just absent from the list).

This means **`associated_tools` is a necessary but not sufficient condition for a cross-team
tool to actually reach a coordinator** — a real, sharp edge the plan's own "cross-team
integration summary" table didn't anticipate (it assumed team ownership only gated
server-level admin/reachability, not a second per-tool filter layered on top of that).

Since `TokenCreateRequest.team_id` is a single optional string (confirmed from the live
schema — no multi-team support, and omitting it fails closed rather than bypassing the
check), a coordinator token cannot simply be minted against both teams at once. The fix
that doesn't require re-architecting team ownership: `visibility` is a field independent of
`team_id` on **two separate objects** — the A2A agent registration itself
(`A2AAgentUpdate.visibility`) and its auto-created linked tool (`ToolUpdate.visibility`,
confirmed via `PUT /tools/{tool_id}` — a completely separate DB row/endpoint from the A2A
agent, another real gotcha: updating the agent's visibility via `PUT /a2a/{id}` does **not**
cascade to the linked tool's own visibility field). Both had to be set to `public`
independently before the coordinator's tools/list picked up `a2a-dev-agent` — confirmed via
the same raw-protocol test, now returning both tools.

`team_id: dev-team` was left unchanged on both objects — this only widens *read/attach*
visibility within ContextForge's own internal RBAC model (still fully gated behind bearer-
token auth; no unauthenticated access, no change to network exposure or SSO), matching the
same `visibility: public` convention this project's own CLAUDE.md already documents for all
86 pre-existing MCP-federated tools ("tools are visibility=public by default \\(set
explicitly\\), virtual servers as the RBAC boundary"). Confirmed live with the real user
before making the change, given it touches shared production RBAC state.

### Live verification (2026-07-21) — real, end-to-end, not simulated

- `id-dev-agent` workload identity + federated credential: provisioned via `bicep-deploy`
  (`az deployment sub what-if` run first, confirmed only 3 resources to create, zero node-pool
  drift, before the real `create`).
- `dev-agent` pod: `1/1 Running`, 0 restarts; both Key Vault secrets synced
  (`ANTHROPIC_API_KEY` 108 bytes, `DEV_AGENT_JWT` 749 bytes).
- A2A registration: `POST /a2a` → `reachable: true`, agent id `164ccaa0a7844c46876c343b85c9a9fb`,
  linked tool id `21647e86bce34c9ea57ae641236fba59` (read from gateway pod logs — same
  workaround as Phase 5.2, since `GET /a2a` and `GET /a2a/{id}` both return empty/404 for a
  genuine platform admin, the same `admin_bypass:false` gap Phase 4 Step 9 found on
  `GET /servers/{id}`, now confirmed to also affect the `/a2a` endpoint family).
- Coordinator's live `tools/list` (raw MCP protocol, `mcp.client.sse`): 2 tools,
  `a2a-sre-agent` + `a2a-dev-agent`, after the visibility fix above.
- Real delegated call: `agents/coordinator-agent/coordinator.py` given "Delegate to the dev
  agent: use its GitHub tools to list open pull requests in the GourmandTech/ai-engineering
  repository." Confirmed via logs, not just the final answer:
  - Gateway: `Invoking tool: a2a-dev-agent ... Calling A2A agent 'dev-agent' at
    http://dev-agent.mcp.svc.cluster.local:8000/run`
  - `dev-agent` pod: real Claude Agent SDK tool call,
    `mcp__contextforge__github-mcp-list-pull-requests({'owner': 'GourmandTech', 'repo':
    'ai-engineering', 'state': 'open'})`, cost `$0.0341`, correct result (repo has no open PRs).
- No new Entra AD app was needed — `devtester@gourmandtech.net` is a local
  (`auth_provider: "local"`) ContextForge account created via `POST /auth/email/admin/users`
  specifically because it only ever needs to *hold* a minted token, never sign in
  interactively (see finding #1).

### Not yet done in this wave

- **Coordinator routing logic itself is unchanged** — Wave 1 deliberately does not touch
  `coordinator.py`'s model/tool-binding code (that's 6.1.2). The delegation above worked
  because Claude's native tool-selection picked the right tool given two clearly-described
  options in the prompt, not because of any new custom routing — proving the *pattern*
  generalizes, not yet proving *dynamic* routing under ambiguity.
- **PR not yet opened** — code, infra, and this runbook entry are complete and committed
  locally; opening the PR is the next step.
