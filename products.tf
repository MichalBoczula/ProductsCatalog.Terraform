# The firewall keys come from a reviewed local input file generated AFTER prepare.
# Do not derive for_each from the app's computed outbound_ip_addresses: the app
# must be able to start before SQL rules exist, and plan must know all keys.
resource "azurerm_mssql_firewall_rule" "products_aca" {
  for_each         = var.deploy_products_app ? var.products_sql_egress_ipv4 : {}
  name             = "products-aca-${each.key}"
  server_id        = azurerm_mssql_server.products.id
  start_ip_address = each.value
  end_ip_address   = each.value
}

resource "azurerm_container_app" "products" {
  count                        = var.deploy_products_app ? 1 : 0
  name                         = local.names.products_app
  resource_group_name          = azurerm_resource_group.products.name
  container_app_environment_id = azurerm_container_app_environment.products.id
  workload_profile_name        = "Consumption"
  revision_mode                = "Single"
  tags                         = local.tags

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.products.id]
  }

  secret {
    name                = local.names.sql_connection_key
    identity            = azurerm_user_assigned_identity.products.id
    key_vault_secret_id = azurerm_key_vault_secret.products_sql.id
  }

  ingress {
    external_enabled           = var.products_external_ingress_enabled
    allow_insecure_connections = false
    target_port                = 8080
    transport                  = "http"

    dynamic "ip_security_restriction" {
      for_each = var.products_external_ingress_enabled && var.operator_ipv4 != null ? [var.operator_ipv4] : []
      content {
        name             = "operator-only"
        action           = "Allow"
        ip_address_range = "${ip_security_restriction.value}/32"
        description      = "Temporary Products API verification from the operator address."
      }
    }

    traffic_weight {
      latest_revision = true
      percentage      = 100
    }
  }

  template {
    min_replicas = 0
    max_replicas = 1

    http_scale_rule {
      name                = "http"
      concurrent_requests = "10"
    }

    container {
      name   = "products"
      image  = var.products_image
      cpu    = 0.25
      memory = "0.5Gi"

      env {
        name  = "ASPNETCORE_ENVIRONMENT"
        value = "Production"
      }
      env {
        name  = "ASPNETCORE_HTTP_PORTS"
        value = "8080"
      }
      env {
        name        = "ConnectionStrings__ProductCatalogDb"
        secret_name = local.names.sql_connection_key
      }
      env {
        name  = "Database__ApplyMigrations"
        value = tostring(var.products_deployment_stage == "serve" && var.products_apply_migrations)
      }

      startup_probe {
        transport               = "HTTP"
        port                    = 8080
        path                    = "/health/live"
        interval_seconds        = 5
        timeout                 = 3
        failure_count_threshold = 120
      }
      liveness_probe {
        transport               = "HTTP"
        port                    = 8080
        path                    = "/health/live"
        interval_seconds        = 30
        timeout                 = 3
        failure_count_threshold = 3
      }
      readiness_probe {
        transport               = "HTTP"
        port                    = 8080
        path                    = var.products_deployment_stage == "serve" ? "/health/ready" : "/health/live"
        interval_seconds        = 10
        timeout                 = 15
        failure_count_threshold = 30
        success_count_threshold = 1
      }
    }
  }

  depends_on = [
    azurerm_role_assignment.products_secrets,
    azapi_resource.products_database,
    azurerm_mssql_firewall_rule.products_aca,
  ]

}
