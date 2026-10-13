resource "azurerm_resource_group" "products" {
  name     = local.names.resource_group
  location = var.location
  tags     = local.tags
}
