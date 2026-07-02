"""
SRE Toolbox MCP Server
======================
A custom FastMCP server exposing SRE-relevant tools to ContextForge.

Tools:
  sre_healthcheck       — HTTP health check any URL, return status + latency
  sre_k8s_pod_status    — Get pod status from AKS via kubeconfig
  sre_azure_resource    — Query Azure resource properties via az CLI
  sre_prometheus_query  — Run a raw PromQL expression against Prometheus
  sre_incident_summary  — Summarize recent pod restarts and failed checks

Transport: SSE via FastMCP (uvicorn on port 8000)

Environment variables:
  PROMETHEUS_URL        — Prometheus endpoint (default: http://prometheus:9090)
  KUBECONFIG            — Path to kubeconfig (default: in-cluster service account)
  AZURE_SUBSCRIPTION_ID — Azure subscription ID for resource queries
"""

import asyncio
import json
import os
import subprocess
import time
from typing import Any

import httpx
from mcp.server.fastmcp import FastMCP

# ---------------------------------------------------------------------------
# Server setup
# ---------------------------------------------------------------------------

mcp = FastMCP(
    name="sre-toolbox",
    instructions="SRE toolbox for ContextForge — healthchecks, k8s, Azure, Prometheus",
    host="0.0.0.0",   # must be 0.0.0.0; default 127.0.0.1 blocks k8s TCP probes
    port=8000,
)


# ---------------------------------------------------------------------------
# Health endpoint — required for k8s readiness/liveness probes
# FastMCP's SSE server doesn't expose /health by default; add it via the
# underlying Starlette app so probes don't require TCP-only checks.
# ---------------------------------------------------------------------------
from starlette.requests import Request
from starlette.responses import JSONResponse

@mcp.custom_route("/health", methods=["GET"])
async def health_check(request: Request) -> JSONResponse:
    return JSONResponse({"status": "healthy", "service": "sre-toolbox"})

PROMETHEUS_URL = os.getenv("PROMETHEUS_URL", "http://prometheus:9090")
AZURE_SUBSCRIPTION_ID = os.getenv("AZURE_SUBSCRIPTION_ID", "")


# ---------------------------------------------------------------------------
# Tool: HTTP healthcheck
# ---------------------------------------------------------------------------

@mcp.tool()
async def sre_healthcheck(url: str, timeout_seconds: int = 10) -> dict[str, Any]:
    """
    Check the health of any HTTP(S) endpoint.

    Args:
        url: The URL to check (e.g. https://contextforge.gourmandtech.com/health)
        timeout_seconds: Request timeout (default 10)

    Returns:
        dict with status_code, latency_ms, healthy (bool), and body (first 500 chars)
    """
    start = time.monotonic()
    try:
        async with httpx.AsyncClient(timeout=timeout_seconds) as client:
            resp = await client.get(url, follow_redirects=True)
        latency_ms = round((time.monotonic() - start) * 1000, 1)
        return {
            "url": url,
            "status_code": resp.status_code,
            "latency_ms": latency_ms,
            "healthy": resp.status_code < 400,
            "body": resp.text[:500],
        }
    except Exception as exc:
        latency_ms = round((time.monotonic() - start) * 1000, 1)
        return {
            "url": url,
            "status_code": None,
            "latency_ms": latency_ms,
            "healthy": False,
            "error": str(exc),
        }


# ---------------------------------------------------------------------------
# Tool: Kubernetes pod status
# ---------------------------------------------------------------------------

@mcp.tool()
async def sre_k8s_pod_status(namespace: str = "mcp", label_selector: str = "") -> dict[str, Any]:
    """
    List pods in a Kubernetes namespace with their status, restarts, and age.

    Args:
        namespace: Kubernetes namespace (default: mcp)
        label_selector: Optional label selector (e.g. 'app=sre-mcp-server')

    Returns:
        dict with pod list and a summary of unhealthy pods
    """
    cmd = ["kubectl", "get", "pods", "-n", namespace, "-o", "json"]
    if label_selector:
        cmd += ["-l", label_selector]

    try:
        result = await asyncio.to_thread(
            subprocess.run, cmd, capture_output=True, text=True, timeout=15
        )
        if result.returncode != 0:
            return {"error": result.stderr.strip(), "namespace": namespace}

        data = json.loads(result.stdout)
        pods = []
        for item in data.get("items", []):
            meta = item.get("metadata", {})
            status = item.get("status", {})
            containers = status.get("containerStatuses", [])
            restarts = sum(c.get("restartCount", 0) for c in containers)
            phase = status.get("phase", "Unknown")
            pods.append({
                "name": meta.get("name"),
                "phase": phase,
                "restarts": restarts,
                "ready": all(c.get("ready", False) for c in containers),
                "node": status.get("hostIP", "unknown"),
            })

        unhealthy = [p for p in pods if not p["ready"] or p["restarts"] > 5]
        return {
            "namespace": namespace,
            "total": len(pods),
            "unhealthy_count": len(unhealthy),
            "pods": pods,
            "unhealthy": unhealthy,
        }
    except asyncio.TimeoutError:
        return {"error": "kubectl timed out after 15s", "namespace": namespace}
    except Exception as exc:
        return {"error": str(exc), "namespace": namespace}


# ---------------------------------------------------------------------------
# Tool: Azure resource query
# ---------------------------------------------------------------------------

