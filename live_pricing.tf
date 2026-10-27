# Read-only, account-specific prices from phoenixNAP Billing API through
# provider 0.34.0. These lookups are only made for an enabled provisioning plan.
data "pnap_products" "seattle_server" {
  count            = var.enable_provisioning ? 1 : 0
  product_code     = "s2.c2.large"
  product_category = "SERVER"
  location         = "SEA"
}

data "pnap_products" "seattle_public_ip" {
  count            = var.enable_provisioning ? 1 : 0
  product_category = "PUBLIC_IP"
  location         = "SEA"
}

locals {
  # The server hourly SKU must resolve to exactly one distinct rate.
  seattle_server_hourly_rates = distinct(flatten([
    for product in (var.enable_provisioning ? data.pnap_products.seattle_server[0].products : []) : [
      for plan in product.plans : plan.price
      if upper(plan.location) == "SEA"
      && upper(plan.pricing_model) == "HOURLY"
      && upper(plan.price_unit) == "HOUR"
    ]
  ]))

  # phoenixNAP bills public IPv4 per *address*, including reserved addresses.
  # The /29 allocation contains eight addresses (five assignable). If the
  # Billing API returns multiple different hourly prices, fail closed and
  # require public_ipv4_sku to disambiguate rather than assuming a rate.
  seattle_public_ip_hourly_plans = flatten([
    for product in (var.enable_provisioning ? data.pnap_products.seattle_public_ip[0].products : []) : [
      for plan in product.plans : {
        product_code = product.product_code
        sku          = plan.sku
        rate         = plan.price
      }
      if upper(plan.location) == "SEA"
      && upper(plan.price_unit) == "HOUR"
      && (var.public_ipv4_sku == null ? true : plan.sku == var.public_ipv4_sku)
    ]
  ])

  seattle_public_ip_hourly_rates = distinct([
    for plan in local.seattle_public_ip_hourly_plans : plan.rate
  ])

  quoted_server_hourly_usd        = length(local.seattle_server_hourly_rates) == 1 ? local.seattle_server_hourly_rates[0] : null
  quoted_ipv4_per_ip_hourly_usd = length(local.seattle_public_ip_hourly_rates) == 1 ? local.seattle_public_ip_hourly_rates[0] : null

  quoted_total_hourly_usd = (
    local.quoted_server_hourly_usd != null && local.quoted_ipv4_per_ip_hourly_usd != null
    ? local.quoted_server_hourly_usd + (8 * local.quoted_ipv4_per_ip_hourly_usd)
    : null
  )

  # Preconditions on *both* billable resources prevent any creation when
  # the API price is unavailable, ambiguous, zero or above the user's cap.
  quote_within_budget = local.quoted_total_hourly_usd == null ? false : (
    local.quoted_server_hourly_usd > 0 &&
    local.quoted_ipv4_per_ip_hourly_usd > 0 &&
    local.quoted_total_hourly_usd <= var.maximum_hourly_usd
  )
}

output "quoted_server_usd_per_hour" {
  description = "Live SEA s2.c2.large hourly price (null if quote is ambiguous)."
  value       = local.quoted_server_hourly_usd
}

output "quoted_ipv4_usd_per_address_hour" {
  description = "Live SEA public-IP hourly unit price (null if ambiguous)."
  value       = local.quoted_ipv4_per_ip_hourly_usd
}

output "quoted_total_usd_per_hour" {
  description = "Live estimate: one server and all eight /29 addresses, excluding tax, bandwidth overages and other extras."
  value       = local.quoted_total_hourly_usd
}

output "quoted_public_ip_skus" {
  description = "Hourly PUBLIC_IP SKUs from the Seattle billing catalog; use to select public_ipv4_sku if the API is ambiguous."
  value       = local.seattle_public_ip_hourly_plans
}
