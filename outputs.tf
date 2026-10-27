output "esxi_server_id" {
  description = "Bare Metal Cloud server ID (null while disabled)."
  value       = try(pnap_server.esxi[0].id, null)
}

output "esxi_public_ip" {
  description = "First public management IP (null while disabled or unassigned)."
  value       = try(pnap_server.esxi[0].public_ip_addresses[0], null)
}

output "esxi_management_url" {
  description = "ESXi Host Client URL (null while disabled)."
  value       = try(pnap_server.esxi[0].management_ui_url, null)
}
