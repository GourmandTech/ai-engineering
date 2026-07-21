// ContextForge MCP Gateway — Azure Infrastructure
// Phase 3: AKS deployment with Bicep IaC
//
// Deploy:
//   az deployment sub create \
//     --location eastus \
//     --template-file infra/bicep/main.bicep \
//     --parameters infra/bicep/main.parameters.json

targetScope = 'subscription'

// ── Parameters ───────────────────────────────────────────────────────────────

@description('Azure region for all resources')
param location string = 'eastus'

@description('Environment tag (dev | staging | prod)')
@allowed(['dev', 'staging', 'prod'])
param environment string = 'dev'

@description('Project name — used in all resource names')
param project string = 'contextforge'

@description('Owner alias — tagged on every resource')
param ownerAlias string = 'dfernandez'

@description('Object ID of your Azure AD user or service principal — grants Key Vault Secrets Officer so you can populate secrets after deploy. Leave empty to skip.')
param adminObjectId string = ''

@description('Kubernetes version to pin. Run: az aks get-versions -l eastus -o table')
param kubernetesVersion string = '1.35'

@description('System node pool VM size')
param nodeVmSize string = 'Standard_D2s_v7'

@description('System node pool initial/minimum count')
@minValue(1)
@maxValue(5)
param nodeCount int = 1

@description('Enable cluster autoscaler on the system node pool — see modules/aks.bicep for why this must stay true (live config was set via Portal, not IaC, after a 2026-07-02 CPU exhaustion incident; redeploying with this false reverts it)')
param enableAutoScaling bool = true

@description('Autoscaler floor, only used when enableAutoScaling is true')
param minNodeCount int = 2

@description('Autoscaler ceiling, only used when enableAutoScaling is true')
param maxNodeCount int = 10

@description('Maximum pods per node. Increase from Azure CNI default of 30 when running observability add-ons.')
@minValue(10)
@maxValue(250)
param maxPodsPerNode int = 50

// ── Derived names (no hardcoding — all derived from params) ──────────────────

var resourceGroupName  = 'rg-${project}-${environment}'
var vnetName           = 'vnet-${project}-${environment}'
var aksClusterName     = 'aks-${project}-${environment}'
// ACR name: alphanumeric only, no hyphens, globally unique
var acrName            = 'acr${replace(project, '-', '')}${environment}'
var keyVaultName       = 'kv-${project}-${environment}'
var logWorkspaceName   = 'log-${project}-${environment}'

var commonTags = {
  environment: environment
  project: project
  owner: ownerAlias
  managedBy: 'bicep'
}

// ── Resource Group ───────────────────────────────────────────────────────────

resource rg 'Microsoft.Resources/resourceGroups@2022-09-01' = {
  name: resourceGroupName
  location: location
  tags: commonTags
}

// ── Log Analytics Workspace ───────────────────────────────────────────────────

module logWorkspace 'modules/logworkspace.bicep' = {
  name: 'deploy-logworkspace'
  scope: rg
  params: {
    name: logWorkspaceName
    location: location
    tags: commonTags
    retentionInDays: 30
  }
}

// ── Networking ───────────────────────────────────────────────────────────────

module network 'modules/network.bicep' = {
  name: 'deploy-network'
  scope: rg
  params: {
    vnetName: vnetName
    location: location
    tags: commonTags
  }
}

// ── Container Registry ───────────────────────────────────────────────────────

module acr 'modules/acr.bicep' = {
  name: 'deploy-acr'
  scope: rg
  params: {
    acrName: acrName
    location: location
    tags: commonTags
    sku: 'Standard'
  }
}

// ── Key Vault ────────────────────────────────────────────────────────────────

module keyVault 'modules/keyvault.bicep' = {
  name: 'deploy-keyvault'
  scope: rg
  params: {
    keyVaultName: keyVaultName
    location: location
    tags: commonTags
    adminObjectId: adminObjectId
  }
}

// ── AKS Cluster ──────────────────────────────────────────────────────────────

module aks 'modules/aks.bicep' = {
  name: 'deploy-aks'
  scope: rg
  params: {
    clusterName: aksClusterName
    location: location
    tags: commonTags
    aksSubnetId: network.outputs.aksSubnetId
    logAnalyticsWorkspaceId: logWorkspace.outputs.workspaceId
    acrId: acr.outputs.acrId
    keyVaultId: keyVault.outputs.keyVaultId
    adminObjectId: adminObjectId
    kubernetesVersion: kubernetesVersion
    nodeVmSize: nodeVmSize
    nodeCount: nodeCount
    maxPodsPerNode: maxPodsPerNode
    enableAutoScaling: enableAutoScaling
    minNodeCount: minNodeCount
    maxNodeCount: maxNodeCount
  }
}

