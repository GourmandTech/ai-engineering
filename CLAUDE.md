# AI Engineering — Claude Code Context

## Mission
Personal SRE/DevOps learning platform. Goal: demonstrate self-advancement in AI-assisted engineering, agentic coding, and AI automation for job placement. Core background: Microsoft Azure, Azure DevOps, Bicep. Expanding into: AI/ML Ops, agentic infrastructure, federated MCP.

## Current State (updated 2026-07-04)

### Phase 4 — COMPLETE ✅ (Federated MCP)
Full runbook: `docs/runbooks/phase4-federated-mcp.md`

**Goal:** Register multiple MCP servers into ContextForge, apply RBAC teams, and add Entra ID SSO.

**Numbering note:** this sub-task list (1-6) is the checklist of record for Phase 4. The runbook's own `## Step N` headings (0-9) are a finer breakdown of sub-task 4 alone (one step per server) plus sub-tasks 5-6 — the two numbering schemes don't line up 1:1. See the runbook's "Numbering scheme" section for the full mapping before assuming "step N" means the same thing in both places.

**MCP Server Inventory:**
| Server | Source | Transport | Status |
|---|---|---|---|
| SRE Toolbox MCP | `services/sre-mcp-server/` (custom Python FastMCP) | SSE | ✅ Running in AKS + registered in ContextForge |
| GitHub MCP | `github/github-mcp-server` (official, self-hosted) | stdio via `mcpgateway.translate` wrapper | ✅ Running in AKS + registered in ContextForge |
| Azure DevOps MCP | `microsoft/azure-devops-mcp` (official) | stdio via `mcpgateway.translate` wrapper | ✅ Running in AKS + registered in ContextForge |
| Kubernetes MCP | `containers/kubernetes-mcp-server` (Red Hat/containers, native SSE — no wrapper) | SSE (native) | ✅ Running in AKS + registered in ContextForge (13 tools) |
| Prometheus MCP | `pab1it0/prometheus-mcp-server` (community, native SSE — no wrapper) | SSE (native) | ✅ Running in AKS + registered in ContextForge (6 tools) |

