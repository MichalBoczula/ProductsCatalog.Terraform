provider "azurerm" {
  subscription_id = var.subscription_id
  use_cli         = true

  resource_provider_registrations = "none"
  resource_providers_to_register = [
    "Microsoft.App",
    "Microsoft.KeyVault",
    "Microsoft.ManagedIdentity",
    "Microsoft.Network",
    "Microsoft.Sql",
    "Microsoft.Storage",
  ]
  storage_use_azuread = true

  features {
    key_vault {
      # This first environment is disposable; destroy purges its vault/secrets.
      purge_soft_delete_on_destroy    = true
      recover_soft_deleted_key_vaults = false
    }
  }
}

provider "azapi" {
  subscription_id = var.subscription_id
  use_cli         = true
}

data "azurerm_client_config" "current" {}
