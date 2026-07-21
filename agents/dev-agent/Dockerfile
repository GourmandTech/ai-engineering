# syntax=docker/dockerfile:1
# Dev Agent (Phase 6.1.1) — Claude Agent SDK client, exposed as an A2A endpoint.
#
# Identical shape to agents/sre-agent/Dockerfile — needs both Python (agent
# code + claude-agent-sdk) and Node.js (the SDK drives the `claude` CLI as
# its subprocess backend).
FROM python:3.12-slim AS base

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
      curl ca-certificates gnupg \
    && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && npm install -g @anthropic-ai/claude-code \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY agent.py a2a_server.py .

RUN useradd -m -u 1000 devagent && chown -R devagent:devagent /app
USER devagent

EXPOSE 8000

CMD ["python", "a2a_server.py"]