**Phase 4 sub-tasks:**
1. ✅ Build + push SRE Toolbox MCP container to ACR (`make sre-mcp-build`)
2. ✅ Deploy SRE Toolbox to AKS (`make sre-mcp-deploy`) — pod `1/1 Running`
3. ✅ Register SRE Toolbox in ContextForge (`make mcp-register-sre`) — `status: active`, 5 tools federated
4. ✅ Register remaining MCP servers (GitHub, Azure DevOps, Kubernetes, Prometheus)
   - GitHub: ✅ COMPLETE 2026-07-02 — pod `1/1 Running`, registered, `status: active`, `reachable: true`, 22 tools federated. Hit five real bugs on the way, all fixed (full writeup: runbook Step 2 incident log): (1) `AADSTS70025` — CSI SecretProviderClass pointed at the wrong identity, fixed with a dedicated per-workload identity (`infra/bicep/modules/workload-identity.bicep`, reusable for Steps 3-5); (2) `make bicep-deploy` reverted the node pool autoscaler — fixed, see Node pool note above; (3) `mcpgateway.translate` invoked with flags that don't exist in the published package (`--expose-sse`) — fixed, pinned to `mcp-contextforge-gateway==0.1.1`; (4) NetworkPolicy ingress label guessed wrong (`app.kubernetes.io/name: mcpgateway` vs actual `app: mcp-stack-mcpgateway`) — fixed; (5) wrapped binary invoked without its required `stdio` positional subcommand, silently exiting instantly — fixed. `make github-mcp-deploy` also now force-restarts the rollout, since a `:latest`-tagged image rebuild doesn't otherwise trigger one.
   - Azure DevOps: ✅ COMPLETE 2026-07-03 — pod `1/1 Running`, registered, `status: active`, `reachable: true`, 40 tools federated. Reused the Step 2 wrapper pattern end-to-end: `services/azure-devops-mcp-wrapper/` (Node 20 base, `@azure-devops/mcp` installed globally and version-pinned rather than `npx`'d at runtime), `infra/k8s/azure-devops-mcp-server.yaml` + `azure-devops-mcp-secrets-provider.yaml`, `azureDevOpsMcpIdentity` module instance in `main.bicep` (same `workload-identity.bicep`, different name/SA), and `make azure-devops-mcp-build` / `azure-devops-mcp-deploy` / `mcp-register-azure-devops` targets. Hit five real bugs on the way, all fixed (full writeup: runbook Step 3 incident log): (1) `useradd -u 1000` failed with "UID 1000 is not unique" — `node:20-slim` already owns UID 1000 for its built-in `node` user (unlike the GitHub wrapper's `python:3.12-slim` base) — fixed by moving to UID 1001 in both the Dockerfile and the Deployment's `securityContext.runAsUser` (they must match); (2) `azure-devops-mcp-deploy`'s "identity not found" guard printed an error but didn't stop the recipe — `(... && exit 1)` only exits its own subshell, not the outer `;`-chained script — so it `kubectl apply`'d a SecretProviderClass/ServiceAccount with an **empty** clientID before `make bicep-deploy` had even provisioned the identity — fixed in both `github-mcp-deploy` and `azure-devops-mcp-deploy` by switching the guard to `{ ...; exit 1; }`; (3) `mcp-register-azure-devops` hung and returned a 504 — root cause was `mcpgateway.translate==0.1.1`'s stdout pump hitting its hard 64 KiB per-line limit on the combined `core+work-items+repositories+pipelines` tools/list response (measured at 71,345 bytes) — fixed by dropping the `repositories` domain (this org's source lives in GitHub, already federated via Step 2), landing at 42,364 bytes / 40 tools; (4) found while investigating (3) — the Dockerfile's `ARG AZURE_DEVOPS_MCP_VERSION` was declared before `FROM` and silently went out of scope, so the pin never applied and npm installed `latest` (2.7.0) instead of the intended 2.4.0 — fixed by re-pinning to the confirmed-correct 2.7.0 and redeclaring the ARG after `FROM`; (5) `make mcp-list-tools`/`mcp-list-gateways` weren't `@`-silenced, so piping their output into a further `jq` failed on Make's own echoed command text (SIGPIPE/Error 141) — fixed by `@`-silencing both. One real difference from GitHub worth remembering: the PAT must be **base64 of `<email>:<pat>`**, not the raw token, and there's no upstream `--read-only` flag — read-only enforcement here is entirely the PAT's own scopes (`Project and Team (Read)`, `Work Items (Read)`, `Build (Read)` — no `Code (Read)`, since `repositories` is excluded).
   - Kubernetes: ✅ COMPLETE 2026-07-03 — pod `1/1 Running`, `0` restarts, registered, `status: active`, `reachable: true`, 13 tools federated. Full writeup: runbook Step 4 incident log. Chose `containers/kubernetes-mcp-server` (Red Hat/containers, Go, native client-go) over the more popular `Flux159/mcp-server-kubernetes` specifically because of CVE-2026-46519 (CVSS 8.8, fixed upstream in v3.6.0) — Flux159's read-only/allowlist env vars were enforced at `tools/list` discovery but not `tools/call` execution, letting any client invoke a restricted tool by name. Three deliberate deviations from the Step 2-3 pattern: (1) no `mcpgateway.translate` wrapper — this binary natively serves SSE/Streamable HTTP via `--port`; (2) no Key Vault CSI / workload identity — it authenticates to the AKS API purely via its own ServiceAccount's automounted token (in-cluster client-go config), so `make bicep-deploy` isn't a prerequisite; (3) no image to build — deployed straight from `quay.io/containers/kubernetes_mcp_server:v0.0.63` (note the underscored repo name). RBAC: built-in `view` ClusterRole cluster-wide (excludes Secret data by k8s design) plus app-layer `--read-only` and `--toolsets=core,config` — defense in depth. **Bug found on first deploy:** pod CrashLoopBackOff'd 167 times with `dial tcp 10.1.0.1:443: i/o timeout` — the NetworkPolicy originally scoped apiserver egress to the AKS service CIDR (`10.1.0.0/16`), wrongly assuming `kubernetes.default.svc` was in-VNet traffic. This cluster has no AKS API Server VNet Integration, so the control plane is public — `kubectl get endpoints kubernetes -n default` showed the real backend is `4.157.231.123:443`, a public IP entirely outside the service/pod CIDR. Fixed by pointing the NetworkPolicy's egress `ipBlock` at that verified `/32` instead — reaching the apiserver on this cluster is architecturally identical to GitHub/ADO reaching their own public APIs, not intra-cluster traffic. Caveat carried into the manifest's comments: that public IP could in principle rotate (cluster upgrade, Azure-side migration), which would silently reproduce the same failure signature — re-run the `get endpoints` check first if this ever crash-loops again with the same error. RBAC verification: `list pods` → yes, `delete pods`/`get secrets` → no (returned as "Azure does not have opinion for this user" since this cluster has `enableAzureRBAC: true` and this ServiceAccount was deliberately never given an Azure role assignment — falls through to native K8s RBAC as expected, not a gap). New targets: `make kubernetes-mcp-deploy`, `make mcp-register-kubernetes`.
   - Prometheus: ✅ COMPLETE 2026-07-03 — pod `1/1 Running`, registered, `status: active`, `reachable: true`, 6 tools federated. Full writeup: runbook Step 5 incident log. Chose `pab1it0/prometheus-mcp-server` (GHCR, own Helm chart, native `stdio`/`http`/`sse` transport) — same no-wrapper, no-CSI, no-`bicep-deploy`-prerequisite shape as Kubernetes MCP, since kube-prometheus-stack's Prometheus has no auth in front of it by default. **Prerequisite confirmed 2026-07-03:** kube-prometheus-stack was genuinely not installed (`svc/prometheus-operated` didn't exist) — installed via `helm install kube-prom prometheus-community/kube-prometheus-stack -n monitoring --create-namespace`; `svc/prometheus-operated` now exists exactly as assumed (`prometheus-operated.monitoring.svc.cluster.local:9090`), and ContextForge's own ServiceMonitor is confirmed live too. **Bug found on first `make prometheus-mcp-deploy`, fixed:** the manifest's ServiceAccount put `automountServiceAccountToken: false` under `metadata:` instead of at the document's top level (a sibling of `apiVersion`/`kind`/`metadata`) — the API server's strict decoding rejected it (`unknown field "metadata.automountServiceAccountToken"`) while the Deployment/Service/NetworkPolicy in the same file applied cleanly. Caught by comparing against `azure-devops-mcp-server.yaml`'s ServiceAccount, which already had the field placed correctly. This slipped past this session's own YAML validation because `yaml.safe_load` only checks the file parses as YAML, not that it matches the Kubernetes API schema — worth remembering for any future manifest authored without a live cluster to `kubectl apply --dry-run=server` against. **Second bug, found immediately after re-deploying the fix above:** the pod went `ImagePullBackOff` — the manifest pinned `ghcr.io/pab1it0/prometheus-mcp-server:v1.6.1`, a `v`-prefixed tag that doesn't exist on GHCR (this project's other pinned image, `quay.io/containers/kubernetes_mcp_server:v0.0.63`, does use a `v` prefix, and that convention got pattern-matched onto this image without checking). Confirmed via the live GHCR package page: real tags are `1.6.1`, `1.6.0`, `1.5.3`, etc., none `v`-prefixed. Fixed: image now reads `ghcr.io/pab1it0/prometheus-mcp-server:1.6.1`.
   - **All 5 gateways verified together (runbook Step 6) ✅ COMPLETE 2026-07-03:** all `enabled: true`, `"total": 86` tools federated (5+22+40+13+6), exact match. Two more real bugs found and fixed during this verification pass, both in this project's own tooling: (1) the runbook's "equivalent direct curl" blocks use `$GATEWAY_URL` as a shell variable, but it was only ever a Makefile variable — never exported to the shell, so pasting those commands directly produced silent empty output while the `make` targets worked fine; fixed by adding `export GATEWAY_URL=...` to runbook Step 0; (2) `GET /tools`/`GET /gateways` default to ContextForge's `PAGINATION_DEFAULT_PAGE_SIZE=50` and silently truncate — `make mcp-list-tools` reported 50 instead of 86; fixed by appending `?limit=0` (disables pagination) to both Makefile targets and every curl reference in the runbook.
