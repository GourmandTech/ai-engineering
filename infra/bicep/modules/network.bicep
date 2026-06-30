@description('Virtual network name')
param vnetName string

@description('Azure region')
param location string

@description('Resource tags')
param tags object

@description('VNet address space')
param vnetAddressPrefix string = '10.0.0.0/16'

@description('AKS node subnet address prefix — must be large enough for node IPs with Azure CNI (/22 = ~1000 IPs)')
param aksSubnetPrefix string = '10.0.0.0/22'

// ── Virtual Network ──────────────────────────────────────────────────────────
resource vnet 'Microsoft.Network/virtualNetworks@2023-05-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [vnetAddressPrefix]
    }
    subnets: [
      {
        name: 'snet-aks'
        properties: {
          addressPrefix: aksSubnetPrefix
          // Disable private endpoint network policies — needed if you add
          // private endpoints for Postgres/Redis later.
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
    ]
  }
}

output vnetId string = vnet.id
output vnetName string = vnet.name
output aksSubnetId string = vnet.properties.subnets[0].id
