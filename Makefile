.PHONY: help up down logs test \
        minikube-start helm-install helm-upgrade helm-status helm-diff helm-uninstall \
        az-login bicep-validate bicep-deploy aks-creds helm-aks \
        mcp-register mcp-status port-forward \
        lint clean

# ─────────────────────────────────────────────────────────────
# Config
# ─────────────────────────────────────────────────────────────
RESOURCE_GROUP   ?= rg-contextforge-dev
AKS_CLUSTER      ?= aks-contextforge-dev
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
	  --wait --timeout=10m
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
	  http://$(MCP_HOST)/v1/gateways | jq .

mcp-register: ## Register a new MCP server (MCP_NAME and MCP_URL required)
	@test -n "$(MCP_NAME)" || (echo "Usage: make mcp-register MCP_NAME=myserver MCP_URL=http://..." && exit 1)
	@test -n "$(MCP_URL)"  || (echo "Usage: make mcp-register MCP_NAME=myserver MCP_URL=http://..." && exit 1)
	curl -X POST http://$(MCP_HOST)/v1/gateways \
	  -H "Authorization: Bearer $${JWT_TOKEN:-}" \
	  -H "Content-Type: application/json" \
	  -d "{\"name\": \"$(MCP_NAME)\", \"url\": \"$(MCP_URL)\"}" | jq .

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