5. ✅ COMPLETE 2026-07-04 — Created RBAC teams (`sre-team` id `64be6990afc14d69890d7fb6a33c94a7`, `dev-team` id `555c6cf678884774a65ed7725488baf2`) and virtual servers (`sre-full` — 86 tools, all 5 gateways, team-scoped to `sre-team`; `dev-tools` — 62 tools, GitHub + Azure DevOps only, team-scoped to `dev-team`), confirmed live via `mcp-list-teams`/`mcp-list-servers`. Full writeup: runbook Step 7. Resolved both prior open questions against the live `/openapi.json`: (1) virtual servers attach via individual **tool IDs** (`associated_tools`), not gateway IDs — there's no gateway-level association field, so `mcp-create-server` resolves a `GATEWAYS=name1,name2` input to tool IDs via each tool's `gatewaySlug` before posting; (2) `visibility: "team"` does require `team_id` in the same request, in both the top-level body wrapper and the nested `ServerCreate` object. Two more real bugs found and fixed: (3) `POST /teams` (no trailing slash) 404s — only `POST /teams/` exists; (4) `GET /teams/` returns `{"teams": [...], "total": N}`, not a bare array like `/gateways`/`/tools`/`/servers` — and its `limit` param has a schema minimum of 1, so `?limit=0` 422s there (unlike the other list endpoints); fixed by using `?limit=500` instead.
6. ✅ COMPLETE 2026-07-04 — Registered Entra ID app `contextforge-sso` (App ID `628f926c-f973-4959-808b-5a01d41f9097`, tenant `c3754182-39f9-49ae-ada5-6aa91b4258a3`), created its Service Principal, granted Microsoft Graph `User.Read` with admin consent, stored the client secret in KV (`entra-client-secret`), wired `SSO_ENTRA_*` into `values.azure.yaml`/`helm-aks-secrets`, and deployed live via `make helm-aks-secrets`. Verified end-to-end at the API level: `/health` healthy post-rollout, `/auth/sso/providers` lists `entra`, `/auth/sso/login/entra` returns a correctly-formed Microsoft authorize URL (right client_id/tenant/redirect_uri/PKCE/scopes), and existing email/password JWT login still works (no regression). Full writeup: runbook Step 8. The original draft was wrong on several points, caught by reading `.contextforge/mcpgateway/config.py`/`routers/sso.py` directly instead of the docs tutorial: (1) there's no generic `SSO_PROVIDER`/`SSO_CLIENT_ID`/`SSO_TENANT_ID`/`SSO_REDIRECT_URI` — ContextForge namespaces every provider (`SSO_ENTRA_ENABLED`, `SSO_ENTRA_CLIENT_ID`, etc.); (2) the callback path is fixed by the app at `/auth/sso/callback/{provider_id}`, not configurable — the Entra app's redirect URI had to be `/auth/sso/callback/entra`, not the drafted `/auth/callback`; (3) `az ad app create` doesn't create the Service Principal that `az ad app permission grant` (and real sign-in) requires — needed an extra `az ad sp create` step the draft didn't have; (4) `az ad app permission grant` requires `--scope`, which the draft omitted. Also confirmed via `helm template` that although the chart's own `secret-gateway.yaml` independently defaults `SSO_ENABLED`/`SSO_ENTRA_ENABLED` to `"false"` (since the real values live under `config:`, not `secret:`), the Deployment's `envFrom` lists `configMapRef` after `secretRef`, so the ConfigMap's `"true"` correctly wins on the duplicate key. Interactive browser click-through (done manually 2026-07-04) surfaced two further real issues, both resolved — full writeup: runbook Step 8d. (1) First login hit `user_creation_failed`: the signed-in Azure AD user had `mail: null` (this tenant is the auto-provisioned "Default Directory" for a personal Microsoft account, with no `optionalClaims` configured on the app), so Microsoft's ID token omitted the `email` claim that `authenticate_or_create_user` hard-requires. Fixed by setting `mail` directly via `az rest PATCH` on the Graph `/users/{id}` endpoint (no `--mail` flag on `az ad user update`) and adding `email` as an optional ID-token claim on the app registration. (2) Second login hit `user_creation_failed` again for a different, non-bug reason: `djfernandez80@gmail.com` already exists as a local (`auth_provider='local'`) platform-admin account, and ContextForge deliberately refuses to auto-link an incoming SSO identity to an existing local account with the same email — confirmed via gateway logs (`SSO authenticate_or_create_user: account-linking required...`). There's no supported API to change `auth_provider` (checked `AdminUserUpdateRequest` in `schemas.py` — not one of its fields); the only path would be an unsupported raw SQL `UPDATE`, not done. Resolution: created a disposable second Entra user (`ssoadmin@djfernandez80gmail.onmicrosoft.com`, same missing-`mail` fix applied) purely for SSO testing — logged in via SSO successfully (auto-created as `auth_provider: "entra"`), then promoted to `is_admin: true` via the supported `PATCH /auth/email/admin/users/{email}` endpoint (note: `email_auth_router` is mounted at `/auth/email`, not `/auth` as first guessed). SSO login is now confirmed fully working end-to-end for any non-colliding identity; `djfernandez80@gmail.com` intentionally cannot use SSO login without a raw DB edit or retiring the local account — correct security behavior, not a gap.

