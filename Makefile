.PHONY: help up down logs test \
        minikube-start helm-install helm-upgrade helm-status helm-diff helm-uninstall \
        az-login bicep-validate bicep-deploy aks-creds helm-aks \
        mcp-register mcp-status port-forward \
        sre-mcp-build sre-mcp-deploy github-mcp-build github-mcp-deploy \
        azure-devops-mcp-build azure-devops-mcp-deploy \
        kubernetes-mcp-deploy \
        prometheus-mcp-deploy \
        mcp-get-token mcp-list-gateways mcp-list-tools mcp-register-sre mcp-register-github mcp-register-azure-devops mcp-register-kubernetes mcp-register-prometheus \
        mcp-create-team mcp-list-teams mcp-create-server mcp-list-servers \
        lint clean

# ─────────────────────────────────────────────────────────────
# Config
# ─────────────────────────────────────────────────────────────
RESOURCE_GROUP   ?= rg-contextforge-dev
AKS_CLUSTER      ?= aks-contextforge-dev
AKS_NODEPOOL     ?= system
NAMESPACE        ?= mcp
HELM_RELEASE     ?= mcp-stack
HELM_CHART       ?= .contextforge/charts/mcp-stack
HELM_VALUES      ?= infra/helm/values.yaml
HELM_VALUES_AKS  ?= infra/helm/values.azure.yaml
MINIKUBE_PROFILE ?= mcpgw
AZ_LOCATION      ?= eastus

# With docker-in-docker, the Compose stack runs on this devcontainer's own daemon
# and publishes ports to the devcontainer's localhost — so localhost works whether
# or not we're inside the container.
MCP_HOST         ?= localhost:4444

# ─────────────────────────────────────────────────────────────
# Help
# ─────────────────────────────────────────────────────────────
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'

# ─────────────────────────────────────────────────────────────
# Local Dev — Docker Compose
# ─────────────────────────────────────────────────────────────
up: ## Start ContextForge stack via Docker Compose
	docker compose up -d
	@echo "Waiting for gateway to be healthy..."
	@for i in $$(seq 1 30); do \
	  if curl -sf http://$(MCP_HOST)/health > /dev/null 2>&1; then \
	    echo "✓ ContextForge ready at http://$(MCP_HOST)"; \
	    break; \
	  fi; \
	  sleep 2; \
	done

down: ## Stop and remove Docker Compose services
	docker compose down

logs: ## Tail gateway container logs
	docker compose logs -f gateway

test: ## Smoke test MCP endpoints
	@echo "=== Health ===" && curl -sf http://$(MCP_HOST)/health | jq .
	@echo "=== Tools ===" && curl -sf http://$(MCP_HOST)/v1/tools | jq '{count: (.tools | length)}'
	@echo "=== Metrics ===" && curl -sf http://$(MCP_HOST)/metrics | grep "^mcp_" | head -5

# ─────────────────────────────────────────────────────────────
# Minikube — Local Kubernetes
# ─────────────────────────────────────────────────────────────
chart-fetch: ## Clone ContextForge upstream repo (run once before helm-install)
	@if [ -d ".contextforge" ]; then \
	  echo "✓ .contextforge already present. Remove it first to re-fetch."; \
	else \
	  git clone --depth 1 https://github.com/IBM/mcp-context-forge.git .contextforge; \
	  echo "✓ Chart available at .contextforge/charts/mcp-stack"; \
	fi

minikube-start: ## Start Minikube cluster (profile: mcpgw) with ingress + ingress-dns
	@# Devcontainer runs docker-in-docker: the Docker daemon is local to this
	@# container, so minikube's docker driver reaches the kicbase node over its
	@# 127.0.0.1 forwarded ports natively — no network pre-create/attach needed.
	minikube start \
	  --profile $(MINIKUBE_PROFILE) \
	  --driver docker \
	  --cpus 4 \
	  --memory 6144 \
	  --preload=false \
	  --addons ingress,ingress-dns,metrics-server
	kubectl config use-context $(MINIKUBE_PROFILE)
	@echo "✓ Minikube ready. Context: $$(kubectl config current-context)"
	@printf '  Next: add gateway.local to /etc/hosts:\n    echo "%s  gateway.local" | sudo tee -a /etc/hosts\n' "$$(minikube ip --profile $(MINIKUBE_PROFILE))"

helm-install: ## Install ContextForge to Minikube (requires: make chart-fetch first)
	@test -d "$(HELM_CHART)" || (echo "ERROR: Chart not found. Run: make chart-fetch" && exit 1)
	helm upgrade --install $(HELM_RELEASE) $(HELM_CHART) \
	  --namespace $(NAMESPACE) --create-namespace \
	  --values $(HELM_VALUES) \
	  --kube-context $(MINIKUBE_PROFILE) \
	  --wait --timeout=8m
	@$(MAKE) helm-status

helm-status: ## Show Helm release status and pod health
	@echo "=== Helm Release ==="
	helm status $(HELM_RELEASE) -n $(NAMESPACE) --kube-context $(MINIKUBE_PROFILE)
	@echo "=== Pods ==="
	kubectl get pods -n $(NAMESPACE) -o wide --context $(MINIKUBE_PROFILE)
	@echo "=== Services ==="
	kubectl get svc -n $(NAMESPACE) --context $(MINIKUBE_PROFILE)

helm-diff: ## Show diff between deployed and local chart (requires helm-diff plugin)
	helm diff upgrade $(HELM_RELEASE) $(HELM_CHART) \
	  --namespace $(NAMESPACE) \
	  --values $(HELM_VALUES) \
	  --kube-context $(MINIKUBE_PROFILE)

