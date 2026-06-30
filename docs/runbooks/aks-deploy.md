# Runbook: Deploy ContextForge to AKS (Phase 3)

## Overview

End-to-end deployment of IBM ContextForge MCP Gateway to Azure Kubernetes Service using Bicep IaC and Helm. This runbook reflects the actual deploy sequence including all issues encountered and resolved on 2026-06-29/30.

**Production result:** `https://contextforge.gourmandtech.com/health` → `{"status":"healthy"}`, TLSv1.3, HTTP/2, Let's Encrypt cert, HSTS enabled.

## Prerequisites

- Azure CLI authenticated: `az login && az account show`
- Bicep CLI: `az bicep install`
- kubectl, helm 3+
- An Azure subscription with Contributor access
- A real domain with DNS control (Cloudflare or equivalent) — Let's Encrypt does not issue certs for `.nip.io`
- `openssl` and `unzip` available in your shell

Confirm your subscription before proceeding:

```bash
az account show --query '{name: name, id: id}' -o json
```

---

## Step 1 — Register Azure resource providers (once per subscription)

```bash
make az-register
```

Takes ~2 minutes. Safe to re-run — already-registered providers are a no-op.

---

## Step 2 — Set your admin Object ID

```bash
az ad signed-in-user show --query id -o tsv
```

Edit `infra/bicep/main.bicepparam` and paste the value into `adminObjectId`.

> **Note:** `main.bicepparam` (Bicep-native params) is used instead of `main.parameters.json` (ARM JSON). The `.bicepparam` format supports type-checking and `using` directive.

---

## Step 3 — Validate and Deploy Bicep

```bash
make bicep-validate
make bicep-deploy
```

The deployment creates (in `rg-contextforge-dev`):
- Log Analytics workspace
- VNet + AKS subnet (10.0.0.0/22, Azure CNI)
- Azure Container Registry (Standard, admin disabled)
- Key Vault (Standard, RBAC auth, soft-delete 7 days)
- AKS cluster (1 node, Standard_D2s_v7, k8s 1.35, **maxPods=50**) with:
  - Key Vault CSI add-on (secret rotation every 2 min)
  - OIDC issuer + workload identity
  - Azure Monitor / Container Insights
  - AcrPull pre-assigned to kubelet identity
  - Key Vault Secrets User pre-assigned to CSI driver identity
  - AKS RBAC Cluster Admin pre-assigned to your adminObjectId

Show outputs when done:

```bash
make bicep-outputs
```

### ⚠️ maxPods is immutable

`maxPods` (pods per node) cannot be changed on an existing AKS node pool — it requires cluster deletion and recreation. The Bicep sets `maxPodsPerNode: 50` (Azure CNI default is 30). **Do not lower this.** cert-manager alone needs ~6 pods and system pods consume ~15.

### ⚠️ Orphaned role assignments after cluster deletion

When you delete an AKS cluster and recreate it, the old kubelet/CSI managed identity object IDs are gone but their role assignments at the RG scope persist. Bicep uses `guid()` to name role assignments deterministically — the same GUID already exists (assigned to a deleted principal) and Azure returns `RoleAssignmentUpdateNotPermitted`.

Clean before redeploying:

```bash
az role assignment list -g rg-contextforge-dev \
  --query "[?principalName=='' || principalName==null].id" -o tsv \
  | xargs -I {} az role assignment delete --ids {}
```

The `make aks-delete` target runs this sweep automatically after cluster deletion.

---

## Step 4 — Install kubelogin (arm64 devcontainer)

`az aks install-cli` requires write access to `/usr/local/bin` which the `vscode` user doesn't have. `make aks-creds` auto-installs kubelogin to `~/.local/bin`, but the PATH must include it:

```bash
export PATH="$HOME/.local/bin:$PATH"
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
```

Then:

```bash
make aks-creds
kubectl get nodes   # should show 1 node in Ready state
```