**End-to-end smoke test (runbook Step 9) ✅ COMPLETE 2026-07-04:** health check, gateway list (all 5 enabled), and tool list (86 total, exact match) all passed cleanly. Found and worked around one confirmed upstream ContextForge bug in the process: `GET /servers/{id}/sse` (and the identical `GET /servers/{id}` single-object lookup) 404s for a genuine platform admin on a team-visibility virtual server — confirmed via the pod's own `server_access_denied` log showing `admin_bypass: false` for a real DB admin, even though the same admin correctly sees the same server via `GET /servers` (list) and `GET /servers/{id}/tools`. Root cause: the admin's session resolves `token_teams` to `[]` (not `None`/bypass) specifically at this endpoint's visibility check. Confirmed this is isolated to the admin-bypass path, not a broader RBAC failure, by creating a disposable non-admin Entra test user (`sretester@djfernandez80gmail.onmicrosoft.com`), adding it to `sre-team` as a plain member via `POST /teams/{team_id}/members`, and successfully establishing a live SSE handshake with that account's own session (`event: endpoint` + session ID + keepalive pings) — proving the real team-scoped RBAC mechanism from Step 7 works correctly end-to-end; only the platform-admin bypass shortcut is broken on this one endpoint family. This is vendored upstream code (`.contextforge/`) and not patched per this project's own convention. Also found: `/metrics` requires auth (401 without a token) and returns JSON aggregate stats, not Prometheus text — there is no `mcp_tool_calls_total` metric anywhere in the real Prometheus catalog (`/metrics/prometheus`); per-execution counts live in the JSON endpoint's `.tools.totalExecutions`. Full writeup: runbook Step 9.

