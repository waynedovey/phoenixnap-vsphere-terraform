output "esxi_id" {
  value = try(pnap_server.esxi[0].id, null)
}
output "esxi_public_ip_addresses" {
  value = try(pnap_server.esxi[0].public_ip_addresses, null)
}
output "esxi_management_url" {
  value = try(pnap_server.esxi[0].management_ui_url, null)
}
output "public_ipv4_29_cidr" {
  value = try(pnap_ip_block.esxi_29[0].cidr, null)
}
output "installer_id" {
  value = try(pnap_server.installer[0].id, null)
}
output "installer_public_ip_addresses" {
  description = "Find the server's primary SSH IP from these addresses or PNAP portal."
  value       = try(pnap_server.installer[0].public_ip_addresses, null)
}
output "quoted_esxi_usd_per_hour" {
  value = local.esxi_rate
}
output "quoted_ipv4_29_usd_per_hour" {
  value = local.ip29_rate
}
output "quoted_installer_usd_per_hour" {
  value = local.installer_rate
}
output "quoted_ipv4_31_usd_per_hour" {
  value = local.ip31_rate
}
output "quoted_combined_usd_per_hour" {
  description = "ESXi + /29 + temporary Ubuntu host + estimated default /31, excluding taxes and bandwidth."
  value       = local.quoted_total
}
