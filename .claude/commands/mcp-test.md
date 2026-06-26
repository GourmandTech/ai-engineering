---
description: Run a full smoke test suite against the MCP gateway endpoint
---

Run smoke tests against the MCP gateway. Auto-detect whether the target is local (localhost:4444) or ask which environment (minikube/aks) to test.

**Test Suite:**

1. **Health check**
   ```bash
   curl -sf http://$MCP_HOST/health | jq .
   ```
   Expected: `{"status":"healthy"}`

2. **List registered MCP tools**
   ```bash
   curl -sf http://$MCP_HOST/v1/tools | jq '{tool_count: (.tools | length), tools: [.tools[].name]}'
   ```

3. **List registered gateways (federated servers)**
   ```bash
   curl -sf -H "Authorization: Bearer $JWT_TOKEN" http://$MCP_HOST/v1/gateways | jq .
   ```

4. **Metrics endpoint**
   ```bash
   curl -sf http://$MCP_HOST/metrics | grep -E "^mcp_" | head -20
   ```

5. **MCP protocol compliance** — send a tools/list JSON-RPC call:
   ```bash
   curl -sf -X POST http://$MCP_HOST/v1/ \
     -H "Content-Type: application/json" \
     -d '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' | jq .
   ```

Print a test results table showing PASS/FAIL for each check and the response times.
