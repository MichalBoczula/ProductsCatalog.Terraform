resource "azurerm_storage_account" "photos" {
  name                            = local.names.storage_account
  resource_group_name             = azurerm_resource_group.products.name
  location                        = var.location
  account_kind                    = "StorageV2"
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  access_tier                     = "Hot"
  https_traffic_only_enabled      = true
  min_tls_version                 = "TLS1_2"
  shared_access_key_enabled       = false
  default_to_oauth_authentication = true
  allow_nested_items_to_be_public = var.photos_anonymous_read_enabled
  public_network_access           = "Enabled"
  tags                            = local.tags

  # Disposable first deployment. Photo originals must remain in their source.
  blob_properties {
    versioning_enabled = false
  }
}

resource "azurerm_storage_container" "photos" {
  name                  = local.names.photos_container
  storage_account_id    = azurerm_storage_account.photos.id
  container_access_type = var.photos_anonymous_read_enabled ? "blob" : "private"
}
