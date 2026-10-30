# Quoted rates are account-specific. Fail closed on missing, ambiguous or non-hourly prices.
data "pnap_products" "esxi" {
  count            = var.enable_esxi ? 1 : 0
  product_category = "SERVER"
  product_code     = var.esxi_type
  location         = "ASH"
}

data "pnap_products" "installer" {
  count            = var.enable_installer ? 1 : 0
  product_category = "SERVER"
  product_code     = var.installer_type
  location         = "ASH"
}

data "pnap_products" "public_ip" {
  count            = var.enable_esxi || var.enable_installer ? 1 : 0
  product_category = "PUBLIC_IP"
  location         = "ASH"
}

locals {
  esxi_rates = distinct(flatten([
    for p in (var.enable_esxi ? data.pnap_products.esxi[0].products : []) : [
      for x in p.plans : x.price
      if upper(x.location) == "ASH" && upper(x.pricing_model) == "HOURLY" && upper(x.price_unit) == "HOUR"
    ]
  ]))
  installer_rates = distinct(flatten([
    for p in (var.enable_installer ? data.pnap_products.installer[0].products : []) : [
      for x in p.plans : x.price
      if upper(x.location) == "ASH" && upper(x.pricing_model) == "HOURLY" && upper(x.price_unit) == "HOUR"
    ]
  ]))
  ip29_rates = distinct(flatten([
    for p in (var.enable_esxi || var.enable_installer ? data.pnap_products.public_ip[0].products : []) : [
      for x in p.plans : x.price
      if p.product_code == "range-29" && contains(["ASH", "GLOBAL"], upper(x.location))
      && upper(x.pricing_model) == "HOURLY" && upper(x.price_unit) == "HOUR"
    ]
  ]))
  ip31_rates = distinct(flatten([
    for p in (var.enable_esxi || var.enable_installer ? data.pnap_products.public_ip[0].products : []) : [
      for x in p.plans : x.price
      if p.product_code == "range-31" && contains(["ASH", "GLOBAL"], upper(x.location))
      && upper(x.pricing_model) == "HOURLY" && upper(x.price_unit) == "HOUR"
    ]
  ]))

  esxi_rate      = length(local.esxi_rates) == 1 ? local.esxi_rates[0] : null
  installer_rate = length(local.installer_rates) == 1 ? local.installer_rates[0] : null
  ip29_rate      = length(local.ip29_rates) == 1 ? local.ip29_rates[0] : null
  ip31_rate      = length(local.ip31_rates) == 1 ? local.ip31_rates[0] : null

  rates_known = (
    (!var.enable_esxi || (local.esxi_rate != null && local.ip29_rate != null)) &&
    (!var.enable_installer || (local.installer_rate != null && local.ip31_rate != null))
  )
  quoted_total = local.rates_known ? sum(concat(
    var.enable_esxi ? [local.esxi_rate, local.ip29_rate] : [],
    var.enable_installer ? [local.installer_rate, local.ip31_rate] : []
  )) : null
  approved_quote = local.quoted_total == null ? false : (
    local.quoted_total > 0 && local.quoted_total <= var.maximum_hourly_usd
    && (!var.enable_esxi || (local.esxi_rate > 0 && local.ip29_rate > 0))
    && (!var.enable_installer || (local.installer_rate > 0 && local.ip31_rate > 0))
  )
  provisioning_approved = var.confirm_seattle_retired && var.confirm_esxi_image && var.approve_hourly_costs && local.approved_quote
}
