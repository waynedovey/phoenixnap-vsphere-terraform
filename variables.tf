variable "enable_provisioning" {
  description = "Must be true to create a billable Bare Metal Cloud server."
  type        = bool
  default     = false
}

variable "approve_hourly_costs" {
  description = "Acknowledge US$0.40/hour quote plus any additional IP/bandwidth/license costs."
  type        = bool
  default     = false
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
  description = "Your fixed public source IPs, e.g. [\"203.0.113.10/32\"]. Never use 0.0.0.0/0."
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for cidr in var.management_allowed_cidrs :
      can(cidrhost(cidr, 0)) && cidr != "0.0.0.0/0" && cidr != "::/0"
    ])
    error_message = "Every allowlist entry must be a valid, non-global CIDR."
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
