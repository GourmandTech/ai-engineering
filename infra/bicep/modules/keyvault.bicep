@description('Key Vault name — 3–24 chars, alphanumeric + hyphens, globally unique')
param keyVaultName string

@description('Azure region')
param location string

@description('Resource tags')
param tags object

@description('Object ID of the identity that will administer the vault (e.g., your own user or a pipeline service principal)')
param adminObjectId string = ''

// ── Key Vault ────────────────────────────────────────────────────────────────
resource kv 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  tags: tags
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId

    // RBAC auth model — no legacy access policies needed.
    // Grant access with: az role assignment create --role "Key Vault Secrets Officer" ...
    enableRbacAuthorization: true

    // Soft-delete retention: 7 days (minimum allowed).
    // Purge protection is omitted (defaults to disabled) so the vault can be fully
    // deleted in dev. Set enablePurgeProtection: true for production — note it's
    // irreversible once enabled, so don't set it here for a learning environment.
    enableSoftDelete: true
    softDeleteRetentionInDays: 7

    // Allow AKS CSI driver access over the VNet later (can tighten to private endpoint)
    publicNetworkAccess: 'Enabled'

    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
      ipRules: []
      virtualNetworkRules: []
    }
  }
}

// ── Admin role assignment (optional — only if adminObjectId is provided) ─────
//
// Grants 'Key Vault Secrets Officer' to the supplied identity so you can
// create/read secrets right after deploy.  Skip by leaving adminObjectId empty.
var secretsOfficerRoleId = 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'

resource adminRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(adminObjectId)) {
  name: guid(kv.id, adminObjectId, secretsOfficerRoleId)
  scope: kv
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', secretsOfficerRoleId)
    principalId: adminObjectId
    principalType: 'User'
  }
}

output keyVaultId string = kv.id
output keyVaultName string = kv.name
output keyVaultUri string = kv.properties.vaultUri
