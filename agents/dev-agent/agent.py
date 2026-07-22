#!/usr/bin/env python3
"""Phase 6.1.1 — dev-agent: second A2A specialist, scoped to dev-tools (GitHub + Azure DevOps).

Mirrors agents/sre-agent/agent.py exactly (same Claude Agent SDK / ClaudeSDKClient
pattern, same _wait_for_mcp_connection race-condition fix), scoped to the
dev-tools virtual server (62 tools: GitHub + Azure DevOps) instead of sre-full.
Exists to prove the Phase 4/5 RBAC + A2A pattern generalizes to a second,
independently-scoped specialist before the coordinator gets real multi-specialist
routing (6.1.2).
"""

import asyncio
import os
import sys
from dataclasses import dataclass

from claude_agent_sdk import ClaudeAgentOptions, ClaudeSDKClient
from claude_agent_sdk.types import AssistantMessage, McpSSEServerConfig, ResultMessage, TextBlock, ToolUseBlock


@dataclass
class AgentRunResult:
    """Phase 6.1.4 — carries per-hop Claude API token cost alongside the answer.

    See `agents/sre-agent/agent.py`'s identical dataclass for the full rationale —
    this is the second half of the same fix, applied to the other specialist.
    """

    text: str
    cost_usd: float | None

GATEWAY_URL = os.environ.get("GATEWAY_URL", "https://contextforge.gourmandtech.com")
DEV_TOOLS_SERVER_ID = os.environ.get("DEV_TOOLS_SERVER_ID", "86c6565d348848f195d1b41640432a35")
MCP_SERVER_NAME = "contextforge"
CONNECT_TIMEOUT_S = 20

DEFAULT_TASK = (
    "Using only the tools available to you, look up recent activity in this "
    "project's GitHub repository (open PRs/issues) or Azure DevOps work items "
    "and give one short summary."
)


def _load_token() -> str:
    token = os.environ.get("DEV_AGENT_JWT")
    if not token:
        raise RuntimeError("DEV_AGENT_JWT not set. Run: export DEV_AGENT_JWT=$(make dev-agent-get-token)")
    return token


async def _wait_for_mcp_connection(client: ClaudeSDKClient) -> None:
    """Block until the ContextForge SSE handshake completes.

    Same fix as sre-agent's agent.py: query()'s one-shot mode races the SSE
    handshake, so poll get_mcp_status() until it flips to connected before
    sending the first prompt.
    """
    last_status = None
    for _ in range(CONNECT_TIMEOUT_S * 2):
        status = await client.get_mcp_status()
        servers = status["mcpServers"] if isinstance(status, dict) else status.mcp_servers
        server = next((s for s in servers if s.get("name") == MCP_SERVER_NAME), None)
        last_status = server
        if server and server.get("status") == "connected":
            return
        if server and server.get("status") == "failed":
            raise RuntimeError(f"ContextForge MCP connection failed: {server}")
        await asyncio.sleep(0.5)
    print(f"[dev-agent] MCP connect timeout — last status: {last_status}", file=sys.stderr)
    raise TimeoutError(f"ContextForge MCP server did not connect within {CONNECT_TIMEOUT_S}s")


async def run_task(task: str) -> AgentRunResult:
    """Run one task against the dev-tools-federated tools and return the report + its cost.

    Shared by the CLI entrypoint below and a2a_server.py (the A2A HTTP wrapper
    both the coordinator and 6.1.3's sre-agent delegate to) — same agent,
    multiple callers.
    """
    options = ClaudeAgentOptions(
        mcp_servers={
            MCP_SERVER_NAME: McpSSEServerConfig(
                type="sse",
                url=f"{GATEWAY_URL}/servers/{DEV_TOOLS_SERVER_ID}/sse",
                headers={"Authorization": f"Bearer {_load_token()}"},
            )
        },
        tools=[],
        permission_mode="bypassPermissions",
        system_prompt=(
            "You are the dev agent for this project. Every tool you have access to "
            "is federated through the ContextForge gateway and scoped to the "
            "dev-team's RBAC boundary (GitHub + Azure DevOps only) — you cannot "
            "see or call anything outside it."
        ),
    )

    texts: list[str] = []
    cost_usd: float | None = None
    async with ClaudeSDKClient(options=options) as client:
        await _wait_for_mcp_connection(client)
        await client.query(task)
        async for message in client.receive_response():
            if isinstance(message, AssistantMessage):
                for block in message.content:
                    if isinstance(block, TextBlock):
                        texts.append(block.text)
                        print(block.text)
                    elif isinstance(block, ToolUseBlock):
                        print(f"[tool call] {block.name}({block.input})", file=sys.stderr)
            elif isinstance(message, ResultMessage):
                cost_usd = message.total_cost_usd
                print(f"\n--- {message.subtype}, cost=${message.total_cost_usd:.4f} ---", file=sys.stderr)
    return AgentRunResult(text="\n".join(texts), cost_usd=cost_usd)


if __name__ == "__main__":
    asyncio.run(run_task(sys.argv[1] if len(sys.argv) > 1 else DEFAULT_TASK))
