#!/usr/bin/env python3
"""Phase 5.2/6.1.2 — LangGraph coordinator that delegates to specialists via A2A.

Demonstrates agent-to-agent delegation *through ContextForge*, not a direct
function call: the coordinator's only tools are `a2a-sre-agent` and (as of
Phase 6.1.1/6.1.2) `a2a-dev-agent`, exposed by a dedicated `coordinator-delegate`
virtual server that carries nothing else — it structurally cannot bypass
delegation and call kubernetes/prometheus/github/azure-devops tools directly,
the same way the 87-tool `sre-full` server does. LangGraph is used here
(Claude Agent SDK was used for 5.1) specifically for its explicit checkpointed
state: a failed delegation is a first-class, recoverable branch in the graph,
not a bare exception.

Phase 6.1.2 extends 5.2's single-specialist retry loop into real routing: a
system prompt describes both specialists' domains so Claude's native
tool-selection picks the right one instead of defaulting to whichever tool
happened to bind first, and the failure-handling edge tracks which tool was
just attempted so that after MAX_DELEGATION_RETRIES failed attempts on *one*
specialist, it explicitly falls back to the *other* specialist by name rather
than just rephrasing the same request to the same tool.

Unlike agents/sre-agent and agents/dev-agent, this is a client only — no
standing HTTP service, no AKS deployment. Run it directly wherever it has
network access to the gateway plus its own scoped JWT and an ANTHROPIC_API_KEY.
"""

import asyncio
import os
import sys
from typing import Optional

from langchain_anthropic import ChatAnthropic
from langchain_core.messages import HumanMessage, SystemMessage
from langchain_mcp_adapters.client import MultiServerMCPClient
from langgraph.checkpoint.memory import MemorySaver
from langgraph.graph import END, START, MessagesState, StateGraph
from langgraph.prebuilt import ToolNode

GATEWAY_URL = os.environ.get("GATEWAY_URL", "https://contextforge.gourmandtech.com")
COORDINATOR_SERVER_ID = os.environ.get("COORDINATOR_SERVER_ID", "ed47e8c660dd4e529cefa48826b6cd1d")
MAX_DELEGATION_RETRIES = 2

SRE_AGENT_TOOL = "a2a-sre-agent"
DEV_AGENT_TOOL = "a2a-dev-agent"
KNOWN_SPECIALIST_TOOLS = (SRE_AGENT_TOOL, DEV_AGENT_TOOL)

SYSTEM_PROMPT = (
    "You are a coordinator agent. You have no direct access to any "
    "infrastructure, source-control, or observability tools yourself — your "
    "only capability is delegating to exactly two specialist agents through "
    "ContextForge:\n\n"
    f"- `{SRE_AGENT_TOOL}` — the SRE specialist. Delegate here for anything "
    "about AKS/Kubernetes cluster or node-pool health, pod status, or "
    "Prometheus metrics/alerts. Its domain is infrastructure operations and "
    "observability.\n"
    f"- `{DEV_AGENT_TOOL}` — the dev specialist. Delegate here for anything "
    "about GitHub (pull requests, issues, repositories) or Azure DevOps (work "
    "items, pipelines, builds). Its domain is source control and "
    "project-tracking.\n\n"
    "Read the task and choose the specialist whose domain actually matches "
    "it — do not default to one specialist out of habit. A task mentioning "
    "GitHub, pull requests, issues, or Azure DevOps belongs to the dev "
    "specialist; a task mentioning AKS, Kubernetes, nodes, or Prometheus "
    "belongs to the SRE specialist. If a task spans both domains, delegate "
    "each part to the specialist that owns it and combine the results "
    "yourself in your final answer."
)

DEFAULT_TASK = (
    "Delegate to the SRE specialist agent: check AKS node pool health and "
    "summarize any Prometheus alerts firing in the last 24 hours."
)


class CoordinatorState(MessagesState):
    delegation_attempts: int
    attempted_tools: list


