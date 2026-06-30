@description('Container Registry name — must be globally unique, alphanumeric, 5–50 chars')
param acrName string

@description('Azure region')
param location string

@description('Resource tags')
param tags object

@description('SKU for the registry (Basic | Standard | Premium)')
@allowed(['Basic', 'Standard', 'Premium'])
param sku string = 'Standard'

// ── Azure Container Registry ─────────────────────────────────────────────────
resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: acrName
  location: location
  tags: tags
  sku: {
    name: sku
  }
  properties: {
    adminUserEnabled: false   // use managed identity, not admin credentials
    publicNetworkAccess: 'Enabled'
    zoneRedundancy: 'Disabled'
  }
}

output acrId string = acr.id
output loginServer string = acr.properties.loginServer
output acrName string = acr.name
