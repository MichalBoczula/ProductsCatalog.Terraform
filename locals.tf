locals {
  workload = "ecommercestore-products"
  prefix   = "${local.workload}-${var.environment}"

  names = {
    resource_group     = "rg-${local.prefix}"
    virtual_network    = "vnet-${local.prefix}"
    aca_environment    = "cae-${local.prefix}"
    aca_managed_group  = "rg-${local.prefix}-aca-managed"
    products_identity  = "id-${local.prefix}"
    products_app       = "ca-${local.prefix}"
    sql_server         = "sql-${local.prefix}-${var.name_suffix}"
    key_vault          = "kv-ecp-${var.environment}-${var.name_suffix}"
    storage_account    = "stecproducts${var.environment}${var.name_suffix}"
    photos_container   = "photos"
    products_database  = "products"
    sql_connection_key = "products-sql-connection"
  }

  tags = {
    project     = "EcommerceStore"
    component   = "Products"
    environment = var.environment
    managed_by  = "Terraform"
  }
}
