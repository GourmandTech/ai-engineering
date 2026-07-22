#!/usr/bin/env python3
"""Phase 5.2 — exposes the sre-agent as an A2A-registrable HTTP endpoint.

ContextForge's A2A integration expects a plain HTTP endpoint speaking either
JSONRPC (`message/send`) or a simpler `{"parameters": {...}}` / `{"query": "..."}`
shape — see `.contextforge/scripts/demo_a2a_agent.py` for the reference parsing
this mirrors. Once registered (`POST /a2a`), ContextForge auto-creates an
`a2a_sre-agent` MCP tool that any other agent — e.g. the 5.2 coordinator — can
call *through the gateway*, without knowing this service exists directly.
"""

import logging

from fastapi import FastAPI, Request
from pydantic import BaseModel

from agent import run_task

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("sre-agent-a2a")

app = FastAPI(title="SRE Agent (A2A)", description="Phase 5.1 SRE agent, exposed for A2A delegation")


class AgentResponse(BaseModel):
    response: str
    # Phase 6.1.4 — per-hop Claude API token cost, so a caller (or a human
    # inspecting a multi-hop chain) can see this specific hop's spend, not
    # just the final answer text. None if the SDK didn't report a cost.
    cost_usd: float | None = None


def _extract_query(body: dict) -> str:
    """Pull the task text out of whichever shape ContextForge sent."""
    if "jsonrpc" in body:
        params = body.get("params", {})
        message_obj = params.get("message")
        if isinstance(message_obj, dict):
            for part in message_obj.get("parts", []):
                if isinstance(part, dict) and part.get("kind") == "text":
                    return part.get("text", "")
        return params.get("query") or params.get("message", "")
    if isinstance(body.get("parameters"), dict):
        params = body["parameters"]
        return params.get("query") or params.get("message", "")
    return body.get("query") or body.get("message", "")


@app.post("/run")
async def run_agent(request: Request) -> AgentResponse:
    body = await request.json()
    task = _extract_query(body) or "Check AKS node pool health and summarize firing Prometheus alerts."
    logger.info("A2A task received: %s", task)
    result = await run_task(task)
    return AgentResponse(response=result.text, cost_usd=result.cost_usd)


@app.get("/health")
def health() -> dict:
    return {"status": "healthy", "agent": "sre-agent"}


if __name__ == "__main__":
    import os

    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=int(os.environ.get("PORT", "8000")))  # noqa: S104 - bound intentionally for in-cluster ClusterIP access, not host-network exposed