**Key Phase 4 design decisions:**
- stdio MCP servers (GitHub, Azure DevOps MCP, Azure MCP) wrapped via `mcpgateway.translate` → SSE — GitHub's upstream binary is stdio-only (confirmed from its own Dockerfile), the vendor's only HTTP transport is the non-self-hostable `api.githubcopilot.com/mcp/`
- GitHub MCP self-hosted in-cluster rather than registered against GitHub's remote hosted endpoint — keeps the PAT and API traffic inside the AKS network boundary; the PAT is synced via Key Vault CSI directly into the `github-mcp-server` pod and never touches ContextForge's own gateway config
- GitHub App auth (short-lived installation tokens, no PAT rotation) is the stronger long-term auth pattern but is currently broken upstream — `github-mcp-server` forces a `GET /user` check that doesn't work with App auth ([issue #1610](https://github.com/github/github-mcp-server/issues/1610)). Using a fine-grained, repo-scoped PAT on a bot account as the interim approach; revisit when that's fixed.
- RBAC: API key auth for service accounts first, Entra ID OIDC SSO for human users second
- Virtual servers as the RBAC boundary — tools are `visibility=public` by default (set explicitly)
- Tool namespacing: ContextForge names tools as `<gateway-name>-<tool-name>` (hyphens, not `__`)
  - e.g. `sre-toolbox-sre-healthcheck` (underscores in tool names converted to hyphens)
- Custom Python MCP uses `mcp[cli]` + FastMCP SSE transport, AKS pod with ClusterRole read-only access
- HPA disabled on gateway Deployment: chart has no `{{- if not .Values.hpa.enabled }}` guard on
  `spec.replicas`, causing Helm SSA conflict with kube-controller-manager; AKS node autoscaler handles capacity
- `make helm-aks-secrets` always runs `kubectl rollout restart` post-upgrade: chart uses `envFrom`
  (env snapshotted at container start), so ConfigMap-only changes require a pod restart to take effect
- SSRF allowlist scoped to cluster CIDRs: `10.1.0.0/16` (service CIDR) + `10.0.0.0/22` (pod subnet)
- Gateway registration API is at `POST /gateways` — no `/v1/` prefix on any management endpoint

---


### Phase 1 — COMPLETE ✅
- Docker Compose stack running locally at `http://localhost:4444/admin`
- Confirmed healthy on MacBook Pro M1 (2026-06-26): `make test` returns `{"status":"healthy"}`
- Key fix: `MCPGATEWAY_UI_ENABLED: "true"` and `MCPGATEWAY_ADMIN_API_ENABLED: "true"` required in env (default is False in latest image)
- Devcontainer: `mcr.microsoft.com/devcontainers/python:3.12-bookworm` base, **`docker-in-docker` feature** (switched from `docker-outside-of-docker` on 2026-06-29 — see Minikube note).
- NOTE: With `docker-in-docker` the Compose stack runs on the devcontainer's own daemon and publishes to the devcontainer's localhost, so `MCP_HOST=localhost:4444` works directly (the old `gateway-1:4444` container-routing hack is gone).

### Minikube on M1 + devcontainer — root cause & fix (2026-06-29)
- **Symptom:** `make minikube-start` failed with `DRV_CREATE_TIMEOUT` — minikube created the kicbase node, then powered it off and retried until timeout.
- **Root cause:** minikube's docker driver on Docker Desktop always SSHes to the node via the **host's `127.0.0.1:<forwarded-port>`** (libmachine log: `dial tcp 127.0.0.1:54525: connect: connection refused`). Under `docker-outside-of-docker`, the devcontainer shares the host daemon but `127.0.0.1` is the devcontainer's own loopback, not the Mac host where that port is published — so SSH never connects. Pre-creating the docker network and attaching the devcontainer made `192.168.49.2:22` reachable, but minikube never dials the container IP, so it couldn't fix this.
- **Fix:** switched the devcontainer to `docker-in-docker`. The Docker daemon is now local to the devcontainer, so kicbase's forwarded ports land on the devcontainer's own `127.0.0.1` and minikube works natively — no `--network`, no pre-create, no attach hacks. `make minikube-start` is back to a plain `minikube start`.
- Confirmed during debugging: container-to-container traffic on the bridge was fine (`192.168.49.2:22` reachable), and the host's forwarded port was reachable via `host.docker.internal` — the only broken path was minikube's hardcoded `127.0.0.1`.

