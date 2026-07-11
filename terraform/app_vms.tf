resource "proxmox_virtual_environment_container" "app" {
  for_each = {
    for name, svc in local.services : name => svc
    if name != "gateway"
  }

  node_name = var.proxmox_node
  vm_id     = each.value.vm_id

  initialization {
    hostname = each.key

    ip_config {
      ipv4 {
        address = each.value.ip
        gateway = local.network.gateway
      }
    }

    user_account {
      keys     = [trimspace(var.ssh_public_key)]
      password = var.proxmox_password
    }
  }

  cpu {
    cores = each.value.cores
  }

  memory {
    dedicated = each.value.memory
  }

  disk {
    datastore_id = var.disk_storage
    size         = each.value.disk
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

  started = true
}