// ── Workload identities (Phase 4 — per-MCP-server Key Vault access) ──────────
// One dedicated UAMI + federated credential per workload ServiceAccount that
// needs to read a Key Vault secret via the CSI driver — see
// modules/workload-identity.bicep for why this exists (the AKS Key Vault CSI
// add-on's own identity is not meant to be federated against by application
// pods). Reuse this module for Step 3-5 MCP servers that need their own
// credentials (e.g. Azure DevOps PAT).

module githubMcpIdentity 'modules/workload-identity.bicep' = {
  name: 'deploy-github-mcp-identity'
  scope: rg
  params: {
    name: 'id-github-mcp-server'
    location: location
    tags: commonTags
    oidcIssuerUrl: aks.outputs.oidcIssuerUrl
    serviceAccountNamespace: 'mcp'
    serviceAccountName: 'github-mcp-server'
    keyVaultId: keyVault.outputs.keyVaultId
  }
}

// Phase 4 Step 3 — same pattern as githubMcpIdentity above, dedicated
// identity + federated credential scoped to the azure-devops-mcp-server
// ServiceAccount only. See infra/k8s/azure-devops-mcp-secrets-provider.yaml
// for why this must NOT reuse githubMcpIdentity or the CSI add-on identity.
module azureDevOpsMcpIdentity 'modules/workload-identity.bicep' = {
  name: 'deploy-azure-devops-mcp-identity'
  scope: rg
  params: {
    name: 'id-azure-devops-mcp-server'
    location: location
    tags: commonTags
    oidcIssuerUrl: aks.outputs.oidcIssuerUrl
    serviceAccountNamespace: 'mcp'
    serviceAccountName: 'azure-devops-mcp-server'
    keyVaultId: keyVault.outputs.keyVaultId
  }
}

// Phase 5.2 — same pattern again, dedicated identity + federated credential
// scoped to the sre-agent ServiceAccount only. This workload needs two Key
// Vault secrets the other MCP-server identities don't (anthropic-api-key,
// sre-agent-jwt-token) — see infra/k8s/sre-agent-secrets-provider.yaml.
module sreAgentIdentity 'modules/workload-identity.bicep' = {
  name: 'deploy-sre-agent-identity'
  scope: rg
  params: {
    name: 'id-sre-agent'
    location: location
    tags: commonTags
    oidcIssuerUrl: aks.outputs.oidcIssuerUrl
    serviceAccountNamespace: 'mcp'
    serviceAccountName: 'sre-agent'
    keyVaultId: keyVault.outputs.keyVaultId
  }
}

// Phase 6.1.1 — same pattern again, dedicated identity + federated credential
// scoped to the dev-agent ServiceAccount only. Second A2A specialist (GitHub +
// Azure DevOps via dev-tools), proving the per-workload-identity + narrow
// virtual server + associated_tools pattern generalizes to a second agent
// before the coordinator gets real multi-specialist routing (6.1.2). Needs
// the same two Key Vault secrets as sre-agent (anthropic-api-key, reused —
// same key works for any Claude Agent SDK workload — and dev-agent-jwt-token,
// its own team+server-scoped token) — see infra/k8s/dev-agent-secrets-provider.yaml.
module devAgentIdentity 'modules/workload-identity.bicep' = {
  name: 'deploy-dev-agent-identity'
  scope: rg
  params: {
    name: 'id-dev-agent'
    location: location
    tags: commonTags
    oidcIssuerUrl: aks.outputs.oidcIssuerUrl
    serviceAccountNamespace: 'mcp'
    serviceAccountName: 'dev-agent'
    keyVaultId: keyVault.outputs.keyVaultId
  }
}

