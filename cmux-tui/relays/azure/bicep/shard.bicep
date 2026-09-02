targetScope = 'resourceGroup'

@description('Azure region for this relay shard.')
param location string = resourceGroup().location

@description('Stable shard name. The cmux control plane gives this endpoint to both sides of a circuit.')
@minLength(1)
@maxLength(32)
param shard string

@description('Optional availability zone. Leave empty for a region without availability zones.')
@allowed([
  ''
  '1'
  '2'
  '3'
])
param availabilityZone string = ''

@description('Immutable files.cmux.com URL for the x86_64 Linux cmux-relay binary.')
@minLength(1)
param relayBinaryUrl string

@description('Lowercase SHA-256 digest of relayBinaryUrl.')
@minLength(64)
@maxLength(64)
param relayBinarySha256 string

@description('Existing Key Vault that stores the relay HMAC secret and the Application Gateway certificate.')
@minLength(1)
param keyVaultName string

@description('Key Vault secret name containing at least 32 random bytes.')
@minLength(1)
param relaySecretName string = 'cmux-relay-hmac'

@description('Key Vault secret name used by Application Gateway for the TLS certificate.')
@minLength(1)
param certificateSecretName string = 'cmux-relay-tls'

@description('Versioned Key Vault secret ID for the TLS certificate consumed by Application Gateway.')
@secure()
@minLength(1)
param certificateSecretId string

@description('SSH public key for break-glass host access. No SSH ingress rule is created.')
@minLength(1)
param adminSshPublicKey string

@description('Linux VM administrator name.')
@minLength(1)
@maxLength(32)
param adminUsername string = 'cmuxrelay'

@description('One VM per shard is intentional. The relay pairing ledger is in memory.')
@minValue(1)
@maxValue(1)
param vmssCapacity int = 1

var gatewaySubnetPrefix = '10.42.0.0/24'
var relaySubnetPrefix = '10.42.1.0/24'
var relayFrontendIp = '10.42.1.4'
// Azure resource names and public DNS labels use a hash-derived suffix. The
// human shard can contain routing separators without making Azure names invalid.
var relayResourceName = 'cmux-relay-${uniqueString(resourceGroup().id, shard)}'
var relayZones = empty(availabilityZone) ? null : [availabilityZone]
var cloudInit = base64(
  replace(
    replace(
      replace(
        replace(
          replace(
            loadTextContent('../cloud-init.sh'),
            '__CMUX_RELAY_BINARY_URL_B64__',
            base64(relayBinaryUrl)
          ),
          '__CMUX_RELAY_BINARY_SHA256_B64__',
          base64(relayBinarySha256)
        ),
        '__CMUX_RELAY_SHARD_B64__',
        base64(shard)
        ),
        '__CMUX_RELAY_KEY_VAULT_NAME_B64__',
        base64(keyVaultName)
      ),
      '__CMUX_RELAY_SECRET_NAME_B64__',
      base64(relaySecretName)
    )
  )

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
}

resource relayHmacSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' existing = {
  parent: keyVault
  name: relaySecretName
}

resource tlsCertificateSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' existing = {
  parent: keyVault
  name: certificateSecretName
}

resource relayIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${relayResourceName}-vm'
  location: location
  tags: {
    'cmux.relay.shard': shard
  }
}

resource gatewayIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${relayResourceName}-gateway'
  location: location
  tags: {
    'cmux.relay.shard': shard
    'cmux.relay.role': 'application-gateway'
  }
}

// The vault must use Azure RBAC authorization. Scoping each identity to one
// secret limits the impact of a compromise of either the VM or gateway.
resource relaySecretRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(relayHmacSecret.id, relayIdentity.id, 'Key Vault Secrets User')
  scope: relayHmacSecret
  properties: {
    principalId: relayIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '4633458b-17de-408a-b874-0445c86b69e6'
    )
  }
}

resource gatewayCertificateRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(tlsCertificateSecret.id, gatewayIdentity.id, 'Key Vault Secrets User')
  scope: tlsCertificateSecret
  properties: {
    principalId: gatewayIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '4633458b-17de-408a-b874-0445c86b69e6'
    )
  }
}

resource relayNsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: '${relayResourceName}-nsg'
  location: location
  properties: {
    securityRules: [
      {
        name: 'allow-application-gateway-relay'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: gatewaySubnetPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '8787'
        }
      }
      {
        name: 'allow-azure-load-balancer-probe'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'AzureLoadBalancer'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '8787'
        }
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: '${relayResourceName}-vnet'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.42.0.0/16'
      ]
    }
  }
}

