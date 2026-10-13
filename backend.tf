terraform {
  # Reuse the independently managed state account with a Products-only blob key.
  # Supply storage_account_name/container_name/key using backend.hcl at init.
  backend "azurerm" {
    use_cli          = true
    use_azuread_auth = true
  }
}
