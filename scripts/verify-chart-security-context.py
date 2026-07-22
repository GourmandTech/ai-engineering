#!/usr/bin/env python3
"""Fail loudly if any rendered container would hit the exact failure mode from
the 2026-07-22 incident: `runAsNonRoot: true` (pod- or container-level) with no
paired `runAsUser` anywhere in the effective security context. Kubernetes then
refuses to start the container if its image defaults to root (postgres:17 and
redis:8.0.0 both do), with the unhelpful "container has runAsNonRoot and image
will run as root" error, discovered only at deploy time.

Usage: helm template mcp-stack .contextforge/charts/mcp-stack \
         -f infra/helm/values.yaml -f infra/helm/values.azure.yaml \
         | python3 scripts/verify-chart-security-context.py
"""
import sys
import yaml

POD_SPEC_CONTAINER_KEYS = ("containers", "initContainers")


def pod_specs(doc):
    kind = doc.get("kind")
    if kind in ("Deployment", "StatefulSet", "DaemonSet", "Job"):
        template = doc["spec"].get("template", {})
        yield doc, template.get("spec", {})
    elif kind == "CronJob":
        template = doc["spec"]["jobTemplate"]["spec"].get("template", {})
        yield doc, template.get("spec", {})
    elif kind == "Pod":
        yield doc, doc.get("spec", {})


def check(pod_spec):
    pod_sc = pod_spec.get("securityContext") or {}
    findings = []
    for key in POD_SPEC_CONTAINER_KEYS:
        for c in pod_spec.get(key) or []:
            c_sc = c.get("securityContext") or {}
            effective_non_root = c_sc.get("runAsNonRoot", pod_sc.get("runAsNonRoot"))
            effective_user = c_sc.get("runAsUser", pod_sc.get("runAsUser"))
            if effective_non_root is True and effective_user is None:
                findings.append(c.get("name", "<unnamed>"))
    return findings


def main():
    raw = sys.stdin.read()
    docs = [d for d in yaml.safe_load_all(raw) if d]
    problems = []
    for doc in docs:
        for source, pod_spec in pod_specs(doc):
            for container_name in check(pod_spec):
                problems.append(
                    f"{source.get('kind')}/{source['metadata']['name']}: "
                    f"container '{container_name}' has runAsNonRoot=true with no runAsUser "
                    f"(image will be refused if it defaults to root)"
                )
    if problems:
        print("✗ chart-verify: found containers with runAsNonRoot=true and no runAsUser:",
              file=sys.stderr)
        for p in problems:
            print(f"  - {p}", file=sys.stderr)
        return 1
    print(f"✓ chart-verify: {len(docs)} rendered documents, no runAsNonRoot/runAsUser gaps")
    return 0


if __name__ == "__main__":
    sys.exit(main())
