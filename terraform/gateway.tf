resource "proxmox_lxc" "gateway" {
  vm_id      = local.services.gateway.vm_id
  target_node = var.proxmox_node
  hostname   = "gateway"
  ostemplate = local.template
  password   = var.proxmox_password
  unprivileged = true

  cores  = local.services.gateway.cores
  memory = local.services.gateway.memory

  rootfs {
    storage = var.disk_storage
    size    = "${local.services.gateway.disk}G"
  }

  network {
    name   = "eth0"
    bridge = local.network.bridge
    ip     = local.services.gateway.ip
    gw     = local.network.gateway
  }

  ssh_public_keys = var.ssh_public_key

  features {
    nesting = true
  }

  startup = "order=1"
}
