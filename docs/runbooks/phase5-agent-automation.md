# Phase 5 — Agent Automation: A2A Delegation and CI/CD

## Overview

Phase 5 closes the loop from "gateway exists" (Phase 4) to "agents actually use it, and changes
ship safely." Two agents now call ContextForge's federated tools for real, and a GitHub Actions
pipeline replaces "run `make bicep-deploy` by hand" with automatic CI + a deliberately gated CD step.

Full plan: `docs/phase5-plan.md`. Condensed status: `CLAUDE.md` Phase 5 section (source of truth
for what's done; this runbook is the how/why).

**Production gateway:** `https://contextforge.gourmandtech.com`

---

## Architecture

```
GitHub Actions (ci.yml — every PR, unguarded)
  └── Azure OIDC (Reader-only app) ── az aks get-credentials ── helm diff (AKS context)

GitHub Actions (deploy.yml — merge to main, gated by "production" Environment reviewer)
  └── Azure OIDC (Contributor + RBAC Admin app) ── bicep-deploy → aks-creds → helm-aks-secrets

LangGraph coordinator (agents/coordinator-agent/, client only, no AKS deployment)
        │  MCP tool call: a2a-sre-agent
        ▼
ContextForge Gateway (https://contextforge.gourmandtech.com)
  ├── virtual server: coordinator-delegate (exactly one tool: a2a-sre-agent)
  ├── virtual server: sre-full (87 tools — the original 86 + a2a-sre-agent itself)
  └── A2A agent registration: sre-agent → http://sre-agent.mcp.svc.cluster.local:8000/run
        │
        ▼
sre-agent pod (AKS, agents/sre-agent/)
  ├── a2a_server.py — FastAPI POST /run, parses ContextForge's JSONRPC/query shapes
  └── agent.py — Claude Agent SDK client, connects BACK to the gateway's sre-full SSE
        endpoint using its own team-scoped token, chains kubernetes-mcp-*/prometheus-mcp-*/
        sre-toolbox-* tools
```

---

## 5.1 — Simple agent client against the gateway

**Goal:** prove an agent can call federated tools through ContextForge, not just via curl.

### Auth: team-scoped, not platform-admin

`/auth/login` only issues a session JWT for a real user — using it here would mean testing as
platform-admin, exactly what this step is meant to avoid. Instead, mint via the **Token Catalog
API** (`POST /tokens`, new Makefile target `mcp-create-scoped-token`): an authenticated admin can
mint a token *for another user* (`TokenCreateRequest.user_email`, admin-only field) scoped to a
`team_id` + `scope.server_id` + explicit permissions. Issued to the existing non-admin
`sretester@djfernandez80gmail.onmicrosoft.com` (created in Phase 4 Step 9, already a plain member
of `sre-team`), scoped to `sre-full`, permissions `[tools.read, tools.execute]`. Decoded JWT
confirms `is_admin: false`, `auth_provider: "api_token"`, non-empty `teams` claim.

Stored in Key Vault as `sre-agent-jwt-token` (same pattern as `mcp-get-token`'s admin password),
pulled at runtime via `make sre-agent-get-token`.

### Real bug: `query()` races the MCP connection

The Claude Agent SDK's one-shot `query()` sends the prompt immediately on connect — it doesn't
wait for the MCP handshake. Confirmed via `ClaudeSDKClient.get_mcp_status()`: the gateway reports
`pending` for ~2s after `connect()` before flipping to `connected`. With `query()`, the model's
first turn can run during that window with zero tools injected — it silently answered with a
*hypothetical* plan instead of calling anything real, no error surfaced anywhere.

**Fix:** switched to `ClaudeSDKClient` and explicitly poll `get_mcp_status()` until the named
server reports `connected` before sending the actual task — see `_wait_for_mcp_connection` in
`agents/sre-agent/agent.py`.

### Other things worth knowing
- `claude_agent_sdk.types.McpSSEServerConfig`/`McpStatusResponse` aren't exported from the
  top-level `claude_agent_sdk` package (only `McpSdkServerConfig` is) — import from
  `claude_agent_sdk.types` directly.
- `get_mcp_status()` returns plain camelCase dict keys (`mcpServers`) at runtime, not the dataclass
  attribute access its type hints imply.
- `tools=[]` in `ClaudeAgentOptions` disables all built-in Claude Code tools (Bash/Read/Write/etc —
  confirmed from the SDK's own `_build_command`, maps to `--tools ""`) without touching
  MCP-injected tools — the agent can only act through ContextForge's federated tools.
- Requires the `claude` CLI on `PATH` (`npm install -g @anthropic-ai/claude-code`), not just the
  Python package — the SDK drives it as a subprocess.

### Verified live
Chained 6+ real tool calls (`kubernetes-mcp-*`, `prometheus-mcp-*`, `sre-toolbox-*`) for "check AKS
node pool health, summarize last-24h Prometheus alerts" — correct combined report, cost $0.61.

---

## 5.2 — A2A: agent-to-agent delegation

**Goal:** one agent delegates to another *through the gateway*, not a direct function call.

### Open question, resolved
Does A2A registration need its own workload identity / RBAC team? **No.** A2A agents register via
`POST /a2a` with the same `team_id`/`visibility` model as MCP gateways/tools — confirmed from the
vendored `.contextforge/docs/docs/using/agents/a2a.md` before assuming the Phase 4 gateway-
registration pattern transferred 1:1.

### Making the specialist A2A-reachable

Unlike 5.1's one-shot CLI test, ContextForge's A2A integration calls *into* a standing HTTP
endpoint — so the specialist needed a real deployment:

- `agents/sre-agent/a2a_server.py`: FastAPI `POST /run`, parsing ContextForge's JSONRPC /
  `parameters` / `query` request shapes (mirrors `.contextforge/scripts/demo_a2a_agent.py`).
- New `id-sre-agent` workload identity (`infra/bicep/modules/workload-identity.bicep` instance,
  same per-workload pattern as Phase 4 Steps 2-3).
- Two Key Vault secrets synced via CSI: `sre-agent-jwt-token` (from 5.1) and `anthropic-api-key` —
  a **real Anthropic Console API key**, distinct from a Claude Code OAuth session, since the SDK's
  `claude` CLI needs to run unattended in a container with no interactive login.
- `agents/sre-agent/Dockerfile` needs both Python *and* Node.js
  (`npm install -g @anthropic-ai/claude-code`).
- New Makefile targets: `sre-agent-build`, `sre-agent-deploy`, `mcp-register-a2a-sre-agent`,
  `mcp-attach-a2a-agent`.

### Coordinator's own RBAC boundary

Rather than give the coordinator the full 87-tool `sre-full` server (which would let its own model
bypass delegation entirely and call kubernetes/prometheus tools directly), created a second,
narrower virtual server, **`coordinator-delegate`** (id `ed47e8c660dd4e529cefa48826b6cd1d`), whose
`associated_tools` is exactly one tool: `a2a-sre-agent`. Same "virtual servers as the RBAC
boundary" design decision from Phase 4, applied to scope an *agent's* capability set instead of a
human team's. `agents/coordinator-agent/coordinator.py` uses LangGraph (rather than the Claude
Agent SDK, used for 5.1) specifically for its explicit checkpointed state: a failed delegation is
a first-class, recoverable branch in the graph (`handle_delegation_failure` node + retry, capped at
`MAX_DELEGATION_RETRIES`), not a bare exception.

### Real bug #1 (ContextForge): `associated_a2a_agents` doesn't expose the tool

Attaching an A2A agent to a server via `associated_a2a_agents` (`PUT /servers/{id}`, per the docs'
own example) updates that field correctly but does **not** expose the agent's auto-created tool
over the server's actual SSE tool listing. The tool row itself *was* created (gateway logs:
`"...with tool ID: 19e56cb9..."`), but a live SSE `tools/list` via the properly-scoped non-admin
token still showed the pre-existing 86 tools, not 87.

Root cause, confirmed by reading `_update_server_associations` in `server_service.py`: a server's
exposed tool set is driven by `associated_tools` only; `associated_a2a_agents` is a separate,
independent relationship — cosmetic/routing metadata, not the SSE exposure mechanism.

**Fix:** also `PUT associated_tools` with the new tool's id appended to the existing 86 (the field
replaces wholesale when provided — confirmed harmless to the a2a-agents relationship via
`_update_server_associations`'s `if new_ids is None: continue` check).

### Real bug #2 (this project's IaC): nodeCount drift, caught before it happened

A routine `bicep-deploy` for the new `id-sre-agent` identity nearly re-triggered the Phase 3/4
node-pool-scale-down incident. `az deployment sub what-if` showed `count: 2 => 1` on the AKS agent
pool. Root cause: `main.bicepparam`'s `nodeCount` was still `1` from before the autoscaler fix, and
`aks.bicep` sends `count` unconditionally on every deploy regardless of `enableAutoScaling` — the
earlier fix (defaulting `enableAutoScaling` to `true`) never actually addressed this specific field.

**Fix:** set `nodeCount = 2` (matching `minNodeCount`), verified via a second `what-if` that the
diff disappeared, then deployed — live node count confirmed unchanged (`2`) afterward.

**Standing habit worth keeping:** run `az deployment sub what-if` before *any* `bicep-deploy` on
this project, not just when a scale-down is already suspected.

### Real bug #3 (this project's IaC): NetworkPolicy blocked the specialist's own egress

sre-agent's outbound SSE connection back to the gateway
(`http://mcp-stack-mcpgateway.mcp.svc.cluster.local:80`) hung at `status: pending` forever, every
call failing with an HTTP 500 after a 20s timeout. This is the **first workload in the project with
calls in both directions** — the gateway calls in (A2A invocation), and this pod calls out (its own
MCP client) — every prior Phase 4 MCP server only ever received calls from the gateway.

The `sre-agent` NetworkPolicy's egress rules were copy-adapted from `azure-devops-mcp-server`'s,
which only ever calls *out* to the public internet: its `namespaceSelector: {}` rule only opens
port 53 (DNS), and its public-HTTPS rule explicitly excludes `10.0.0.0/8` (the whole AKS service
CIDR) — neither rule permits reaching another in-cluster pod at all.

Confirmed via `kubectl exec sre-agent -- curl -m 8 http://mcp-stack-mcpgateway.../health` timing
out (exit 28, `HTTP:000`) from *inside* the pod, while the identical URL worked instantly via
`kubectl port-forward` from outside the cluster network — proving the gateway side was healthy and
the failure was specifically sre-agent's own egress path.

**Fix:** added a dedicated egress rule targeting `app: mcp-stack-mcpgateway` pods on port **4444**
(the gateway's actual container port — NetworkPolicy pod-selector rules match the destination
pod's real listening port, not the Service's externally-exposed `80`).

### Metrics gap, noticed but not chased
`GET /metrics`'s `a2aAgents` block still read `totalInteractions: 0` immediately after two
confirmed-successful delegated calls (visible in gateway logs:
`"Invoking tool: a2a-sre-agent..."`, `"Calling A2A agent 'sre-agent' at http://sre-agent..."`,
`HTTP/1.1 200 OK`). Logs satisfy "observable in gateway logs/metrics" on their own; the counter gap
wasn't investigated further — possibly `A2A_STATS_CACHE_TTL=30`-related, possibly a real tracking
gap. Flag if this matters for a future dashboard.

### Verified live end-to-end
Coordinator asked for both an AKS node-pool check and a Prometheus alert summary. Both delegated
through the gateway to sre-agent, which chained its own federated tool calls and returned real
reports; the coordinator consolidated them into one final answer.

---

## 5.3 — CI/CD: GitHub Actions

**Goal:** replace manual `make bicep-deploy` with a pipeline that catches regressions before they
reach AKS, directly motivated by this project's own drift-incident history.

### Auth design: two separate Azure OIDC apps, not one

The plan's stated pattern — "automatic CI, deliberately gated CD" — means `ci.yml`'s `helm-diff`
job runs on *every* PR, unguarded, no reviewer approval. If it shared the same Azure identity as
the gated deploy job, any PR (including from an untrusted branch) could mint a token with
Contributor-level access before a human ever reviewed anything — the gate would be theater.

Two apps instead:

| App | Federated credential subject | Used by |
|---|---|---|
| `github-actions-contextforge-cicd` | `repo:GourmandTech/ai-engineering:environment:production` | `deploy.yml`'s gated job only |
| `github-actions-contextforge-ci-readonly` | `repo:GourmandTech/ai-engineering:pull_request` | `ci.yml`'s `helm-diff`, every PR |

Final role assignments (after the incident log below — every one of these was added reactively,
in response to a real `Forbidden`/`ForbiddenByRbac` from an actual pipeline run, not decided
upfront):

| App | Role | Scope |
|---|---|---|
| deploy | `Contributor` | `rg-contextforge-dev` |
| deploy | `Role Based Access Control Administrator` | `rg-contextforge-dev` |
| deploy | `Azure Kubernetes Service RBAC Admin` | `rg-contextforge-dev` |
| deploy | `Deployment Orchestrator` (custom — see incident #7) | subscription |
| deploy | `Key Vault Secrets User` | the `kv-contextforge-dev` vault only |
| CI | `Reader` | `rg-contextforge-dev` |
| CI | `Azure Kubernetes Service Cluster User Role` | `rg-contextforge-dev` |
| CI | `AKS RBAC Reader + Secrets Read` (custom — see incident #5) | `rg-contextforge-dev` |

RBAC Admin (not just Contributor) is needed on the deploy app because
`infra/bicep/modules/workload-identity.bicep`'s per-workload identities each create their own role
assignment (`Microsoft.Authorization/roleAssignments`) — plain Contributor can't do that.

The federated credential's subject scoping is the actual security boundary here, not GitHub's UI:
a token request from a PR-triggered run naming the *production*-scoped app's client ID would be
rejected by Azure AD itself (issuer/subject mismatch), before the request ever reaches a GitHub-side
permission check.

### Real platform limitation: required reviewers needs a paid plan
GitHub's required-reviewers Environment protection rule isn't available for private repos below
GitHub Team — `PUT /repos/.../environments/production` 422'd with
`"Please ensure the billing plan supports the required reviewers protection rule."` This is a
personal learning-platform repo with no sensitive proprietary content (verified via a secret-pattern
grep before the change), so the repo was made public instead of upgrading billing — required
reviewers on Environments is free for public repos.

### Branch protection as a prerequisite
The Environment's `deployment_branch_policy: {protected_branches: true}` silently allows *no*
branch to deploy unless that branch is actually a protected branch — `main` had none configured
yet. Added: 1 required PR approval, required status checks named `lint` and `helm-diff` (matching
the two `ci.yml` job names exactly, since GitHub matches status checks by job name/id).

### Workflows
- `.github/workflows/ci.yml` — on PR: `lint` job (`make lint`, no Azure creds needed) +
  `helm-diff` job (Reader-scoped OIDC, `make aks-creds` + new `make helm-diff-aks` target — the
  original `helm-diff` was minikube-only).
- `.github/workflows/deploy.yml` — on push to `main`: single `deploy` job running inside the
  `production` Environment (reviewer-gated), reusing the existing Makefile targets end to end
  (`bicep-validate` → `bicep-deploy` → `aks-creds` → `helm-aks-secrets`) rather than
  reimplementing their logic in YAML — keeps the incident-log-documented fixes baked into those
  targets (HPA/managedFields workaround, KV-sourced secrets, etc.) as the single source of truth.
  The Makefile targets' interactive `read -p` confirmations are piped (`echo y | make ...`) since
  the real gate is the Environment's reviewer approval, already satisfied by the time that step
  runs — not a bypass of anything.

### Getting the first live run green: 8 real bugs, one per RBAC/platform boundary

Every one of these only surfaced by actually running the pipeline against production — none of
them were things a review of the YAML or the role names in the abstract would have caught. Fixed
in the order encountered:

1. **Helm plugin schema mismatch.** `helm plugin install https://github.com/databus23/helm-diff`
   "succeeded" but the plugin was unusable: `error unmarshaling JSON: json: unknown field
   "platformHooks"`. `helm-diff`'s current release's `plugin.yaml` uses Helm's `platformHooks`
   schema, which Helm's own `pkg/plugin/plugin.go` only gained in **3.18.0** — confirmed directly
   against Helm's source across tags (absent 3.14-3.17, present 3.18.0+). Both workflows were
   pinned to `v3.14.0`, from before this mattered. Fixed: bumped to `v3.21.2`.
2. **`aks-creds`'s own sanity check too strict for a legitimately read-only identity.** The target
   ends with a bare `kubectl get nodes` (originally just a human-facing connectivity echo). The CI
   app's Reader-tier role correctly 403'd on it — Nodes are cluster-scoped, and Azure's built-in AKS
   reader roles deliberately exclude cluster-scoped resources by design (same rationale as
   Kubernetes' own built-in `view` ClusterRole). Fixed: made that one line non-fatal
   (`kubectl get nodes || echo "..."`) instead of granting node access nothing downstream needed.
3. **Missing `listClusterUserCredential`.** `make aks-creds` itself failed:
   `AuthorizationFailed ... listClusterUserCredential/action`. Plain `Reader` explicitly excludes
   this action (same category as storage account `listKeys` — Azure treats credential-listing as
   more sensitive than generic reads). Fixed: added `Azure Kubernetes Service Cluster User Role`.
4. **Missing Kubernetes-object read.** Credentials fetched fine, but `kubectl get nodes` still
   403'd with a *different* message this time — `"User does not have access to the resource in
   Azure"`. This cluster has Azure RBAC for Kubernetes Authorization enabled, a completely separate
   authorization layer from ARM roles: being able to fetch a kubeconfig doesn't mean you're
   authorized to do anything with it. Fixed: added `Azure Kubernetes Service RBAC Reader`.
5. **Missing Secrets read, and no built-in role offers it read-only.** With #4 fixed, `aks-creds`
   passed clean, but `helm-diff-aks` still failed: `secrets is forbidden ... in the namespace
   "mcp"`. `helm diff`/`helm get` fundamentally need to read Helm 3's own release state, which is
   stored *as Kubernetes Secrets* — and Azure's built-in `AKS RBAC Reader`'s `dataActions` list
   (checked directly via `az role definition list`) has zero Secrets access at all, by design. The
   next role up, `AKS RBAC Writer`, bundles full `secrets/*` (read **and** write/delete) — using it
   would have defeated the entire point of a read-only identity safe to run on any unguarded PR.
   Fixed: a **custom role** (`docs/runbooks/aks-rbac-reader-plus-secrets-role.json`) — the built-in
   Reader role's exact `dataActions` plus exactly one addition, the granular
   `Microsoft.ContainerService/managedClusters/secrets/read` action (confirmed via
   `az provider operation show` that Azure exposes this as a distinct action from `write`/`delete`,
   not just bundled).
6. **Solo maintainer can't review their own PR.** With CI green, the PR sat blocked:
   `reviewDecision: REVIEW_REQUIRED`, `mergeStateStatus: BLOCKED`. GitHub does not allow
   self-approval regardless of admin status, and `enforce_admins: false`'s bypass path wasn't a
   practical escape hatch here. Fixed: dropped `required_approving_review_count` to `0`, kept the
   required status checks (`lint`, `helm-diff`) — the real gate for a solo-maintained repo is CI
   passing, not a human-approval requirement that literally cannot be satisfied by one person.
7. **Subscription-scope deployment vs. the RG-scoped blast-radius goal.** First `deploy.yml` run:
   `bicep validate` failed with `AuthorizationFailed ... Microsoft.Resources/deployments/validate/action
   ... over scope /subscriptions/<id>`. `main.bicep` is `targetScope = 'subscription'` (a Phase 3
   decision — it creates the resource group itself), so running it needs deployment-orchestration
   permission at the **subscription**, not just `rg-contextforge-dev` — no amount of RG-scoped
   Contributor covers that. Granting full subscription Contributor would have defeated the plan's
   explicit "scope to one RG" goal outright. Fixed: a second custom role
   (`docs/runbooks/deployment-orchestrator-role.json`), assignable at the subscription, containing
   *only* `Microsoft.Resources/deployments/{read,write}`, `validate/action`, `whatIf/action`,
   `operations/read`, `operationstatuses/read`, and `subscriptions/resourceGroups/read` — zero
   resource-management actions. Azure evaluates "can this caller run a deployment at this scope"
   and "can this caller create the specific resources it declares" as two independent checks, so
   this role doesn't widen the deploy app's actual resource-level power beyond the RG-scoped
   Contributor it already had.
8. **Key Vault RBAC-auth mode: control-plane ≠ data-plane — this one nearly shipped a broken
   gateway.** With #7 fixed, `bicep deploy` and `aks-creds` passed, but the new gateway pod went
   `CrashLoopBackOff`: `SecurityConfigurationError: JWT_SECRET_KEY is not configured`. Root cause:
   `helm-aks-secrets` reads each secret via `az keyvault secret show` *from inside the CI job*
   (not via CSI/pod identity) and passes it to `helm --set`. The deploy app's `Contributor` on the
   RG manages the Key Vault as an ARM resource, but this vault uses **RBAC authorization mode**,
   where reading secret *values* is a separate data-plane role, `Key Vault Secrets User`, which
   Contributor does not include. Every `az keyvault secret show` call returned
   `ForbiddenByRbac` — silently, since each was wrapped in `$(...)` in the Makefile — so
   `JWT_SECRET_KEY`, `AUTH_ENCRYPTION_SECRET`, and every other gateway secret got passed to Helm as
   **empty strings**. The *previous* gateway pod kept serving traffic unaffected the whole time
   (Kubernetes doesn't tear down an old ReplicaSet's pod until the new one passes its readiness
   probe), so there was no actual customer-facing outage — but it's the closest this pipeline came
   to shipping something broken. Fixed: added `Key Vault Secrets User`, scoped to just the
   `kv-contextforge-dev` vault (not the RG), to the deploy app.

**Lesson worth generalizing:** #3, #4, #5, #7, and #8 are five genuinely *different* Azure
permission models colliding — subscription vs. resource-group scope, ARM control-plane vs. Key
Vault data-plane, generic ARM roles vs. Azure RBAC for Kubernetes Authorization, and built-in roles
vs. custom roles for one granular action. None of these gaps were things "read the role name and
guess" would have caught — each was found by running the real pipeline and reading the exact
`Forbidden` / `ForbiddenByRbac` message, one at a time, in the order the pipeline actually
encountered them.

### Status
✅ Fully verified live end-to-end 2026-07-06: PR #2 merged, `deploy.yml` approved through the
`production` Environment gate, `bicep-deploy` → `aks-creds` → `helm-aks-secrets` all green, gateway
pod confirmed healthy post-deploy (`kubectl get pods` showed a single `1/1 Running` pod, `/health`
returned `{"status":"healthy"}`).

---

## 5.4 — Observability (stretch)

Not started as of this writing. See `docs/phase5-plan.md` 5.4 for the intended scope
(OTel tracing on the 5.1/5.2 agents).