### Phase 2 — COMPLETE ✅
Full Helm stack deployed to minikube (profile `mcpgw`) on MacBook Pro M1. Confirmed 2026-06-29: `make helm-install` → all pods `1/1 Running`, gateway healthy over ingress (`curl http://gateway.local/health` from inside the devcontainer returns `{"status":"healthy"}`).

**Working flow:**
1. `make chart-fetch` — clones IBM/mcp-context-forge to `.contextforge/` (run once)
2. `make minikube-start` — plain `minikube start` under DinD (see Minikube note above)
3. `minikube image load ghcr.io/ibm/mcp-context-forge:v1.0.4 --profile mcpgw` — pre-load arm64 image
4. `make helm-install` — deploys chart with `infra/helm/values.yaml` overrides
5. Verify (inside devcontainer): `echo "192.168.49.2  gateway.local" | sudo tee -a /etc/hosts` then `curl http://gateway.local/health`
6. Host browser: `make port-forward` → open `http://localhost:8080/admin` on the Mac. `gateway.local` does NOT work from the host (cluster is nested in DinD — see Host access below).

**Phase 2 Helm override fixes** (full write-up: `docs/runbooks/helm-install-minikube.md`):
- `mcpContextForge.metrics.serviceMonitor.enabled: false` — minikube has no Prometheus Operator, so the chart's `ServiceMonitor` (`monitoring.coreos.com/v1`) is an unregistered kind and Helm can't render it.
- `migration.enabled: false` — the chart's migration Job is a Helm `post-install` hook that **deadlocks** against `--wait` (the gateway can't be Ready until the schema is migrated, but the hook only runs after Ready). With it off, the gateway self-migrates on boot (`MCPGATEWAY_SKIP_MIGRATIONS=false`), safe for single-replica. Re-enable for AKS.
- `mcpContextForge.ingress.annotations` → `ssl-redirect`/`force-ssl-redirect: "false"` — the chart hardcodes a forced HTTPS 308 even with TLS off, which 308s every request (incl. `/health`) to a dead `https://` scheme.

**Host access under DinD:** the minikube node IP (`192.168.49.2`) and `gateway.local` resolve/route only *inside* the devcontainer. From the Mac host browser, `gateway.local` fails with `DNS_PROBE_FINISHED_NXDOMAIN` — use `make port-forward` (gateway → `localhost:8080`, VS Code forwards to the host). See `docs/runbooks/minikube-devcontainer-dind.md`.

**M1/arm64 note:** ContextForge image (`ghcr.io/ibm/mcp-context-forge`) must support `linux/arm64`. Check with `docker manifest inspect ghcr.io/ibm/mcp-context-forge:v1.0.4` before pulling. If arm64 is missing, use `--platform linux/amd64` (Rosetta) in docker-compose.yml and Helm values extraEnv.

**Helm chart location:** `.contextforge/charts/mcp-stack` (upstream, not committed — listed in .gitignore)
**Our overrides:** `infra/helm/values.yaml` — 1 replica, pinned tag `v1.0.4`, ingress on `gateway.local`, TLS off, admin UI via extraEnv, ServiceMonitor off, migration off (self-migrate), ssl-redirect off.

### Phase 3 — COMPLETE ✅ (AKS)
Confirmed 2026-06-30: `curl https://contextforge.gourmandtech.com/health` → `{"status":"healthy"}` with valid Let's Encrypt TLS, TLSv1.3, HTTP/2, HSTS, and production security headers.

**Production URL:** `https://contextforge.gourmandtech.com`

**Node pool:** `system` — autoscaling enabled (min: 2, max: 10), configured 2026-07-02 via Azure Portal after single-node CPU exhaustion when sre-mcp-server was added alongside the gateway. This was Portal-only until 2026-07-02: a later `make bicep-deploy` (for the Phase 4 workload identity) silently reverted it back to a fixed 1-node pool via `infra/bicep/modules/aks.bicep`'s stale `enableAutoScaling: false` default, causing a second CPU-exhaustion-shaped outage (gateway pod `FailedScheduling`). Now fixed in IaC — `enableAutoScaling`/`minNodeCount`/`maxNodeCount` are real Bicep params defaulting to true/2/10, so `bicep-deploy` is safe to re-run. See `docs/runbooks/phase4-federated-mcp.md` Step 2 incident log.

**IaC files:**
- `infra/bicep/main.bicep` — subscription-scoped deployment, derives all resource names from params
- `infra/bicep/main.bicepparam` — 1 node, Standard_D2s_v7, eastus, maxPods=50, adminObjectId set
- `infra/bicep/modules/network.bicep` — VNet 10.0.0.0/16, AKS subnet 10.0.0.0/22
- `infra/bicep/modules/acr.bicep` — Standard ACR, admin disabled, managed identity pull
- `infra/bicep/modules/keyvault.bicep` — Standard KV, RBAC auth, soft-delete 7 days
- `infra/bicep/modules/aks.bicep` — AKS with CSI add-on, OIDC issuer, workload identity, Container Insights, AcrPull role, KV Secrets User role, maxPodsPerNode param
- `infra/bicep/modules/logworkspace.bicep` — PerGB2018, 30-day retention