resource relaySubnet 'Microsoft.Network/virtualNetworks/subnets@2023-11-01' = {
  parent: vnet
  name: 'relay'
  properties: {
    addressPrefix: relaySubnetPrefix
    natGateway: {
      id: natGateway.id
    }
    networkSecurityGroup: {
      id: relayNsg.id
    }
  }
}

resource gatewaySubnet 'Microsoft.Network/virtualNetworks/subnets@2023-11-01' = {
  parent: vnet
  name: 'application-gateway'
  properties: {
    addressPrefix: gatewaySubnetPrefix
  }
  dependsOn: [
    relaySubnet
  ]
}

resource publicIp 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: '${relayResourceName}-public-ip'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    dnsSettings: {
      domainNameLabel: relayResourceName
    }
  }
}

// A dedicated egress IP keeps VM bootstrap independent from Azure's changing
// implicit outbound-access defaults. The Application Gateway public IP is not
// reused because its lifecycle and SNAT behavior are different.
resource outboundPublicIp 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: '${relayResourceName}-egress-ip'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource natGateway 'Microsoft.Network/natGateways@2023-11-01' = {
  name: '${relayResourceName}-nat'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    idleTimeoutInMinutes: 10
    publicIpAddresses: [
      {
        id: outboundPublicIp.id
      }
    ]
  }
}

resource loadBalancer 'Microsoft.Network/loadBalancers@2023-11-01' = {
  name: '${relayResourceName}-lb'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    frontendIPConfigurations: [
      {
        name: 'relay'
        properties: {
          privateIPAddress: relayFrontendIp
          privateIPAllocationMethod: 'Static'
          subnet: {
            id: relaySubnet.id
          }
        }
      }
    ]
    backendAddressPools: [
      {
        name: 'relay'
      }
    ]
    probes: [
      {
        name: 'readyz'
        properties: {
          protocol: 'Http'
          port: 8787
          requestPath: '/readyz'
          intervalInSeconds: 5
          numberOfProbes: 2
        }
      }
      {
        // /healthz remains 200 during a planned drain. VMSS automatic repairs
        // must not replace a healthy instance just because it left rotation.
        name: 'healthz'
        properties: {
          protocol: 'Http'
          port: 8787
          requestPath: '/healthz'
          intervalInSeconds: 5
          numberOfProbes: 2
        }
      }
    ]
    loadBalancingRules: [
      {
        name: 'relay'
        properties: {
          protocol: 'Tcp'
          frontendPort: 8787
          backendPort: 8787
          idleTimeoutInMinutes: 30
          enableTcpReset: true
          frontendIPConfiguration: {
            id: resourceId(
              'Microsoft.Network/loadBalancers/frontendIPConfigurations',
              '${relayResourceName}-lb',
              'relay'
            )
          }
          backendAddressPool: {
            id: resourceId(
              'Microsoft.Network/loadBalancers/backendAddressPools',
              '${relayResourceName}-lb',
              'relay'
            )
          }
          probe: {
            id: resourceId(
              'Microsoft.Network/loadBalancers/probes',
              '${relayResourceName}-lb',
              'readyz'
            )
          }
        }
      }
    ]
  }
}

resource vmss 'Microsoft.Compute/virtualMachineScaleSets@2023-09-01' = {
  name: '${relayResourceName}-vmss'
  location: location
  zones: relayZones
  sku: {
    name: 'Standard_D2as_v6'
    tier: 'Standard'
    capacity: vmssCapacity
  }
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${relayIdentity.id}': {}
    }
  }
  properties: {
    orchestrationMode: 'Uniform'
    overprovision: false
    upgradePolicy: {
      mode: 'Rolling'
      rollingUpgradePolicy: {
        maxBatchInstancePercent: 100
        maxUnhealthyInstancePercent: 100
        pauseTimeBetweenBatches: 'PT1M'
        enableCrossZoneUpgrade: false
      }
    }
    automaticRepairsPolicy: {
      enabled: true
      repairAction: 'Replace'
      gracePeriod: 'PT10M'
    }
    virtualMachineProfile: {
      osProfile: {
        computerNamePrefix: 'cmuxrelay'
        adminUsername: adminUsername
        customData: cloudInit
        linuxConfiguration: {
          disablePasswordAuthentication: true
          ssh: {
            publicKeys: [
              {
                path: '/home/${adminUsername}/.ssh/authorized_keys'
                keyData: adminSshPublicKey
              }
            ]
          }
        }
      }
      storageProfile: {
        imageReference: {
          publisher: 'Canonical'
          offer: '0001-com-ubuntu-server-jammy'
          sku: '22_04-lts-gen2'
          version: 'latest'
        }
        osDisk: {
          createOption: 'FromImage'
          managedDisk: {
            storageAccountType: 'Premium_LRS'
          }
        }
      }
      networkProfile: {
        healthProbe: {
          id: resourceId(
            'Microsoft.Network/loadBalancers/probes',
            '${relayResourceName}-lb',
            'healthz'
          )
        }
        networkInterfaceConfigurations: [
          {
            name: 'relay'
            properties: {
              primary: true
              ipConfigurations: [
                {
                  name: 'relay'
                  properties: {
                    subnet: {
                      id: relaySubnet.id
                    }
                    loadBalancerBackendAddressPools: [
                      {
                        id: resourceId(
                          'Microsoft.Network/loadBalancers/backendAddressPools',
                          '${relayResourceName}-lb',
                          'relay'
                        )
                      }
                    ]
                  }
                }
              ]
            }
          }
        ]
      }
    }
  }
  tags: {
    'cmux.relay.shard': shard
    'cmux.relay.role': 'data-plane'
  }
  dependsOn: [
    relaySecretRole
    loadBalancer
  ]
}

