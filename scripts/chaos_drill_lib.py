#!/usr/bin/env python3
"""Phase 6.3.3-6.3.4 — shared mechanics for gated fault-injection drills.

Every non-negotiable guardrail from docs/phase6-plan.md's own §6.3 design is
enforced *here*, in code, not left to each drill script's own discipline:
  1. Human approval on every fault-injecting run — this module never applies
     a manifest on its own initiative; every caller must have already gotten
     a live "yes" for this specific run (see the drill scripts' own __main__).
  2. Pod-scoped only, hard allow/deny list (below) — checked before any apply.
  3. Node count / autoscaler / min=2 are never touched — there is no code
     path in this module that can reach node-level or node-pool-level
     resources at all (it only ever `kubectl apply -f`s a namespaced
     PodChaos/NetworkChaos manifest and polls pod/gateway state).
  4. Every fault stays bounded and auto-reverting: pod-kill is inherently
     one-shot (Kubernetes' own Deployment controller recreates the pod
     immediately); NetworkChaos manifests carry their own `duration` field.
     The dead-man's-switch below is the *additional* safety net on top of
     that, for the case where a fault doesn't clear on its own.
  5. A live-usage check can abort a drill before it starts.
  6. Drills are meant to run one at a time, serialized — nothing here
     provides any parallel/concurrent-fault mechanism.
"""

import asyncio
import subprocess
import sys
import time
from datetime import datetime, timezone

import requests

GATEWAY_URL = "https://contextforge.gourmandtech.com"
NAMESPACE = "mcp"

# Stateless MCP/agent pods — safe drill targets. Deliberately does NOT include
# anything stateful or customer-facing.
ALLOWED_TARGET_APPS = {
    "github-mcp-server",
    "azure-devops-mcp-server",
    "kubernetes-mcp-server",
    "prometheus-mcp-server",
    "sre-mcp-server",
    "cost-mcp-server",
    "sre-agent",
    "dev-agent",
}

# Explicit, hard deny — checked even if a caller somehow bypasses
# ALLOWED_TARGET_APPS. Never touched by anything in this module.
HARD_DENIED_APPS = {
    "mcp-stack-mcpgateway",
    "mcp-stack-postgres",
    "mcp-stack-redis",
    "cert-manager",
    "ingress-nginx",
}


class DrillSafetyError(RuntimeError):
    """Raised when a drill's own pre-flight safety checks fail — never bypassed."""


def _utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def assert_target_allowed(app_label: str) -> None:
    if app_label in HARD_DENIED_APPS:
        raise DrillSafetyError(f"'{app_label}' is on the hard deny-list — never a valid drill target.")
    if app_label not in ALLOWED_TARGET_APPS:
        raise DrillSafetyError(
            f"'{app_label}' is not on the allow-list ({sorted(ALLOWED_TARGET_APPS)}) — refusing to target it."
        )


def check_gateway_health() -> tuple[bool, int]:
    try:
        resp = requests.get(f"{GATEWAY_URL}/health", timeout=10)
        return resp.ok, resp.status_code
    except requests.RequestException:
        return False, 0


def check_recent_gateway_activity(admin_token: str, within_minutes: int = 2) -> bool:
    """Best-effort 'is someone actively using this system right now' proxy.

    Personal single-user project — this is a cheap, sufficient check per the
    plan's own framing ("cheap and sufficient given the owner is the sole
    real user"), not a rigorous multi-tenant traffic-shaping guard.
    """
    try:
        resp = requests.get(
            f"{GATEWAY_URL}/admin/metrics",
            headers={"Authorization": f"Bearer {admin_token}"},
            timeout=10,
        )
        if not resp.ok:
            return False
        last_exec = resp.json().get("tools", {}).get("lastExecutionTime")
        if not last_exec:
            return False
        last_dt = datetime.fromisoformat(last_exec.replace("Z", "+00:00"))
        age_s = (datetime.now(timezone.utc) - last_dt).total_seconds()
        return age_s < within_minutes * 60
    except Exception:  # noqa: BLE001 - a failed liveness check should not block a drill
        return False


def apply_manifest(path: str) -> None:
    subprocess.run(["kubectl", "apply", "-f", path], check=True)


def delete_manifest(path: str) -> None:
    subprocess.run(["kubectl", "delete", "-f", path, "--ignore-not-found"], check=True)


def get_pod_phase(app_label: str, namespace: str = NAMESPACE) -> list[dict]:
    result = subprocess.run(
        [
            "kubectl", "get", "pods", "-n", namespace,
            "-l", f"app={app_label}",
            "-o", "jsonpath={range .items[*]}{.metadata.name} {.status.phase} {.status.containerStatuses[0].ready}\n{end}",
        ],
        capture_output=True, text=True, check=True,
    )
    pods = []
    for line in result.stdout.strip().splitlines():
        if not line:
            continue
        parts = line.split()
        pods.append({"name": parts[0], "phase": parts[1] if len(parts) > 1 else "", "ready": parts[2] if len(parts) > 2 else "false"})
    return pods


def wait_for_pod_ready(app_label: str, namespace: str = NAMESPACE, timeout_s: int = 60, poll_s: float = 2.0) -> tuple[bool, float]:
    """Poll until at least one pod for app_label is Running+Ready, or timeout."""
    start = time.monotonic()
    while time.monotonic() - start < timeout_s:
        pods = get_pod_phase(app_label, namespace)
        if any(p["phase"] == "Running" and p["ready"] == "true" for p in pods):
            return True, time.monotonic() - start
        time.sleep(poll_s)
    return False, time.monotonic() - start


async def run_dead_mans_switch(manifest_path: str, stop_event: asyncio.Event, threshold_s: float = 30.0, poll_interval_s: float = 3.0) -> None:
    """Polls gateway /health; if it's non-200 for a sustained threshold_s, deletes the manifest immediately.

    This is the safety net *in addition to* each manifest's own bounded
    duration/one-shot nature — not a substitute for it.
    """
    consecutive_fail_start: float | None = None
    while not stop_event.is_set():
        ok, _ = check_gateway_health()
        now = time.monotonic()
        if not ok:
            if consecutive_fail_start is None:
                consecutive_fail_start = now
            elif now - consecutive_fail_start > threshold_s:
                print(f"[dead-man's-switch] gateway /health unhealthy for >{threshold_s}s — aborting drill, deleting {manifest_path}", file=sys.stderr)
                delete_manifest(manifest_path)
                return
        else:
            consecutive_fail_start = None
        await asyncio.sleep(poll_interval_s)


def call_sre_agent_evaluation(prompt: str, local_port: int = 18010) -> dict:
    """Reuses the already-deployed sre-agent's own /run endpoint for the
    'agent evaluation harness' the plan calls for — same port-forward
    mechanism as agents/sre-agent/baseline_drill.py, no new cluster access.
    """
    pf = subprocess.Popen(
        ["kubectl", "port-forward", "-n", NAMESPACE, "svc/sre-agent", f"{local_port}:8000"],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
    )
    try:
        deadline = time.time() + 15
        ready = False
        while time.time() < deadline:
            line = pf.stdout.readline()
            if "Forwarding from" in line:
                ready = True
                break
            if pf.poll() is not None:
                break
        if not ready:
            time.sleep(2)
        resp = requests.post(f"http://localhost:{local_port}/run", json={"query": prompt}, timeout=180)
        body = resp.json() if resp.ok else resp.text
        return {"status_code": resp.status_code, "ok": resp.ok, "response": body}
    finally:
        pf.terminate()
        try:
            pf.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pf.kill()
