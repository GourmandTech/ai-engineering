# Runbook / Postmortem — Minikube `DRV_CREATE_TIMEOUT` inside a Dev Container on Apple Silicon

**Status:** Resolved
**Date:** 2026-06-29
**Phase:** 2 (Minikube)
**Severity:** Blocker — no local Kubernetes cluster could be created
**Affected:** MacBook Pro M1 (arm64), Docker Desktop, VS Code Dev Container

---

## Summary

`make minikube-start` failed every time with `DRV_CREATE_TIMEOUT`. Minikube created the
kicbase node container, immediately powered it off, deleted it, retried, and finally timed
out after 360 s. The root cause was that **minikube's docker driver reaches the node over the
host's `127.0.0.1:<forwarded-port>` SSH mapping**, which is unreachable from inside a
`docker-outside-of-docker` (DOOD) dev container — `127.0.0.1` there is the dev container's own
loopback, not the Mac host where the port is published. The fix was to switch the dev container
from `docker-outside-of-docker` to `docker-in-docker` (DinD), making the Docker daemon local to
the container so the forwarded ports resolve natively.

---

## Symptom

```
🔥  Creating docker container (CPUs=4, Memory=6144MB) ...
✋  Stopping node "mcpgw"  ...
🛑  Powering off "mcpgw" via SSH ...
🔥  Deleting "mcpgw" in docker ...
🤦  StartHost failed, but will try again: creating host: create host timed out in 360.000000 seconds
❌  Exiting due to DRV_CREATE_TIMEOUT: Failed to start host: creating host: create host timed out in 360.000000 seconds
```

With `--alsologtostderr -v=5`, the decisive line repeated every ~3 s:

```
libmachine: Error dialing TCP: dial tcp 127.0.0.1:54525: connect: connection refused
```

---

## Environment

| Component | Value |
|---|---|
| Host | MacBook Pro M1 (arm64) |
| Container runtime | Docker Desktop |
| Dev Container base | `mcr.microsoft.com/devcontainers/python:3.12-bookworm` |
| Dev Container Docker access | `docker-outside-of-docker` (at time of failure) |
| Kubernetes tool | minikube v1.38.1, docker driver |
| Node image | `gcr.io/k8s-minikube/kicbase:v0.0.50` |

---

## Investigation timeline

1. **Resources ruled out.** `docker info` reported `CPUs=10, Mem=12.5GB`. Bumping Docker
   Desktop memory to 12 GB changed nothing — not a resource shortage.

2. **`--network mcpgw` removed.** An explicit `--network mcpgw` flag on `minikube start` was
   colliding on the `172.19.x` subnet during kicbase creation. Removing it let minikube use its
   default `192.168.49.0/24`. This was necessary but not sufficient.

3. **Zombie container confusion.** A first SSH probe to `192.168.49.2:22` reported `BLOCKED`,
   but that test ran against a kicbase that minikube had already "powered off via SSH" and left
   behind. Testing a powered-off container is meaningless — re-tested against a live one.

4. **Inter-container connectivity proven good.** With the dev container attached to the
   `mcpgw` network (`192.168.49.3`) alongside a freshly booting kicbase (`192.168.49.2`):

   ```bash
   for i in $(seq 1 90); do timeout 1 bash -c "echo > /dev/tcp/192.168.49.2/22" 2>/dev/null \
     && { echo "SSH UP at try $i"; break; }; sleep 2; done
   # -> SSH UP at try 1
   ```

   So the bridge path worked. Yet minikube still timed out — meaning minikube was **not dialing
   that address**.

5. **Root cause located via verbose log.** `-v=5` showed libmachine dialing
   `127.0.0.1:54525` (the host-published SSH port), refused forever from inside the DOOD
   container.

6. **Host path confirmed reachable the "right" way.** The forwarded port *is* reachable from the
   dev container via `host.docker.internal`:

   ```bash
   PORT=$(docker port mcpgw 22 | head -1 | sed 's/.*://')
   timeout 2 bash -c "echo > /dev/tcp/host.docker.internal/$PORT" && echo "HDI OK"
   # -> HDI OK
   ```

   This proved the only broken path was minikube's hardcoded `127.0.0.1`.

