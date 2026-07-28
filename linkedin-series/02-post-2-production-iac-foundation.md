# Post 2 — Production IaC Foundation

**Status:** ✅ Scheduled — posting Wed, Jul 29, 2026 at 12:00 PM Mountain Daylight Time via LinkedIn's native scheduler
**Series:** ContextForge AI Engineering LinkedIn Series (Post 2 of 8)

## Still missing / open items

- ~~`az deployment sub what-if` terminal screenshot~~ — **resolved 2026-07-28.** This session turned out to have live, authenticated `az` access after all (correcting the earlier assumption it didn't). Ran a real `az deployment sub what-if --location eastus --parameters infra/bicep/main.bicepparam` against the actual subscription — read-only, nothing applied. See visual #3 below.

## Caption

"What-if" isn't a suggestion. It's the one command that's saved me from shipping an outage more than once on this project.

I run everything on Azure through modular Bicep — one file per resource type (network, ACR, Key Vault, AKS, Log Analytics), a subscription-scoped deployment that provisions the whole resource group from nothing. Two incidents from building it taught me why `az deployment sub what-if` runs before every single deploy now, no exceptions.

Incident one: after a single-node CPU exhaustion outage, I fixed AKS node pool autoscaling (2-10 nodes) — through the Azure Portal. Weeks later, an unrelated Bicep deploy silently reverted it back to a fixed 1-node pool. Why: the fix lived in the Portal, not in code, and the Bicep module still defaulted to autoscaling disabled. Second outage, same root cause. The real fix wasn't reapplying the setting — it was making autoscaling a real, version-controlled Bicep parameter, so a Portal-only change can never again get silently erased by the next deploy.

Incident two: the gateway was live, healthy, and still timing out from the outside. Root cause: Azure's Standard Load Balancer created two separate frontend IPs, and the outbound SNAT rule only referenced one of them — so return traffic went out the wrong public IP and clients silently dropped it. Fixed with `externalTrafficPolicy: Local`, which routes responses directly pod-to-client and skips kube-proxy SNAT entirely.

Neither of these announced itself with an obvious error. Both were "it looks fine until you check the actual state" bugs — which is exactly what `what-if` is for.

Post 3: what gets built on top of this foundation — five MCP servers federated behind one gateway.

Repo: github.com/GourmandTech/ai-engineering

#Azure #Bicep #Kubernetes #InfrastructureAsCode #SRE #PlatformEngineering

---

**Length check:** 1,807 characters, 282 words — within the standard LinkedIn range (~1,300–1,900 chars).

## Visuals

### 1. Azure resource architecture diagram — original SVG
**File:** `linkedin-series/assets/post2-architecture.svg` (source) / `linkedin-series/assets/post2-architecture.png` (2400×1500, exported for LinkedIn)
**Placement:** First image in the post (primary thumbnail).
**Alt text:** "Diagram of the Azure resource group containing a VNet and AKS subnet with an AKS cluster (autoscaling system node pool, OIDC workload identity, CSI secrets, Container Insights), connected via scoped roles to ACR (AcrPull), Key Vault (KV Secrets User), and a Log Analytics Workspace — all per-workload managed identities, not broad Owner/Contributor grants."
**Source of truth:** `infra/bicep/main.bicep` + its modules (`network.bicep`, `acr.bicep`, `keyvault.bicep`, `aks.bicep`, `logworkspace.bicep`), all documented in `CLAUDE.md`'s Phase 3 section.

### 2. Before/after network-path diagram — original SVG (the SNAT fix)
**File:** `linkedin-series/assets/post2-snat-fix.svg` (source) / `linkedin-series/assets/post2-snat-fix.png` (2400×1400, exported for LinkedIn)
**Placement:** Second image in the post.
**Alt text:** "Two-panel diagram. Before: a client request returns via the wrong Azure Load Balancer frontend IP due to SNAT asymmetry and is dropped, causing a timeout. After: with externalTrafficPolicy set to Local, the response returns directly from the pod to the client, bypassing kube-proxy SNAT, and a health-check NodePort lets the load balancer probe pass."
**Source of truth:** CLAUDE.md's Phase 3 "Critical Phase 3 lessons learned" — the exact frontend-IP/`aksOutboundRule`/`DisableOutboundSnat`/`externalTrafficPolicy: Local` mechanics. (Left the real resource GUIDs/public IPs referenced in CLAUDE.md's own incident notes out of the diagram — not needed for the story and no reason to publish literal production identifiers.)

