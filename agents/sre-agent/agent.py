#!/usr/bin/env python3
"""Phase 5.1 — SRE agent: Claude Agent SDK client against the ContextForge gateway.

Proves an agent can call federated MCP tools *through ContextForge*, not just
via curl. Connects to the `sre-full` virtual server's SSE endpoint using a
team-scoped API token (issued to a non-admin identity via
`make mcp-create-scoped-token`) — not platform-admin — so this actually
exercises the RBAC boundary built in Phase 4 rather than bypassing it.
"""

import asyncio
import os
import sys

from claude_agent_sdk import ClaudeAgentOptions, ClaudeSDKClient
from claude_agent_sdk.types import AssistantMessage, McpSSEServerConfig, ResultMessage, TextBlock, ToolUseBlock

GATEWAY_URL = os.environ.get("GATEWAY_URL", "https://contextforge.gourmandtech.com")
SRE_FULL_SERVER_ID = os.environ.get("SRE_SERVER_ID", "7c7b4364c6214f089e847802819b7f2f")
MCP_SERVER_NAME = "contextforge"
CONNECT_TIMEOUT_S = 20

DEFAULT_TASK = (
    "Using only the tools available to you, check the AKS node pool health "
    "(node count, ready status, any pending or failed pods) and summarize any "
    "Prometheus alerts that fired in the last 24 hours. Give one short combined report."
)


def _load_token() -> str:
    token = os.environ.get("SRE_AGENT_JWT")
    if not token:
        raise RuntimeError("SRE_AGENT_JWT not set. Run: export SRE_AGENT_JWT=$(make sre-agent-get-token)")
    return token


async def _wait_for_mcp_connection(client: ClaudeSDKClient) -> None:
    """Block until the ContextForge SSE handshake completes.

    `query()`'s one-shot mode sends the prompt immediately, racing the SSE
    connection — the first turn can run before ContextForge finishes its
    handshake, silently starting the model with zero tools. Confirmed via
    `get_mcp_status()`: the gateway reports `pending` for ~2s after connect()
    before flipping to `connected`. ClaudeSDKClient lets us poll and hold the
    prompt until that flip happens.
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
    # Log the last observed status before raising — a bare "didn't connect in
    # time" hides whatever the SDK/CLI's own diagnostics captured (error
    # detail, last attempted step, etc), which matters once this runs
    # somewhere other than the interactive devcontainer this was proven in.
    print(f"[sre-agent] MCP connect timeout — last status: {last_status}", file=sys.stderr)
    raise TimeoutError(f"ContextForge MCP server did not connect within {CONNECT_TIMEOUT_S}s")


async def run_task(task: str) -> str:
    """Run one task against the gateway-federated tools and return the final report text.

    Shared by the CLI entrypoint below and `a2a_server.py` (the A2A HTTP wrapper
    used by 5.2's coordinator agent) — same agent, two callers.
    """
    options = ClaudeAgentOptions(
        mcp_servers={
            MCP_SERVER_NAME: McpSSEServerConfig(
                type="sse",
                url=f"{GATEWAY_URL}/servers/{SRE_FULL_SERVER_ID}/sse",
                headers={"Authorization": f"Bearer {_load_token()}"},
            )
        },
        # No built-in Bash/Read/Write/etc — the point of this agent is to prove
        # tool access flows entirely through ContextForge's federated MCP tools.
        tools=[],
        # Non-interactive script, no TTY to answer permission prompts. Safe here
        # because the real access boundary is already enforced one layer down,
        # by the token's own team+server scope (RBAC done in Phase 4) — the SDK's
        # permission layer would otherwise just double-prompt for the same tools.
        permission_mode="bypassPermissions",
        system_prompt=(
            "You are the SRE agent for this project. Every tool you have access to "
            "is federated through the ContextForge gateway and scoped to the "
            "sre-team's RBAC boundary — you cannot see or call anything outside it."
        ),
    )

    texts: list[str] = []
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
                print(f"\n--- {message.subtype}, cost=${message.total_cost_usd:.4f} ---", file=sys.stderr)
    return "\n".join(texts)


if __name__ == "__main__":
    asyncio.run(run_task(sys.argv[1] if len(sys.argv) > 1 else DEFAULT_TASK))
