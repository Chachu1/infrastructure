terraform {
  cloud {
    organization = "Chachu1"

    workspaces {
      name = "proxmox-infra"
    }
  }

  required_version = ">= 1.7.0"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.62"
    }
  }
}
