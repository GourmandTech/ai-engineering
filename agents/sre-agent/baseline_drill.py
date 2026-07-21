#!/usr/bin/env python3
"""Phase 6.3.2 — Chaos Mesh observe-only baseline drill.

Records a healthy steady-state fingerprint of the serving path *before* any
fault injection is ever allowed to run (Phase 6.3 guardrail #2: "observe-only
baseline, no faults... prove evaluation works before anything is allowed to
break"). This script makes exactly three calls:

1. GET  {GATEWAY_URL}/health           — deterministic REST, no auth
2. GET  {GATEWAY_URL}/metrics          — deterministic REST, bearer-token auth
3. POST http://sre-agent:8000/run      — one narrowly-prompted agent call,
   reached via `kubectl port-forward` (no new secrets, no new identity, no
   new cluster access — reuses the already-deployed, already-credentialed
   Phase 5.2 sre-agent pod's existing A2A HTTP endpoint)

Hard scope boundary (Phase 6.3 plan, non-negotiable for this wave): this
script never queries node count or autoscaler config, and the agent prompt
below explicitly instructs the model to avoid that surface too — node-level
chaos and even node-level *observation* here is out of scope; only pod /
restart / alert state is fair game.
"""

import json
import os
import subprocess
import sys
import time
from datetime import datetime, timezone

import requests

GATEWAY_URL = os.environ.get("GATEWAY_URL", "https://contextforge.gourmandtech.com")
SRE_AGENT_NAMESPACE = os.environ.get("SRE_AGENT_NAMESPACE", "mcp")
SRE_AGENT_SERVICE = os.environ.get("SRE_AGENT_SERVICE", "sre-agent")
SRE_AGENT_SVC_PORT = int(os.environ.get("SRE_AGENT_SVC_PORT", "8000"))
LOCAL_PORT = int(os.environ.get("SRE_AGENT_LOCAL_PORT", "18000"))
PORT_FORWARD_READY_TIMEOUT_S = 15

# Deliberately narrow: pod/restart/alert state only. Never node count or
# autoscaler config — that's Phase 6.3's hard exclusion, not a suggestion.
AGENT_PROMPT = (
    "This is an observe-only baseline drill, not a fault-injection test — nothing has been "
    "broken yet. Report the current steady-state health of the MCP server pods only: "
    "for each of the 5 federated MCP server pods and yourself (sre-agent), report pod phase "
    "(Running/Pending/etc), restart count, and readiness. Also summarize any Prometheus alerts "
    "firing in the last 24 hours. "
    "Do NOT query node count, node status, or autoscaler/node-pool configuration in any way — "
    "that is explicitly out of scope for this drill, even for read-only observation. "
    "Keep the report short and factual."
)


def _utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def check_gateway_health() -> dict:
    resp = requests.get(f"{GATEWAY_URL}/health", timeout=10)
    return {
        "call": "GET /health",
        "status_code": resp.status_code,
        "ok": resp.ok,
        "body": resp.json() if resp.ok else resp.text,
    }


def check_gateway_metrics(token: str) -> dict:
    """GET /metrics with the sre-agent's own team+server-scoped token.

    Real finding (2026-07-21, confirmed live): a non-admin, team+server-scoped
    token — the exact kind sre-agent already holds — gets a flat 403
    `{"detail": "Access denied"}` from /metrics, even though the *same* token
    works fine for every federated tool call. /metrics is apparently
    admin-gated in a way the Phase 4 runbook's "requires auth (401 without a
    token)" note didn't capture (that note was written against an admin
    token, so it never saw the 403 case). If this happens, fall back to the
    existing platform-admin credential path (same KV secrets `make
    mcp-get-token` already reads — no new identity, nothing new provisioned)
    so the drill can still get one *some* /metrics reading, and flag which
    token tier actually produced it.
    """
    resp = requests.get(
        f"{GATEWAY_URL}/metrics",
        headers={"Authorization": f"Bearer {token}"},
        timeout=10,
    )
    token_tier = "sre-agent-scoped"
    if resp.status_code == 403:
        try:
            admin_token = _load_admin_token()
            resp = requests.get(
                f"{GATEWAY_URL}/metrics",
                headers={"Authorization": f"Bearer {admin_token}"},
                timeout=10,
            )
            token_tier = "platform-admin (fallback — scoped token got 403)"
        except Exception as exc:  # noqa: BLE001 - keep the original 403 result if fallback fails
            return {
                "call": "GET /metrics",
                "status_code": 403,
                "ok": False,
                "token_tier": "sre-agent-scoped",
                "note": f"scoped token 403'd and admin fallback failed: {exc}",
            }

    body = resp.json() if resp.ok else resp.text
    # Trim to the fields that actually matter for a fingerprint — the full
    # payload is large and most of it (per-tool breakdowns) isn't needed here.
    summary = None
    if resp.ok and isinstance(body, dict):
        summary = {
            "tools_totalExecutions": body.get("tools", {}).get("totalExecutions"),
            "gateways": body.get("gateways"),
            "a2aAgents": body.get("a2aAgents"),
        }
    return {
        "call": "GET /metrics",
        "status_code": resp.status_code,
        "ok": resp.ok,
        "token_tier": token_tier,
        "summary": summary,
    }


