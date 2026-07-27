#!/usr/bin/env python3
"""Phase 6.3.4 — NetworkChaos egress-partition drill, sre-agent -> gateway.

Deliberately re-exercises the exact failure surface that broke by accident
twice already in this project (Phase 4 kubernetes-mcp-server apiserver
egress; Phase 5.2 sre-agent's own port-4444 egress, which hung forever at
SSE `status: pending` before _wait_for_mcp_connection's CONNECT_TIMEOUT_S=20
fix). The actual pass/fail bar for this drill is specific: a call made
*during* the partition must fail cleanly (a real error, at or before the
known ~20s internal timeout) rather than hang indefinitely — proving the
5.2 fix still holds, not just that the pod eventually recovers.

Requires a human to have already approved THIS SPECIFIC run before it's
invoked, same as the pod-kill drill — see
docs/runbooks/phase6-orchestration-finops-chaos.md Sec 6.3.4.
"""

import asyncio
import json
import sys
import time

sys.path.insert(0, "scripts")
from chaos_drill_lib import (  # noqa: E402
    ALLOWED_TARGET_APPS,
    assert_target_allowed,
    apply_manifest,
    call_sre_agent_evaluation,
    check_gateway_health,
    delete_manifest,
    get_pod_phase,
    run_dead_mans_switch,
)

TARGET_APP = "sre-agent"
MANIFEST_PATH = "infra/chaos/network-partition-sre-agent-egress.yaml"
OTHER_APPS_TO_WATCH = sorted(ALLOWED_TARGET_APPS - {TARGET_APP})
DURING_PARTITION_CLIENT_TIMEOUT_S = 25  # slightly above sre-agent's own 20s internal connect timeout
PARTITION_DURATION_S = 30  # matches the manifest's own `duration: "30s"`


async def _call_sre_agent_during_partition() -> dict:
    """Fires a call to sre-agent expecting either a clean fast failure or a
    clean failure at ~20s (its own internal timeout) — NOT a hang past
    DURING_PARTITION_CLIENT_TIMEOUT_S, which would mean the 5.2 bug is back.
    """
    import subprocess

    import requests

    pf = subprocess.Popen(
        ["kubectl", "port-forward", "-n", "mcp", "svc/sre-agent", "18011:8000"],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
    )
    try:
        time.sleep(3)
        start = time.monotonic()
        try:
            resp = requests.post(
                "http://localhost:18011/run",
                json={"query": "Say hello, no tool calls needed."},
                timeout=DURING_PARTITION_CLIENT_TIMEOUT_S,
            )
            elapsed = time.monotonic() - start
            return {"hung": False, "elapsed_seconds": round(elapsed, 1), "status_code": resp.status_code, "clean_failure": not resp.ok}
        except requests.exceptions.Timeout:
            elapsed = time.monotonic() - start
            return {"hung": True, "elapsed_seconds": round(elapsed, 1), "note": f"client-side timeout hit at {DURING_PARTITION_CLIENT_TIMEOUT_S}s — this would mean the 5.2 hang regressed"}
    finally:
        pf.terminate()
        try:
            pf.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pf.kill()


async def main() -> int:
    report: dict = {"drill": "6.3.4 network-partition", "target": f"{TARGET_APP} -> gateway egress", "steps": {}}

    print(f"=== Pre-flight: confirming '{TARGET_APP}' is an allowed target ===", file=sys.stderr)
    assert_target_allowed(TARGET_APP)

    print("=== Pre-flight: gateway health + baseline other-app state ===", file=sys.stderr)
    ok, code = check_gateway_health()
    report["steps"]["pre_gateway_health"] = {"ok": ok, "status_code": code}
    baseline = {app: get_pod_phase(app) for app in OTHER_APPS_TO_WATCH}
    report["steps"]["baseline_other_apps"] = baseline
    if not ok or any(not all(p["phase"] == "Running" and p["ready"] == "true" for p in pods) for pods in baseline.values()):
        print("ABORT: system not healthy before the drill even starts.", file=sys.stderr)
        print(json.dumps(report, indent=2))
        return 1

    print(f"=== Applying {MANIFEST_PATH} (duration: {PARTITION_DURATION_S}s) ===", file=sys.stderr)
    stop_event = asyncio.Event()
    watcher = asyncio.create_task(run_dead_mans_switch(MANIFEST_PATH, stop_event, threshold_s=30.0))

    try:
        apply_manifest(MANIFEST_PATH)

        print("=== Calling sre-agent DURING the partition — expecting a clean failure, not a hang ===", file=sys.stderr)
        during_result = await _call_sre_agent_during_partition()
        report["steps"]["during_partition_call"] = during_result

        remaining = max(0, PARTITION_DURATION_S - during_result.get("elapsed_seconds", 0))
        print(f"=== Waiting out the remaining ~{remaining:.0f}s of the partition duration ===", file=sys.stderr)
        await asyncio.sleep(remaining + 2)

    finally:
        stop_event.set()
        await watcher
        print(f"=== Cleaning up: deleting {MANIFEST_PATH} ===", file=sys.stderr)
        delete_manifest(MANIFEST_PATH)

    print("=== Confirming other watched apps stayed healthy throughout ===", file=sys.stderr)
    after = {app: get_pod_phase(app) for app in OTHER_APPS_TO_WATCH}
    report["steps"]["after_other_apps"] = after
    others_still_healthy = all(all(p["phase"] == "Running" and p["ready"] == "true" for p in pods) for pods in after.values())
    report["steps"]["others_still_healthy"] = others_still_healthy

    ok_after, code_after = check_gateway_health()
    report["steps"]["post_gateway_health"] = {"ok": ok_after, "status_code": code_after}

    print("=== Confirming sre-agent recovered after the partition cleared ===", file=sys.stderr)
    eval_prompt = "Say hello, no tool calls needed. Also report if you can reach your federated tools normally now."
    recovery_result = call_sre_agent_evaluation(eval_prompt)
    report["steps"]["post_partition_recovery"] = recovery_result

    passed = (
        not during_result["hung"]
        and others_still_healthy
        and ok_after
        and recovery_result.get("ok", False)
    )
    report["result"] = "PASS" if passed else "FAIL"

    print(json.dumps(report, indent=2))
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