helm-uninstall: ## Uninstall the Helm release from Minikube
	helm uninstall $(HELM_RELEASE) -n $(NAMESPACE) --kube-context $(MINIKUBE_PROFILE)

port-forward: ## Port-forward gateway to localhost:8080 (Minikube → host browser)
	@echo "Gateway → http://localhost:8080   (admin UI: /admin · health: /health)"
	@echo "VS Code forwards 8080 to your Mac; open it in the host browser."
	kubectl port-forward svc/$(HELM_RELEASE)-mcpgateway 8080:80 \
	  -n $(NAMESPACE) --context $(MINIKUBE_PROFILE)

# ─────────────────────────────────────────────────────────────
# Azure — Authentication & Infra
# ─────────────────────────────────────────────────────────────
az-login: ## Authenticate to Azure
	az login
	@echo "Subscription: $$(az account show --query name -o tsv)"

az-register: ## Register all Azure resource providers required by this stack (run once per subscription)
	@echo "Registering required providers (this takes ~2 min, watch with: az provider list --query \"[?registrationState=='Registering']\" -o table)"
	az provider register --namespace Microsoft.ContainerService
	az provider register --namespace Microsoft.OperationsManagement
	az provider register --namespace Microsoft.OperationalInsights
	az provider register --namespace Microsoft.Insights
	az provider register --namespace Microsoft.KeyVault
	az provider register --namespace Microsoft.ContainerRegistry
	az provider register --namespace Microsoft.Network
	@echo "Waiting for registration to complete..."
	@for ns in Microsoft.ContainerService Microsoft.OperationsManagement Microsoft.OperationalInsights Microsoft.Insights; do \
	  echo -n "  $$ns: "; \
	  for i in $$(seq 1 30); do \
	    state=$$(az provider show --namespace $$ns --query registrationState -o tsv 2>/dev/null); \
	    if [ "$$state" = "Registered" ]; then echo "✓"; break; fi; \
	    sleep 5; \
	  done; \
	done
	@echo "✓ All providers registered"

bicep-validate: ## Validate Bicep templates without deploying
	az bicep build --file infra/bicep/main.bicep
	az deployment sub validate \
	  --location $(AZ_LOCATION) \
	  --parameters infra/bicep/main.bicepparam
	@echo "✓ Bicep validation passed"

bicep-deploy: bicep-validate ## Deploy Azure infrastructure via Bicep (prompts for confirmation)
	@echo "WARNING: This will create/update Azure resources in subscription: $$(az account show --query name -o tsv)"
	@read -p "Continue? [y/N] " confirm && [ "$$confirm" = "y" ] || exit 1
	az deployment sub create \
	  --location $(AZ_LOCATION) \
	  --parameters infra/bicep/main.bicepparam \
	  --name "contextforge-$$(date +%Y%m%d-%H%M%S)"

bicep-outputs: ## Show outputs from the last Bicep deployment
	@az deployment sub show \
	  --name "$$(az deployment sub list --query '[0].name' -o tsv)" \
	  --query properties.outputs \
	  -o json | jq '{aksCluster: .aksClusterName.value, acr: .acrLoginServer.value, keyVault: .keyVaultName.value, oidcIssuer: .oidcIssuerUrl.value}'

kv-populate: ## Generate and store ContextForge secrets in Key Vault (KV_NAME required)
	@test -n "$(KV_NAME)" || (echo "Usage: make kv-populate KV_NAME=kv-contextforge-dev" && exit 1)
	@echo "Populating Key Vault: $(KV_NAME)"
	az keyvault secret set --vault-name $(KV_NAME) --name jwt-secret-key         --value "$$(openssl rand -base64 32)" -o none
	az keyvault secret set --vault-name $(KV_NAME) --name auth-encryption-secret --value "$$(openssl rand -base64 32)" -o none
	az keyvault secret set --vault-name $(KV_NAME) --name default-user-password  --value "$$(openssl rand -base64 18)" -o none
	az keyvault secret set --vault-name $(KV_NAME) --name basic-auth-password    --value "$$(openssl rand -base64 18)" -o none
	@echo "✓ Secrets written. Set platform-admin-email and platform-admin-password manually."
	@echo "  az keyvault secret set --vault-name $(KV_NAME) --name platform-admin-email --value 'you@example.com'"
	@echo "  az keyvault secret set --vault-name $(KV_NAME) --name platform-admin-password --value 'YourPassword'"
	@echo "  az keyvault secret set --vault-name $(KV_NAME) --name github-mcp-pat --value 'YourFineGrainedPAT'"
	@echo "    (fine-grained PAT, repo-scoped, from a bot/machine account — see"
	@echo "     infra/k8s/github-mcp-secrets-provider.yaml for generation guidance)"
	@echo "  az keyvault secret set --vault-name $(KV_NAME) --name azure-devops-mcp-pat --value 'BASE64_OF_email:PAT'"
	@echo "    (value must be base64-encoded '<email>:<pat>', NOT the raw PAT — see"
	@echo "     infra/k8s/azure-devops-mcp-secrets-provider.yaml for generation + encoding steps)"

aks-delete: ## Delete the AKS cluster and its orphaned role assignments (preserves ACR, Key Vault, VNet)
	@echo "WARNING: This deletes $(AKS_CLUSTER). ACR, Key Vault, and VNet are preserved."
	@read -p "Continue? [y/N] " confirm && [ "$$confirm" = "y" ] || exit 1
	az aks delete \
	  --resource-group $(RESOURCE_GROUP) \
	  --name $(AKS_CLUSTER) \
	  --yes
	@echo "Cluster deleted. Cleaning up orphaned role assignments..."
	@STALE=$$(az role assignment list -g $(RESOURCE_GROUP) \
	  --query "[?principalName=='' || principalName==null].id" -o tsv 2>/dev/null); \
	if [ -n "$$STALE" ]; then \
	  echo "$$STALE" | xargs -I {} az role assignment delete --ids {} && echo "✓ Stale role assignments removed"; \
	else \
	  echo "✓ No stale role assignments found"; \
	fi

