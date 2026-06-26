---
description: Deploy ContextForge to local Minikube cluster using the Helm chart
---

Deploy IBM ContextForge to the local Minikube k8s cluster. Execute these steps:

1. Check Minikube is running: `minikube status`. If not running, run `make minikube-start`
2. Set kubectl context: `kubectl config use-context minikube`
3. Verify required addons: `minikube addons list | grep -E "ingress|metrics-server"`
   - If missing: `minikube addons enable ingress && minikube addons enable metrics-server`
4. Run `make helm-install` to deploy the chart
5. Watch pods come up: `kubectl get pods -n mcp -w` (timeout after 3 minutes)
6. Run `make helm-status` and report:
   - Release status
   - All pod statuses
   - Service external IPs/ports
7. Run a smoke test against the MCP endpoint via port-forward:
   ```
   kubectl port-forward svc/mcp-gateway 4444:4444 -n mcp &
   sleep 3
   curl -sf http://localhost:4444/health | jq .
   ```
8. Print the Admin UI access instructions for Minikube

If pods fail to start, run `/k8s-debug` to diagnose.
