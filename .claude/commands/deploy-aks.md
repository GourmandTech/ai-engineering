---
description: Full deployment pipeline to Azure AKS — Bicep infra then Helm chart
---

Execute a full deployment of IBM ContextForge to Azure Kubernetes Service. This is a MULTI-STEP operation requiring confirmation at key gates.

**Pre-flight checklist (verify before proceeding):**
1. Run `az account show` and confirm the correct subscription
2. Run `az group list --output table` and verify `rg-contextforge-dev` exists (or will be created)
3. Lint the Bicep: `az bicep build --file infra/bicep/main.bicep`
4. Validate Helm values: `helm lint ./infra/helm -f infra/helm/values.yaml -f infra/helm/values.azure.yaml`

**STOP — confirm with user before proceeding to infrastructure creation.**

**Phase 1: Deploy Azure Infrastructure**
5. Run `make bicep-deploy` (will prompt for confirmation)
6. Monitor deployment in Azure portal or: `az deployment sub list --output table`
7. Verify AKS cluster is running: `az aks show -g rg-contextforge-dev -n aks-contextforge-dev --query provisioningState`

**STOP — confirm with user before deploying application.**

**Phase 2: Deploy Application**
8. Pull kubeconfig: `make aks-creds`
9. Verify cluster access: `kubectl get nodes`
10. Run `make helm-aks` to deploy ContextForge
11. Watch rollout: `kubectl rollout status deploy/mcp-gateway -n mcp --timeout=300s`
12. Run health check against the AKS external endpoint

Report the final external IP/DNS of the gateway service and the Admin UI URL.
