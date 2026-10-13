resource "azurerm_user_assigned_identity" "products" {
  name                = local.names.products_identity
  resource_group_name = azurerm_resource_group.products.name
  location            = var.location
  tags                = local.tags
}

resource "azurerm_key_vault" "products" {
  name                          = local.names.key_vault
  resource_group_name           = azurerm_resource_group.products.name
  location                      = var.location
  tenant_id                     = data.azurerm_client_config.current.tenant_id
  sku_name                      = "standard"
  rbac_authorization_enabled    = true
  public_network_access_enabled = true
  soft_delete_retention_days    = 7
  purge_protection_enabled      = false
  tags                          = local.tags
}

resource "azurerm_role_assignment" "products_photos" {
  scope                = azurerm_storage_container.photos.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.products.principal_id
}

resource "azurerm_role_assignment" "products_secrets" {
  scope                = azurerm_key_vault.products.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.products.principal_id
}

resource "azurerm_role_assignment" "operator_photos" {
  scope                = azurerm_storage_container.photos.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = var.operator_object_id
}

resource "azurerm_role_assignment" "operator_secrets" {
  scope                = azurerm_key_vault.products.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = var.operator_object_id
}
