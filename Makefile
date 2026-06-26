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
MINIKUBE_PROFILE ?= mcpgw
AZ_LOCATION      ?= eastus
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
	minikube start \
	  --profile $(MINIKUBE_PROFILE) \
	  --driver docker \
	  --cpus 4 \
	  --memory 6144 \
	  --addons ingress,ingress-dns,metrics-server
	kubectl config use-context $(MINIKUBE_PROFILE)
	@echo "✓ Minikube ready. Context: $$(kubectl config current-context)"
	@echo "  Add to /etc/hosts: $$(minikube ip --profile $(MINIKUBE_PROFILE))  gateway.local"

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

port-forward: ## Port-forward gateway to localhost:4444 (Minikube)
	kubectl port-forward svc/$(HELM_RELEASE)-mcpcontextforge 4444:4444 \
	  -n $(NAMESPACE) --context $(MINIKUBE_PROFILE)

# ─────────────────────────────────────────────────────────────
# Azure — Authentication & Infra
# ─────────────────────────────────────────────────────────────
az-login: ## Authenticate to Azure
	az login
	@echo "Subscription: $$(az account show --query name -o tsv)"

bicep-validate: ## Validate Bicep templates without deploying
	az bicep build --file infra/bicep/main.bicep
	az deployment sub validate \
	  --location $(AZ_LOCATION) \
	  --template-file infra/bicep/main.bicep \
	  --parameters infra/bicep/main.parameters.json
	@echo "✓ Bicep validation passed"

bicep-deploy: bicep-validate ## Deploy Azure infrastructure via Bicep (prompts for confirmation)
	@echo "WARNING: This will create/update Azure resources in subscription: $$(az account show --query name -o tsv)"
	@read -p "Continue? [y/N] " confirm && [ "$$confirm" = "y" ] || exit 1
	az deployment sub create \
	  --location $(AZ_LOCATION) \
	  --template-file infra/bicep/main.bicep \
	  --parameters infra/bicep/main.parameters.json \
	  --name "contextforge-$$(date +%Y%m%d-%H%M%S)"

aks-creds: ## Pull AKS kubeconfig and set context
	az aks get-credentials \
	  --resource-group $(RESOURCE_GROUP) \
	  --name $(AKS_CLUSTER) \
	  --overwrite-existing
	kubectl config use-context $(AKS_CLUSTER)
	@echo "✓ Context: $$(kubectl config current-context)"
	kubectl get nodes

helm-aks: aks-creds ## Deploy/upgrade ContextForge to AKS (prompts for confirmation)
	@echo "WARNING: Deploying to AKS cluster: $(AKS_CLUSTER)"
	@read -p "Continue? [y/N] " confirm && [ "$$confirm" = "y" ] || exit 1
	helm upgrade --install $(HELM_RELEASE) $(HELM_CHART) \
	  --namespace $(NAMESPACE) --create-namespace \
	  --values $(HELM_CHART)/values.yaml \
	  --values $(HELM_CHART)/values.azure.yaml \
	  --wait --timeout=10m
	@$(MAKE) helm-status

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
