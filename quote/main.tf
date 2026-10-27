# Pricing-only configuration. It declares NO managed resources and can
# never create, destroy, or alter the running ESXi host or IP allocations.
terraform {
  required_version = ">= 1.6.0"

  required_providers {
    pnap = {
      source  = "phoenixnap/pnap"
      version = "= 0.34.0"
    }
  }
}

provider "pnap" {}

# Keep the proven Seattle server filter for a comparable live price.
data "pnap_products" "seattle_server" {
  product_code     = "s2.c2.large"
  product_category = "SERVER"
  location         = "SEA"
}

# Do NOT filter by SEA here. phoenixNAP may publish IP prices under
# GLOBAL, a different price unit, or a different pricing model.
# We need the exact API catalog before selecting the correct public-IP SKU.
data "pnap_products" "public_ip_catalog" {
  product_category = "PUBLIC_IP"
}

output "seattle_server_plans" {
  description = "Live server price plans (not billed by this configuration)."
  value = flatten([
    for product in data.pnap_products.seattle_server.products : [
      for plan in product.plans : {
        product_code  = product.product_code
        sku           = plan.sku
        description   = plan.sku_description
        location      = plan.location
        pricing_model = plan.pricing_model
        price_unit    = plan.price_unit
        price         = plan.price
      }
    ]
  ])
}

output "public_ip_catalog" {
  description = "Raw live PUBLIC_IP SKU/price plans across locations, including GLOBAL; no allocation is purchased."
  value = flatten([
    for product in data.pnap_products.public_ip_catalog.products : [
      for plan in product.plans : {
        product_code  = product.product_code
        sku           = plan.sku
        description   = plan.sku_description
        location      = plan.location
        pricing_model = plan.pricing_model
        price_unit    = plan.price_unit
        price         = plan.price
      }
    ]
  ])
}
