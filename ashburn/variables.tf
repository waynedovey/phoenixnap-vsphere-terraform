variable "enable_esxi" {
  description = "Create the Ashburn ESXi BMC and its /29 block (off by default)."
  type        = bool
  default     = false
}

variable "enable_installer" {
  description = "Create the temporary Ashburn Ubuntu media/CLI server (off by default)."
  type        = bool
  default     = false
}

variable "confirm_seattle_retired" {
  description = "True only after checking the Seattle BMC server, VM and IP billing have been retired."
  type        = bool
  default     = false
}

variable "confirm_esxi_image" {
  description = "True only after PNAP confirms the requested ESXi 8 image and hardware in Ashburn."
  type        = bool
  default     = false
}

variable "approve_hourly_costs" {
  description = "Explicit approval of the Ashburn live quote and maximum hourly charge."
  type        = bool
  default     = false
}

variable "maximum_hourly_usd" {
  description = "Fail-closed hourly ceiling for enabled ESXi, /29, installer and default /31."
  type        = number
  default     = 1.00
  validation {
    condition     = var.maximum_hourly_usd > 0 && var.maximum_hourly_usd <= 1.00
    error_message = "Maximum hourly budget must be above zero and at most US$1.00."
  }
}

variable "esxi_type" {
  type    = string
  default = "s2.c2.large"
}

variable "installer_type" {
  type    = string
  default = "s0.d1.small"
}

variable "management_allowed_cidrs" {
  description = "ESXi management allowlist. Restrict to trusted /32s before production."
  type        = list(string)
  default     = ["0.0.0.0/0"]
  validation {
    condition     = length(var.management_allowed_cidrs) > 0 && alltrue([for c in var.management_allowed_cidrs : can(cidrhost(c, 0))])
    error_message = "Provide at least one valid management CIDR."
  }
}

variable "vcsa_iso_url" {
  description = "HTTPS location of verified VCSA 8 ISO; never use untrusted installer binaries."
  type        = string
  default     = ""
  validation {
    condition     = var.vcsa_iso_url == "" || startswith(var.vcsa_iso_url, "https://")
    error_message = "ISO source must use HTTPS if provided."
  }
}

variable "vcsa_iso_sha256" {
  description = "Independently vendor-verified ISO SHA-256. Missing value prevents media download."
  type        = string
  default     = ""
  validation {
    condition     = var.vcsa_iso_sha256 == "" || can(regex("^[a-fA-F0-9]{64}$", var.vcsa_iso_sha256))
    error_message = "Provide a 64-hex-character SHA-256 digest or leave blank."
  }
}
