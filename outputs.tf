output "esxi_server_id" {
  description = "Bare Metal Cloud server ID (null while disabled)."
  value       = try(pnap_server.esxi[0].id, null)
}

output "esxi_public_ip" {
  description = "Public management IP (null while disabled)."
  value       = try(sort(tolist(pnap_server.esxi[0].public_ip_addresses))[0], null)
}

output "esxi_management_url" {
  description = "ESXi Host Client URL (null while disabled)."
  value       = try(pnap_server.esxi[0].management_ui_url, null)
}

output "seattle_public_ipv4_cidr" {
  description = "New /29 block; identify an unused assignable guest address from phoenixNAP before configuring vCenter."
  value       = try(pnap_ip_block.lab_public_ipv4[0].cidr, null)
}
