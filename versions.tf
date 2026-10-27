terraform {
  required_version = ">= 1.6.0"

  required_providers {
    pnap = {
      source  = "phoenixnap/pnap"
      version = "= 0.34.0"
    }
  }
}

provider "pnap" {
  # Reads PNAP_CLIENT_ID and PNAP_CLIENT_SECRET from the environment.
}
