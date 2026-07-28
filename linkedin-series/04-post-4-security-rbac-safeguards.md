# Post 4 — Security & RBAC Safeguards

**Status:** ✅ Scheduled — posting Fri, Jul 31, 2026 at 12:00 PM Mountain Daylight Time via LinkedIn's native scheduler
**Series:** ContextForge AI Engineering LinkedIn Series (Post 4 of 8)

## Caption

The most convincing security story isn't "I got it working." It's "here's the time the system correctly said no to me."

RBAC on this project has two layers. First, virtual servers as the access boundary: the same 86 federated tools get sliced into different views depending on who's asking — an `sre-full` server exposing all 86 to the SRE team, a narrower `dev-tools` server exposing only 62 (GitHub + Azure DevOps) to the dev team. Second, Microsoft Entra ID SSO on top, so humans authenticate with real identity, not a shared password.

Building the SSO piece surfaced two real moments worth sharing.

First: my own login failed. Not a bug — the gateway deliberately refuses to auto-link an incoming SSO identity to an existing local admin account with the same email, even though I owned both. That's the correct behavior; account-linking is exactly the kind of implicit trust that gets abused. I proved control a different way instead of asking the system to make an exception for me.

Second, while smoke-testing the finished setup: I, the actual platform admin, got a 404 trying to reach a team-scoped server through the normal admin path. My first instinct was "that's broken" — my second was to prove *how* broken. I created a disposable non-admin account, added it to the team properly, and confirmed it could reach the same server just fine over a live connection. The bug was isolated to one admin-bypass shortcut, not the RBAC mechanism itself — a materially different, far less alarming finding, and I only knew that because I tested it instead of assuming.

That distinction — verify the blast radius, don't guess it — is the whole point of this post.

Post 5: the first AI agent I let touch any of this, running under a scoped, non-admin token of its own.

Repo: github.com/GourmandTech/ai-engineering

#RBAC #Security #Azure #Entra #SRE #ZeroTrust

---

**Length check:** 1,854 characters, 312 words — within the standard LinkedIn range (~1,300–1,900 chars), toward the upper end given the two-incident structure.

## Visuals

### 1. RBAC boundary diagram — original SVG
**File:** `linkedin-series/assets/post4-rbac-boundary.svg` (source) / `linkedin-series/assets/post4-rbac-boundary.png` (2400×1500, exported for LinkedIn)
**Placement:** First image in the post (primary thumbnail).
**Alt text:** "Diagram showing sre-team and dev-team each connecting to their own virtual server — sre-full with 86 tools across all 5 gateways, dev-tools with 62 tools limited to GitHub and Azure DevOps — mapped onto the shared pool of 86 total federated tools, showing which 24 tools are reachable only through sre-full."
**Source of truth:** Phase 4 Step 5 in `CLAUDE.md` — team IDs, server IDs, tool counts (86 / 62), and the `associated_tools`-not-`associated_a2a_agents` attachment mechanism.

### 2. SSO login-flow diagram — original SVG
**File:** `linkedin-series/assets/post4-sso-flow.svg` (source) / `linkedin-series/assets/post4-sso-flow.png` (2400×1640, exported for LinkedIn)
**Placement:** Second image in the post.
**Alt text:** "Flowchart of the Entra ID SSO login sequence: user signs in via Microsoft, the gateway validates the token and checks whether the email already exists as a local account. If yes, auto-linking is refused as correct security behavior. If no, an SSO identity is created and a session is issued."
**Source of truth:** Phase 4 Step 8d in `CLAUDE.md` — the exact `user_creation_failed` / account-linking-refusal incident, including the confirmation via gateway logs that this is deliberate ContextForge behavior, not a bug.

## Hashtag suggestions

`#RBAC` `#Security` `#Azure` `#Entra` `#SRE` `#ZeroTrust`

## Fact-check notes (sourced from `CLAUDE.md`, Phase 4)

- Virtual servers: `sre-full` (86 tools, all 5 gateways, team-scoped to `sre-team`) and `dev-tools` (62 tools, GitHub + Azure DevOps only, team-scoped to `dev-team`) — Phase 4 Step 5.
- SSO account-linking refusal: "ContextForge deliberately refuses to auto-link an incoming SSO identity to an existing local account with the same email — confirmed via gateway logs (`SSO authenticate_or_create_user: account-linking required...`)." Resolution used a disposable second Entra test user, not a workaround to the local account itself — Phase 4 Step 8d.
- Admin-bypass 404 bug: "`GET /servers/{id}/sse` (and the identical `GET /servers/{id}` single-object lookup) 404s for a genuine platform admin on a team-visibility virtual server... Confirmed this is isolated to the admin-bypass path, not a broader RBAC failure, by creating a disposable non-admin Entra test user... and successfully establishing a live SSE handshake with that account's own session." — Phase 4 Step 9. Noted in the source as vendored upstream code, left unpatched per this project's own convention of not modifying `.contextforge/`.

**Deliberately not used:** the master plan's brief for this post also referenced two custom Azure IAM roles ("AKS RBAC Reader + exactly one `secrets/read` action," "deployment-orchestrator role with zero resource-management actions") and the Key Vault control-plane/data-plane gap that shipped `JWT_SECRET_KEY` empty. Checked against `CLAUDE.md`: all three are **Phase 5.3** incidents from building the CI/CD pipeline, not Phase 4 RBAC work — and Post 7's own brief already explicitly claims this exact material ("8 real Azure IAM gaps found only by running the real pipeline against production"). Using it here too would duplicate content across two posts in the same series and misattribute when it actually happened (same category of correction as Post 2's). Post 4 instead leans on two genuine Phase 4 findings — the SSO account-linking refusal and the admin-bypass 404 — which make the same "verified, not assumed" point without borrowing from Post 7.