**Helm / App files:**
- `infra/helm/values.azure.yaml` — 1 replica, Recreate strategy, HPA, TLS on `contextforge.gourmandtech.com`, cert-manager HTTP-01, strong security config, migration off (self-migrate)
- `infra/k8s/secret-provider-class.yaml` — CSI SecretProviderClass syncs KV → k8s Secret
- `infra/k8s/cluster-issuer.yaml` — Let's Encrypt prod ClusterIssuer (HTTP-01 via nginx)

**Working deploy flow (see full runbook: `docs/runbooks/aks-deploy.md`):**
1. `az account show` — confirm subscription
2. `make bicep-deploy` — provisions RG, VNet, ACR, Key Vault, AKS (uses `main.bicepparam`)
3. `make kv-populate KV_NAME=kv-contextforge-dev` — generate all secrets in KV
4. `make cluster-bootstrap` — installs nginx-ingress + cert-manager, applies ClusterIssuer + SecretProviderClass
5. `make helm-aks-secrets KV_NAME=kv-contextforge-dev` — deploy ContextForge with secrets from KV
6. Verify: `curl https://contextforge.gourmandtech.com/health`

**Critical Phase 3 lessons learned (see runbook for full detail):**

- **maxPods is immutable** — changing it requires AKS cluster deletion. Set `maxPodsPerNode: 50` in Bicep upfront (Azure CNI default of 30 is too low for observability add-ons like cert-manager).
- **Role assignment idempotency** — after AKS deletion, orphaned RG-scoped role assignments block redeployment with `RoleAssignmentUpdateNotPermitted`. Clean them before redeploying: `az role assignment list -g rg-contextforge-dev --query "[?principalName=='' || principalName==null].id" -o tsv | xargs -I {} az role assignment delete --ids {}`
- **BASIC_AUTH_PASSWORD** — gateway crashes even with `API_ALLOW_BASIC_AUTH: "false"` if the secret is weak. Must supply a strong value via `--set` from KV.
- **Migration Job deadlock** — `migration.enabled: true` + `helm --wait` deadlocks on single replica. Keep `migration.enabled: false`; gateway self-migrates on boot.
- **Azure Standard LB SNAT asymmetry** — the root cause of external port 80 timeouts. AKS creates two frontend IPs: one for the nginx ingress service (`a6e0a676...` = 52.226.253.79) and one for the system LB (`90989c11-...`). The `aksOutboundRule` only references the system frontend IP. With `DisableOutboundSnat: true` on the inbound rule, response packets are SNAT'd via the wrong public IP — clients drop them. **Fix:** `controller.service.externalTrafficPolicy: Local` on nginx-ingress. This bypasses kube-proxy SNAT entirely (direct pod→client path) and creates a health-check nodeport that returns 200 so the LB probe passes.
- **Let's Encrypt + `.nip.io`** — LE does not issue certificates for nip.io. Use a real domain.
- **Cloudflare proxy must be gray-cloud** for HTTP-01 ACME challenge — orange-cloud (proxy) breaks the challenge because LE sees Cloudflare's IP, not the LB IP.
- **kubelogin** — required for AKS with Azure AD RBAC. `make aks-creds` auto-installs arm64 binary and runs `kubelogin convert-kubeconfig -l azurecli`. Re-run after devcontainer restart.

---

## Active Project: IBM ContextForge MCP Gateway on AKS
Deploying IBM ContextForge — an open-source AI Gateway that federates MCP servers, REST APIs, gRPC services, and AI agents into a single unified endpoint — on Azure Kubernetes Service using Bicep IaC and Helm.