---

## Root cause

Minikube's docker driver, on Docker Desktop, always reaches the kicbase node through
**host-loopback forwarded ports** (`127.0.0.1:<random>`), because it assumes the SSH client is
the Mac host — where Docker Desktop publishes those ports. Under `docker-outside-of-docker`, the
dev container shares the host's Docker *daemon* but has its **own loopback**; `127.0.0.1` inside
the container is not the Mac host, so every SSH dial is refused. No amount of shared-network
plumbing fixes this, because minikube never dials the node's container IP — only the loopback
port.

---

## Resolution

Switched the dev container from `docker-outside-of-docker` to **`docker-in-docker`**:

```jsonc
// .devcontainer/devcontainer.json
"ghcr.io/devcontainers/features/docker-in-docker:2": {
  "dockerDashComposeVersion": "v2",
  "moby": true
}
```

With DinD the Docker daemon runs **inside** the dev container, so kicbase's forwarded ports are
published on the dev container's *own* `127.0.0.1` — exactly where minikube dials. Minikube then
works natively with a plain `minikube start` (no `--network`, no network pre-create, no
post-start attach).

Follow-on simplifications (all in `Makefile`):

- `minikube-start` reduced to a plain `minikube start` — removed the network pre-create/attach
  hack.
- `MCP_HOST` is now always `localhost:4444` — under DinD the Compose stack publishes to the dev
  container's localhost, retiring the old `gateway-1:4444` container-routing workaround.
- `make up` no longer connects the dev container to the Compose network.

---

## Verification

```
make up        # -> ✓ ContextForge ready at http://localhost:4444
make test      # -> {"status":"healthy"}
make minikube-start
# 🏄  Done! kubectl is now configured to use "mcpgw" cluster and "default" namespace by default
```

---

## Trade-offs introduced by DinD

- The dev container's Docker daemon starts **empty** after each rebuild: first `make up`
  re-pulls images, first `minikube-start` re-pulls kicbase, and Compose volumes do not carry
  over from the host daemon.
- Containers built/run inside the dev container are **isolated** from the host daemon. This is
  usually desirable for a self-contained k8s lab, but means `docker ps` on the host no longer
  shows them.
- **Host-browser access changes.** The cluster is now nested inside the dev container, so the
  minikube node IP (`192.168.49.2`) and `gateway.local` resolve/route only *inside* the dev
  container (where `curl` works). The Mac host has no route to the in-DinD node network, so
  `http://gateway.local/...` in the host browser fails with `DNS_PROBE_FINISHED_NXDOMAIN`. To
  reach a Service from the host, use `kubectl port-forward` (e.g. `make port-forward`, which maps
  the gateway to `localhost:8080`); VS Code forwards that port to the Mac. The `gateway.local`
  `/etc/hosts` entry added during setup lives inside the dev container and does not help the host.

---

## Lessons learned

- On Docker Desktop, the minikube docker driver is hardwired to host-loopback SSH. If minikube
  must run inside a container, use **DinD**, not DOOD.
- When a "create host" loop times out, get `-v=5` early — the libmachine dial address is the
  single most diagnostic line.
- Always re-test connectivity against a **live** node; a node minikube has torn down gives false
  negatives.
- `host.docker.internal` is the dev container's route to host-published ports, useful both as a
  diagnostic and as a (rejected) workaround.

---

## References

- minikube issue tracker: https://github.com/kubernetes/minikube/issues/7072
- Dev Containers `docker-in-docker` feature: https://github.com/devcontainers/features/tree/main/src/docker-in-docker
- CLAUDE.md → "Minikube on M1 + devcontainer — root cause & fix (2026-06-29)"
- Companion runbook: `docs/runbooks/helm-install-minikube.md` — the Helm-layer issues hit *after*
  the cluster was up (ServiceMonitor CRD, migration hook deadlock, forced HTTPS redirect).
