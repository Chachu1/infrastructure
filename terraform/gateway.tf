resource "proxmox_virtual_environment_container" "gateway" {
  node_name = var.proxmox_node
  vm_id     = local.services.gateway.vm_id

  description = "Gateway LXC - Caddy, WireGuard, CoreDNS, nftables"

  initialization {
    hostname = "gateway"

    ip_config {
      ipv4 {
        address = local.services.gateway.ip
        gateway = local.network.gateway
      }
    }

    user_account {
      keys     = [trimspace(var.ssh_public_key)]
      password = var.proxmox_password
    }
  }

  cpu {
    cores = local.services.gateway.cores
  }

  memory {
    dedicated = local.services.gateway.memory
  }

  disk {
    datastore_id = var.disk_storage
    size         = local.services.gateway.disk
  }

  network_interface {
    name   = "eth0"
    bridge = local.network.bridge
  }

  operating_system {
    template_file_id = local.template
    type             = "ubuntu"
  }

  features {
    nesting = true
  }

  started     = true
  startup_order = 1
}
