# Independent Terraform state: run terraform with -chdir=ashburn.
# Never run this config against the Seattle Terraform state.
resource "pnap_ip_block" "esxi_29" {
  count           = var.enable_esxi ? 1 : 0
  location        = "ASH"
  cidr_block_size = "/29"
  ip_version      = "V4"
  description     = "Ashburn ESXi and VCSA public IPv4 /29"

  lifecycle {
    precondition {
      condition     = local.provisioning_approved
      error_message = "Complete Seattle retirement, ESXi image confirmation and Ashburn quote approvals before provisioning."
    }
  }
}

resource "pnap_server" "esxi" {
  count         = var.enable_esxi ? 1 : 0
  hostname      = "esxi-01"
  description   = "Single-host VMware ESXi 8 vSphere evaluation lab in Ashburn"
  type          = var.esxi_type
  location      = "ASH"
  os            = "esxi/esxi80"
  pricing_model = "HOURLY"

  network_type                  = "PUBLIC_AND_PRIVATE"
  delete_ip_blocks              = false
  management_access_allowed_ips = var.management_allowed_cidrs

  network_configuration {
    ip_blocks_configuration {
      configuration_type = "USER_DEFINED"
      ip_blocks {
        server_ip_block {
          id = pnap_ip_block.esxi_29[0].id
        }
      }
    }
  }

  esxi {
    datastore_configuration {
      datastore_name = "datastore1"
    }
  }

  lifecycle {
    precondition {
      condition     = local.provisioning_approved
      error_message = "Ashburn ESXi provisioning blocked pending explicit migration and pricing approvals."
    }
  }
}

resource "pnap_server" "installer" {
  count         = var.enable_installer ? 1 : 0
  hostname      = "vcsa-installer-ash"
  description   = "TEMPORARY Ubuntu VCSA 8 ISO downloader/CLI; retire after successful install"
  type          = var.installer_type
  location      = "ASH"
  os            = "ubuntu/focal"
  pricing_model = "HOURLY"

  network_type             = "PUBLIC_AND_PRIVATE"
  delete_ip_blocks         = true
  install_default_ssh_keys = true

  # Boot-time automation downloads + verifies + mounts the ISO. It never
  # embeds passwords or launches the privileged VCSA deployment itself.
  cloud_init {
    user_data = base64encode(templatefile("${path.module}/cloud-init/bootstrap.sh.tftpl", {
      iso_url    = var.vcsa_iso_url
      iso_sha256 = var.vcsa_iso_sha256
    }))
  }

  lifecycle {
    precondition {
      condition     = local.provisioning_approved
      error_message = "Temporary installer provisioning blocked pending explicit migration and pricing approvals."
    }
  }
}