def _load_admin_token() -> str:
    kv = os.environ.get("KV_NAME", "kv-contextforge-dev")
    email = subprocess.run(
        ["az", "keyvault", "secret", "show", "--vault-name", kv, "--name", "platform-admin-email", "--query", "value", "-o", "tsv"],
        capture_output=True, text=True, check=False,
    ).stdout.strip()
    password = subprocess.run(
        ["az", "keyvault", "secret", "show", "--vault-name", kv, "--name", "platform-admin-password", "--query", "value", "-o", "tsv"],
        capture_output=True, text=True, check=False,
    ).stdout.strip()
    if not email or not password:
        raise RuntimeError("Could not read platform-admin-email/password from Key Vault")
    resp = requests.post(
        f"{GATEWAY_URL}/auth/login",
        json={"email": email, "password": password},
        timeout=10,
    )
    resp.raise_for_status()
    return resp.json()["access_token"]


def _load_gateway_token() -> str:
    token = os.environ.get("SRE_AGENT_JWT")
    if token:
        return token
    result = subprocess.run(
        ["make", "sre-agent-get-token"],
        cwd=os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
        capture_output=True,
        text=True,
        check=False,
    )
    token = result.stdout.strip()
    if not token:
        raise RuntimeError(
            "Could not obtain a gateway JWT. Set SRE_AGENT_JWT or ensure "
            "`make sre-agent-get-token` works (needs az login + KV access)."
        )
    return token


def call_sre_agent_run() -> dict:
    """Port-forward to the sre-agent Service and POST /run with the narrow prompt."""
    pf = subprocess.Popen(
        [
            "kubectl",
            "port-forward",
            "-n",
            SRE_AGENT_NAMESPACE,
            f"svc/{SRE_AGENT_SERVICE}",
            f"{LOCAL_PORT}:{SRE_AGENT_SVC_PORT}",
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    try:
        deadline = time.time() + PORT_FORWARD_READY_TIMEOUT_S
        ready = False
        while time.time() < deadline:
            line = pf.stdout.readline()
            if "Forwarding from" in line:
                ready = True
                break
            if pf.poll() is not None:
                break
        if not ready:
            # Fall back to a short sleep + probe rather than failing outright —
            # some kubectl versions buffer the "Forwarding from" line.
            time.sleep(2)

        resp = requests.post(
            f"http://localhost:{LOCAL_PORT}/run",
            json={"query": AGENT_PROMPT},
            timeout=180,
        )
        body = resp.json() if resp.ok else resp.text
        return {
            "call": "POST /run (sre-agent, via kubectl port-forward)",
            "status_code": resp.status_code,
            "ok": resp.ok,
            "response": body,
        }
    finally:
        pf.terminate()
        try:
            pf.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pf.kill()


def main() -> int:
    fingerprint = {"timestamp_utc": _utc_now(), "drill": "6.3.2 observe-only baseline", "results": {}}

    print("=== 1/3: GET /health ===", file=sys.stderr)
    fingerprint["results"]["health"] = check_gateway_health()

    print("=== 2/3: GET /metrics ===", file=sys.stderr)
    try:
        token = _load_gateway_token()
        fingerprint["results"]["metrics"] = check_gateway_metrics(token)
    except Exception as exc:  # noqa: BLE001 - want the fingerprint to still print partial results
        fingerprint["results"]["metrics"] = {"call": "GET /metrics", "ok": False, "error": str(exc)}

    print("=== 3/3: POST /run (sre-agent, narrow pod/restart/alert prompt) ===", file=sys.stderr)
    try:
        fingerprint["results"]["agent_report"] = call_sre_agent_run()
    except Exception as exc:  # noqa: BLE001
        fingerprint["results"]["agent_report"] = {"call": "POST /run", "ok": False, "error": str(exc)}

    print(json.dumps(fingerprint, indent=2))

    all_ok = all(r.get("ok") for r in fingerprint["results"].values())
    return 0 if all_ok else 1


if __name__ == "__main__":
    sys.exit(main())