cluster-bootstrap: aks-creds ## Install nginx ingress + cert-manager and apply cluster manifests (run once after AKS is provisioned)
	@echo "=== Installing nginx ingress controller ==="
	helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
	helm repo update
	helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
	  --namespace ingress-nginx --create-namespace \
	  --set controller.service.type=LoadBalancer \
	  --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-load-balancer-health-probe-protocol"=tcp \
	  --wait --timeout=5m
	@echo "External IP: $$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
	@echo "=== Installing cert-manager ==="
	helm repo add jetstack https://charts.jetstack.io 2>/dev/null || true
	helm repo update
	helm upgrade --install cert-manager jetstack/cert-manager \
	  --namespace cert-manager --create-namespace \
	  --set installCRDs=true \
	  --wait --timeout=5m
	@echo "=== Applying cluster manifests ==="
	kubectl create namespace $(NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -
	@TENANT_ID=$$(az account show --query tenantId -o tsv); \
	CSI_CLIENT_ID=$$(az aks show -g $(RESOURCE_GROUP) -n $(AKS_CLUSTER) \
	  --query addonProfiles.azureKeyvaultSecretsProvider.identity.clientId -o tsv); \
	sed \
	  -e "s/<TENANT_ID>/$$TENANT_ID/" \
	  -e "s/<KV_NAME>/kv-contextforge-dev/" \
	  -e "s/<CSI_DRIVER_CLIENT_ID>/$$CSI_CLIENT_ID/" \
	  infra/k8s/secret-provider-class.yaml | kubectl apply -n $(NAMESPACE) -f -
	kubectl apply -f infra/k8s/cluster-issuer.yaml
	@echo "✓ Cluster bootstrap complete. Run: make helm-aks-secrets KV_NAME=kv-contextforge-dev"

aks-creds: ## Pull AKS kubeconfig, install kubelogin if missing, and set context
	@if ! command -v kubelogin >/dev/null 2>&1; then \
	  echo "kubelogin not found — installing arm64 binary to ~/.local/bin ..."; \
	  ARCH=$$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/'); \
	  curl -sSLo /tmp/kubelogin.zip "https://github.com/Azure/kubelogin/releases/latest/download/kubelogin-linux-$${ARCH}.zip"; \
	  unzip -q /tmp/kubelogin.zip -d /tmp/kubelogin; \
	  mkdir -p ~/.local/bin && mv /tmp/kubelogin/bin/linux_$${ARCH}/kubelogin ~/.local/bin/; \
	  export PATH="$$HOME/.local/bin:$$PATH"; \
	  echo 'export PATH="$$HOME/.local/bin:$$PATH"' >> ~/.bashrc; \
	  echo "✓ kubelogin installed"; \
	fi
	az aks get-credentials \
	  --resource-group $(RESOURCE_GROUP) \
	  --name $(AKS_CLUSTER) \
	  --overwrite-existing
	kubelogin convert-kubeconfig -l azurecli
	kubectl config use-context $(AKS_CLUSTER)
	@echo "✓ Context: $$(kubectl config current-context)"
	kubectl get nodes


aks-status: ## Show AKS Helm release status and pod health
	@echo "=== Helm Release ==="
	helm status $(HELM_RELEASE) -n $(NAMESPACE)
	@echo "=== Pods ==="
	kubectl get pods -n $(NAMESPACE) -o wide
	@echo "=== Certificate ==="
	kubectl get certificate -n $(NAMESPACE) 2>/dev/null || echo "cert-manager not installed"
	@echo "=== Ingress ==="
	kubectl get ingress -n $(NAMESPACE)

helm-aks-secrets: aks-creds ## Deploy ContextForge to AKS, pulling secrets from Key Vault at deploy time (KV_NAME required)
	@test -n "$(KV_NAME)" || (echo "Usage: make helm-aks-secrets KV_NAME=kv-contextforge-dev" && exit 1)
	@echo "WARNING: Deploying to AKS cluster: $(AKS_CLUSTER) with secrets from $(KV_NAME)"
	@read -p "Continue? [y/N] " confirm && [ "$$confirm" = "y" ] || exit 1
	@# Remove any stale HPA (HPA is now disabled; chart no longer creates one).
	kubectl delete hpa -n $(NAMESPACE) --all --ignore-not-found 2>/dev/null || true
	@# Surgically remove kube-controller-manager's scale managedField entry from the Deployment.
	@# When HPA was active, kube-controller-manager took SSA ownership of spec.replicas.
	@# Deleting the HPA does NOT automatically release that ownership — the entry persists
	@# in the Deployment's managedFields until explicitly removed. Without this, Helm's SSA
	@# conflicts on spec.replicas even after the HPA is gone.
	@# kubectl >=1.21 strips managedFields from get output unless --show-managed-fields is set.
	@MFIDX=$$(kubectl get deployment $(HELM_RELEASE)-mcpgateway -n $(NAMESPACE) --show-managed-fields -o json 2>/dev/null | \
	  jq -r '[(.metadata.managedFields // []) | to_entries[] | select(.value.manager == "kube-controller-manager" and (.value.subresource // "") == "scale")] | if length > 0 then .[0].key else empty end'); \
	  if [ -n "$$MFIDX" ]; then \
	    echo "Removing kube-controller-manager scale managedField at index $$MFIDX"; \
	    kubectl patch deployment $(HELM_RELEASE)-mcpgateway -n $(NAMESPACE) --type=json \
	      -p="[{\"op\":\"remove\",\"path\":\"/metadata/managedFields/$$MFIDX\"}]"; \
	  else \
	    echo "No stale kube-controller-manager scale managedField found (already clean)"; \
	  fi
	helm upgrade --install $(HELM_RELEASE) $(HELM_CHART) \
	  --namespace $(NAMESPACE) --create-namespace \
	  --values $(HELM_VALUES) \
	  --values $(HELM_VALUES_AKS) \
	  --set "mcpContextForge.secret.JWT_SECRET_KEY=$$(az keyvault secret show --vault-name $(KV_NAME) --name jwt-secret-key --query value -o tsv)" \
	  --set "mcpContextForge.secret.AUTH_ENCRYPTION_SECRET=$$(az keyvault secret show --vault-name $(KV_NAME) --name auth-encryption-secret --query value -o tsv)" \
	  --set "mcpContextForge.secret.PLATFORM_ADMIN_EMAIL=$$(az keyvault secret show --vault-name $(KV_NAME) --name platform-admin-email --query value -o tsv)" \
	  --set "mcpContextForge.secret.PLATFORM_ADMIN_PASSWORD=$$(az keyvault secret show --vault-name $(KV_NAME) --name platform-admin-password --query value -o tsv)" \
	  --set "mcpContextForge.secret.DEFAULT_USER_PASSWORD=$$(az keyvault secret show --vault-name $(KV_NAME) --name default-user-password --query value -o tsv)" \
	  --set "mcpContextForge.secret.BASIC_AUTH_PASSWORD=$$(az keyvault secret show --vault-name $(KV_NAME) --name basic-auth-password --query value -o tsv)" \
	  --set "mcpContextForge.secret.SSO_ENTRA_CLIENT_SECRET=$$(az keyvault secret show --vault-name $(KV_NAME) --name entra-client-secret --query value -o tsv)" \
	  --wait --timeout=10m
	@# Force pod restart so ConfigMap changes take effect.
	@# Helm updates the ConfigMap but does NOT roll pods unless the pod template changes.
	@# The chart has no config-checksum annotation, so envFrom values are stale until restart.
	kubectl rollout restart deployment/$(HELM_RELEASE)-mcpgateway -n $(NAMESPACE)
	kubectl rollout status deployment/$(HELM_RELEASE)-mcpgateway -n $(NAMESPACE) --timeout=3m
	@$(MAKE) aks-status

helm-aks: aks-creds ## Deploy/upgrade ContextForge to AKS (prompts for confirmation)
	@echo "WARNING: Deploying to AKS cluster: $(AKS_CLUSTER)"
	@read -p "Continue? [y/N] " confirm && [ "$$confirm" = "y" ] || exit 1
	helm upgrade --install $(HELM_RELEASE) $(HELM_CHART) \
	  --namespace $(NAMESPACE) --create-namespace \
	  --values $(HELM_VALUES) \
	  --values $(HELM_VALUES_AKS) \
	  --wait --timeout=10m
	@$(MAKE) aks-status

# ─────────────────────────────────────────────────────────────
# MCP Gateway Operations
# ─────────────────────────────────────────────────────────────
mcp-status: ## Check all registered MCP servers in the gateway
	@curl -sf -H "Authorization: Bearer $${JWT_TOKEN:-}" \
	  http://$(MCP_HOST)/gateways | jq .

mcp-register: ## Register a new MCP server (MCP_NAME and MCP_URL required)
	@test -n "$(MCP_NAME)" || (echo "Usage: make mcp-register MCP_NAME=myserver MCP_URL=http://..." && exit 1)
	@test -n "$(MCP_URL)"  || (echo "Usage: make mcp-register MCP_NAME=myserver MCP_URL=http://..." && exit 1)
	curl -X POST http://$(MCP_HOST)/gateways \
	  -H "Authorization: Bearer $${JWT_TOKEN:-}" \
	  -H "Content-Type: application/json" \
	  -d "{\"name\": \"$(MCP_NAME)\", \"url\": \"$(MCP_URL)\"}" | jq .

# ─────────────────────────────────────────────────────────────
# Phase 4 — Federated MCP
# ─────────────────────────────────────────────────────────────
SRE_MCP_IMAGE    ?= sre-mcp-server
SRE_MCP_TAG      ?= latest
GITHUB_MCP_IMAGE ?= github-mcp-server
GITHUB_MCP_TAG   ?= latest
AZURE_DEVOPS_MCP_IMAGE ?= azure-devops-mcp-server
AZURE_DEVOPS_MCP_TAG   ?= latest
# No build vars for Kubernetes MCP — deployed straight from the upstream
# public image (quay.io/containers/kubernetes_mcp_server), no wrapper to
# build/push to ACR. See infra/k8s/kubernetes-mcp-server.yaml header.
# Same story for Prometheus MCP — deployed straight from
# ghcr.io/pab1it0/prometheus-mcp-server, no wrapper, no ACR build step.
# See infra/k8s/prometheus-mcp-server.yaml header for the prerequisite
# (kube-prometheus-stack must already be installed in-cluster).
GATEWAY_URL      ?= https://contextforge.gourmandtech.com

sre-mcp-build: ## Build SRE Toolbox MCP image locally and push to ACR (az acr build/Tasks not permitted on this subscription)
	$(eval ACR := $(shell az acr list -g $(RESOURCE_GROUP) --query '[0].loginServer' -o tsv))
	@test -n "$(ACR)" || (echo "ERROR: No ACR found in $(RESOURCE_GROUP)" && exit 1)
	az acr login --name $(shell echo $(ACR) | cut -d. -f1)
	docker build --platform linux/amd64 -t $(ACR)/$(SRE_MCP_IMAGE):$(SRE_MCP_TAG) services/sre-mcp-server/
	docker push $(ACR)/$(SRE_MCP_IMAGE):$(SRE_MCP_TAG)
	@echo "✓ Pushed: $(ACR)/$(SRE_MCP_IMAGE):$(SRE_MCP_TAG)"

github-mcp-build: ## Build GitHub MCP wrapper image (stdio->SSE bridge) and push to ACR
	$(eval ACR := $(shell az acr list -g $(RESOURCE_GROUP) --query '[0].loginServer' -o tsv))
	@test -n "$(ACR)" || (echo "ERROR: No ACR found in $(RESOURCE_GROUP)" && exit 1)
	az acr login --name $(shell echo $(ACR) | cut -d. -f1)
	docker build --platform linux/amd64 -t $(ACR)/$(GITHUB_MCP_IMAGE):$(GITHUB_MCP_TAG) services/github-mcp-wrapper/
	docker push $(ACR)/$(GITHUB_MCP_IMAGE):$(GITHUB_MCP_TAG)
	@echo "✓ Pushed: $(ACR)/$(GITHUB_MCP_IMAGE):$(GITHUB_MCP_TAG)"

azure-devops-mcp-build: ## Build Azure DevOps MCP wrapper image (stdio->SSE bridge) and push to ACR
	$(eval ACR := $(shell az acr list -g $(RESOURCE_GROUP) --query '[0].loginServer' -o tsv))
	@test -n "$(ACR)" || (echo "ERROR: No ACR found in $(RESOURCE_GROUP)" && exit 1)
	az acr login --name $(shell echo $(ACR) | cut -d. -f1)
	docker build --platform linux/amd64 -t $(ACR)/$(AZURE_DEVOPS_MCP_IMAGE):$(AZURE_DEVOPS_MCP_TAG) services/azure-devops-mcp-wrapper/
	docker push $(ACR)/$(AZURE_DEVOPS_MCP_IMAGE):$(AZURE_DEVOPS_MCP_TAG)
	@echo "✓ Pushed: $(ACR)/$(AZURE_DEVOPS_MCP_IMAGE):$(AZURE_DEVOPS_MCP_TAG)"

aks-scale: ## Manually scale the system node pool (NODE_COUNT required; autoscaler overrides this when active)
	az aks nodepool scale \
	  --resource-group $(RESOURCE_GROUP) \
	  --cluster-name $(AKS_CLUSTER) \
	  --name $(AKS_NODEPOOL) \
	  --node-count $(NODE_COUNT)

sre-mcp-deploy: aks-creds ## Deploy SRE Toolbox MCP server to AKS
	kubectl apply -f infra/k8s/sre-mcp-server.yaml -n $(NAMESPACE)
	kubectl rollout status deployment/sre-mcp-server -n $(NAMESPACE) --timeout=3m
	@echo "✓ sre-mcp-server deployed"

github-mcp-deploy: aks-creds ## Deploy self-hosted GitHub MCP server to AKS (requires: make bicep-deploy has run, github-mcp-pat in Key Vault)
	@TENANT_ID=$$(az account show --query tenantId -o tsv); \
	IDENTITY_CLIENT_ID=$$(az identity show -g $(RESOURCE_GROUP) -n id-github-mcp-server --query clientId -o tsv); \
	test -n "$$IDENTITY_CLIENT_ID" || { echo "ERROR: id-github-mcp-server not found — run 'make bicep-deploy' first (adds it via modules/workload-identity.bicep)"; exit 1; }; \
	sed \
	  -e "s/<TENANT_ID>/$$TENANT_ID/" \
	  -e "s/<KV_NAME>/kv-contextforge-dev/" \
	  -e "s/<GITHUB_MCP_IDENTITY_CLIENT_ID>/$$IDENTITY_CLIENT_ID/" \
	  infra/k8s/github-mcp-secrets-provider.yaml | kubectl apply -n $(NAMESPACE) -f -; \
	sed \
	  -e "s/<GITHUB_MCP_IDENTITY_CLIENT_ID>/$$IDENTITY_CLIENT_ID/" \
	  infra/k8s/github-mcp-server.yaml | kubectl apply -n $(NAMESPACE) -f -
	@# Same reasoning as make helm-aks-secrets: GITHUB_MCP_TAG defaults to
	@# `latest` and the Deployment YAML text doesn't change between image
	@# rebuilds, so `kubectl apply` alone reports "unchanged" and never
	@# schedules a new pod even after `make github-mcp-build` pushed a new
	@# image — kubectl has no way to know the tag's content changed. Force it.
	kubectl rollout restart deployment/github-mcp-server -n $(NAMESPACE)
	kubectl rollout status deployment/github-mcp-server -n $(NAMESPACE) --timeout=3m
	@echo "✓ github-mcp-server deployed"
	@echo "  Verify the PAT synced: kubectl get secret github-mcp-secrets -n $(NAMESPACE) -o jsonpath='{.data.GITHUB_PERSONAL_ACCESS_TOKEN}' | base64 -d | wc -c"

azure-devops-mcp-deploy: aks-creds ## Deploy self-hosted Azure DevOps MCP server to AKS (requires: make bicep-deploy has run, azure-devops-mcp-pat in Key Vault, AZURE_DEVOPS_ORG set)
	@test -n "$(AZURE_DEVOPS_ORG)" || (echo "Usage: make azure-devops-mcp-deploy AZURE_DEVOPS_ORG=yourorg  (the org segment of https://dev.azure.com/yourorg)" && exit 1)
	@TENANT_ID=$$(az account show --query tenantId -o tsv); \
	IDENTITY_CLIENT_ID=$$(az identity show -g $(RESOURCE_GROUP) -n id-azure-devops-mcp-server --query clientId -o tsv); \
	test -n "$$IDENTITY_CLIENT_ID" || { echo "ERROR: id-azure-devops-mcp-server not found — run 'make bicep-deploy' first (adds it via modules/workload-identity.bicep)"; exit 1; }; \
	sed \
	  -e "s/<TENANT_ID>/$$TENANT_ID/" \
	  -e "s/<KV_NAME>/kv-contextforge-dev/" \
	  -e "s/<AZURE_DEVOPS_MCP_IDENTITY_CLIENT_ID>/$$IDENTITY_CLIENT_ID/" \
	  infra/k8s/azure-devops-mcp-secrets-provider.yaml | kubectl apply -n $(NAMESPACE) -f -; \
	sed \
	  -e "s/<AZURE_DEVOPS_MCP_IDENTITY_CLIENT_ID>/$$IDENTITY_CLIENT_ID/" \
	  -e "s/<AZURE_DEVOPS_ORG>/$(AZURE_DEVOPS_ORG)/" \
	  infra/k8s/azure-devops-mcp-server.yaml | kubectl apply -n $(NAMESPACE) -f -
	@# Same reasoning as github-mcp-deploy: AZURE_DEVOPS_MCP_TAG defaults to
	@# `latest` and a rebuilt image under the same tag doesn't change the
	@# Deployment YAML text, so `kubectl apply` alone won't roll it out.
	kubectl rollout restart deployment/azure-devops-mcp-server -n $(NAMESPACE)
	kubectl rollout status deployment/azure-devops-mcp-server -n $(NAMESPACE) --timeout=3m
	@echo "✓ azure-devops-mcp-server deployed"
	@echo "  Verify the PAT synced: kubectl get secret azure-devops-mcp-secrets -n $(NAMESPACE) -o jsonpath='{.data.PERSONAL_ACCESS_TOKEN}' | base64 -d | wc -c"

kubernetes-mcp-deploy: aks-creds ## Deploy Kubernetes MCP server to AKS (no build step — deploys the upstream quay.io image directly, no bicep-deploy prerequisite either — no Azure credential involved)
	kubectl apply -f infra/k8s/kubernetes-mcp-server.yaml -n $(NAMESPACE)
	kubectl rollout status deployment/kubernetes-mcp-server -n $(NAMESPACE) --timeout=3m
	@echo "✓ kubernetes-mcp-server deployed"
	@echo "  Verify RBAC: kubectl auth can-i list pods --as=system:serviceaccount:$(NAMESPACE):kubernetes-mcp-server --all-namespaces  (expect 'yes')"
	@echo "  Verify RBAC is read-only: kubectl auth can-i delete pods --as=system:serviceaccount:$(NAMESPACE):kubernetes-mcp-server --all-namespaces  (expect 'no')"

prometheus-mcp-deploy: aks-creds ## Deploy Prometheus MCP server to AKS (no build step, no bicep-deploy prerequisite — but kube-prometheus-stack MUST already be installed in-cluster; see infra/k8s/prometheus-mcp-server.yaml header)
	@kubectl get svc -n monitoring prometheus-operated >/dev/null 2>&1 || { echo "ERROR: svc/prometheus-operated not found in namespace monitoring — install kube-prometheus-stack first (see infra/k8s/prometheus-mcp-server.yaml header for the helm install command)"; exit 1; }
	kubectl apply -f infra/k8s/prometheus-mcp-server.yaml -n $(NAMESPACE)
	kubectl rollout status deployment/prometheus-mcp-server -n $(NAMESPACE) --timeout=3m
	@echo "✓ prometheus-mcp-server deployed"
	@echo "  Verify it can actually reach Prometheus: kubectl logs -n $(NAMESPACE) deploy/prometheus-mcp-server | grep -i prometheus"

mcp-get-token: ## Get a ContextForge JWT — pulls password from Key Vault (KV_NAME required; set ADMIN_EMAIL or uses KV platform-admin-email)
	$(eval KV  := $(or $(KV_NAME),kv-contextforge-dev))
	$(eval EMAIL := $(or $(ADMIN_EMAIL),$(shell az keyvault secret show --vault-name $(KV) --name platform-admin-email --query value -o tsv 2>/dev/null)))
	$(eval PASS  := $(shell az keyvault secret show --vault-name $(KV) --name platform-admin-password --query value -o tsv 2>/dev/null))
	@test -n "$(EMAIL)" || (echo "ERROR: Could not resolve admin email from KV or ADMIN_EMAIL" && exit 1)
	@test -n "$(PASS)"  || (echo "ERROR: Could not read platform-admin-password from $(KV)" && exit 1)
	@# Endpoint: POST /auth/login — JSON body, email field required (not plain username)
	@curl -sf -X POST $(GATEWAY_URL)/auth/login \
	  -H "Content-Type: application/json" \
	  -d "{\"email\": \"$(EMAIL)\", \"password\": \"$(PASS)\"}" \
	  | jq -r .access_token

mcp-list-gateways: ## List all registered gateways (JWT_TOKEN required)
	@test -n "$(JWT_TOKEN)" || (echo "Set JWT_TOKEN first: export JWT_TOKEN=\$$(make mcp-get-token)" && exit 1)
	@# @-silenced (unlike most other recipes here) specifically so this target's
	@# output is pure JSON and safe to pipe into a further `| jq ...` — without
	@# it, Make echoes the raw curl command to stdout before running it, and a
	@# downstream jq chokes trying to parse that echoed shell text as JSON
	@# (confirmed 2026-07-03: `make mcp-list-tools ... | jq ...` failed with
	@# "Invalid numeric literal" + SIGPIPE/Error 141 for exactly this reason).
	@# ?limit=0 disables ContextForge's default pagination (PAGINATION_DEFAULT_PAGE_SIZE=50)
	@# so this returns every registered gateway as a plain array, not just the first 50.
	@# Harmless at 5 gateways today; added for when that count grows.
	@curl -sf "$(GATEWAY_URL)/gateways?limit=0" \
	  -H "Authorization: Bearer $(JWT_TOKEN)" | jq '[.[] | {name, url, status: .enabled}]'

mcp-list-tools: ## List all federated tools across registered gateways (JWT_TOKEN required)
	@test -n "$(JWT_TOKEN)" || (echo "Set JWT_TOKEN first" && exit 1)
	@# See mcp-list-gateways above for why this is @-silenced.
	@# ?limit=0 disables ContextForge's default pagination (PAGINATION_DEFAULT_PAGE_SIZE=50) —
	@# confirmed 2026-07-03: without it, GET /tools silently returned only the first 50 of
	@# the 86 actually-federated tools (5+22+40+13+6 across all five gateways), which looked
	@# like a real discovery gap until traced to pagination, not a bug in any one gateway.
	@curl -sf "$(GATEWAY_URL)/tools?limit=0" \
	  -H "Authorization: Bearer $(JWT_TOKEN)" \
	  | jq '{total: length, names: [.[].name]}'

mcp-register-sre: ## Register SRE Toolbox MCP server in ContextForge (JWT_TOKEN required)
	@test -n "$(JWT_TOKEN)" || (echo "Set JWT_TOKEN first" && exit 1)
	curl -sX POST $(GATEWAY_URL)/gateways \
	  -H "Authorization: Bearer $(JWT_TOKEN)" \
	  -H "Content-Type: application/json" \
	  -d '{"name":"sre-toolbox","url":"http://sre-mcp-server.mcp.svc.cluster.local:8000/sse","transport":"SSE","description":"Custom SRE toolbox — healthchecks, k8s, Azure, Prometheus","tags":["sre","custom","azure","kubernetes"],"visibility":"public"}' \
	  | jq .

mcp-register-github: ## Register self-hosted GitHub MCP gateway (JWT_TOKEN required — no PAT here, it lives in the pod via Key Vault CSI)
	@test -n "$(JWT_TOKEN)" || (echo "Set JWT_TOKEN first" && exit 1)
	curl -sX POST $(GATEWAY_URL)/gateways \
	  -H "Authorization: Bearer $(JWT_TOKEN)" \
	  -H "Content-Type: application/json" \
	  -d '{"name":"github-mcp","url":"http://github-mcp-server.mcp.svc.cluster.local:8000/sse","transport":"SSE","description":"GitHub — repos, PRs, issues, Actions (self-hosted, read-only, in-cluster)","tags":["github","vcs","ci-cd"],"visibility":"public"}' \
	  | jq .

mcp-register-azure-devops: ## Register self-hosted Azure DevOps MCP gateway (JWT_TOKEN required — no PAT here, it lives in the pod via Key Vault CSI)
	@test -n "$(JWT_TOKEN)" || (echo "Set JWT_TOKEN first" && exit 1)
	curl -sX POST $(GATEWAY_URL)/gateways \
	  -H "Authorization: Bearer $(JWT_TOKEN)" \
	  -H "Content-Type: application/json" \
	  -d '{"name":"azure-devops-mcp","url":"http://azure-devops-mcp-server.mcp.svc.cluster.local:8000/sse","transport":"SSE","description":"Azure DevOps — pipelines, releases, work items, boards (self-hosted, in-cluster; repositories domain excluded, source lives in GitHub)","tags":["azure","devops","ci-cd","iac"],"visibility":"public"}' \
	  | jq .

mcp-register-kubernetes: ## Register Kubernetes MCP gateway (JWT_TOKEN required — no credential to hide, this workload auths via its own in-cluster ServiceAccount token)
	@test -n "$(JWT_TOKEN)" || (echo "Set JWT_TOKEN first" && exit 1)
	curl -sX POST $(GATEWAY_URL)/gateways \
	  -H "Authorization: Bearer $(JWT_TOKEN)" \
	  -H "Content-Type: application/json" \
	  -d '{"name":"kubernetes-mcp","url":"http://kubernetes-mcp-server.mcp.svc.cluster.local:8000/sse","transport":"SSE","description":"Kubernetes — pod health, deployments, logs, generic resources (read-only, view ClusterRole, in-cluster AKS API access only)","tags":["kubernetes","aks","observability","sre"],"visibility":"public"}' \
	  | jq .

mcp-register-prometheus: ## Register Prometheus MCP gateway (JWT_TOKEN required — no credential to hide, kube-prometheus-stack has no auth in front of it by default)
	@test -n "$(JWT_TOKEN)" || (echo "Set JWT_TOKEN first" && exit 1)
	curl -sX POST $(GATEWAY_URL)/gateways \
	  -H "Authorization: Bearer $(JWT_TOKEN)" \
	  -H "Content-Type: application/json" \
	  -d '{"name":"prometheus-mcp","url":"http://prometheus-mcp-server.mcp.svc.cluster.local:8000/sse","transport":"SSE","description":"Prometheus — PromQL queries, metric/target discovery (self-hosted, in-cluster, no auth — network-policy-scoped trust boundary)","tags":["prometheus","metrics","observability","sre"],"visibility":"public"}' \
	  | jq .

# ─────────────────────────────────────────────────────────────
# RBAC — Teams + Virtual Servers (Phase 4 sub-task 5 / runbook Step 7)
#
# Verified live 2026-07-04 against $(GATEWAY_URL)/openapi.json and confirmed
# by actually creating sre-team/dev-team + sre-full/dev-tools. Three real
# findings that corrected an earlier unverified draft of this section:
#   1. POST /teams — no bare path exists, only POST /teams/ (trailing slash).
#   2. GET /teams/ returns {"teams": [...], "total": N}, NOT a bare array
#      like /gateways, /tools, /servers — needs its own jq shape.
#   3. Virtual servers attach to individual TOOL IDs (ServerCreate's
#      associated_tools), not gateway IDs — there is no gateway-level
#      association field. visibility:"team" requires team_id in the same
#      POST body (both at the Body_create_server_servers_post wrapper level
#      and inside the nested ServerCreate object).
# Also: GET /teams/'s `limit` param has a schema minimum of 1 (max 500) —
# unlike /gateways, /tools, /servers, `?limit=0` 422s here instead of
# disabling pagination. Use an explicit `?limit=500` instead.
# ─────────────────────────────────────────────────────────────
mcp-create-team: ## Create an RBAC team (TEAM_NAME, TEAM_DESC, JWT_TOKEN required)
	@test -n "$(JWT_TOKEN)" || (echo "Set JWT_TOKEN first" && exit 1)
	@test -n "$(TEAM_NAME)" || (echo "Usage: make mcp-create-team TEAM_NAME=sre-team TEAM_DESC='...' JWT_TOKEN=..." && exit 1)
	curl -sX POST $(GATEWAY_URL)/teams/ \
	  -H "Authorization: Bearer $(JWT_TOKEN)" \
	  -H "Content-Type: application/json" \
	  -d "{\"name\": \"$(TEAM_NAME)\", \"description\": \"$(TEAM_DESC)\"}" \
	  | jq .

mcp-list-teams: ## List all RBAC teams (JWT_TOKEN required)
	@test -n "$(JWT_TOKEN)" || (echo "Set JWT_TOKEN first" && exit 1)
	@# @-silenced, same reasoning as mcp-list-gateways/mcp-list-tools above.
	@# Response is {"teams": [...], "total": N} — not a bare array. And
	@# `?limit=0` 422s here (schema minimum is 1); use the max, 500, instead.
	@curl -sf "$(GATEWAY_URL)/teams/?limit=500" \
	  -H "Authorization: Bearer $(JWT_TOKEN)" | jq '[.teams[] | {id, name, description, visibility}]'

mcp-create-server: ## Create a virtual server scoped to a team, attaching all tools from one or more gateways (SERVER_NAME, SERVER_DESC, TEAM_ID, GATEWAYS required; JWT_TOKEN required)
	@test -n "$(JWT_TOKEN)" || (echo "Set JWT_TOKEN first" && exit 1)
	@test -n "$(SERVER_NAME)" || (echo "Usage: make mcp-create-server SERVER_NAME=sre-full SERVER_DESC='...' TEAM_ID=... GATEWAYS=sre-toolbox,github-mcp JWT_TOKEN=..." && exit 1)
	@test -n "$(TEAM_ID)" || (echo "TEAM_ID required — look one up with: make mcp-list-teams JWT_TOKEN=..." && exit 1)
	@test -n "$(GATEWAYS)" || (echo "GATEWAYS required — comma-separated gateway names (matched against each tool's gatewaySlug), e.g. GATEWAYS=github-mcp,azure-devops-mcp" && exit 1)
	@TOOL_IDS=$$(curl -sf "$(GATEWAY_URL)/tools?limit=0" -H "Authorization: Bearer $(JWT_TOKEN)" \
	  | jq -c --arg gws "$(GATEWAYS)" '[.[] | select(($$gws | split(",") | index(.gatewaySlug)) != null) | .id]'); \
	curl -sX POST $(GATEWAY_URL)/servers \
	  -H "Authorization: Bearer $(JWT_TOKEN)" \
	  -H "Content-Type: application/json" \
	  -d "{\"server\": {\"name\": \"$(SERVER_NAME)\", \"description\": \"$(SERVER_DESC)\", \"associated_tools\": $$TOOL_IDS, \"visibility\": \"team\", \"team_id\": \"$(TEAM_ID)\"}, \"team_id\": \"$(TEAM_ID)\", \"visibility\": \"team\"}" \
	  | jq .

mcp-list-servers: ## List all virtual servers (JWT_TOKEN required)
	@test -n "$(JWT_TOKEN)" || (echo "Set JWT_TOKEN first" && exit 1)
	@curl -sf "$(GATEWAY_URL)/servers?limit=0" \
	  -H "Authorization: Bearer $(JWT_TOKEN)" | jq '[.[] | {id, name, teamId, team, visibility, toolCount: (.associatedTools | length)}]'

# ─────────────────────────────────────────────────────────────
# Quality & Maintenance
# ─────────────────────────────────────────────────────────────
lint: ## Lint Helm charts and Bicep templates
	helm lint $(HELM_CHART) --values $(HELM_VALUES)
	@if [ -f infra/bicep/main.bicep ]; then az bicep build --file infra/bicep/main.bicep; fi
	@echo "✓ Lint passed"

clean: ## Remove build artifacts and temp files
	find . -name "*.pyc" -delete
	find . -name "__pycache__" -delete
	find . -name ".DS_Store" -delete
	@echo "✓ Clean complete"