**Key Documentation:**
- [ContextForge Docs](https://ibm.github.io/mcp-context-forge/latest/)
- [GitHub Source](https://github.com/IBM/mcp-context-forge)
- [Deployment Overview](https://ibm.github.io/mcp-context-forge/latest/deployment/)
- [Azure/AKS Deployment](https://ibm.github.io/mcp-context-forge/latest/deployment/azure/)
- [Helm Chart Guide](https://ibm.github.io/mcp-context-forge/latest/deployment/helm/)
- [Federated MCP / A2A](https://ibm.github.io/mcp-context-forge/latest/using/agents/a2a/)

---

## Tech Stack

| Layer | Technology |
|---|---|
| Cloud | Microsoft Azure (personal subscription) |
| IaC | Bicep (modular) |
| Container Orchestration | AKS — Azure Kubernetes Service |
| Helm | v3 — chart deployments |
| CI/CD | GitHub Actions |
| AI Gateway | IBM ContextForge MCP Gateway |
| Protocol | MCP (Model Context Protocol), A2A (Agent-to-Agent) |
| Backing Services | PostgreSQL, Redis |
| Observability | Prometheus, OpenTelemetry |
| Local Dev | Docker Compose, Minikube |
| Language | Python, YAML, Bicep, Bash |

---

## Repository Structure

```
.
├── CLAUDE.md                       # This file — Claude Code context
├── AGENTS.md                       # Agentic behavior guidelines
├── Makefile                        # Task automation shortcuts
├── .claude/
│   ├── settings.json               # Claude Code permissions
│   └── commands/                   # Custom slash commands (skills)
│       ├── deploy-local.md         # /deploy-local
│       ├── deploy-minikube.md      # /deploy-minikube
│       ├── deploy-aks.md           # /deploy-aks
│       ├── mcp-test.md             # /mcp-test
│       ├── k8s-debug.md            # /k8s-debug
│       └── resume-update.md        # /resume-update
├── .devcontainer/
│   └── devcontainer.json           # VS Code dev container (all tools pre-installed)
├── .vscode/
│   └── extensions.json             # Recommended extensions
├── infra/
│   ├── bicep/                      # Azure IaC
│   │   ├── main.bicep
│   │   ├── main.parameters.json
│   │   └── modules/                # aks.bicep, acr.bicep, keyvault.bicep, network.bicep
│   └── helm/                       # Helm values per environment
│       ├── values.yaml             # Base defaults
│       └── values.azure.yaml       # AKS-specific overrides
├── docs/
│   ├── learning-path.md            # Phase-by-phase progression
│   ├── resume-bullets.md           # Generated resume impact bullets
│   ├── runbooks/                   # Operational runbooks
│   └── architecture/               # Architecture diagrams and ADRs
└── scripts/
    ├── setup.sh                    # Local dev setup script
    └── test-mcp.sh                 # MCP endpoint smoke tests
```

---

## Learning Phases

| Phase | Focus | Status |
|---|---|---|
| 1 | Local Docker Compose — understand ContextForge fundamentals | ✅ |
| 2 | Minikube — deploy full Helm stack, learn k8s primitives | ✅ |
| 3 | AKS — deploy to Azure with Bicep IaC, production-grade config | ✅ |
| 4 | Federated MCP — register multiple MCP servers, RBAC + OAuth | ✅ |
| 5 | Agent automation — A2A protocol, multi-agent orchestration | ⬜ |

---

## Common Commands

```bash
# ── Local Dev ───────────────────────
make up              # Start ContextForge via Docker Compose
make down            # Tear down
make logs            # Tail gateway logs
make test            # Smoke test MCP endpoints

# ── Minikube ────────────────────────
make minikube-start  # Start local k8s cluster
make helm-install    # Install chart to minikube
make helm-status     # Check release + pods

# ── Azure / AKS ─────────────────────
make az-login        # Authenticate to Azure
make bicep-deploy    # Deploy Azure infra via Bicep
make aks-creds       # Pull kubeconfig for AKS cluster
make helm-aks        # Deploy/upgrade to AKS
```

---

## Conventions

### Azure Resources
- All resources tagged: `environment`, `project=contextforge`, `owner=dfernandez`
- Resource group naming: `rg-contextforge-{env}`
- AKS cluster naming: `aks-contextforge-{env}`
- Primary region: `eastus`

### Bicep
- `@description()` decorator on every parameter
- Modular: one file per resource type under `infra/bicep/modules/`
- Use `existing` references — no hardcoded resource IDs
- Output resource IDs and endpoints, never secrets

### Helm
- Base values in `values.yaml`, environment overrides in `values.azure.yaml`
- Always set resource `requests` and `limits` on all containers
- Secrets via Azure Key Vault CSI driver — never literal values in values files
- Use `nameOverride` to keep release names predictable

### Git / Commits
- Conventional Commits: `feat:`, `fix:`, `docs:`, `chore:`, `infra:`
- Never commit `.env` files, `*.tfstate`, `kubeconfig`, or any credentials
- Branch naming: `feat/phase-2-minikube`, `fix/helm-postgres-pvc`

---

## MCP Gateway — Default Endpoints (local)

| Endpoint | URL |
|---|---|
| Admin UI | http://localhost:4444 |
| MCP (SSE) | http://localhost:4444/v1/ |
| Health | http://localhost:4444/health |
| Metrics | http://localhost:4444/metrics |
| Tools List | http://localhost:4444/v1/tools |

---

## What NOT To Do
- Never run `kubectl apply` raw manifests to AKS — use Helm
- Never use `latest` image tags in any Helm values for AKS
- Never modify upstream ContextForge source — override via Helm values only
- Never store secrets in environment variables unencrypted
- Never push directly to `main` — use PRs
