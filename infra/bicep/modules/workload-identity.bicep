// Dedicated User-Assigned Managed Identity + federated credential for a single
// in-cluster workload's ServiceAccount, granted read-only access to Key Vault.
//
// Root cause this module fixes (found 2026-07-02, first GitHub MCP deploy attempt):
// infra/k8s/github-mcp-secrets-provider.yaml originally pointed its CSI
// SecretProviderClass `clientID` at the AKS Key Vault CSI add-on's own
// system-managed identity (`aks.outputs.csiDriverIdentityObjectId` /
// addonProfiles.azureKeyvaultSecretsProvider.identity). That identity has never
// had a federated identity credential — AKS provisions it for the CSI driver's
// own internal use, not for arbitrary application ServiceAccounts to federate
// against. Result: AADSTS70025 "has no configured federated identity
// credentials" on every mount attempt (see FailedMount events on pod
// github-mcp-server-*, 2026-07-02T21:29-21:33Z).
//
// It also would have been the wrong fix even if it had worked: that identity
// already holds Key Vault Secrets User at the vault scope for the CSI driver's
// own purposes, so federating an application pod against it grants that pod
// ambient read access to every secret in the vault (jwt-secret-key,
// platform-admin-password, etc.), not just the one secret it needs.
//
// This module is the correct pattern instead: one dedicated identity per
// workload, with a federated credential scoped to exactly that workload's
// (namespace, ServiceAccount) pair, granted only Key Vault Secrets User.
// Reuse this module for the Step 3-5 MCP servers that need their own
// credentials (Azure DevOps PAT, etc.) — same shape, different name/subject.

@description('Name of the user-assigned managed identity, e.g. id-github-mcp-server')
param name string

@description('Azure region')
param location string

@description('Resource tags')
param tags object

@description('AKS OIDC issuer URL — from aks.bicep output oidcIssuerUrl')
param oidcIssuerUrl string

@description('Kubernetes namespace of the workload ServiceAccount, e.g. mcp')
param serviceAccountNamespace string

@description('Name of the Kubernetes ServiceAccount this identity federates with, e.g. github-mcp-server')
param serviceAccountName string

@description('Resource ID of the Key Vault to grant read access to')
param keyVaultId string

@description('Whether to grant this identity Key Vault Secrets User at the vault scope. Default true preserves every existing consumer of this module unchanged (they all hold a stored secret synced via CSI). Set false for a workload that holds no stored secret at all and authenticates purely via workload-identity federation to an Azure API rather than a Key Vault-held credential — added 2026-07-21 for id-cost-mcp-server specifically, so the project\'s widest-scoped identity (subscription-level Cost Management Reader, granted separately in main.bicep) doesn\'t also carry an unused, unrelated grant to read every secret in the vault.')
param grantKeyVaultAccess bool = true

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: name
  location: location
  tags: tags
}

// Trust exchange: a token issued by the AKS OIDC issuer for exactly this
// ServiceAccount can be exchanged for an Azure AD token as this identity.
// Subject format is fixed by Kubernetes: system:serviceaccount:<ns>:<name>
resource federatedCredential 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = {
  parent: identity
  name: 'fic-${serviceAccountNamespace}-${serviceAccountName}'
  properties: {
    issuer: oidcIssuerUrl
    subject: 'system:serviceaccount:${serviceAccountNamespace}:${serviceAccountName}'
    audiences: [
      'api://AzureADTokenExchange'
    ]
  }
}

// Scoped to the vault itself, not the resource group — deliberately tighter
// than aks.bicep's kvCsiRoleAssignment (that one is scope: resourceGroup(),
// which grants the CSI add-on identity read access to every vault in the RG;
// fine when there's only one vault, but not a pattern worth repeating for a
// per-workload identity). Requires an `existing` reference since keyVaultId
// arrives as a resource ID string, not a resource symbol.
// Conditional on grantKeyVaultAccess (default true — every consumer before
// id-cost-mcp-server holds a stored secret and needs this). Phase 6.2 is the
// first workload identity in the project holding NO stored secret at all (it
// authenticates purely via workload-identity federation straight to an Azure
// API, Cost Management, not via a Key Vault-held credential) — for that one,
// this grant would be real but entirely unused (ambient read access to every
// secret in the vault for an identity that never mounts a
// SecretProviderClass). Set false for that call site specifically rather than
// leave an unused grant on the project's widest-scoped identity.
resource kv 'Microsoft.KeyVault/vaults@2023-07-01' existing = if (grantKeyVaultAccess) {
  name: last(split(keyVaultId, '/'))
}

// 'Key Vault Secrets User' = read secret values only (least privilege).
// Still vault-wide, not secret-scoped — Azure RBAC for Key Vault does support
// per-secret role assignment scope, which would be a further hardening step
// (assign at scope '${keyVaultId}/secrets/<secretName>' instead of the vault),
// but verify current API support for that scope format before relying on it.
var kvSecretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6'

resource kvRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (grantKeyVaultAccess) {
  name: guid(keyVaultId, identity.id, kvSecretsUserRoleId)
  scope: kv
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', kvSecretsUserRoleId)
    principalId: identity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

output identityId string = identity.id
output clientId string = identity.properties.clientId
output principalId string = identity.properties.principalId
