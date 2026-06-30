@description('AKS cluster name')
param clusterName string

@description('Azure region')
param location string

@description('Resource tags')
param tags object

@description('Resource ID of the AKS node subnet')
param aksSubnetId string

@description('Resource ID of the Log Analytics workspace for Container Insights')
param logAnalyticsWorkspaceId string

@description('Resource ID of the Azure Container Registry to attach')
param acrId string

@description('Resource ID of the Key Vault')
param keyVaultId string

@description('Object ID of the admin user/service principal to grant AKS RBAC Cluster Admin. Leave empty to skip.')
param adminObjectId string = ''

@description('System node pool VM size')
param nodeVmSize string = 'Standard_D2s_v7'

@description('Initial system node count')
@minValue(1)
@maxValue(5)
param nodeCount int = 1

@description('OS disk size in GB (0 = use managed default)')
param osDiskSizeGB int = 50

@description('Maximum pods per node. Azure CNI default is 30 — increase for observability add-ons (cert-manager, prometheus, etc.)')
@minValue(10)
@maxValue(250)
param maxPodsPerNode int = 50

@description('Kubernetes version — check: az aks get-versions -l eastus -o table')
param kubernetesVersion string = '1.35'

// ── AKS Cluster ──────────────────────────────────────────────────────────────
resource aks 'Microsoft.ContainerService/managedClusters@2024-01-01' = {
  name: clusterName
  location: location
  tags: tags

  // System-assigned identity for the control plane
  identity: {
    type: 'SystemAssigned'
  }

  properties: {
    kubernetesVersion: kubernetesVersion
    dnsPrefix: clusterName

    // ── Node pool ──────────────────────────────────────────────────────────
    agentPoolProfiles: [
      {
        name: 'system'
        mode: 'System'
        count: nodeCount
        vmSize: nodeVmSize
        osDiskSizeGB: osDiskSizeGB
        osDiskType: 'Managed'
        osType: 'Linux'
        osSKU: 'AzureLinux'
        vnetSubnetID: aksSubnetId
        maxPods: maxPodsPerNode
        enableAutoScaling: false   // enable HPA; cluster autoscaler is optional for dev
        type: 'VirtualMachineScaleSets'
        upgradeSettings: {
          maxSurge: '1'
        }
      }
    ]

    // ── Networking ────────────────────────────────────────────────────────
    // Azure CNI: each pod gets an IP from the subnet — required for Azure RBAC
    // network policies and better node-to-pod connectivity.
    networkProfile: {
      networkPlugin: 'azure'
      networkPolicy: 'calico'
      loadBalancerSku: 'standard'
      // serviceCidr and dnsServiceIP must not overlap with the subnet
      serviceCidr: '10.1.0.0/16'
      dnsServiceIP: '10.1.0.10'
    }

    // ── Add-ons ───────────────────────────────────────────────────────────
    addonProfiles: {
      // Container Insights — sends logs/metrics to Log Analytics
      omsagent: {
        enabled: true
        config: {
          logAnalyticsWorkspaceResourceID: logAnalyticsWorkspaceId
        }
      }
      // Azure Key Vault CSI secrets-store provider
      azureKeyvaultSecretsProvider: {
        enabled: true
        config: {
          enableSecretRotation: 'true'
          rotationPollInterval: '2m'
        }
      }
    }

    // ── OIDC + Workload Identity ──────────────────────────────────────────
    // Required for pods to authenticate to Azure services (Key Vault, ACR, etc.)
    // without node-level credentials.
    oidcIssuerProfile: {
      enabled: true
    }
    securityProfile: {
      workloadIdentity: {
        enabled: true
      }
    }

    // ── RBAC ──────────────────────────────────────────────────────────────
    enableRBAC: true
    aadProfile: {
      managed: true
      enableAzureRBAC: true
    }

    // ── Auto-upgrade ──────────────────────────────────────────────────────
    autoUpgradeProfile: {
      upgradeChannel: 'patch'   // auto-patch within minor version
    }
  }
}

// ── ACR Pull — grant the kubelet identity AcrPull on the registry ────────────
// This lets any pod on any node pull images from ACR without image pull secrets.
var acrPullRoleId = '7f951dda-4ed3-4680-a7ca-43fe172d538d'

resource acrPullAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  // guid() args must be computable at deployment start — use known input params, not runtime identity objectIds
  name: guid(acrId, clusterName, acrPullRoleId)
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', acrPullRoleId)
    principalId: aks.properties.identityProfile.kubeletidentity.objectId
    principalType: 'ServicePrincipal'
  }
}

// ── Key Vault — grant CSI driver identity Key Vault Secrets User ─────────────
// The CSI driver's managed identity (addon-managed) needs to read secrets.
// 'Key Vault Secrets User' = read secret values only (least privilege).
var kvSecretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6'

resource kvCsiRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  // guid() args must be computable at deployment start — use known input params, not runtime identity objectIds
  name: guid(keyVaultId, clusterName, kvSecretsUserRoleId)
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', kvSecretsUserRoleId)
    principalId: aks.properties.addonProfiles.azureKeyvaultSecretsProvider.identity.objectId
    principalType: 'ServicePrincipal'
  }
}

// ── AKS RBAC Cluster Admin — grant the adminObjectId full cluster access ──────
// Required when enableAzureRBAC: true — k8s access is controlled via Azure RBAC,
// not kubeconfig alone. Without this, kubectl get nodes returns Forbidden.
// 'Azure Kubernetes Service RBAC Cluster Admin' role.
var aksRbacClusterAdminRoleId = 'b1ff04bb-8a4e-4dc4-8eb5-8693973ce19b'

resource aksAdminRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(adminObjectId)) {
  name: guid(aks.id, adminObjectId, aksRbacClusterAdminRoleId)
  scope: aks
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', aksRbacClusterAdminRoleId)
    principalId: adminObjectId
    principalType: 'User'
  }
}

output clusterName string = aks.name
output clusterId string = aks.id
output kubeletIdentityObjectId string = aks.properties.identityProfile.kubeletidentity.objectId
output csiDriverIdentityObjectId string = aks.properties.addonProfiles.azureKeyvaultSecretsProvider.identity.objectId
output oidcIssuerUrl string = aks.properties.oidcIssuerProfile.issuerURL
