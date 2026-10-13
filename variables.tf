variable "subscription_id" {
  description = "Azure subscription UUID; use the same subscription in Azure CLI."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.subscription_id))
    error_message = "subscription_id must be an Azure subscription UUID."
  }
}

variable "operator_object_id" {
  description = "Human operator's Entra object UUID, granted photo import and Key Vault secret management access."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", var.operator_object_id))
    error_message = "operator_object_id must be your Entra user object UUID, not an email address or application client ID."
  }
}

variable "environment" {
  description = "Environment component of resource names; each environment requires a separate state key."
  type        = string
  default     = "dev"
  nullable    = false

  validation {
    condition     = contains(["dev", "test", "prod"], var.environment)
    error_message = "environment must be dev, test or prod."
  }
}

variable "name_suffix" {
  description = "Stable unique suffix for Storage, SQL and Key Vault; keep it unchanged for the lifetime of this state."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[a-z0-9]{3,8}$", var.name_suffix))
    error_message = "name_suffix must contain 3-8 lowercase letters/digits."
  }
}

variable "location" {
  description = "Region for the resource group, VNet, ACA environment, Blob storage, identity and Key Vault."
  type        = string
  default     = "northeurope"
  nullable    = false

  validation {
    condition     = contains(["northeurope", "francecentral"], var.location)
    error_message = "Use northeurope or francecentral for this initial Products foundation."
  }
}

variable "sql_location" {
  description = "SQL Free offer region. Keep France Central for the existing subscription's free-offer region."
  type        = string
  default     = "francecentral"
  nullable    = false

  validation {
    condition     = can(regex("^[a-z][a-z0-9]+$", var.sql_location))
    error_message = "sql_location must be an Azure region identifier, such as francecentral."
  }
}

variable "sql_admin_password" {
  description = "SQL administrator password; supply through TF_VAR_sql_admin_password, never in tracked files."
  type        = string
  sensitive   = true
  nullable    = false

  validation {
    condition = (
      length(var.sql_admin_password) >= 16 && length(var.sql_admin_password) <= 64 &&
      can(regex("[A-Z]", var.sql_admin_password)) && can(regex("[a-z]", var.sql_admin_password)) &&
      can(regex("[0-9]", var.sql_admin_password)) && can(regex("[^A-Za-z0-9]", var.sql_admin_password)) &&
      !can(regex("[\r\n]", var.sql_admin_password))
    )
    error_message = "Use 16-64 characters with uppercase, lowercase, a digit and a symbol, without line breaks."
  }
}

variable "operator_ipv4" {
  description = "Optional single public IPv4 for local SQL migrations. Null leaves SQL closed; photo import uses Entra RBAC separately."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition = var.operator_ipv4 == null ? true : try(
      can(regex("^[0-9]{1,3}(\\.[0-9]{1,3}){3}$", var.operator_ipv4)) &&
      can(cidrhost("${var.operator_ipv4}/32", 0)) &&
      tonumber(split(".", var.operator_ipv4)[0]) > 0 &&
      tonumber(split(".", var.operator_ipv4)[0]) < 224 &&
      !can(regex("^(10\\.|127\\.|169\\.254\\.|172\\.(1[6-9]|2[0-9]|3[01])\\.|192\\.168\\.)", var.operator_ipv4)),
      false
    )
    error_message = "operator_ipv4 must be one public IPv4, without a CIDR suffix, private/loopback address or Azure-wide 0.0.0.0 rule."
  }
}
