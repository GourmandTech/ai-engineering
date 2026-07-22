#!/usr/bin/env bash
# Phase 6.1.4 follow-up — idempotently provisions the Infinity datasource +
# A2A agent dashboard against the self-hosted kube-prom Grafana instance.
#
# Prerequisites:
#   - make monitoring-upgrade has run (installs the yesoreyeram-infinity-datasource
#     plugin via infra/helm/values.monitoring.yaml)
#   - Key Vault secret grafana-admin-metrics-token exists (a ContextForge admin-tier
#     API token — see docs/runbooks/phase6-orchestration-finops-chaos.md Sec 6.1.4
#     for why this specifically needs to be admin-tier: GET /admin/metrics gates on
#     the requesting user's is_admin flag, not a scoped permission)
#
# Usage: KV_NAME=kv-contextforge-dev ./scripts/grafana-provision-a2a-dashboard.sh
set -euo pipefail

KV_NAME="${KV_NAME:-kv-contextforge-dev}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCAL_PORT="${GRAFANA_LOCAL_PORT:-3000}"

echo "=== Port-forwarding to kube-prom-grafana ==="
kubectl port-forward -n monitoring svc/kube-prom-grafana "${LOCAL_PORT}:80" > /tmp/grafana-provision-pf.log 2>&1 &
PF_PID=$!
trap 'kill $PF_PID 2>/dev/null || true' EXIT
sleep 3

GRAFANA_PASS=$(kubectl get secret --namespace monitoring kube-prom-grafana -o jsonpath="{.data.admin-password}" | base64 --decode)
CF_TOKEN=$(az keyvault secret show --vault-name "$KV_NAME" --name grafana-admin-metrics-token --query value -o tsv)

echo "=== Creating/updating the Infinity datasource ==="
EXISTING_UID=$(curl -s -u "admin:${GRAFANA_PASS}" "http://localhost:${LOCAL_PORT}/api/datasources" \
  | jq -r '.[] | select(.name=="ContextForge Admin Metrics") | .uid')

DS_BODY=$(jq -n --arg token "$CF_TOKEN" '{
  name: "ContextForge Admin Metrics",
  type: "yesoreyeram-infinity-datasource",
  access: "proxy",
  url: "https://contextforge.gourmandtech.com",
  jsonData: {auth_method: "bearerToken"},
  secureJsonData: {bearerToken: $token}
}')

if [ -n "$EXISTING_UID" ]; then
  DS_UID="$EXISTING_UID"
  curl -sf -u "admin:${GRAFANA_PASS}" -X PUT "http://localhost:${LOCAL_PORT}/api/datasources/uid/${DS_UID}" \
    -H "Content-Type: application/json" -d "$DS_BODY" > /dev/null
  echo "✓ Datasource updated (uid: ${DS_UID})"
else
  DS_UID=$(curl -sf -u "admin:${GRAFANA_PASS}" -X POST "http://localhost:${LOCAL_PORT}/api/datasources" \
    -H "Content-Type: application/json" -d "$DS_BODY" | jq -r '.datasource.uid')
  echo "✓ Datasource created (uid: ${DS_UID})"
fi

echo "=== Creating/updating the A2A agent dashboard ==="
DASHBOARD_JSON=$(sed "s/\${DS_UID}/${DS_UID}/g" "${REPO_ROOT}/infra/grafana/a2a-agent-dashboard.json")
PAYLOAD=$(jq -n --argjson dash "$DASHBOARD_JSON" '{dashboard: $dash, overwrite: true, message: "Provisioned via scripts/grafana-provision-a2a-dashboard.sh"}')
RESULT=$(curl -sf -u "admin:${GRAFANA_PASS}" -X POST "http://localhost:${LOCAL_PORT}/api/dashboards/db" \
  -H "Content-Type: application/json" -d "$PAYLOAD")
echo "✓ Dashboard provisioned: $(echo "$RESULT" | jq -r '.url')"
echo ""
echo "View at: make port-forward-grafana, then http://localhost:${LOCAL_PORT}$(echo "$RESULT" | jq -r '.url')"