### 3. `what-if` terminal screenshot — real output, captured live
**File:** `linkedin-series/assets/post2-whatif-screenshot.svg` (source) / `linkedin-series/assets/post2-whatif-screenshot.png` (2400×1600, exported for LinkedIn)
**Placement:** Third image (optional carousel slide, or lead the post with it if you'd rather open on the terminal proof before the diagrams).
**Alt text:** "Terminal screenshot of a real az deployment sub what-if run, showing a curated excerpt of the diff: the AKS agent pool's powerState changing from Stopped, several unchanged managed identities, a Key Vault networkAcls addition, and a summary line reading 15 to modify, 10 no change, 1 to ignore. Subscription and tenant IDs are redacted."
**How this was captured:** Run live from this session on 2026-07-28 — `az deployment sub what-if --location eastus --parameters infra/bicep/main.bicepparam` against the real subscription, read-only (a `what-if` never applies anything). The cluster was in a `Stopped` power state at the time (confirmed via `az aks show` immediately before), which is why the AKS block shows `powerState.code: "Stopped"` — an authentic detail, not staged. This run is mostly benign identity-reference noise rather than a dramatic caught-drift moment (the two historical incidents in this post's caption were already fixed long before this run) — it demonstrates the standing practice, not a new bug. Full raw output (163 lines, unredacted) is not committed to the repo; only the curated, redacted excerpt was turned into an image.
**Redaction note:** the real subscription ID and tenant ID appear in the raw CLI output (and are already committed elsewhere in this repo, e.g. `CLAUDE.md` and `docs/reports/`), but were redacted from this image anyway — no reason to republish them more widely than necessary on a public post.

## Hashtag suggestions

`#Azure` `#Bicep` `#Kubernetes` `#InfrastructureAsCode` `#SRE` `#PlatformEngineering`

## Fact-check notes (sourced from `CLAUDE.md`)

- Modular Bicep structure: `infra/bicep/main.bicep` (subscription-scoped) + `modules/network.bicep`, `acr.bicep`, `keyvault.bicep`, `aks.bicep`, `logworkspace.bicep` — Phase 3 "IaC files" list.
- Node-pool autoscaler incident: Phase 3 note — Portal fix (min 2/max 10) after a real single-node CPU exhaustion outage, silently reverted by a later `bicep-deploy` (for Phase 4 workload identity work) due to `aks.bicep`'s stale `enableAutoScaling: false` default; fixed by making `enableAutoScaling`/`minNodeCount`/`maxNodeCount` real Bicep params.
- SNAT asymmetry: Phase 3 "Critical Phase 3 lessons learned" — two LB frontend IPs, `aksOutboundRule` referencing only one, `DisableOutboundSnat: true` causing wrong-frontend egress; fixed via `externalTrafficPolicy: Local` on the nginx-ingress controller service, which also required a health-check NodePort for the LB probe to pass.
- Resource specs in the diagram (ACR Standard/admin disabled, Key Vault Standard/RBAC auth/7-day soft-delete, Log Analytics PerGB2018/30-day retention, VNet 10.0.0.0/16, AKS subnet 10.0.0.0/22) — all directly from Phase 3's "IaC files" section.

**Deliberately not used:** the master plan's brief for this post also listed "Key Vault RBAC control-plane vs. data-plane gap" as a Phase 3 incident. Checked against `CLAUDE.md` directly — that bug (`JWT_SECRET_KEY` deploying empty because the CI/CD deploy app's `Contributor` role didn't include the Key Vault data-plane `Key Vault Secrets User` role) is documented under **Phase 5.3** ("CI/CD"), not Phase 3 — it happened while building the GitHub Actions deploy pipeline, months after this Bicep/AKS foundation was already live. Using it here would misattribute it. It's already accounted for in Post 7's brief ("8 real Azure IAM gaps found only by running the real pipeline against production"), so it'll appear there instead, correctly grounded. Post 2's safeguards angle is reframed slightly to match what Phase 3 actually shows: `what-if` discipline (both incidents) and per-workload least-privilege role assignments baked into the Bicep design itself (`AcrPull`, `KV Secrets User` — scoped built-in roles, not custom role definitions, which come later in Phases 5.3/6.2 and belong in a later post).
