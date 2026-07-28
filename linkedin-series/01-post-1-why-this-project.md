# Post 1 — Why This Project / Mission

**Status:** ✅ Published 2026-07-28 — posted live to LinkedIn (linkedin.com/in/davidjfernandez) with both images, alt text, and hashtags exactly as below
**Series:** ContextForge AI Engineering LinkedIn Series (Post 1 of 8)

## Caption

In November 2024, I was promoted from QA Engineer to Site Reliability Engineer. By August 2025, I was the sole owner of the entire DevOps function for a SaaS engineering organization — no added headcount, no title change.

The short version sounds tidy. The real version: inheriting 100+ Azure DevOps YAML pipelines and rebuilding about half from scratch, taking deployment frequency from bi-weekly to daily, and becoming the sole owner of platform observability across 1,500+ Grafana alert configurations while holding a 99.9% SLA.

I didn't wait to be handed that scope. I took it, and treated "I don't know Azure IAM yet" as a to-do list, not a blocker.

Now I'm applying the same approach to AI-assisted engineering — deliberately, and in public.

Under my own company, GourmandTech LLC, I've spent the past year designing, building, and operating agentic AI infrastructure from scratch: IBM ContextForge running on Azure Kubernetes Service, federating multiple MCP servers behind one authenticated endpoint, with AI agents that delegate work to each other under least-privilege, team-scoped access.

Six phases, solo-built: local Docker Compose → Minikube → AKS → federated MCP → AI agent automation → multi-agent orchestration with FinOps and chaos engineering.

Starting with this post, I'm walking through how it was built — the real incidents, the RBAC gaps, the production bugs I hit and fixed along the way. Not a tutorial series. A build log.

Post 2: the Bicep/AKS foundation, and two production incidents it took to get the node pool autoscaling right.

Repo: github.com/GourmandTech/ai-engineering

#DevOps #SRE #Azure #Kubernetes #AIEngineering #AgenticAI

---

**Length check:** 1,658 characters, 258 words — within the standard LinkedIn range (~1,300–1,900 chars) for a long-form text post that still reads well on mobile.

## Visuals

### 1. Cover image — AI-generated (Gemini `gemini-2.5-flash-image`)
**File:** `linkedin-series/assets/post1-cover.png` (1344×768, 16:9)
**Placement:** First image in the post (appears as the primary thumbnail in feed).
**Alt text:** "Abstract illustration of a glowing blue network of connected nodes forming an ascending diagonal path across a dark navy background, symbolizing steady growth through interconnected systems."
**Note:** No text, logos, or human figures in the image by design — reads as a professional, abstract tech visual rather than a literal illustration, appropriate as a cover for a technical/career post.

### 2. Phase roadmap diagram — original SVG (built from this repo's real phase structure)
**File:** `linkedin-series/assets/post1-roadmap.svg` (source) / `linkedin-series/assets/post1-roadmap.png` (2400×1260, exported for LinkedIn — LinkedIn does not render SVG natively)
**Placement:** Second image in the post.
**Alt text:** "Diagram of a six-phase build roadmap: Docker Compose (local dev), Minikube (Kubernetes primitives), AKS (production IaC), Federated MCP (86 tools, one gateway), AI Agent Automation (A2A delegation, OIDC CI/CD), and Multi-Agent orchestration with FinOps and chaos engineering — all six marked complete."
**Source of truth:** Phase names and status pulled directly from `CLAUDE.md`'s "Learning Phases" table — all six phases are ✅ complete (Phase 5's 5.4 stretch item is not shown at this summary level, consistent with how the phase-status table itself reports it).

## Hashtag suggestions

`#DevOps` `#SRE` `#Azure` `#Kubernetes` `#AIEngineering` `#AgenticAI`

Kept to 5, all high-signal for the target audience (senior SRE/DevOps/platform engineers and technical recruiters), no filler tags.

## Fact-check notes (sourced from `private/David_Fernandez_Resume_SRE.docx` and `private/David_Fernandez_Resume_LeadDevOps.docx`, both consistent)

- QA Engineer, Suzy Inc.: May 2023 – Nov 2024
- Promoted to Site Reliability Engineer: Nov 2024 (resume: "platform depth earned promotion... in November 2024")
- Sole DevOps ownership: "designated backup from March 2025, full responsibility from August 2025, held concurrently with SRE duties without title change or added headcount"
- 100+ Azure DevOps YAML CI/CD pipelines owned/operated, ~50 authored from scratch
- Deployment frequency: bi-weekly → daily
- 99.9% platform SLA; sole owner of Grafana observability, 1,500+ database alert configurations
- GourmandTech LLC: Founder & Technical Director, March 2024–present
- Repo: `github.com/GourmandTech/ai-engineering` (matches resume bullet exactly)

**Deliberately not used:** the master plan's original brief for this post said "10+ years of Azure/Bicep SRE work" — this does not match the resumes (actual hands-on cloud/DevOps tenure is ~3 years; the 10+ years of prior experience is in Forbes Five-Star culinary leadership, 2010–2022). Corrected per your "rapid internal growth" framing decision — the culinary background is intentionally omitted from this post's lead (may resurface as supporting texture in a later post if you want it).

**Softened per your review:** the resume states "60-person SaaS engineering organization" twice, but you flagged you're not fully confident that headcount figure is accurate. Dropped the specific number from the caption — now reads "a SaaS engineering organization" — since an unverifiable specific claim is a bigger risk on a public post than a slightly less punchy but fully defensible one. Left the resume files themselves untouched (out of scope here; flag if you want that number revisited there too).

## Open item carried forward

Cover image required switching to an active-billing Gemini API key (the original key hit a `RESOURCE_EXHAUSTED` — image generation quota is 0 on the free tier for `gemini-2.5-flash-preview-image`). Now resolved and working — future posts needing AI-generated images can reuse the same `.env` key and the script pattern in this session.
