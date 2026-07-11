resource "proxmox_lxc" "app" {
  for_each = {
    for name, svc in local.services : name => svc
    if name != "gateway"
  }

  vm_id       = each.value.vm_id
  target_node = var.proxmox_node
  hostname    = each.key
  ostemplate  = local.template
  password    = var.proxmox_password
  unprivileged = true

  cores  = each.value.cores
  memory = each.value.memory

  rootfs {
    storage = var.disk_storage
    size    = "${each.value.disk}G"
  }

  network {
    name   = "eth0"
    bridge = local.network.bridge
    ip     = each.value.ip
    gw     = local.network.gateway
  }

  ssh_public_keys = var.ssh_public_key

  features {
    nesting = true
  }
}
