resource "proxmox_virtual_environment_file" "cloud_init" {
  content_type = "snippets"
  datastore_id = "local"
  node_name    = var.proxmox_node

  source_raw {
    data = templatefile("${path.module}/cloud-init.yml", {
      ssh_public_key   = trimspace(var.ssh_public_key)
      proxmox_password = var.proxmox_password
    })
    file_name = "cloud-init-app.yml"
  }
}

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

  clone {
    vm_id = local.vm_templates[try(each.value.distro, "debian")]
    full  = true
  }

  disk {
    datastore_id = var.vm_disk_storage
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
    datastore_id = var.vm_disk_storage

    ip_config {
      ipv4 {
        address = each.value.ip
        gateway = split("/", local.services.gateway.ip)[0]
      }
    }

    user_data_file_id = proxmox_virtual_environment_file.cloud_init.id
  }

  operating_system {
    type = "l26"
  }

  agent {
    enabled = true
  }

  timeout_clone = 600

  stop_on_destroy = true

  started = true
}
