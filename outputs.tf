output "esxi_server_id" {
  description = "Bare Metal Cloud server ID (null while disabled)."
  value       = try(pnap_server.esxi[0].id, null)
}

output "esxi_public_ip" {
  description = "Public management IP (null while disabled)."
  value       = try(pnap_server.esxi[0].primary_ip_address, null)
}

output "esxi_management_url" {
  description = "ESXi Host Client URL (null while disabled)."
  value       = try(pnap_server.esxi[0].management_ui_url, null)
}
