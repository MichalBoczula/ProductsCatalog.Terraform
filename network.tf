resource "azurerm_virtual_network" "products" {
  name                = local.names.virtual_network
  resource_group_name = azurerm_resource_group.products.name
  location            = var.location
  # Distinct from the earlier whole-store foundation's 10.42.0.0/16.
  address_space = ["10.43.0.0/16"]
  tags          = local.tags
}

resource "azurerm_subnet" "aca" {
  name                 = "snet-aca"
  resource_group_name  = azurerm_resource_group.products.name
  virtual_network_name = azurerm_virtual_network.products.name
  address_prefixes     = ["10.43.0.0/27"]

  delegation {
    name = "container-apps"
    service_delegation {
      name    = "Microsoft.App/environments"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_container_app_environment" "products" {
  name                               = local.names.aca_environment
  resource_group_name                = azurerm_resource_group.products.name
  location                           = var.location
  infrastructure_subnet_id           = azurerm_subnet.aca.id
  infrastructure_resource_group_name = local.names.aca_managed_group
  internal_load_balancer_enabled     = false
  public_network_access              = "Enabled"
  zone_redundancy_enabled            = false
  tags                               = local.tags

  workload_profile {
    name                  = "Consumption"
    workload_profile_type = "Consumption"
  }

  # Azure owns the managed networking group and its IP/load-balancer resources.
  # Streamed logs are sufficient for this first step; no Log Analytics workspace.
  # Products rollout and its SQL egress rules are managed in products.tf.
}