resource appGateway 'Microsoft.Network/applicationGateways@2023-11-01' = {
  name: '${relayResourceName}-gateway'
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${gatewayIdentity.id}': {}
    }
  }
  // The Azure type schema omits this required property for this API version.
  #disable-next-line BCP187
  sku: {
    name: 'Standard_v2'
    tier: 'Standard_v2'
  }
  properties: {
    enableHttp2: true
    autoscaleConfiguration: {
      minCapacity: 1
      maxCapacity: 2
    }
    gatewayIPConfigurations: [
      {
        name: 'gateway'
        properties: {
          subnet: {
            id: gatewaySubnet.id
          }
        }
      }
    ]
    frontendIPConfigurations: [
      {
        name: 'public'
        properties: {
          publicIPAddress: {
            id: publicIp.id
          }
        }
      }
    ]
    frontendPorts: [
      {
        name: 'https'
        properties: {
          port: 443
        }
      }
    ]
    sslCertificates: [
      {
        name: 'relay'
        properties: {
          keyVaultSecretId: certificateSecretId
        }
      }
    ]
    backendAddressPools: [
      {
        name: 'relay'
        properties: {
          backendAddresses: [
            {
              ipAddress: relayFrontendIp
            }
          ]
        }
      }
    ]
    backendHttpSettingsCollection: [
      {
        name: 'relay'
        properties: {
          port: 8787
          protocol: 'Http'
          cookieBasedAffinity: 'Disabled'
          requestTimeout: 3600
          pickHostNameFromBackendAddress: false
          connectionDraining: {
            enabled: true
            drainTimeoutInSec: 3600
          }
          probe: {
            id: resourceId(
              'Microsoft.Network/applicationGateways/probes',
              '${relayResourceName}-gateway',
              'readyz'
            )
          }
        }
      }
    ]
    probes: [
      {
        name: 'readyz'
        properties: {
          protocol: 'Http'
          path: '/readyz'
          host: 'relay.internal'
          interval: 5
          timeout: 5
          unhealthyThreshold: 2
          pickHostNameFromBackendHttpSettings: false
        }
      }
    ]
    httpListeners: [
      {
        name: 'https'
        properties: {
          frontendIPConfiguration: {
            id: resourceId(
              'Microsoft.Network/applicationGateways/frontendIPConfigurations',
              '${relayResourceName}-gateway',
              'public'
            )
          }
          frontendPort: {
            id: resourceId(
              'Microsoft.Network/applicationGateways/frontendPorts',
              '${relayResourceName}-gateway',
              'https'
            )
          }
          protocol: 'Https'
          sslCertificate: {
            id: resourceId(
              'Microsoft.Network/applicationGateways/sslCertificates',
              '${relayResourceName}-gateway',
              'relay'
            )
          }
        }
      }
    ]
    requestRoutingRules: [
      {
        name: 'relay'
        properties: {
          priority: 100
          ruleType: 'Basic'
          httpListener: {
            id: resourceId(
              'Microsoft.Network/applicationGateways/httpListeners',
              '${relayResourceName}-gateway',
              'https'
            )
          }
          backendAddressPool: {
            id: resourceId(
              'Microsoft.Network/applicationGateways/backendAddressPools',
              '${relayResourceName}-gateway',
              'relay'
            )
          }
          backendHttpSettings: {
            id: resourceId(
              'Microsoft.Network/applicationGateways/backendHttpSettingsCollection',
              '${relayResourceName}-gateway',
              'relay'
            )
          }
        }
      }
    ]
  }
  dependsOn: [
    gatewayCertificateRole
    vmss
  ]
}

output relayHostname string = publicIp.properties.dnsSettings.fqdn
output relayRoute string = 'relay+wss://${publicIp.properties.dnsSettings.fqdn}/v1/relay'
output shardName string = shard