def _load_token() -> str:
    token = os.environ.get("COORDINATOR_JWT")
    if not token:
        raise RuntimeError("COORDINATOR_JWT not set. Run: export COORDINATOR_JWT=$(make coordinator-get-token)")
    return token


def _tool_call_failed(message) -> bool:
    """Best-effort check for a failed delegation in the last ToolMessage."""
    content = str(getattr(message, "content", ""))
    return getattr(message, "status", None) == "error" or content.strip().lower().startswith("error")


def _tool_call_name(tool_call) -> Optional[str]:
    """A ToolCall is a dict in some langchain versions, an object in others."""
    if isinstance(tool_call, dict):
        return tool_call.get("name")
    return getattr(tool_call, "name", None)


def _last_attempted_tool(messages) -> Optional[str]:
    """Walk back to the most recent AIMessage that made a tool call and return its
    (first) tool name — this is "which specialist did we just delegate to."
    """
    for msg in reversed(messages):
        tool_calls = getattr(msg, "tool_calls", None)
        if tool_calls:
            return _tool_call_name(tool_calls[0])
    return None


def _other_specialist(tool_name: Optional[str]) -> Optional[str]:
    """Given one known specialist tool, name the other one. None if tool_name is
    unrecognized (e.g. new specialists added later without updating this list).
    """
    if tool_name not in KNOWN_SPECIALIST_TOOLS:
        return None
    return next(t for t in KNOWN_SPECIALIST_TOOLS if t != tool_name)


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
    tool_names = {t.name for t in tools}
    if any(name not in tool_names for name in KNOWN_SPECIALIST_TOOLS):
        raise RuntimeError(
            "Expected both specialist tools "
            f"({', '.join(KNOWN_SPECIALIST_TOOLS)}) from the coordinator-delegate "
            f"server, got {sorted(tool_names)}. Check the server's associated_tools "
            "and that both A2A agents are registered/reachable — see the Phase 6.1.1 "
            "runbook's cross-team tool-visibility gotcha (associated_tools AND "
            "visibility=public are both required, independently, per tool)."
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
        attempted_tools = list(state.get("attempted_tools", []))
        failed_tool = _last_attempted_tool(state["messages"])
        if failed_tool:
            attempted_tools.append(failed_tool)

        # How many times in a row has this *same* specialist just failed?
        same_specialist_run = 0
        for name in reversed(attempted_tools):
            if name == failed_tool:
                same_specialist_run += 1
            else:
                break

        other = _other_specialist(failed_tool)
        if failed_tool and other and same_specialist_run >= MAX_DELEGATION_RETRIES:
            # Exhausted retries on this specialist — explicitly fall back to the
            # other one by name instead of rephrasing the same request to the
            # same tool again.
            print(
                f"[coordinator] `{failed_tool}` failed {same_specialist_run}x in a "
                f"row, falling back to `{other}`...",
                file=sys.stderr,
            )
            retry_note = HumanMessage(
                content=(
                    f"The delegated call to `{failed_tool}` has failed "
                    f"{same_specialist_run} time(s) in a row. Stop retrying "
                    f"`{failed_tool}` for this task. Instead, delegate this task to "
                    f"the other specialist, `{other}`, if its domain plausibly "
                    f"covers it — call `{other}` explicitly by name. If neither "
                    "specialist's domain actually fits, say so instead of "
                    "delegating again."
                )
            )
        else:
            print(f"[coordinator] delegation attempt {attempts} failed, retrying with guidance...", file=sys.stderr)
            retry_note = HumanMessage(
                content=(
                    "The delegated call to the specialist failed. Rephrase the "
                    "request more explicitly (e.g. name the specific check to run) "
                    "and delegate again."
                )
            )
        return {
            "messages": [retry_note],
            "delegation_attempts": attempts,
            "attempted_tools": attempted_tools,
        }

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
        {
            "messages": [SystemMessage(content=SYSTEM_PROMPT), HumanMessage(content=task)],
            "delegation_attempts": 0,
            "attempted_tools": [],
        },
        config=config,
    )
    return result["messages"][-1].content


if __name__ == "__main__":
    task = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_TASK
    print(asyncio.run(run(task)))
