# syntax=docker/dockerfile:1
# SRE Agent (Phase 5.1/5.2) — Claude Agent SDK client, exposed as an A2A endpoint.
#
# Needs both runtimes: Python for the agent code + claude-agent-sdk, and
# Node.js because the SDK drives the `claude` CLI as its subprocess backend
# (confirmed in the devcontainer: `claude_agent_sdk.query()` shells out to a
# `claude` binary on PATH — pure pip install is not enough).
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

RUN useradd -m -u 1000 sreagent && chown -R sreagent:sreagent /app
USER sreagent

EXPOSE 8000

CMD ["python", "a2a_server.py"]
