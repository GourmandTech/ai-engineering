---
description: Generate and append resume-ready bullet points based on completed work in this project
---

Review the current project state and recent git log to identify completed milestones. Generate professional resume bullets and append them to `docs/resume-bullets.md`.

**Step 1: Assess completed work**
- Read `CLAUDE.md` (Learning Phases table)
- Run `git log --oneline -20` to see recent commits
- Read existing `docs/resume-bullets.md` to avoid duplicates

**Step 2: Generate bullets**

For each completed phase or significant feature, generate a bullet using this format:
```
- **[Technology/Tool]** — [Strong action verb] [what was built/deployed/automated] using 
  [specific tools and versions], [resulting in / enabling / demonstrating] [concrete outcome].
  Stack: [comma-separated tech list]
```

**Target keywords to include** (relevant to SRE/DevOps + AI Engineering job market):
- IBM ContextForge MCP Gateway
- Federated MCP (Model Context Protocol)
- Azure Kubernetes Service (AKS)
- Bicep IaC / Infrastructure as Code
- Helm / GitOps
- Agent-to-Agent (A2A) protocol
- AI agent orchestration
- Agentic infrastructure
- OpenTelemetry / observability
- RBAC / OAuth 2.0 / Zero-trust

**Example output:**
```
- **IBM ContextForge / AKS** — Deployed federated MCP AI Gateway on Azure Kubernetes Service 
  using Bicep IaC and Helm, enabling centralized tool discovery, RBAC-governed access control, 
  and OpenTelemetry observability across multiple AI agent backends. 
  Stack: AKS, Helm, Bicep, PostgreSQL, Redis, MCP, A2A.
```

**Step 3: Append to docs/resume-bullets.md**

Append the generated bullets with today's date. Then print the full updated file.
