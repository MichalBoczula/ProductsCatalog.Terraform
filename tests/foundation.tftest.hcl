mock_provider "azurerm" {
  override_during = plan
}
mock_provider "azapi" {
  override_during = plan
}

# Standalone overrides default to apply, separately from mock_provider timing.
# These assertions need the overridden IDs/endpoints available during plan.
override_data {
  target          = data.azurerm_client_config.current
  override_during = plan
  values = {
    tenant_id       = "22222222-2222-2222-2222-222222222222"
    subscription_id = "11111111-1111-1111-1111-111111111111"
    object_id       = "44444444-4444-4444-4444-444444444444"
  }
}

override_resource {
  target          = azurerm_user_assigned_identity.products
  override_during = plan
  values = {
    id           = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-ecommercestore-products-dev/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-ecommercestore-products-dev"
    client_id    = "55555555-5555-5555-5555-555555555555"
    principal_id = "66666666-6666-6666-6666-666666666666"
  }
}

override_resource {
  target          = azurerm_storage_account.photos
  override_during = plan
  values = {
    id                    = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-ecommercestore-products-dev/providers/Microsoft.Storage/storageAccounts/stecproductsdevdemo01"
    primary_blob_endpoint = "https://stecproductsdevdemo01.blob.core.windows.net/"
  }
}

override_resource {
  target          = azurerm_storage_container.photos
  override_during = plan
  values = {
    id = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-ecommercestore-products-dev/providers/Microsoft.Storage/storageAccounts/stecproductsdevdemo01/blobServices/default/containers/photos"
  }
}

override_resource {
  target          = azurerm_virtual_network.products
  override_during = plan
  values = {
    id = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-ecommercestore-products-dev/providers/Microsoft.Network/virtualNetworks/vnet-ecommercestore-products-dev"
  }
}

override_resource {
  target          = azurerm_subnet.aca
  override_during = plan
  values = {
    id = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-ecommercestore-products-dev/providers/Microsoft.Network/virtualNetworks/vnet-ecommercestore-products-dev/subnets/snet-aca"
  }
}

override_resource {
  target          = azurerm_key_vault.products
  override_during = plan
  values = {
    id = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-ecommercestore-products-dev/providers/Microsoft.KeyVault/vaults/kv-ecp-dev-demo01"
  }
}

override_resource {
  target          = azurerm_mssql_server.products
  override_during = plan
  values = {
    id                          = "/subscriptions/11111111-1111-1111-1111-111111111111/resourceGroups/rg-ecommercestore-products-dev/providers/Microsoft.Sql/servers/sql-ecommercestore-products-dev-demo01"
    fully_qualified_domain_name = "sql-ecommercestore-products-dev-demo01.database.windows.net"
  }
}

override_resource {
  target          = azapi_resource.products_database
  override_during = plan
  values = {
    output = {
      properties = {
        useFreeLimit                = true
        freeLimitExhaustionBehavior = "AutoPause"
      }
    }
  }
}

variables {
  subscription_id    = "11111111-1111-1111-1111-111111111111"
  operator_object_id = "33333333-3333-3333-3333-333333333333"
  sql_admin_password = "TestOnly-Sql-123456!"
  name_suffix        = "demo01"
  environment        = "dev"
  location           = "northeurope"
  sql_location       = "francecentral"
  operator_ipv4      = null
}

run "products_foundation" {
  command = plan

  assert {
    condition = (
      azurerm_resource_group.products.name == "rg-ecommercestore-products-dev" &&
      azurerm_container_app_environment.products.name == "cae-ecommercestore-products-dev" &&
      azurerm_storage_account.photos.name == "stecproductsdevdemo01" &&
      azurerm_key_vault.products.name == "kv-ecp-dev-demo01"
    )
    error_message = "Resource names must identify EcommerceStore Products and respect per-service conventions."
  }

  assert {
    condition = (
      azurerm_storage_container.photos.container_access_type == "private" &&
      !azurerm_storage_account.photos.shared_access_key_enabled &&
      !azurerm_storage_account.photos.allow_nested_items_to_be_public &&
      azurerm_storage_account.photos.account_replication_type == "LRS" &&
      azurerm_role_assignment.products_photos.scope == azurerm_storage_container.photos.id &&
      azurerm_role_assignment.operator_photos.scope == azurerm_storage_container.photos.id &&
      azurerm_role_assignment.products_photos.role_definition_name == "Storage Blob Data Contributor" &&
      azurerm_role_assignment.operator_photos.principal_id == var.operator_object_id
    )
    error_message = "Photos must be private, use Entra authentication, and grant Products/operator data access only on the photos container."
  }

  assert {
    condition = (
      azurerm_key_vault.products.rbac_authorization_enabled &&
      azurerm_role_assignment.products_secrets.role_definition_name == "Key Vault Secrets User" &&
      azurerm_role_assignment.operator_secrets.role_definition_name == "Key Vault Secrets Officer" &&
      azurerm_role_assignment.operator_secrets.principal_id == var.operator_object_id &&
      azurerm_role_assignment.products_secrets.principal_id == azurerm_user_assigned_identity.products.principal_id &&
      azurerm_key_vault_secret.products_sql.name == "products-sql-connection"
    )
    error_message = "Keep the human operator explicit and give the Products identity secret-read access."
  }

  assert {
    condition = (
      azapi_resource.products_database.name == "products" &&
      azapi_resource.products_database.body.properties.useFreeLimit == true &&
      azapi_resource.products_database.body.properties.freeLimitExhaustionBehavior == "AutoPause" &&
      azapi_resource.products_database.body.properties.requestedBackupStorageRedundancy == "Local" &&
      azapi_resource.products_database.body.properties.maxSizeBytes == 34359738368 &&
      length(azurerm_mssql_firewall_rule.operator) == 0
    )
    error_message = "SQL must retain the Free offer with pause-at-limit and no default firewall access."
  }

  assert {
    condition = (
      one(azurerm_virtual_network.products.address_space) == "10.43.0.0/16" &&
      one(azurerm_subnet.aca.address_prefixes) == "10.43.0.0/27" &&
      azurerm_subnet.aca.delegation[0].service_delegation[0].name == "Microsoft.App/environments" &&
      length(azurerm_container_app_environment.products.workload_profile) == 1 &&
      one(azurerm_container_app_environment.products.workload_profile).workload_profile_type == "Consumption" &&
      contains([null, ""], azurerm_container_app_environment.products.logs_destination)
    )
    error_message = "The ACA environment needs its own delegated subnet, Consumption profile, and no paid log destination in this step."
  }

  assert {
    condition = (
      output.products_foundation.photos_access == "private" &&
      output.products_foundation.photos_base_url == "https://stecproductsdevdemo01.blob.core.windows.net/photos/" &&
      output.products_foundation.sql_database_name == "products"
    )
    error_message = "Non-secret outputs must describe the photo import and SQL migration targets."
  }
}

run "local_migration_access" {
  command = plan

  variables {
    operator_ipv4 = "203.0.113.10"
  }

  assert {
    condition = (
      length(azurerm_mssql_firewall_rule.operator) == 1 &&
      azurerm_mssql_firewall_rule.operator[0].start_ip_address == "203.0.113.10" &&
      azurerm_mssql_firewall_rule.operator[0].end_ip_address == "203.0.113.10"
    )
    error_message = "Local SQL access must allow only the explicitly supplied IPv4."
  }
}
