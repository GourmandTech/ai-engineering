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
HELM_CHART       ?= ./infra/helm
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
minikube-start: ## Start local Minikube cluster with required addons
	minikube start --cpus=4 --memory=8192 \
	  --addons=ingress,metrics-server
	kubectl config use-context minikube
	@echo "✓ Minikube ready. Context: $$(kubectl config current-context)"

helm-install: ## Install ContextForge Helm chart to Minikube
	helm upgrade --install $(HELM_RELEASE) $(HELM_CHART) \
	  --namespace $(NAMESPACE) --create-namespace \
	  --values $(HELM_CHART)/values.yaml \
	  --wait --timeout=5m
	@$(MAKE) helm-status

helm-status: ## Show Helm release status and pod health
	@echo "=== Helm Release ==="
	helm status $(HELM_RELEASE) -n $(NAMESPACE)
	@echo "=== Pods ==="
	kubectl get pods -n $(NAMESPACE) -o wide
	@echo "=== Services ==="
	kubectl get svc -n $(NAMESPACE)

helm-diff: ## Show diff between deployed and local chart (requires helm-diff plugin)
	helm diff upgrade $(HELM_RELEASE) $(HELM_CHART) \
	  --namespace $(NAMESPACE) \
	  --values $(HELM_CHART)/values.yaml

port-forward: ## Port-forward gateway to localhost:4444 (Minikube/AKS)
	kubectl port-forward svc/mcp-gateway 4444:4444 -n $(NAMESPACE)

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
	helm lint $(HELM_CHART) --values $(HELM_CHART)/values.yaml
	@if [ -f infra/bicep/main.bicep ]; then az bicep build --file infra/bicep/main.bicep; fi
	@echo "✓ Lint passed"

clean: ## Remove build artifacts and temp files
	find . -name "*.pyc" -delete
	find . -name "__pycache__" -delete
	find . -name ".DS_Store" -delete
	@echo "✓ Clean complete"
