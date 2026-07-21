# syntax=docker/dockerfile:1
# Cost MCP Server — Phase 6.2.1. Simpler than sre-mcp-server's Dockerfile:
# no kubectl (this server never touches the k8s API — its only credential is
# the workload-identity-federated Azure AD token used to call Cost Management,
# acquired automatically via azure-identity's DefaultAzureCredential once the
# AKS workload-identity webhook injects the standard env vars into this pod).
FROM python:3.12-slim AS base

WORKDIR /app

# Python deps
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# App code
COPY server.py .

# Run as non-root — uid 1000 confirmed free on python:3.12-slim (same base
# and same uid sre-mcp-server already uses successfully).
RUN useradd -m -u 1000 cost && chown -R cost:cost /app
USER cost

EXPOSE 8000

# FastMCP SSE server
CMD ["python", "server.py"]
