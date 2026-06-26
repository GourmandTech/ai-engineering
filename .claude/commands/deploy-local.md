---
description: Start ContextForge locally with Docker Compose and verify all services are healthy
---

Start the local ContextForge stack and verify it is fully operational. Execute these steps:

1. Confirm Docker is running: `docker info`
2. Run `make up` to start all services (gateway, postgres, redis)
3. Poll `http://localhost:4444/health` every 2 seconds until it returns `{"status":"healthy"}` or timeout after 60s
4. Run `docker compose ps` and report which services are Up vs unhealthy
5. Verify the MCP endpoint responds: `curl -sf http://localhost:4444/v1/tools | jq '.tools | length'`
6. Print a summary:
   - Admin UI: http://localhost:4444 (default credentials: check your .env ADMIN_PASSWORD)
   - MCP Endpoint: http://localhost:4444/v1/
   - Health: http://localhost:4444/health
   - Metrics: http://localhost:4444/metrics

If any service fails to start, run `make logs` and show the last 30 lines of output to diagnose the issue.