@mcp.tool()
async def sre_azure_resource(
    resource_group: str,
    resource_name: str = "",
    resource_type: str = "",
) -> dict[str, Any]:
    """
    Query Azure resources in a resource group using the az CLI.

    Args:
        resource_group: Azure resource group name (e.g. rg-contextforge-dev)
        resource_name:  Optional specific resource name to filter
        resource_type:  Optional resource type filter (e.g. Microsoft.ContainerService/managedClusters)

    Returns:
        dict with list of matching Azure resources and their properties
    """
    cmd = ["az", "resource", "list", "-g", resource_group, "-o", "json"]
    if resource_type:
        cmd += ["--resource-type", resource_type]
    if resource_name:
        cmd += ["--name", resource_name]

    try:
        result = await asyncio.to_thread(
            subprocess.run, cmd, capture_output=True, text=True, timeout=30
        )
        if result.returncode != 0:
            return {"error": result.stderr.strip(), "resource_group": resource_group}

        resources = json.loads(result.stdout)
        summary = [
            {
                "name": r.get("name"),
                "type": r.get("type"),
                "location": r.get("location"),
                "tags": r.get("tags", {}),
                "provisioning_state": r.get("properties", {}).get("provisioningState"),
            }
            for r in resources
        ]
        return {
            "resource_group": resource_group,
            "count": len(summary),
            "resources": summary,
        }
    except asyncio.TimeoutError:
        return {"error": "az CLI timed out after 30s", "resource_group": resource_group}
    except Exception as exc:
        return {"error": str(exc), "resource_group": resource_group}


# ---------------------------------------------------------------------------
# Tool: Prometheus query
# ---------------------------------------------------------------------------

@mcp.tool()
async def sre_prometheus_query(query: str, time_range: str = "5m") -> dict[str, Any]:
    """
    Run a PromQL query against Prometheus and return the results.

    Args:
        query: PromQL expression (e.g. 'rate(http_requests_total[5m])')
        time_range: Time range for range queries (e.g. '5m', '1h', '24h')

    Returns:
        dict with result_type, metric names, and values
    """
    url = f"{PROMETHEUS_URL}/api/v1/query"
    params = {"query": query}

    try:
        async with httpx.AsyncClient(timeout=10) as client:
            resp = await client.get(url, params=params)
        data = resp.json()
        if data.get("status") != "success":
            return {"error": data.get("error", "Prometheus query failed"), "query": query}

        result = data.get("data", {})
        result_type = result.get("resultType")
        raw = result.get("result", [])

        # Summarize: show metric name and latest value
        summarized = []
        for item in raw[:20]:  # cap at 20 series
            metric = item.get("metric", {})
            value = item.get("value") or (item.get("values") or [[None, None]])[-1]
            summarized.append({
                "metric": metric,
                "value": value[1] if value else None,
                "timestamp": value[0] if value else None,
            })

        return {
            "query": query,
            "result_type": result_type,
            "series_count": len(raw),
            "results": summarized,
        }
    except Exception as exc:
        return {"error": str(exc), "query": query, "prometheus_url": PROMETHEUS_URL}


# ---------------------------------------------------------------------------
# Tool: Incident summary
# ---------------------------------------------------------------------------

@mcp.tool()
async def sre_incident_summary(namespace: str = "mcp") -> dict[str, Any]:
    """
    Generate a quick incident summary: pods with high restarts, recent OOMKills,
    and a roll-up of health check results for common endpoints.

    Args:
        namespace: Kubernetes namespace to inspect (default: mcp)

    Returns:
        dict with restart hotspots, oomkills, and endpoint health summary
    """
    # Gather pod restarts
    pod_data = await sre_k8s_pod_status(namespace=namespace)
    restart_hotspots = sorted(
        [p for p in pod_data.get("pods", []) if p.get("restarts", 0) > 0],
        key=lambda p: p["restarts"],
        reverse=True,
    )[:5]

    # Check common gateway endpoints
    base = os.getenv("GATEWAY_URL", "https://contextforge.gourmandtech.com")
    endpoints = [f"{base}/health", f"{base}/metrics"]
    health_results = await asyncio.gather(*[sre_healthcheck(ep) for ep in endpoints])

    # OOMKill check via kubectl (best-effort)
    oom_cmd = [
        "kubectl", "get", "events", "-n", namespace, "-o", "json",
        "--field-selector", "reason=OOMKilling",
    ]
    oom_events = []
    try:
        result = await asyncio.to_thread(
            subprocess.run, oom_cmd, capture_output=True, text=True, timeout=10
        )
        if result.returncode == 0:
            events = json.loads(result.stdout).get("items", [])
            oom_events = [
                {
                    "pod": e.get("involvedObject", {}).get("name"),
                    "message": e.get("message", "")[:200],
                    "time": e.get("lastTimestamp"),
                }
                for e in events[-5:]
            ]
    except Exception:
        pass

    return {
        "namespace": namespace,
        "restart_hotspots": restart_hotspots,
        "oom_events": oom_events,
        "endpoint_health": [
            {"url": r["url"], "healthy": r["healthy"], "latency_ms": r["latency_ms"]}
            for r in health_results
        ],
    }


# ---------------------------------------------------------------------------
# Entrypoint
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    # host/port are set on the FastMCP() constructor, not here.
    # run() only accepts transport and mount_path (mcp SDK v1.28+).
    mcp.run(transport="sse")
