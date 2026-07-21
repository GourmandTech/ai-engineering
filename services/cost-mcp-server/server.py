"""
Cost MCP Server (Phase 6.2.1-6.2.2)
====================================
A custom FastMCP server exposing Azure Cost Management data to ContextForge,
same shape as services/sre-mcp-server/ (native SSE, no stdio wrapper).

Tools:
  cost_by_service   — actual cost grouped by ServiceName, top-N descending
  cost_by_resource  — actual cost grouped by ResourceId, top-N descending
  cost_trend        — daily cost time series over the last N days

Design constraints (see docs/phase6-plan.md §6.2 and
docs/phase6-execution-plan.md's resolved rate-limit research):
  - ALWAYS queries at SUBSCRIPTION scope, never resource-group scope.
    Confirmed live 2026-07-06/07-21: an RG-scoped query against
    rg-contextforge-dev misses ~91% of real spend, because the AKS node
    VMs live in the AKS-managed node resource group
    (MC_rg-contextforge-dev_aks-contextforge-dev_eastus), not the app RG.
    There is no caller-supplied scope override — this is a correctness
    requirement, not a default.
  - Azure Cost Management Query API rate limits (Microsoft-documented):
    4 calls/minute per scope, 20/minute per tenant, 2000/minute per
    ClientType. Callers that omit ClientType share one pooled allowance
    with every other anonymous caller. This server sets a distinct
    ClientType header and self-throttles to <=4 calls/minute against this
    one subscription scope, backed by a 30-minute TTL cache (Cost
    Management's own underlying data only refreshes every 8-24h, so
    aggressive caching costs zero real freshness).
  - Auth: azure-identity's DefaultAzureCredential, whose chain includes
    WorkloadIdentityCredential — auto-activates from the AZURE_CLIENT_ID /
    AZURE_TENANT_ID / AZURE_FEDERATED_TOKEN_FILE / AZURE_AUTHORITY_HOST env
    vars the AKS workload-identity mutating webhook injects into this pod
    (same webhook every other per-workload identity in this project
    already relies on). No PAT, no API key, no CSI-synced secret — this is
    the first MCP server in the project whose only credential is the
    workload-identity-federated Azure AD token itself.

Transport: SSE via FastMCP (uvicorn on port 8000)

Environment variables:
  AZURE_SUBSCRIPTION_ID — Azure subscription ID to query (required)
"""

import asyncio
import os
import time
from datetime import datetime, timedelta, timezone
from typing import Any

import httpx
from azure.identity import DefaultAzureCredential
from mcp.server.fastmcp import FastMCP

# ---------------------------------------------------------------------------
# Server setup
# ---------------------------------------------------------------------------

