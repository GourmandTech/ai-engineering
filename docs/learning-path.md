# Learning Path — IBM ContextForge MCP Gateway on AKS

## Phase 1: Local Docker Compose
**Goal:** Understand what ContextForge is before touching k8s.

Resources:
- [Quick Start](https://ibm.github.io/mcp-context-forge/latest/overview/quick_start/)
- [Docker Compose Deployment](https://ibm.github.io/mcp-context-forge/latest/deployment/compose/)

Tasks:
- [ ] Clone IBM/mcp-context-forge
- [ ] Run `make up`, explore Admin UI at http://localhost:4444
- [ ] Register a sample MCP server through the UI
- [ ] Call a tool through the federated endpoint
- [ ] Read the architecture overview

---

## Phase 2: Minikube
**Goal:** Get k8s reps, understand Helm chart structure.

Resources:
- [Minikube Deployment](https://ibm.github.io/mcp-context-forge/latest/deployment/minikube/)
- [Helm Chart Guide](https://ibm.github.io/mcp-context-forge/latest/deployment/helm/)

Tasks:
- [ ] `make minikube-start`
- [ ] Explore the Helm chart values (understand each key section)
- [ ] `make helm-install` and verify pods come up healthy
- [ ] Port-forward and run `/mcp-test` against Minikube
- [ ] Use `/k8s-debug` to intentionally break and fix something

---

## Phase 3: Azure AKS
**Goal:** Production-grade deployment with Bicep IaC.

Resources:
- [Azure Deployment](https://ibm.github.io/mcp-context-forge/latest/deployment/azure/)
- [Scaling ContextForge](https://ibm.github.io/mcp-context-forge/latest/manage/scale/)

Tasks:
- [ ] Write `infra/bicep/modules/aks.bicep`
- [ ] Write `infra/bicep/modules/keyvault.bicep` for secrets
- [ ] Write `infra/helm/values.azure.yaml` with AKS-specific overrides
- [ ] `make bicep-deploy` → `make helm-aks`
- [ ] Verify gateway is reachable via AKS LoadBalancer IP
- [ ] Run `/resume-update`

---

## Phase 4: Federated MCP
**Goal:** Register multiple MCP servers, implement RBAC and OAuth.

Resources:
- [MCP Architecture Patterns](https://ibm.github.io/mcp-context-forge/latest/best-practices/mcp-architecture-patterns/)
- [RBAC Configuration](https://ibm.github.io/mcp-context-forge/latest/manage/rbac/)
- [Microsoft Entra ID SSO](https://ibm.github.io/mcp-context-forge/latest/manage/sso-microsoft-entra-id-tutorial/)

Tasks:
- [ ] Register 3+ MCP servers behind the gateway
- [ ] Configure RBAC: different teams get different tool access
- [ ] Set up Microsoft Entra ID (Azure AD) OIDC SSO
- [ ] Test tool calls with scoped JWT tokens
- [ ] Run `/resume-update`

---

## Phase 5: Agent Automation
**Goal:** A2A protocol, multi-agent orchestration.

Resources:
- [A2A Agent Integration](https://ibm.github.io/mcp-context-forge/latest/using/agents/a2a/)
- [LangGraph Integration](https://ibm.github.io/mcp-context-forge/latest/using/agents/langgraph/)
- [AutoGen Integration](https://ibm.github.io/mcp-context-forge/latest/using/agents/autogen/)

Tasks:
- [ ] Build a simple agent that calls tools through ContextForge
- [ ] Implement A2A: one agent delegates sub-tasks to another via the gateway
- [ ] Add GitHub Actions CI/CD: lint → helm diff → deploy on merge
- [ ] Run `/resume-update`