// Phase 6.2.2 — WIDEST-SCOPED IDENTITY IN THIS PROJECT. Same per-workload
// pattern as the four identities above (dedicated UAMI + federated credential
// scoped to exactly one ServiceAccount, mcp/cost-mcp-server), but this is the
// first workload identity that holds no stored Key Vault secret at all — see
// grantKeyVaultAccess: false below and workload-identity.bicep's own comment
// on that param, added specifically for this call site. Approved by the
// project owner 2026-07-21 (docs/phase6-plan.md §6.2's own design, confirmed
// live before implementation: az role definition list confirmed
// "Cost Management Reader" (72fafb9e-0641-4937-9268-a91bfd8191a3) is a
// built-in, read-only role — zero write actions, zero dataActions).
//
// Subscription-scoped (not RG-scoped like every other identity here) because
// the underlying spend this identity needs to read is subscription-scoped:
// the AKS node VMs — ~91% of real spend — live in the AKS-managed
// MC_rg-contextforge-dev_aks-contextforge-dev_eastus node resource group, not
// rg-contextforge-dev itself. An RG-scoped grant would reproduce that exact
// spend-visibility gap, which is the whole reason this MCP server exists.
//
// The RBAC boundary containing this identity's *reach* is deliberately NOT a
// narrower role — Cost Management Reader is already Azure's narrowest
// built-in read-only role for this data. Containment instead comes from
// ContextForge's own virtual-server layer: a future finops-full server /
// finops-team (6.2.3+, not yet built) scopes who can actually invoke this
// server's tools, the same "virtual servers as the RBAC boundary" design
// decision this project has used since Phase 4 — this Bicep grant controls
// what the identity CAN read, not who can ask it to.
module costMcpIdentity 'modules/workload-identity.bicep' = {
  name: 'deploy-cost-mcp-identity'
  scope: rg
  params: {
    name: 'id-cost-mcp-server'
    location: location
    tags: commonTags
    oidcIssuerUrl: aks.outputs.oidcIssuerUrl
    serviceAccountNamespace: 'mcp'
    serviceAccountName: 'cost-mcp-server'
    keyVaultId: keyVault.outputs.keyVaultId
    grantKeyVaultAccess: false
  }
}

// Built-in 'Cost Management Reader' role id, confirmed live via
// `az role definition list --name "Cost Management Reader"` 2026-07-21
// against this exact subscription — read-only (Microsoft.CostManagement/*/read,
// Microsoft.Consumption/*/read, etc.), no write actions, no dataActions.
var costManagementReaderRoleId = '72fafb9e-0641-4937-9268-a91bfd8191a3'

// Assigned directly here (not inside workload-identity.bicep, which stays a
// generic, resource-group/vault-scoped module) because this is the one
// subscription-scope grant in the project — deliberately kept out of the
// shared module so every other call site's blast radius stays exactly what
// it was before this identity existed.
resource costMcpRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  // guid() seeded on the identity's fixed *name* (not costMcpIdentity.outputs.*
  // — a module output isn't "calculable at the start of deployment" in
  // Bicep's eyes, confirmed via `az bicep build`: BCP120) plus the role id and
  // subscription — deterministic and unique without depending on the module's
  // runtime output.
  name: guid(subscription().id, 'id-cost-mcp-server', costManagementReaderRoleId)
  scope: subscription()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', costManagementReaderRoleId)
    principalId: costMcpIdentity.outputs.principalId
    principalType: 'ServicePrincipal'
  }
}

// ── Outputs ──────────────────────────────────────────────────────────────────

@description('Resource group that contains all ContextForge resources')
output resourceGroupName string = rg.name

@description('AKS cluster name — pass to: az aks get-credentials -g <rg> -n <cluster>')
output aksClusterName string = aks.outputs.clusterName

@description('ACR login server — used in image pull and Helm values')
output acrLoginServer string = acr.outputs.loginServer

@description('ACR name')
output acrName string = acr.outputs.acrName

@description('Key Vault name — populate secrets here before running helm-aks')
output keyVaultName string = keyVault.outputs.keyVaultName

@description('Key Vault URI')
output keyVaultUri string = keyVault.outputs.keyVaultUri

@description('OIDC issuer URL — needed for workload identity federation')
output oidcIssuerUrl string = aks.outputs.oidcIssuerUrl

@description('CSI driver managed identity object ID — already granted Key Vault Secrets User')
output csiDriverIdentityObjectId string = aks.outputs.csiDriverIdentityObjectId

@description('GitHub MCP workload identity client ID — use in the ServiceAccount azure.workload.identity/client-id annotation and the SecretProviderClass clientID')
output githubMcpIdentityClientId string = githubMcpIdentity.outputs.clientId

@description('Azure DevOps MCP workload identity client ID — use in the ServiceAccount azure.workload.identity/client-id annotation and the SecretProviderClass clientID')
output azureDevOpsMcpIdentityClientId string = azureDevOpsMcpIdentity.outputs.clientId

@description('SRE agent workload identity client ID — use in the ServiceAccount azure.workload.identity/client-id annotation and the SecretProviderClass clientID')
output sreAgentIdentityClientId string = sreAgentIdentity.outputs.clientId

@description('Dev agent workload identity client ID — use in the ServiceAccount azure.workload.identity/client-id annotation and the SecretProviderClass clientID')
output devAgentIdentityClientId string = devAgentIdentity.outputs.clientId

@description('Cost MCP server workload identity client ID — use in the ServiceAccount azure.workload.identity/client-id annotation (no SecretProviderClass — this identity holds no stored Key Vault secret, see grantKeyVaultAccess: false above)')
output costMcpIdentityClientId string = costMcpIdentity.outputs.clientId
