# Nothing is provisioned until enable_provisioning is explicitly set to true.
resource "pnap_server" "esxi" {
  count = var.enable_provisioning ? 1 : 0

  hostname      = var.hostname
  description   = "Single-host VMware vSphere evaluation lab; vCenter installed separately"
  type          = "s2.c2.large"
  location      = "SEA"
  os            = "esxi/esxi80"
  pricing_model = "HOURLY"

  # This requests a public IPv4 allocation, which can have additional charges.
  network_type = "PUBLIC_AND_PRIVATE"
  network_configuration {
    ip_blocks_configuration {
      configuration_type = "PURCHASE_NEW"
    }
  }

  # Do not open the ESXi management interface to the Internet.
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
      condition     = var.approve_hourly_costs
      error_message = "Explicitly acknowledge hourly server and additional public-IP charges."
    }
  }
}
