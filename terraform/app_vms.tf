resource "proxmox_virtual_environment_vm" "app" {
  for_each = {
    for name, svc in local.services : name => svc
    if try(svc.type, "lxc") == "vm"
  }

  node_name = var.proxmox_node
  vm_id     = each.value.vm_id
  name      = each.key

  machine = "q35"
  bios    = "seabios"

  cpu {
    cores = each.value.cores
    type  = "host"
  }

  memory {
    dedicated = each.value.memory
  }

  disk {
    datastore_id = var.vm_disk_storage
    file_id      = local.vm_images[try(each.value.distro, "debian")]
    interface    = "scsi0"
    iothread     = true
    discard      = "on"
    size         = max(each.value.disk, 50)
  }

  scsi_hardware = "virtio-scsi-single"

  network_device {
    bridge = local.network.bridge
    model  = "virtio"
  }

  initialization {
    ip_config {
      ipv4 {
        address = each.value.ip
        gateway = local.network.gateway
      }
    }

    user_account {
      username = "root"
      keys     = [trimspace(var.ssh_public_key)]
      password = var.proxmox_password
    }
  }

  operating_system {
    type = "l26"
  }

  agent {
    enabled = true
  }

  started = true
}
