# Runbook — Deploying the ContextForge `mcp-stack` Helm chart on Minikube

**Status:** Resolved — `make helm-install` deploys cleanly, gateway healthy over ingress
**Date:** 2026-06-29
**Phase:** 2 (Minikube)
**Affected:** MacBook Pro M1 (arm64), minikube (profile `mcpgw`), Helm v4, chart `mcp-stack` v1.0.4
**Prerequisite:** a working minikube cluster — see `minikube-devcontainer-dind.md` for the cluster-creation fix.

---

## Summary

After the minikube cluster was up, `make helm-install` hit three independent failures in
sequence. All three are upstream-chart defaults that assume a production cluster (Prometheus
Operator present, multi-replica, TLS terminated). Each was fixed with an override in
`infra/helm/values.yaml`; none required touching the upstream chart. After all three, the full
stack (gateway + postgres + redis + fast-time-server) deploys and the gateway answers on the
ingress.

| # | Failure | Fix (in `infra/helm/values.yaml`) |
|---|---|---|
| 1 | `no matches for kind "ServiceMonitor"` | `mcpContextForge.metrics.serviceMonitor.enabled: false` |
| 2 | `Deployment ... not ready ... context deadline exceeded` (gateway CrashLoopBackOff) | `migration.enabled: false` |
| 3 | Browser/curl `308 Permanent Redirect → https://` | gateway ingress `force-ssl-redirect: "false"` |

---

## Issue 1 — ServiceMonitor CRD not registered

### Symptom
```
Error: unable to build kubernetes objects from release manifest: resource mapping not found
for name: "mcp-stack-mcpgateway" namespace: "" from "": no matches for kind "ServiceMonitor"
in version "monitoring.coreos.com/v1" ensure CRDs are installed first
```
Helm fails at manifest-build time, before creating anything.

### Root cause
The chart renders a `ServiceMonitor` (`templates/servicemonitor-mcpgateway.yaml`) gated on
`mcpContextForge.metrics.enabled AND mcpContextForge.metrics.serviceMonitor.enabled`, both
`true` by default. `ServiceMonitor` is a CRD supplied by the **Prometheus Operator**, which a
bare minikube does not have — so `monitoring.coreos.com/v1` is not a registered kind and Helm
cannot map the resource.

### Fix
In-app Prometheus metrics stay on; only the CRD object is disabled.
```yaml
mcpContextForge:
  metrics:
    enabled: true
    serviceMonitor:
      enabled: false
```
It is the only `monitoring.coreos.com` resource in the chart, and the broader `monitoring:`
sub-stack is already `enabled: false`, so this is the complete fix. Re-enable in the
observability phase after installing `kube-prometheus-stack` (which ships the CRD).

---

## Issue 2 — Migration hook deadlock vs `--wait` (gateway CrashLoopBackOff)

### Symptom
```
Error: resource Deployment/mcp/mcp-stack-mcpgateway not ready. status: InProgress,
message: Available: 0/1 ... context deadline exceeded
```
`kubectl get pods -n mcp` shows the gateway in `CrashLoopBackOff`; `kubectl get jobs -n mcp`
shows **no migration job**. Gateway logs end with:
```
MCPGATEWAY_SKIP_MIGRATIONS=true but schema is not at head ...
mcpgateway.bootstrap_db._SchemaNotAtHeadError: Schema not at head; migrations required before startup
```

### Root cause
A classic Helm hook-ordering deadlock:

- The chart sets the gateway env `MCPGATEWAY_SKIP_MIGRATIONS = ternary "true" "false"
  .Values.migration.enabled` (`deployment-mcpgateway.yaml`). With `migration.enabled: true`,
  the gateway is told **not** to migrate and to depend on a dedicated migration Job.
- That migration Job (`templates/job-migration.yaml`) is a Helm **`post-install`** hook.
- Helm runs `post-install` hooks **after** `--wait` confirms the release's resources are Ready.
- But the gateway Deployment can never become Ready: it hard-fails on boot because the schema
  isn't migrated. So `--wait` blocks on the gateway → the `post-install` migration hook never
  runs → the schema is never created → 8-minute timeout. The migration Job is never even created,
  which is why `kubectl get jobs` is empty.

