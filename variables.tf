variable "enable_provisioning" {
  description = "Must be true to create a billable Bare Metal Cloud server."
  type        = bool
  default     = false
}

variable "approve_hourly_costs" {
  description = "Acknowledge estimated US$0.414/hour for host plus default public IP, versus a US$0.50/hour total budget; verify live charges."
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
  description = "ESXi management source CIDRs. Defaults to unrestricted IPv4 access by explicit user choice; restrict for production."
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
