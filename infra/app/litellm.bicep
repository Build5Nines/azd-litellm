@description('Location for the resource.')
param location string = resourceGroup().location

@description('Tags for the resource.')
param tags object = {}

@description('Name of the Container Apps managed environment.')
param containerAppsEnvironmentName string

@description('Connection string for PostgreSQL. Use secure parameter.')
param postgresqlConnectionString string

@description('Name for the App.')
param name string

@description('Name of the container.')
param containerName string = 'litellm'

@description('Name of the container registry.')
param containerRegistryName string

@description('Port exposed by the LiteLLM container.')
param containerPort int

@description('Minimum replica count for LiteLLM containers.')
param containerMinReplicaCount int

@description('Maximum replica count for LiteLLM containers.')
param containerMaxReplicaCount int

// @description('Name of the Key Vault.')
// param keyvaultName string

@description('Master key for LiteLLM. Your master key for the proxy server.')
@secure()
param litellm_master_key string

@description('Salt key for LiteLLM. (CAN NOT CHANGE ONCE SET)')
@secure()
param litellm_salt_key string

@description('Azure OpenAI API Key used by LiteLLM.')
@secure()
param azure_api_key string

@description('Azure OpenAI endpoint base URL.')
param azure_api_base string

@description('Azure OpenAI API version.')
param azure_api_version string

param litellmContainerAppExists bool

var abbrs = loadJsonContent('../abbreviations.json')
var identityName = '${abbrs.managedIdentityUserAssignedIdentities}${name}'

resource containerRegistry 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  name: containerRegistryName
}

resource containerAppsEnvironment 'Microsoft.App/managedEnvironments@2023-04-01-preview' existing = {
  name: containerAppsEnvironmentName
}

// resource keyvault 'Microsoft.KeyVault/vaults@2024-11-01' existing = {
//   name: keyvaultName
// }

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: identityName
  location: location
}

resource acrPullRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: containerRegistry
  name: guid(subscription().id, resourceGroup().id, identity.id, 'acrPullRole')
  properties: {
    roleDefinitionId:  subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d') // ACR Pull role
    principalType: 'ServicePrincipal'
    principalId: identity.properties.principalId
  }
}

// resource keyvaultAccessPolicy 'Microsoft.KeyVault/vaults/accessPolicies@2023-07-01' = {
//   parent: keyvault
//   name: 'add'
//   properties: {
//     accessPolicies: [
//       {
//         objectId: identity.properties.principalId
//         permissions: { secrets: [ 'get', 'list' ] }
//         tenantId: subscription().tenantId
//       }
//     ]
//   }
// }

module fetchLatestContainerImage '../shared/fetch-container-image.bicep' = {
  name: '${name}-fetch-image'
  params: {
    exists: litellmContainerAppExists
    containerAppName: name
  }
}

// module keyvaultSecretMasterKey '../shared/keyvault-secret.bicep' = {
//   name: '${name}-master-key'
//   params: {
//     keyvaultName: keyvaultName
//     secretName: 'LITELLM_MASTER_KEY'
//     secretValue: litellm_master_key
//   }
// }

// module keyvaultSecretSaltKey '../shared/keyvault-secret.bicep' = {
//   name: '${name}-salt-key'
//   params: {
//     keyvaultName: keyvaultName
//     secretName: 'LITELLM_SALT_KEY'
//     secretValue: litellm_salt_key
//   }
// }

// module keyVaultSecretPostgreSQLConnectionString '../shared/keyvault-secret.bicep' = {
//   name: '${name}-postgresql-connection-string'
//   params: {
//     keyvaultName: keyvaultName
//     secretName: 'DATABASE_URL'
//     secretValue: postgresqlConnectionString
//   }
// }

resource containerApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: name
  location: location
  tags: union(tags, {'azd-service-name':  'litellm' })
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${identity.id}': {} }
  }
  properties: {
    managedEnvironmentId: containerAppsEnvironment.id
    configuration: {
      ingress: {
        external: true
        targetPort: containerPort
        transport: 'auto'
      }
      registries: [
        {
          server: containerRegistry.properties.loginServer
          identity: identity.id
        }
      ]
      secrets: [
        {
          name: 'litellm-master-key'
          value: litellm_master_key
          // identity: identity.id
          // keyVaultUrl: 'https://${keyvault.name}.vault.azure.net/secrets/${keyvaultSecretMasterKey.outputs.secretName}'
        }
        {
          name: 'litellm-salt-key'
          value: litellm_salt_key
          // identity: identity.id
          // keyVaultUrl: 'https://${keyvault.name}.vault.azure.net/secrets/${keyvaultSecretSaltKey.outputs.secretName}'
        }
        {
          name: 'database-url'
          value: postgresqlConnectionString
          // identity: identity.id
          // keyVaultUrl: 'https://${keyvault.name}.vault.azure.net/secrets/${keyVaultSecretPostgreSQLConnectionString.outputs.secretName}'
        }
        {
          name: 'azure-api-key'
          value: azure_api_key
        }
      ]
    }
    template: {
      containers: [
        {
          name: containerName
          image: fetchLatestContainerImage.outputs.?containers[?0].?image ?? 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'
          resources: {
            cpu: 1
            memory: '2Gi'
          }
          env: [
            {
              name: 'LITELLM_MASTER_KEY'
              secretRef: 'litellm-master-key'
            }
            {
              name: 'LITELLM_SALT_KEY'
              secretRef: 'litellm-salt-key'
            }
            {
              name: 'DATABASE_URL'
              secretRef: 'database-url'
            }
            {
              name: 'AZURE_API_KEY'
              secretRef: 'azure-api-key'
            }
            {
              name: 'AZURE_API_BASE'
              value: azure_api_base
            }
            {
              name: 'AZURE_API_VERSION'
              value: azure_api_version
            }
            {
              name: 'STORE_MODEL_IN_DB'
              value: 'False'
            }
          ]
        }
      ]
      scale: {
        minReplicas: containerMinReplicaCount
        maxReplicas: containerMaxReplicaCount
      }
    }
  }
}

output containerAppName string = containerApp.name
output containerAppFQDN string = containerApp.properties.configuration.ingress.fqdn