`make aks-creds` calls `kubelogin convert-kubeconfig -l azurecli` automatically, wiring kubectl to your `az login` session.

> **After devcontainer restart:** kubectl context is lost. Re-run `make aks-creds` to restore it.

**If `kubectl get nodes` returns Forbidden:** RBAC propagation takes 1-2 min. Run `kubelogin remove-tokens` then retry.

---

## Step 5 — Populate Key Vault Secrets

```bash
make kv-populate KV_NAME=kv-contextforge-dev

az keyvault secret set --vault-name kv-contextforge-dev \
  --name platform-admin-email --value "you@yourdomain.com"
az keyvault secret set --vault-name kv-contextforge-dev \
  --name platform-admin-password --value "YourStrongPassw0rd!"
```

`kv-populate` also generates `basic-auth-password` (a random base64 string). This secret is required even with `API_ALLOW_BASIC_AUTH: "false"` because the gateway validates `REQUIRE_STRONG_SECRETS: "true"` unconditionally.

Verify all secrets exist:

```bash
az keyvault secret list --vault-name kv-contextforge-dev --query '[].name' -o tsv
```

Expected: `auth-encryption-secret`, `basic-auth-password`, `default-user-password`, `jwt-secret-key`, `platform-admin-email`, `platform-admin-password`

---

## Step 6 — Bootstrap the cluster (nginx + cert-manager + ClusterIssuer)

```bash
make cluster-bootstrap
```

