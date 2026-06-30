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

@description('System node pool initial count')
@minValue(1)
@maxValue(5)
param nodeCount int = 1

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
