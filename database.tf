resource "azurerm_mssql_server" "products" {
  name                          = local.names.sql_server
  resource_group_name           = azurerm_resource_group.products.name
  location                      = var.sql_location
  version                       = "12.0"
  administrator_login           = "ecomoperator"
  administrator_login_password  = var.sql_admin_password
  minimum_tls_version           = "1.2"
  public_network_access_enabled = true
  tags                          = local.tags
}

# This resource is the sole Terraform owner of the SQL database, including Free.
resource "azapi_resource" "products_database" {
  type      = "Microsoft.Sql/servers/databases@2023-08-01"
  name      = local.names.products_database
  parent_id = azurerm_mssql_server.products.id
  location  = var.sql_location
  tags      = local.tags

  body = {
    sku = {
      name     = "GP_S_Gen5"
      tier     = "GeneralPurpose"
      family   = "Gen5"
      capacity = 2
    }
    properties = {
      useFreeLimit                     = true
      freeLimitExhaustionBehavior      = "AutoPause"
      autoPauseDelay                   = 60
      minCapacity                      = 0.5
      maxSizeBytes                     = 34359738368
      requestedBackupStorageRedundancy = "Local"
      licenseType                      = "LicenseIncluded"
      zoneRedundant                    = false
    }
  }

  response_export_values = [
    "properties.useFreeLimit",
    "properties.freeLimitExhaustionBehavior",
  ]

  lifecycle {
    postcondition {
      condition = (
        self.output.properties.useFreeLimit == true &&
        self.output.properties.freeLimitExhaustionBehavior == "AutoPause"
      )
      error_message = "Azure must confirm the SQL Free offer with pause-at-limit enabled."
    }
  }
}

resource "azurerm_mssql_firewall_rule" "operator" {
  count            = var.operator_ipv4 == null ? 0 : 1
  name             = "local-products-migration"
  server_id        = azurerm_mssql_server.products.id
  start_ip_address = var.operator_ipv4
  end_ip_address   = var.operator_ipv4
}

resource "azurerm_key_vault_secret" "products_sql" {
  name         = local.names.sql_connection_key
  key_vault_id = azurerm_key_vault.products.id
  content_type = "Azure SQL connection string"

  # Quote the password so connection-string delimiter characters remain literal.
  value = format(
    "Server=tcp:%s,1433;Database=%s;User ID=%s;Password=\"%s\";Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;",
    azurerm_mssql_server.products.fully_qualified_domain_name,
    local.names.products_database,
    azurerm_mssql_server.products.administrator_login,
    replace(var.sql_admin_password, "\"", "\"\"")
  )

  depends_on = [azurerm_role_assignment.operator_secrets]
}
