# Nothing is purchased until enable_provisioning is explicitly true.
# The original /30-backed server MUST be retired first. See REBUILD-29.md.
resource "pnap_ip_block" "lab_public_ipv4" {
  count           = var.enable_provisioning ? 1 : 0
  location        = "SEA"
  cidr_block_size = "/29"
  ip_version      = "V4"
  description     = "Public IPv4 /29 for ESXi and vCenter lab in Seattle"

  lifecycle {
    precondition {
      condition     = var.confirm_previous_server_retired
      error_message = "Retire and verify deletion of the previous ESXi server and its /30 block before buying the /29. See REBUILD-29.md."
    }
    precondition {
      condition     = var.approve_hourly_costs
      error_message = "Set approve_hourly_costs=true only after reviewing the live pricing quote."
    }
    precondition {
      condition     = local.quote_within_budget
      error_message = "Seattle server + one GLOBAL /29 range must have unambiguous live hourly pricing at or below maximum_hourly_usd. No purchase is permitted if the quote fails."
    }
  }
}

resource "pnap_server" "esxi" {
  count = var.enable_provisioning ? 1 : 0

  hostname      = var.hostname
  description   = "Single-host VMware vSphere evaluation lab; vCenter installed separately"
  type          = "s2.c2.large"
  location      = "SEA"
  os            = "esxi/esxi80"
  pricing_model = "HOURLY"

  # This uses the separately purchased /29 instead of buying a default /30.
  network_type     = "PUBLIC_AND_PRIVATE"
  delete_ip_blocks = false
  network_configuration {
    ip_blocks_configuration {
      configuration_type = "USER_DEFINED"
      ip_blocks {
        server_ip_block {
          id = pnap_ip_block.lab_public_ipv4[0].id
        }
      }
    }
  }

  # WARNING: ESXi management HTTPS is open to any IPv4 by user choice.
  management_access_allowed_ips = var.management_allowed_cidrs

  # ESXi is installed by phoenixNAP. This names the initial datastore only;
  # the second NVMe must be checked and configured separately after boot.
  esxi {
    datastore_configuration {
      datastore_name = var.initial_datastore_name
    }
  }

  lifecycle {
    precondition {
      condition     = length(var.management_allowed_cidrs) > 0
      error_message = "Specify at least one trusted management CIDR before provisioning."
    }
    precondition {
      condition     = var.confirm_esxi_image
      error_message = "First confirm with phoenixNAP that esxi/esxi80 deploys the required ESXi 8.0U2 image."
    }
    precondition {
      condition     = var.confirm_previous_server_retired
      error_message = "Destroy the previous /30-backed server before creating the /29-backed replacement."
    }
    precondition {
      condition     = var.approve_hourly_costs
      error_message = "Explicitly acknowledge hourly server and additional public-IP charges."
    }
    precondition {
      condition     = local.quote_within_budget
      error_message = "Live Seattle server + approved GLOBAL /29 range pricing is missing, ambiguous, or exceeds maximum_hourly_usd."
    }
  }
}
