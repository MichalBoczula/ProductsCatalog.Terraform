output "resource_names" {
  description = "Deterministic Azure resource names, including the future Products app name."
  value       = local.names
}

output "products_foundation" {
  description = "Non-secret inputs for photo import, migrations and the later ACA deployment. Blob URLs require authorization."
  value = {
    subscription_id            = var.subscription_id
    resource_group_name        = azurerm_resource_group.products.name
    location                   = var.location
    virtual_network_id         = azurerm_virtual_network.products.id
    aca_subnet_id              = azurerm_subnet.aca.id
    aca_environment_id         = azurerm_container_app_environment.products.id
    aca_environment_name       = azurerm_container_app_environment.products.name
    aca_managed_group_name     = azurerm_container_app_environment.products.infrastructure_resource_group_name
    planned_container_app_name = local.names.products_app
    storage_account_name       = azurerm_storage_account.photos.name
    storage_blob_endpoint      = azurerm_storage_account.photos.primary_blob_endpoint
    photos_container_name      = azurerm_storage_container.photos.name
    photos_base_url            = "${azurerm_storage_account.photos.primary_blob_endpoint}${azurerm_storage_container.photos.name}/"
    photos_access              = azurerm_storage_container.photos.container_access_type
    identity_id                = azurerm_user_assigned_identity.products.id
    identity_client_id         = azurerm_user_assigned_identity.products.client_id
    identity_principal_id      = azurerm_user_assigned_identity.products.principal_id
    sql_server_name            = azurerm_mssql_server.products.name
    sql_server_fqdn            = azurerm_mssql_server.products.fully_qualified_domain_name
    sql_database_name          = local.names.products_database
    sql_connection_secret_uri  = azurerm_key_vault_secret.products_sql.id
    key_vault_name             = azurerm_key_vault.products.name
    operator_object_id         = var.operator_object_id
    operator_ipv4              = var.operator_ipv4
  }
}