mcp = FastMCP(
    name="cost-mcp",
    instructions="Azure Cost Management — cost by service/resource, trend (subscription scope only, read-only)",
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
    return JSONResponse({"status": "healthy", "service": "cost-mcp"})


AZURE_SUBSCRIPTION_ID = os.getenv("AZURE_SUBSCRIPTION_ID", "")
COST_MANAGEMENT_API_VERSION = "2023-11-01"
COST_MANAGEMENT_SCOPE = "https://management.azure.com/.default"
CLIENT_TYPE = "contextforge-cost-mcp-server"  # dedicated pool, not the shared no-ClientType allowance

CACHE_TTL_SECONDS = 30 * 60  # 30 minutes — Cost Management data itself only refreshes every 8-24h
MIN_CALL_INTERVAL_SECONDS = 15.0  # <= 4 calls/minute per scope, with headroom

_credential = DefaultAzureCredential() if AZURE_SUBSCRIPTION_ID else None
_token_cache: dict[str, Any] = {"token": None, "expires_at": 0.0}
_response_cache: dict[str, Any] = {}
_last_call_at = 0.0
_call_lock = asyncio.Lock()


# ---------------------------------------------------------------------------
# Auth: acquire (and cache) an Azure AD access token via workload identity
# federation. DefaultAzureCredential.get_token() already caches internally,
# but we keep an explicit cache here too so a cold get_token() call never
# blocks a burst of concurrent tool calls.
# ---------------------------------------------------------------------------

async def _get_access_token() -> str:
    now = time.monotonic()
    if _token_cache["token"] and now < _token_cache["expires_at"] - 60:
        return _token_cache["token"]

    if _credential is None:
        raise RuntimeError("AZURE_SUBSCRIPTION_ID is not set — cannot acquire a credential")

    token = await asyncio.to_thread(_credential.get_token, COST_MANAGEMENT_SCOPE)
    _token_cache["token"] = token.token
    _token_cache["expires_at"] = now + max(token.expires_on - time.time(), 60)
    return token.token


# ---------------------------------------------------------------------------
# Rate-limit-aware POST to the Cost Management Query API, with:
#   - a distinct ClientType header (own pooled allowance)
#   - a self-imposed <=4-calls/minute gate against this one subscription scope
#   - Retry-After-aware exponential backoff on HTTP 429
# ---------------------------------------------------------------------------

async def _query_cost_management(body: dict[str, Any]) -> dict[str, Any]:
    global _last_call_at

    if not AZURE_SUBSCRIPTION_ID:
        return {"error": "AZURE_SUBSCRIPTION_ID is not configured on this deployment"}

    url = (
        f"https://management.azure.com/subscriptions/{AZURE_SUBSCRIPTION_ID}"
        f"/providers/Microsoft.CostManagement/query"
        f"?api-version={COST_MANAGEMENT_API_VERSION}"
    )

    async with _call_lock:
        # Self-throttle: never issue a new call to this scope faster than
        # MIN_CALL_INTERVAL_SECONDS, regardless of cache misses stacking up.
        now = time.monotonic()
        wait_for = MIN_CALL_INTERVAL_SECONDS - (now - _last_call_at)
        if wait_for > 0:
            await asyncio.sleep(wait_for)

        try:
            token = await _get_access_token()
        except Exception as exc:
            return {"error": f"failed to acquire Azure AD token: {exc}"}

        headers = {
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
            "ClientType": CLIENT_TYPE,
        }

        max_retries = 3
        backoff_seconds = 2.0
        last_error: str | None = None

        async with httpx.AsyncClient(timeout=30) as client:
            for attempt in range(max_retries + 1):
                _last_call_at = time.monotonic()
                try:
                    resp = await client.post(url, headers=headers, json=body)
                except Exception as exc:
                    last_error = str(exc)
                    break

                if resp.status_code == 429:
                    retry_after = resp.headers.get("Retry-After")
                    delay = float(retry_after) if retry_after else backoff_seconds * (2 ** attempt)
                    last_error = f"HTTP 429 rate limited (attempt {attempt + 1}/{max_retries + 1})"
                    if attempt < max_retries:
                        await asyncio.sleep(delay)
                        continue
                    return {"error": "rate_limited", "detail": last_error}

                if resp.status_code >= 400:
                    return {
                        "error": f"HTTP {resp.status_code}",
                        "detail": resp.text[:1000],
                    }

                return resp.json()

        return {"error": last_error or "request failed with no response"}


def _cache_get(key: str) -> dict[str, Any] | None:
    entry = _response_cache.get(key)
    if not entry:
        return None
    if time.monotonic() - entry["cached_at"] > CACHE_TTL_SECONDS:
        return None
    result = dict(entry["value"])
    result["cached"] = True
    return result


def _cache_set(key: str, value: dict[str, Any]) -> None:
    _response_cache[key] = {"value": value, "cached_at": time.monotonic()}


def _parse_rows(raw: dict[str, Any]) -> tuple[list[str], list[list[Any]]]:
    properties = raw.get("properties", {})
    columns = [c.get("name") for c in properties.get("columns", [])]
    rows = properties.get("rows", [])
    return columns, rows


# ---------------------------------------------------------------------------
# Tool: cost by service
# ---------------------------------------------------------------------------

@mcp.tool()
async def cost_by_service(timeframe: str = "MonthToDate", top_n: int = 10) -> dict[str, Any]:
    """
    Actual cost grouped by Azure service (ServiceName), subscription scope only.

    Args:
        timeframe: Cost Management timeframe (e.g. MonthToDate, BillingMonthToDate, TheLastMonth)
        top_n: Number of top services to return, sorted by cost descending

    Returns:
        dict with subscription_id, queried_at, cached, timeframe, and a
        services list of {service_name, cost, currency}
    """
    cache_key = f"cost_by_service:{timeframe}:{top_n}"
    cached = _cache_get(cache_key)
    if cached:
        return cached

    body = {
        "type": "ActualCost",
        "timeframe": timeframe,
        "dataset": {
            "granularity": "None",
            "aggregation": {"totalCost": {"name": "Cost", "function": "Sum"}},
            "grouping": [{"type": "Dimension", "name": "ServiceName"}],
        },
    }
    raw = await _query_cost_management(body)
    if "error" in raw:
        return {"subscription_id": AZURE_SUBSCRIPTION_ID, "timeframe": timeframe, **raw}

    columns, rows = _parse_rows(raw)
    try:
        cost_idx = columns.index("Cost")
        service_idx = columns.index("ServiceName")
        currency_idx = columns.index("Currency") if "Currency" in columns else None
    except ValueError:
        return {"error": "unexpected response shape", "columns": columns}

    services = [
        {
            "service_name": row[service_idx],
            "cost": row[cost_idx],
            "currency": row[currency_idx] if currency_idx is not None else "USD",
        }
        for row in rows
    ]
    services.sort(key=lambda r: r["cost"], reverse=True)

    result = {
        "subscription_id": AZURE_SUBSCRIPTION_ID,
        "queried_at": datetime.now(timezone.utc).isoformat(),
        "cached": False,
        "timeframe": timeframe,
        "services": services[:top_n],
    }
    _cache_set(cache_key, result)
    return result


# ---------------------------------------------------------------------------
# Tool: cost by resource
# ---------------------------------------------------------------------------

@mcp.tool()
async def cost_by_resource(timeframe: str = "MonthToDate", top_n: int = 10) -> dict[str, Any]:
    """
    Actual cost grouped by resource (ResourceId), subscription scope only.

    Args:
        timeframe: Cost Management timeframe (e.g. MonthToDate, BillingMonthToDate, TheLastMonth)
        top_n: Number of top resources to return, sorted by cost descending

    Returns:
        dict with subscription_id, queried_at, cached, timeframe, and a
        resources list of {resource_id, cost, currency}
    """
    cache_key = f"cost_by_resource:{timeframe}:{top_n}"
    cached = _cache_get(cache_key)
    if cached:
        return cached

    body = {
        "type": "ActualCost",
        "timeframe": timeframe,
        "dataset": {
            "granularity": "None",
            "aggregation": {"totalCost": {"name": "Cost", "function": "Sum"}},
            "grouping": [{"type": "Dimension", "name": "ResourceId"}],
        },
    }
    raw = await _query_cost_management(body)
    if "error" in raw:
        return {"subscription_id": AZURE_SUBSCRIPTION_ID, "timeframe": timeframe, **raw}

    columns, rows = _parse_rows(raw)
    try:
        cost_idx = columns.index("Cost")
        resource_idx = columns.index("ResourceId")
        currency_idx = columns.index("Currency") if "Currency" in columns else None
    except ValueError:
        return {"error": "unexpected response shape", "columns": columns}

    resources = [
        {
            "resource_id": row[resource_idx],
            "cost": row[cost_idx],
            "currency": row[currency_idx] if currency_idx is not None else "USD",
        }
        for row in rows
    ]
    resources.sort(key=lambda r: r["cost"], reverse=True)

    result = {
        "subscription_id": AZURE_SUBSCRIPTION_ID,
        "queried_at": datetime.now(timezone.utc).isoformat(),
        "cached": False,
        "timeframe": timeframe,
        "resources": resources[:top_n],
    }
    _cache_set(cache_key, result)
    return result


# ---------------------------------------------------------------------------
# Tool: cost trend
# ---------------------------------------------------------------------------

@mcp.tool()
async def cost_trend(days: int = 30, granularity: str = "Daily") -> dict[str, Any]:
    """
    Daily total cost time series over the last N days, subscription scope only.
    Useful for correlating against utilization time series (e.g. from
    prometheus-mcp-*) in a rightsizing agent context.

    Args:
        days: Number of days to look back (default 30)
        granularity: Cost Management granularity (Daily is the only sensible value here)

    Returns:
        dict with subscription_id, queried_at, cached, from/to, and a
        points list of {date, cost, currency}
    """
    cache_key = f"cost_trend:{days}:{granularity}"
    cached = _cache_get(cache_key)
    if cached:
        return cached

    end = datetime.now(timezone.utc).date()
    start = end - timedelta(days=days)

    body = {
        "type": "ActualCost",
        "timeframe": "Custom",
        "timePeriod": {
            "from": start.isoformat() + "T00:00:00+00:00",
            "to": end.isoformat() + "T00:00:00+00:00",
        },
        "dataset": {
            "granularity": granularity,
            "aggregation": {"totalCost": {"name": "Cost", "function": "Sum"}},
        },
    }
    raw = await _query_cost_management(body)
    if "error" in raw:
        return {"subscription_id": AZURE_SUBSCRIPTION_ID, "from": str(start), "to": str(end), **raw}

    columns, rows = _parse_rows(raw)
    try:
        cost_idx = columns.index("Cost")
        date_idx = columns.index("UsageDate")
        currency_idx = columns.index("Currency") if "Currency" in columns else None
    except ValueError:
        return {"error": "unexpected response shape", "columns": columns}

    points = [
        {
            "date": str(row[date_idx]),
            "cost": row[cost_idx],
            "currency": row[currency_idx] if currency_idx is not None else "USD",
        }
        for row in rows
    ]
    points.sort(key=lambda p: p["date"])

    result = {
        "subscription_id": AZURE_SUBSCRIPTION_ID,
        "queried_at": datetime.now(timezone.utc).isoformat(),
        "cached": False,
        "from": str(start),
        "to": str(end),
        "granularity": granularity,
        "points": points,
    }
    _cache_set(cache_key, result)
    return result


# ---------------------------------------------------------------------------
# Entrypoint
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    # host/port are set on the FastMCP() constructor, not here.
    # run() only accepts transport and mount_path (mcp SDK v1.28+).
    mcp.run(transport="sse")
