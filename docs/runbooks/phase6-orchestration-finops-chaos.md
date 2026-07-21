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

---

## 6.1.2 — Dynamic LangGraph routing across two specialists

**Goal:** turn 6.1.1's "delegation happened to pick the right tool because the prompt was
already unambiguous" into an actual, verified routing decision between `a2a-sre-agent` and
`a2a-dev-agent`, plus a real cross-specialist fallback on repeated failure — not just
retry-the-same-tool, which is all `route_after_tools`/`handle_delegation_failure` did going
into this sub-phase.

### What changed in `agents/coordinator-agent/coordinator.py`

1. **Added a system prompt** (`SYSTEM_PROMPT`, passed as a `SystemMessage` in `run()`'s
   initial state). There was no system message at all before this — `build_graph()` called
   `ChatAnthropic(...).bind_tools(tools)` with nothing telling the model what the two tools
   *mean* beyond their own MCP tool descriptions. The prompt names both tools explicitly,
   states each one's domain (SRE: AKS/Kubernetes/node-pool/Prometheus; dev: GitHub/Azure
   DevOps), and explicitly instructs the model not to default to one out of habit — this
   matters because with only `a2a-sre-agent` ever having been exercised (5.2, 6.1.1's own
   "not yet done" note), there was no prior evidence the model would reliably prefer
   `a2a-dev-agent` on a dev-shaped task without being told it exists and what it's for.
2. **`build_graph()`'s own sanity check was widened** from "at least one tool loaded" to
   "both `a2a-sre-agent` and `a2a-dev-agent` are present in `client.get_tools()`" — the old
   check would have silently passed even if `a2a-dev-agent` never made it onto
   `coordinator-delegate` (e.g. if 6.1.1's cross-team visibility fix ever regressed), and the
   coordinator would then look like it was "choosing" sre-agent for every task when it
   actually only had one tool to pick from.
3. **`handle_delegation_failure` now tracks which specialist was actually attempted.**
   `_last_attempted_tool()` walks the message history backward to the most recent AIMessage
   with `tool_calls` and reads the tool name off it (handles both dict- and object-shaped
   `ToolCall`s across langchain versions). A new `attempted_tools` state field (parallel to
   the existing `delegation_attempts` counter) accumulates this history. On each failure,
   `same_specialist_run` counts how many times the same tool has failed *consecutively*
   (scanning `attempted_tools` from the end). Once that count reaches
   `MAX_DELEGATION_RETRIES` (2), instead of the old generic "rephrase and try again" nudge,
   the retry message explicitly names the *other* specialist (`_other_specialist()`) and
   tells the model to stop retrying the failed one and delegate to the other by name instead
   — this is the actual fallback-across-specialists behavior the sub-phase asked for, not
   just a rephrase-and-hope loop.
   - Given `route_after_tools`'s existing gate (`attempts < MAX_DELEGATION_RETRIES` decides
     whether `handle_delegation_failure` runs at all), with `MAX_DELEGATION_RETRIES=2` the
     node fires on the 1st and 2nd consecutive failures of a given tool and is bypassed
     (falls straight back to `coordinator` with the raw error in context) on a 3rd — so the
     *2nd* failure of the same tool is the one that actually triggers the explicit
     other-specialist nudge, since that's the last `handle_delegation_failure` invocation
     before the retry budget runs out entirely.

### Live verification (2026-07-21) — real, end-to-end, two different tasks, two different specialists

Ran `agents/coordinator-agent/coordinator.py` locally against the live gateway
(`GATEWAY_URL` default, `coordinator-delegate` server id
`ed47e8c660dd4e529cefa48826b6cd1d`), pulling `ANTHROPIC_API_KEY` and `COORDINATOR_JWT` from
Key Vault (`anthropic-api-key`, `coordinator-agent-jwt-token`) into shell variables only
(never printed).

**Task 1 — dev-domain:** `"Delegate to the dev specialist: list open pull requests in the
GourmandTech/ai-engineering GitHub repository."` Gateway logs, `20:49:43`:
```
Invoking tool: a2a-dev-agent with arguments: dict_keys(['query']) ... server_id=ed47e8c660dd4e529cefa48826b6cd1d
Calling A2A agent 'dev-agent' at http://dev-agent.mcp.svc.cluster.local:8000/run
```
followed by `dev-agent`'s own downstream call, `Invoking tool: github-mcp-list-pull-requests`.
Coordinator's final answer: correctly reported zero open PRs.

**Task 2 — SRE-domain:** `"Delegate to the SRE specialist: check AKS node pool health and
summarize any Prometheus alerts firing in the last 24 hours."` Gateway logs, `20:50:28`
(same session, ~45s later):
```
Invoking tool: a2a-sre-agent with arguments: dict_keys(['query']) ... server_id=ed47e8c660dd4e529cefa48826b6cd1d
Calling A2A agent 'sre-agent' at http://sre-agent.mcp.svc.cluster.local:8000/run
```
Coordinator's final answer: real node/alert summary (correctly flagged the perpetual
`KubeSchedulerDown`/`KubeControllerManagerDown`/`KubeProxyDown` alerts as expected
false-positives on managed AKS, and `KubeCPUOvercommit` as a genuine risk worth acting on).

This is the actual bar for this sub-phase: the coordinator was given two structurally
different tasks in the same run and correctly called a different specialist for each one,
driven entirely by the system prompt's domain descriptions plus Claude's native tool
selection — no hardcoded `if "github" in task` branching anywhere in `coordinator.py`.

### Not yet exercised live

- **The other-specialist fallback path itself** (`same_specialist_run >= MAX_DELEGATION_RETRIES`
  branch in `handle_delegation_failure`) was not triggered in this verification — both live
  calls above succeeded on the first attempt, so the failure branch never ran. The routing
  logic (system prompt + tool selection) is confirmed live; the fallback-on-repeated-failure
  logic is confirmed by code review and the existing `_tool_call_failed`/`route_after_tools`
  gating (unchanged from 5.2, already proven to fire correctly), not by an observed live
  failure. Forcing a real failure (e.g. temporarily scaling `dev-agent` to 0 replicas) was
  judged unnecessary risk to production for this verification pass — flag if a future wave
  wants to exercise this branch under a real fault.
- **Pre-existing, unrelated noise:** both runs print a burst of pydantic `ValidationError`
  lines from the `mcp` SDK's SSE transport failing to parse ContextForge's
  `notifications/initialized` message against its own `LoggingMessageNotification`/
  `ResourceUpdatedNotification`/etc. discriminated-union schema during the initial handshake.
  This is unrelated to this sub-phase's changes (same handshake code path as 6.1.1, not
  touched here) and did not affect either result — both tool calls and final answers came
  back correct. Not investigated further; flag if a future wave wants a clean log.