This target:
1. Installs **nginx-ingress** with `externalTrafficPolicy: Local` (critical — see SNAT note below)
2. Installs **cert-manager** with CRDs
3. Applies `infra/k8s/cluster-issuer.yaml` (Let's Encrypt prod, HTTP-01)
4. Creates the `mcp` namespace
5. Applies `infra/k8s/secret-provider-class.yaml` (CSI KV sync)

After completion, get the nginx external IP:

```bash
EXTERNAL_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "External IP: $EXTERNAL_IP"
```

### ⚠️ CRITICAL: externalTrafficPolicy: Local (Azure LB SNAT asymmetry)

AKS Standard Load Balancer creates **two frontend public IPs**: one for the nginx ingress service and one for the AKS system LB. The `aksOutboundRule` for outbound SNAT only references the system frontend IP.

With the default `externalTrafficPolicy: Cluster`:
- Client connects to nginx IP (e.g., `52.226.253.79:80`)
- Response is SNAT'd through the *system* IP (a different public IP)
- Client receives SYN-ACK from the wrong IP and drops it → **external port 80 times out**
- In-cluster curl works (hairpin NAT) — this is a misleading clue

With `externalTrafficPolicy: Local`:
- kube-proxy does NOT SNAT traffic — pod responds directly to client through the same LB frontend
- A health-check nodeport is created that returns 200 → LB probe passes
- No asymmetric routing

This is the root cause of Let's Encrypt HTTP-01 challenge failures when nginx is reachable in-cluster but not externally.

To fix on an existing install:

```bash
helm upgrade ingress-nginx ingress-nginx/ingress-nginx \
  -n ingress-nginx --reuse-values \
  --set controller.service.externalTrafficPolicy=Local
```

### DNS setup

Point your domain A record to `$EXTERNAL_IP` in Cloudflare (or your DNS provider) **before** deploying ContextForge. cert-manager's HTTP-01 challenge will fail if DNS doesn't resolve to the LB IP.

**Cloudflare users:** the record must be **gray-cloud (DNS-only)** for HTTP-01 to work. Orange-cloud proxying hides the origin IP — Let's Encrypt sees Cloudflare's IP and the challenge fails.

---

## Step 7 — Deploy ContextForge via Helm

```bash
make helm-aks-secrets KV_NAME=kv-contextforge-dev
```

This pulls all secrets from Key Vault at deploy time and passes them via `--set`. Watch the rollout:

```bash
kubectl get pods -n mcp -w
```

Expected final state: `mcp-stack-mcpgateway-xxx   1/1 Running`

### ⚠️ BASIC_AUTH_PASSWORD crash

The gateway validates `REQUIRE_STRONG_SECRETS: "true"` for ALL secrets including `BASIC_AUTH_PASSWORD`, even when `API_ALLOW_BASIC_AUTH: "false"`. If this secret is missing or weak, the gateway crashes with `ERR_WEAK_SECRET` on startup. The `kv-populate` target generates a strong value automatically.

### ⚠️ Migration Job deadlock (single node)

`migration.enabled: true` + `helm --wait` deadlocks: the gateway pod can't become `Ready` until migration completes, but the Helm post-install hook only fires after `Ready`. Keep `migration.enabled: false` in `values.azure.yaml` — the gateway self-migrates on boot via `MCPGATEWAY_SKIP_MIGRATIONS=false` (the default). Safe for single-replica. Re-enable for multi-replica AKS when you have a larger node.

---

## Step 8 — Verify TLS and health

cert-manager issues the certificate automatically after the ClusterIssuer is applied and DNS is resolving. Monitor:

```bash
kubectl get certificate,certificaterequest,order,challenge -n mcp -w
```

Once `certificate READY=True`:

```bash
curl https://contextforge.gourmandtech.com/health
curl https://contextforge.gourmandtech.com/v1/tools | jq '{count: (.tools | length)}'
echo "Admin UI: https://contextforge.gourmandtech.com/admin"
```

Expected health response: `{"status":"healthy"}`

### If the certificate stays READY=False

1. Check the challenge: `kubectl describe challenge -n mcp`
2. The most common cause is port 80 unreachable externally (see SNAT asymmetry above)
3. Test external access: `curl -v --max-time 10 http://<EXTERNAL_IP>/` — should return nginx 404 (not timeout)
4. If the order is in `invalid` state, delete the Certificate to force a fresh ACME order:
   ```bash
   kubectl delete certificate contextforge-tls -n mcp
   # cert-manager's ingress-shim recreates it automatically from the Ingress annotation
   ```

---

## Troubleshooting

**Pod stuck in `Init:0/1` or `Pending`:**
```bash
kubectl describe pod -n mcp -l app.kubernetes.io/name=mcpgateway
kubectl get events -n mcp --sort-by='.lastTimestamp'
```

**Too many pods / Unschedulable:**
`maxPods=30` (the Azure CNI default) is too low. cert-manager + nginx + system pods easily exceed 30. You must delete and recreate the AKS cluster with `maxPods=50`. `make aks-delete` cleans orphaned role assignments automatically.

**CSI secret not mounting:**
```bash
kubectl get secretproviderclass -n mcp
kubectl get pods -n kube-system -l app=secrets-store-csi-driver
kubectl get secret contextforge-secrets -n mcp
```

**kubectl context lost (after devcontainer restart):**
```bash
make aks-creds
```

**Helm upgrade stuck (Recreate strategy):**
With `strategy.type: Recreate`, helm `--wait` blocks while the old pod terminates. This is expected — wait for the old pod to terminate before the new one starts. If it hangs: `kubectl delete pod -n mcp -l app.kubernetes.io/name=mcpgateway`.

---

## Cost Estimate (dev configuration)

| Resource | SKU | Est. monthly |
|---|---|---|
| AKS (1 × Standard_D2s_v7) | Pay-as-you-go | ~$70 |
| ACR Standard | Standard | ~$5 |
| Key Vault Standard | Per-secret + ops | <$1 |
| Log Analytics | PerGB2018 / 30-day retention | ~$2 |
| Load Balancer | Standard | ~$20 |
| **Total** | | **~$100/mo** |

Stop costs when not in use:
```bash
az aks stop --name aks-contextforge-dev --resource-group rg-contextforge-dev
```

---

## Next: Phase 4 — Federated MCP

With Phase 3 complete (`https://contextforge.gourmandtech.com` healthy with TLS), Phase 4 registers additional MCP servers against the gateway and enables RBAC + OAuth scoping.
