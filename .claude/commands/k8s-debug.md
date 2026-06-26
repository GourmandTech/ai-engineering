---
description: Diagnose a failing or degraded ContextForge pod in any k8s environment
---

Run through the standard k8s debugging sequence for ContextForge. Ask which namespace to target (default: `mcp`).

**Step 1: Recent Events (usually reveals root cause)**
```bash
kubectl get events -n mcp --sort-by='.lastTimestamp' | tail -25
```

**Step 2: Pod Overview**
```bash
kubectl get pods -n mcp -o wide
```
Flag any pods not in `Running` state or with restart count > 2.

**Step 3: Describe Failing Pod**
For each non-Running pod:
```bash
kubectl describe pod <pod-name> -n mcp
```
Look for: image pull errors, resource limits exceeded, liveness probe failures, volume mount issues.

**Step 4: Logs**
```bash
# Current logs
kubectl logs <pod-name> -n mcp --tail=50

# Previous container (if restarted)
kubectl logs <pod-name> -n mcp --previous --tail=50
```

**Step 5: Resource Pressure**
```bash
kubectl top nodes
kubectl top pods -n mcp
```

**Step 6: Services and Endpoints**
```bash
kubectl get svc,endpoints -n mcp
```
Verify endpoints are populated (not `<none>`).

**Step 7: Helm Release Status**
```bash
helm status mcp-stack -n mcp
helm history mcp-stack -n mcp
```

After each step, summarize what you found and what it indicates. Propose a fix with the exact command to run, but WAIT FOR CONFIRMATION before executing any write/delete operation.