### Fix
For local single-replica dev, let each gateway pod run the migration itself on boot (the chart
documents this path as safe for single-replica):
```yaml
migration:
  enabled: false        # gateway gets MCPGATEWAY_SKIP_MIGRATIONS=false → self-migrates on boot
```
With this, the gateway runs Alembic on startup, brings the schema to head, and becomes Ready —
`--wait` returns success. Keep the dedicated migration Job for multi-replica / AKS
(`values.azure.yaml`), where Postgres is managed separately and the `pre-install`/`pre-upgrade`
hook phase is appropriate.

> Note: a failed first install leaves the release in `failed` state. Because revision 1 never
> reached `deployed`, `helm upgrade --install` can error with "has no deployed releases" — run
> `make helm-uninstall` once, then `make helm-install`.

---

## Issue 3 — Forced HTTPS redirect (308) on a TLS-off cluster

### Symptom
```
$ curl -si http://gateway.local/health
HTTP/1.1 308 Permanent Redirect
Location: https://gateway.local/health
```
`curl ... | jq` fails with `parse error: Invalid numeric literal` (it's parsing nginx's HTML
redirect page, not JSON). The pod itself is healthy — a direct `port-forward` to it returns
`{"status":"healthy"}`.

### Root cause
The chart **hardcodes** SSL-redirect annotations on the gateway ingress
(`templates/ingress.yaml`):
```
nginx.ingress.kubernetes.io/ssl-redirect: "true"
nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
```
`force-ssl-redirect` issues the 308 to `https://` **regardless of whether TLS is configured**.
On minikube with TLS disabled there's no HTTPS listener for the gateway host, so every plain-HTTP
request is bounced to a dead scheme. (The co-resident `fast-time` ingress carrying TLS on the
same host `gateway.local` compounds the host's redirect behavior.)

### Fix
The template merges user annotations *on top of* its hardcoded defaults, so override them to
`false` on the gateway ingress:
```yaml
mcpContextForge:
  ingress:
    annotations:
      nginx.ingress.kubernetes.io/ssl-redirect: "false"
      nginx.ingress.kubernetes.io/force-ssl-redirect: "false"
```
After `make helm-install` (an in-place upgrade), `curl http://gateway.local/health` returns the
healthy JSON with no redirect.

---

## Verification

```bash
make helm-install
# STATUS: deployed ; all pods 1/1 Running

# inside the dev container (gateway.local resolves here):
curl -s http://gateway.local/health | jq .
# -> {"status":"healthy", ...}
```

Host-browser access does **not** use `gateway.local` (the cluster is nested in Docker-in-Docker —
see the DinD runbook). Use a port-forward instead:
```bash
make port-forward          # gateway → localhost:8080, VS Code forwards to the Mac
# open http://localhost:8080/admin in the host browser
```

---

## Lessons learned

- Upstream Helm charts default to production assumptions: a Prometheus Operator CRD, a dedicated
  migration runner, and TLS-terminated ingress. On a bare local cluster, each is a separate
  failure — read the chart's `templates/` and value gates rather than guessing.
- A `post-install` migration hook + `--wait` + an app that hard-requires a migrated schema is a
  deadlock. For single-replica, self-migration (`migration.enabled: false`) sidesteps it.
- When `curl | jq` throws `Invalid numeric literal`, re-run with `curl -si` — you're almost
  certainly parsing an HTTP redirect or an HTML error page, not JSON.
- A `failed` revision 1 must be `helm uninstall`-ed before reinstalling.

---

## References

- Chart source: https://github.com/IBM/mcp-context-forge/tree/main/charts/mcp-stack
- Helm hooks & ordering: https://helm.sh/docs/topics/charts_hooks/
- nginx ingress SSL redirect: https://kubernetes.github.io/ingress-nginx/user-guide/nginx-configuration/annotations/#server-side-https-enforcement-through-redirect
- Companion runbook: `docs/runbooks/minikube-devcontainer-dind.md` — cluster creation under DinD.
- Overrides live in `infra/helm/values.yaml`; AKS overrides will live in `infra/helm/values.azure.yaml`.
