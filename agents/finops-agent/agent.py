#!/usr/bin/env python3
"""Phase 6.2.3-6.2.4 — FinOps rightsizing agent: correlates cost + utilization data
into concrete, resource-specific recommendations.

Chains cost-mcp-* (Azure Cost Management data) with the already-federated
kubernetes-mcp-*/prometheus-mcp-* utilization tools in one context — the actual
reason this is a standalone agent rather than just cost-mcp-server's tools alone
(per docs/phase6-plan.md §6.2's own design: "federating cost data is what lets
one agent correlate both, the same reason Phase 4 federated Prometheus at all").

Recommend-only, by design and by construction: this agent has no tool that can
resize, scale, or modify anything. Every tool reachable through `finops-full`
(cost-mcp-*, kubernetes-mcp-*, prometheus-mcp-*) is read-only — confirmed at
each of those servers' own registration (Phase 4/6.2). There is no code path
here that applies a change; the only output is a text report. Any accepted
recommendation becomes a Bicep param change flowing through the existing
Phase 5.3 gated deploy.yml / production Environment, same as every other
production change in this project — never autonomous.
"""

import asyncio
import os
import sys

from claude_agent_sdk import ClaudeAgentOptions, ClaudeSDKClient
from claude_agent_sdk.types import AssistantMessage, McpSSEServerConfig, ResultMessage, TextBlock, ToolUseBlock

GATEWAY_URL = os.environ.get("GATEWAY_URL", "https://contextforge.gourmandtech.com")
FINOPS_FULL_SERVER_ID = os.environ.get("FINOPS_SERVER_ID", "3e2d29fda61847319a59b5afe3a51184")
MCP_SERVER_NAME = "contextforge"
CONNECT_TIMEOUT_S = 20

# Hard rules encoded directly in the prompt, not left to the model's judgment —
# the min<2 ban specifically exists because this project has already had two
# real incidents from touching node count (Phase 3 CPU exhaustion, Phase 5.2's
# near-miss count:2->1). This is the same node-count ban already standing for
# 6.1/6.3; the agent must never recommend crossing it, even as a "consider".
SYSTEM_PROMPT = (
    "You are the FinOps rightsizing agent for this project. You have read-only tools "
    "for Azure Cost Management data (cost_by_service, cost_by_resource, cost_trend) "
    "and cluster utilization data (kubernetes-mcp-* for pod/node state, prometheus-mcp-* "
    "for metrics/alerts) — nothing else, and none of your tools can resize, scale, or "
    "modify anything. Your job is to produce a written report only.\n\n"
    "Non-negotiable rule: NEVER recommend reducing the AKS system node pool's autoscaler "
    "minimum below 2 nodes, under any circumstance, even as a minor suggestion. This "
    "project has had two real production outages from touching node count (a single-node "
    "CPU exhaustion incident, and a near-miss where a stale IaC parameter almost scaled "
    "the pool from 2 to 1) — min=2 is a hard operational floor, not a cost lever you are "
    "allowed to question.\n\n"
    "Structure your report in this priority order:\n"
    "1. Node pool (the only material cost lever — correlate actual VM spend against real "
    "CPU utilization from prometheus-mcp/kubernetes-mcp). If utilization is low relative to "
    "spend, recommend in order: (a) a burstable B-series VM SKU change, (b) a Spot pool for "
    "non-critical MCP server pods. Never recommend touching min node count.\n"
    "2. ACR tier (Standard vs Basic) — check actual storage usage against Basic tier's quota "
    "and whether any Standard-only features (webhooks, tokens, scope-maps) are actually in "
    "use. Flag as low-priority if the dollar amount is small, but still call it out plainly "
    "if capacity is paid for but unused.\n"
    "3. Log Analytics and Key Vault — if these are already correctly sized/priced, say so "
    "explicitly ('no action recommended') rather than omitting them. A report that finds "
    "something wrong with everything looks like blanket cost-cutting, not real analysis — "
    "showing genuine discrimination (some resources are fine as-is) is itself the point.\n\n"
    "Every recommendation must cite the actual data you queried (real dollar figures, real "
    "CPU percentages) — do not give generic advice unmoored from this cluster's real numbers."
)

DEFAULT_TASK = (
    "Produce a FinOps rightsizing report for this Azure subscription. Query real cost data "
    "(by service, by resource, and the recent trend) and real cluster utilization (node CPU, "
    "pod health) and correlate them into the structured, prioritized report described in your "
    "system prompt."
)


def _load_token() -> str:
    token = os.environ.get("FINOPS_AGENT_JWT")
    if not token:
        raise RuntimeError("FINOPS_AGENT_JWT not set. Run: export FINOPS_AGENT_JWT=$(make finops-agent-get-token)")
    return token


async def _wait_for_mcp_connection(client: ClaudeSDKClient) -> None:
    """Block until the ContextForge SSE handshake completes — same fix as sre-agent/dev-agent."""
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
    print(f"[finops-agent] MCP connect timeout — last status: {last_status}", file=sys.stderr)
    raise TimeoutError(f"ContextForge MCP server did not connect within {CONNECT_TIMEOUT_S}s")


async def run_task(task: str) -> str:
    """Run one task against the finops-full-federated tools and return the report text.

    Recommend-only by construction: `tools=[]` disables every built-in Claude Code
    tool (Bash/Read/Write/etc — confirmed from the SDK's own _build_command), and
    every MCP tool this agent can reach (via finops-full) is itself read-only. There
    is no capability anywhere in this call graph that can apply a change.
    """
    options = ClaudeAgentOptions(
        mcp_servers={
            MCP_SERVER_NAME: McpSSEServerConfig(
                type="sse",
                url=f"{GATEWAY_URL}/servers/{FINOPS_FULL_SERVER_ID}/sse",
                headers={"Authorization": f"Bearer {_load_token()}"},
            )
        },
        tools=[],
        permission_mode="bypassPermissions",
        system_prompt=SYSTEM_PROMPT,
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
