# LinkedIn Series — Handoff for Claude Cowork

**Written:** 2026-07-28, by a Claude Code CLI session, for a Claude Cowork session picking up
publishing. Cowork has no memory of the conversation that built this — everything needed to
continue safely is below. If anything here conflicts with what you observe live (post statuses,
file contents), trust the live files; this doc is a snapshot.

## What this is

David Fernandez (owner of this repo, `github.com/GourmandTech/ai-engineering`) is publishing an
8-post LinkedIn series documenting the ContextForge-on-AKS project built across this repo's Phases
1-6, for career visibility with SRE/DevOps/platform hiring audiences. The full plan, working
agreement, and per-post briefs are in `linkedin-series/00-master-plan.md` — read that first for
the series' goals and tone if anything below is ambiguous.

Each post is one markdown file in `linkedin-series/`, containing: the caption text (ready to
paste as-is), a `## Visuals` section listing each image file with placement order and alt text,
`## Hashtag suggestions`, and a `## Fact-check notes` section tying every claim back to its source
in this repo. Images are in `linkedin-series/assets/`.

## Before you post anything — read this section

**The original working agreement (`00-master-plan.md`) was: 8 posts, built and approved one at a
time, no post starts until the prior one is signed off, manual posting only, no schedule.**
That agreement was later relaxed mid-build — David asked for Posts 5-8 to be built ahead of
review, with "all reviews done at the end" — but **the end-of-batch review itself has not
happened yet as of this handoff.** Do not treat "the files exist and look complete" as equivalent
to "David has approved them." Check each post's own `**Status:**` line at the top of its file —
that's the actual source of truth, not this doc.

**Post 7 (`07-post-7-cicd-agent-safety-guardrails.md`) needs deliberate, extra-careful human
review before it goes anywhere near LinkedIn.** It names Claude Code directly in connection with
a real incident where an AI coding agent fabricated a commit message to justify bypassing a
security control. The framing throughout is "defense-in-depth caught it," not "an AI went rogue,"
but whether that reads correctly to a hiring-manager audience — and whether having it attached to
"GourmandTech LLC" as the named, public repo owner is exactly how David wants it presented — is
his call alone. **Do not publish or schedule Post 7 without an explicit, current, in-session
"yes, post this" from David specifically on Post 7** — a general "go ahead and post the series"
instruction is not sufficient for this one post, given how explicitly it was flagged. If David
hasn't addressed it directly, stop and ask before touching Post 7, even if you post 1-6 and 8.

**If you're driving a browser to actually publish:** posting to a real, public LinkedIn account is
a visible, hard-to-reverse action (technically deletable after the fact, but by then it's already
been seen). Confirm with David before each individual publish/schedule action, not just once at
the start of the session — "post them all" said once at the top of a long session is easy to
misapply to a post he hasn't actually looked at yet.

## Status per post (as of this handoff — re-check each file's own `**Status:**` line, it's authoritative)

| # | File | Status at handoff | Notes |
|---|---|---|---|
| 1 | `01-post-1-why-this-project.md` | ✅ Approved | Career-narrative hook, corrected per David's feedback (headcount figure softened) |
| 2 | `02-post-2-production-iac-foundation.md` | ✅ Approved | Includes a real `what-if` terminal screenshot captured live 2026-07-28 |
| 3 | `03-post-3-federated-mcp-gateway.md` | ✅ Approved | Includes a real `GET /tools` screenshot captured live 2026-07-28 |
| 4 | `04-post-4-security-rbac-safeguards.md` | Draft — batch review pending | Not yet reviewed by David |
| 5 | `05-post-5-first-ai-agent-in-production.md` | Draft — batch review pending | Includes a real agent-run screenshot captured live 2026-07-28. Not yet reviewed. |
| 6 | `06-post-6-multi-agent-orchestration.md` | Draft — batch review pending | Not yet reviewed by David |
| 7 | `07-post-7-cicd-agent-safety-guardrails.md` | Draft — **needs explicit extra-careful sign-off** | See warning above. Not yet reviewed. |
| 8 | `08-post-8-finops-chaos-whats-next.md` | Draft — batch review pending | Capstone post. Not yet reviewed. |

Posts 1-3 show "✅ Approved" because David explicitly signed off on each individually earlier in
the build (before switching to batch-review mode for 4-8). That's real approval, not stale —
still worth a quick re-read since some series-wide details (visual style, hashtag conventions)
solidified further while building later posts, and it's cheap to double check nothing in an
earlier post reads oddly next to the finished set.

## What to actually do

1. **Do the review pass first, with David, before posting anything.** Walk through all 8 post
   files in order. For each: read the caption, look at the referenced images in
   `linkedin-series/assets/`, and get explicit approval. Post 7 needs its own explicit call per
   the warning above — don't bundle it into a general "looks good, post them" for the batch.
2. **Confirm a posting cadence before scheduling anything.** No cadence was ever agreed — the
   original plan said manual/no-schedule, and a later conversation about automating this was cut
   off before landing on an approach (browser automation via Claude in Chrome was being explored
   but wasn't connected/working in that session). Ask David directly: manual one-by-one, or a
   suggested cadence (e.g. one post every 3-4 days) via LinkedIn's own native post-scheduling
   feature in the composer (no third-party tool or API needed for that — just the normal LinkedIn
   UI).
3. **When posting a given post:** paste the caption text verbatim from the `## Caption` section
   (the length-check line right after it confirms it's already sized for LinkedIn — no need to
   trim further). Attach the images in the exact order listed under `## Visuals` for that post
   (each entry says which numbered image goes where, with its alt text — set the alt text too,
   don't skip it). Include the hashtags from `## Hashtag suggestions`.
4. **After a post actually goes out**, update that file's `**Status:**` line to something like
   `✅ Published 2026-MM-DD` so the next session (human or Cowork) has an accurate record — don't
   leave it saying "Approved" once it's live, and don't let two sessions both think a post is
   still pending and double-post it.
5. **If anything about a post's content seems off** (a claim that doesn't match the repo anymore,
   a stale date, something that reads differently now than when it was drafted) — flag it to
   David rather than silently editing and posting. Each post's `## Fact-check notes` section
   documents exactly where every claim came from in the repo, so it's easy to re-verify against
   current `CLAUDE.md`/`docs/runbooks/` content if something looks like it might have drifted.

## Reference: what's already been corrected once (don't reintroduce these)

- Post 1 originally would have claimed "10+ years of Azure/Bicep SRE work" (from the master
  plan's initial brief) — corrected against David's actual resumes to the real "QA → SRE →
  sole DevOps owner" trajectory, and a specific headcount figure ("60-person") was later softened
  at David's request since he wasn't confident it was accurate. Don't reintroduce either.
- Posts 2 and 4 originally would have used several Phase 5.3 (CI/CD) incidents — misattributed
  by the master plan's brief to earlier phases. Left for Post 7, where they actually belong, to
  avoid duplicating the same incident across multiple posts.
- Post 8's "what's next" was corrected from the master plan's stale framing (which pointed at
  work — multi-hop delegation, fault-injection drills — that's actually already complete per
  `CLAUDE.md`) to something genuinely still open (acting on `finops-agent`'s own cost
  recommendation).

Each of these is documented in more detail in the relevant post's own `## Fact-check notes`
section — this is just a pointer so a fresh session doesn't accidentally walk them back.
