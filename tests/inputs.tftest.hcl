mock_provider "azurerm" {}
mock_provider "azapi" {}

override_data {
  target = data.azurerm_client_config.current
  values = {
    tenant_id       = "22222222-2222-2222-2222-222222222222"
    subscription_id = "11111111-1111-1111-1111-111111111111"
    object_id       = "44444444-4444-4444-4444-444444444444"
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

run "maximum_length_names" {
  command = plan
  variables {
    environment = "prod"
    name_suffix = "abcd1234"
  }
  assert {
    condition = (
      can(regex("^[a-z0-9]{3,24}$", local.names.storage_account)) &&
      can(regex("^[a-z][a-z0-9-]{1,22}[a-z0-9]$", local.names.key_vault)) &&
      length(local.names.products_app) <= 32 &&
      length(local.names.sql_server) <= 63 &&
      local.names.resource_group == "rg-ecommercestore-products-prod"
    )
    error_message = "Names must fit Azure limits even for the longest supported environment/suffix."
  }
}

run "reject_invalid_subscription" {
  command = plan
  variables { subscription_id = "Portfolio" }
  expect_failures = [var.subscription_id]
}

run "reject_invalid_operator" {
  command = plan
  variables { operator_object_id = "operator@example.invalid" }
  expect_failures = [var.operator_object_id]
}

run "reject_invalid_environment" {
  command = plan
  variables { environment = "development" }
  expect_failures = [var.environment]
}

run "reject_long_suffix" {
  command = plan
  variables { name_suffix = "abcdefghi" }
  expect_failures = [var.name_suffix]
}

run "reject_uppercase_suffix" {
  command = plan
  variables { name_suffix = "Demo01" }
  expect_failures = [var.name_suffix]
}

run "reject_weak_password" {
  command = plan
  variables { sql_admin_password = "short" }
  expect_failures = [var.sql_admin_password]
}

run "reject_azure_wide_firewall" {
  command = plan
  variables { operator_ipv4 = "0.0.0.0" }
  expect_failures = [var.operator_ipv4]
}

run "reject_private_firewall_address" {
  command = plan
  variables { operator_ipv4 = "192.168.1.1" }
  expect_failures = [var.operator_ipv4]
}

run "reject_invalid_firewall_address" {
  command = plan
  variables { operator_ipv4 = "999.1.1.1" }
  expect_failures = [var.operator_ipv4]
}
