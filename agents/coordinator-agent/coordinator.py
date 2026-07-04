#!/usr/bin/env python3
"""Phase 5.2 — LangGraph coordinator that delegates to the 5.1 sre-agent via A2A.

Demonstrates agent-to-agent delegation *through ContextForge*, not a direct
function call: the coordinator's only tool is `a2a-sre-agent`, exposed by a
dedicated `coordinator-delegate` virtual server that carries nothing else —
it structurally cannot bypass delegation and call kubernetes/prometheus tools
directly, the same way the 87-tool `sre-full` server does. LangGraph is used
here (Claude Agent SDK was used for 5.1) specifically for its explicit
checkpointed state: a failed delegation is a first-class, recoverable branch
in the graph, not a bare exception.

Unlike agents/sre-agent, this is a client only — no standing HTTP service,
no AKS deployment. Run it directly wherever it has network access to the
gateway plus its own scoped JWT and an ANTHROPIC_API_KEY.
"""

import asyncio
import os
import sys

from langchain_anthropic import ChatAnthropic
from langchain_core.messages import HumanMessage
from langchain_mcp_adapters.client import MultiServerMCPClient
from langgraph.checkpoint.memory import MemorySaver
from langgraph.graph import END, START, MessagesState, StateGraph
from langgraph.prebuilt import ToolNode

GATEWAY_URL = os.environ.get("GATEWAY_URL", "https://contextforge.gourmandtech.com")
COORDINATOR_SERVER_ID = os.environ.get("COORDINATOR_SERVER_ID", "ed47e8c660dd4e529cefa48826b6cd1d")
MAX_DELEGATION_RETRIES = 2

DEFAULT_TASK = (
    "Delegate to the SRE specialist agent: check AKS node pool health and "
    "summarize any Prometheus alerts firing in the last 24 hours."
)


class CoordinatorState(MessagesState):
    delegation_attempts: int


def _load_token() -> str:
    token = os.environ.get("COORDINATOR_JWT")
    if not token:
        raise RuntimeError("COORDINATOR_JWT not set. Run: export COORDINATOR_JWT=$(make coordinator-get-token)")
    return token


def _tool_call_failed(message) -> bool:
    """Best-effort check for a failed delegation in the last ToolMessage."""
    content = str(getattr(message, "content", ""))
    return getattr(message, "status", None) == "error" or content.strip().lower().startswith("error")


async def build_graph():
    client = MultiServerMCPClient(
        {
            "contextforge": {
                "transport": "sse",
                "url": f"{GATEWAY_URL}/servers/{COORDINATOR_SERVER_ID}/sse",
                "headers": {"Authorization": f"Bearer {_load_token()}"},
            }
        }
    )
    tools = await client.get_tools()
    if not tools:
        raise RuntimeError(
            "No tools loaded from the coordinator-delegate server — expected exactly "
            "one (a2a-sre-agent). Check the server's associated_tools and that the "
            "A2A agent is still registered/reachable."
        )

    model = ChatAnthropic(model="claude-sonnet-4-6").bind_tools(tools)
    tool_node = ToolNode(tools)

    async def coordinator_node(state: CoordinatorState):
        response = await model.ainvoke(state["messages"])
        return {"messages": [response]}

    def route_after_coordinator(state: CoordinatorState):
        last = state["messages"][-1]
        return "tools" if getattr(last, "tool_calls", None) else END

    def route_after_tools(state: CoordinatorState):
        last = state["messages"][-1]
        attempts = state.get("delegation_attempts", 0)
        if _tool_call_failed(last) and attempts < MAX_DELEGATION_RETRIES:
            return "handle_delegation_failure"
        return "coordinator"

    async def handle_delegation_failure(state: CoordinatorState):
        attempts = state.get("delegation_attempts", 0) + 1
        print(f"[coordinator] delegation attempt {attempts} failed, retrying with guidance...", file=sys.stderr)
        retry_note = HumanMessage(
            content=(
                "The delegated call to the sre-agent specialist failed. Rephrase the "
                "request more explicitly (e.g. name the specific check to run) and "
                "delegate again."
            )
        )
        return {"messages": [retry_note], "delegation_attempts": attempts}

    graph = StateGraph(CoordinatorState)
    graph.add_node("coordinator", coordinator_node)
    graph.add_node("tools", tool_node)
    graph.add_node("handle_delegation_failure", handle_delegation_failure)

    graph.add_edge(START, "coordinator")
    graph.add_conditional_edges("coordinator", route_after_coordinator, {"tools": "tools", END: END})
    graph.add_conditional_edges(
        "tools",
        route_after_tools,
        {"coordinator": "coordinator", "handle_delegation_failure": "handle_delegation_failure"},
    )
    graph.add_edge("handle_delegation_failure", "coordinator")

    return graph.compile(checkpointer=MemorySaver())


async def run(task: str) -> str:
    app = await build_graph()
    config = {"configurable": {"thread_id": "coordinator-demo"}}
    result = await app.ainvoke(
        {"messages": [HumanMessage(content=task)], "delegation_attempts": 0},
        config=config,
    )
    return result["messages"][-1].content


if __name__ == "__main__":
    task = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_TASK
    print(asyncio.run(run(task)))
