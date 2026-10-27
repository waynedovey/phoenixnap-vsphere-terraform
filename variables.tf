variable "enable_provisioning" {
  description = "Must be true to create a billable Bare Metal Cloud server."
  type        = bool
  default     = false
}

variable "approve_hourly_costs" {
  description = "Approve the account-specific live hourly quote, including all eight /29 public IPv4 addresses."
  type        = bool
  default     = false
}

variable "confirm_previous_server_retired" {
  description = "Set true only after destroying the old server and verifying its former /30 IP allocation has been released."
  type        = bool
  default     = false
}

variable "maximum_hourly_usd" {
  description = "Hard precondition for server plus /29 IPv4 block hourly rate; may not exceed the agreed US$0.50/hour."
  type        = number
  default     = 0.50

  validation {
    condition     = var.maximum_hourly_usd > 0 && var.maximum_hourly_usd <= 0.50
    error_message = "The maximum may be reduced but cannot exceed US$0.50/hour."
  }
}

variable "public_ipv4_sku" {
  description = "Optional exact Seattle public IPv4 billing SKU when more than one hourly IP rate is returned; leave null when unambiguous."
  type        = string
  default     = null
}

variable "confirm_esxi_image" {
  description = "Set true only after confirming esxi/esxi80 resolves to the requested ESXi 8.0U2 build."
  type        = bool
  default     = false
}

variable "hostname" {
  description = "Bare-metal ESXi host name."
  type        = string
  default     = "esxi-01"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,61}[a-z0-9]$", var.hostname))
    error_message = "Use a lowercase hostname of 2-63 characters, beginning with a letter and ending with a letter/digit."
  }
}

variable "management_allowed_cidrs" {
  description = "Source CIDRs allowed to reach ESXi management HTTPS; unrestricted 0.0.0.0/0 is the user's lab choice."
  type        = list(string)
  default     = ["0.0.0.0/0"]

  validation {
    condition = alltrue([
      for cidr in var.management_allowed_cidrs :
      can(cidrhost(cidr, 0))
    ])
    error_message = "Every management access entry must be a valid CIDR."
  }
}

variable "initial_datastore_name" {
  description = "Initial VMFS datastore created by phoenixNAP. A second disk requires separate post-boot setup."
  type        = string
  default     = "datastore1"

  validation {
    condition     = can(regex("^[A-Za-z0-9]{1,42}$", var.initial_datastore_name))
    error_message = "Datastore name must contain 1-42 alphanumeric characters."
  }
}
