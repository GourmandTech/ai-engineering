# syntax=docker/dockerfile:1
# SRE Toolbox MCP Server — multi-stage build for AKS (linux/amd64 + linux/arm64)
FROM python:3.12-slim AS base

WORKDIR /app

# Install kubectl for k8s pod tools and az CLI is expected to be available
# via workload identity / managed identity in AKS (no az install needed here)
ARG TARGETARCH
RUN apt-get update && apt-get install -y --no-install-recommends \
      curl ca-certificates \
    && KUBECTL_VERSION=$(curl -sSL https://dl.k8s.io/release/stable.txt) \
    && curl -sSLo /usr/local/bin/kubectl \
        "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl" \
    && chmod +x /usr/local/bin/kubectl \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Python deps
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# App code
COPY server.py .

# Run as non-root
RUN useradd -m -u 1000 sre && chown -R sre:sre /app
USER sre

EXPOSE 8000

# FastMCP SSE server
CMD ["python", "server.py"]
