#!/usr/bin/env python3
"""Phase 6.3.3 — pod-kill drill on github-mcp-server.

Requires a human to have already approved THIS SPECIFIC run before it's
invoked — this script does not itself gate on approval (there is no way for
a script to verify a real human said yes; that has to happen one layer up,
in the actual conversation, immediately before this is run). See
docs/runbooks/phase6-orchestration-finops-chaos.md Sec 6.3.3 for the
approval this exact run was granted under.

Usage: python3 scripts/chaos-drill-pod-kill.py [--force-skip-usage-check]
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
    check_recent_gateway_activity,
    delete_manifest,
    get_pod_phase,
    run_dead_mans_switch,
    wait_for_pod_ready,
)

TARGET_APP = "github-mcp-server"
MANIFEST_PATH = "infra/chaos/pod-kill-github-mcp.yaml"
OTHER_APPS_TO_WATCH = sorted(ALLOWED_TARGET_APPS - {TARGET_APP})


async def main() -> int:
    force_skip_usage_check = "--force-skip-usage-check" in sys.argv

    report: dict = {"drill": "6.3.3 pod-kill", "target": TARGET_APP, "started_at": None, "steps": {}}

    print(f"=== Pre-flight: confirming '{TARGET_APP}' is an allowed target ===", file=sys.stderr)
    assert_target_allowed(TARGET_APP)  # raises DrillSafetyError and aborts if not

    print("=== Pre-flight: gateway health ===", file=sys.stderr)
    ok, code = check_gateway_health()
    report["steps"]["pre_gateway_health"] = {"ok": ok, "status_code": code}
    if not ok:
        print(f"ABORT: gateway /health is not healthy before the drill even starts ({code}).", file=sys.stderr)
        print(json.dumps(report, indent=2))
        return 1

    print("=== Pre-flight: capturing baseline pod state for all watched apps ===", file=sys.stderr)
    baseline = {app: get_pod_phase(app) for app in OTHER_APPS_TO_WATCH}
    report["steps"]["baseline_other_apps"] = baseline
    unhealthy_at_start = [app for app, pods in baseline.items() if not all(p["phase"] == "Running" and p["ready"] == "true" for p in pods)]
    if unhealthy_at_start:
        print(f"ABORT: these apps are already unhealthy before the drill starts: {unhealthy_at_start}", file=sys.stderr)
        print(json.dumps(report, indent=2))
        return 1

    print("=== Pre-flight: live-usage check ===", file=sys.stderr)
    # No live admin token wired into this script deliberately — it shells out
    # to `make mcp-get-token` at call time if ever needed. For now, treat this
    # step as advisory only in a single-user project and let a human confirm.
    report["steps"]["live_usage_check"] = "skipped (advisory only, single-user project)" if force_skip_usage_check else "not wired to a token in this script — confirm manually before running"

    print(f"=== Applying {MANIFEST_PATH} ===", file=sys.stderr)
    report["started_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    stop_event = asyncio.Event()
    watcher = asyncio.create_task(run_dead_mans_switch(MANIFEST_PATH, stop_event, threshold_s=30.0))

    try:
        apply_manifest(MANIFEST_PATH)

        print("=== Waiting for target pod to recover (Running + Ready) ===", file=sys.stderr)
        recovered, elapsed = wait_for_pod_ready(TARGET_APP, timeout_s=60)
        report["steps"]["target_recovery"] = {"recovered": recovered, "elapsed_seconds": round(elapsed, 1)}

        print("=== Checking other watched apps stayed healthy throughout ===", file=sys.stderr)
        after = {app: get_pod_phase(app) for app in OTHER_APPS_TO_WATCH}
        report["steps"]["after_other_apps"] = after
        others_still_healthy = all(
            all(p["phase"] == "Running" and p["ready"] == "true" for p in pods) for pods in after.values()
        )
        report["steps"]["others_still_healthy"] = others_still_healthy

        print("=== Post-drill gateway health ===", file=sys.stderr)
        ok_after, code_after = check_gateway_health()
        report["steps"]["post_gateway_health"] = {"ok": ok_after, "status_code": code_after}

    finally:
        stop_event.set()
        await watcher
        print(f"=== Cleaning up: deleting {MANIFEST_PATH} ===", file=sys.stderr)
        delete_manifest(MANIFEST_PATH)

    print("=== Agent evaluation harness: asking sre-agent to assess post-drill state ===", file=sys.stderr)
    eval_prompt = (
        "A chaos drill was just run against github-mcp-server (a pod-kill test). Report the current "
        "Running/Ready status and restart count of all 5 federated MCP server pods plus yourself, and "
        "summarize any Prometheus alerts firing in the last 10 minutes. Do NOT query node count, node "
        "status, or autoscaler/node-pool configuration — that is out of scope."
    )
    report["steps"]["agent_evaluation"] = call_sre_agent_evaluation(eval_prompt)

    passed = report["steps"]["target_recovery"]["recovered"] and report["steps"]["others_still_healthy"] and ok_after
    report["result"] = "PASS" if passed else "FAIL"

    print(json.dumps(report, indent=2))
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
