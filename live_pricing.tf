# Account-specific prices read through phoenixNAP Billing API (pnap v0.34.0).
# Provisioning is blocked if the approved /29 SKU is missing or mispriced.
data "pnap_products" "seattle_server" {
  count            = var.enable_provisioning ? 1 : 0
  product_code     = "s2.c2.large"
  product_category = "SERVER"
  location         = "SEA"
}

# The /29 public-IP product is billed as a GLOBAL hourly *range*, not an
# individual address. Omitting location=SEA is intentional.
data "pnap_products" "seattle_public_ip" {
  count            = var.enable_provisioning ? 1 : 0
  product_code     = "range-29"
  product_category = "PUBLIC_IP"
}

locals {
  seattle_server_hourly_rates = distinct(flatten([
    for product in (var.enable_provisioning ? data.pnap_products.seattle_server[0].products : []) : [
      for plan in product.plans : plan.price
      if upper(plan.location) == "SEA"
      && upper(plan.pricing_model) == "HOURLY"
      && upper(plan.price_unit) == "HOUR"
    ]
  ]))

  # User-approved live catalog entry:
  #   product_code=range-29, SKU=W0I2-DIVY-ZJVP, GLOBAL, HOURLY/HOUR.
  # Its 0.028 USD/hour price is for ONE COMPLETE /29 RANGE (eight IPv4
  # addresses), so it must not be multiplied by eight again.
  seattle_public_ipv4_29_hourly_plans = flatten([
    for product in (var.enable_provisioning ? data.pnap_products.seattle_public_ip[0].products : []) : [
      for plan in product.plans : {
        product_code  = product.product_code
        sku           = plan.sku
        location      = plan.location
        pricing_model = plan.pricing_model
        price_unit    = plan.price_unit
        rate          = plan.price
      }
      if product.product_code == "range-29"
      && plan.sku == var.public_ipv4_sku
      && upper(plan.location) == "GLOBAL"
      && upper(plan.pricing_model) == "HOURLY"
      && upper(plan.price_unit) == "HOUR"
    ]
  ])

  seattle_public_ipv4_29_hourly_rates = distinct([
    for plan in local.seattle_public_ipv4_29_hourly_plans : plan.rate
  ])

  quoted_server_hourly_usd          = length(local.seattle_server_hourly_rates) == 1 ? local.seattle_server_hourly_rates[0] : null
  quoted_public_ipv4_29_hourly_usd = length(local.seattle_public_ipv4_29_hourly_rates) == 1 ? local.seattle_public_ipv4_29_hourly_rates[0] : null

  quoted_total_hourly_usd = (
    local.quoted_server_hourly_usd != null && local.quoted_public_ipv4_29_hourly_usd != null
    ? local.quoted_server_hourly_usd + local.quoted_public_ipv4_29_hourly_usd
    : null
  )

  quote_within_budget = local.quoted_total_hourly_usd == null ? false : (
    local.quoted_server_hourly_usd > 0 &&
    local.quoted_public_ipv4_29_hourly_usd > 0 &&
    local.quoted_total_hourly_usd <= var.maximum_hourly_usd
  )
}

output "quoted_server_usd_per_hour" {
  description = "Live hourly Seattle s2.c2.large server price (null if ambiguous)."
  value       = local.quoted_server_hourly_usd
}

output "quoted_public_ipv4_29_usd_per_hour" {
  description = "Live hourly charge for ONE complete /29 IPv4 range (not per address)."
  value       = local.quoted_public_ipv4_29_hourly_usd
}

output "quoted_total_usd_per_hour" {
  description = "Live server + one full /29 range; excludes tax, bandwidth overages, and any additional resources."
  value       = local.quoted_total_hourly_usd
}

output "quoted_public_ip_skus" {
  description = "Matching GLOBAL /29 range SKU(s) from the live PUBLIC_IP billing catalog."
  value       = local.seattle_public_ipv4_29_hourly_plans
}
