locals {
  network = {
    bridge  = "vmbr1"
    subnet  = "10.0.0.0/24"
    gateway = "10.0.0.1"
  }

  template = "local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"

  services = {
    # Gateway - Caddy, WireGuard, CoreDNS, nftables
    gateway = {
      vm_id  = 100
      cores  = 1
      memory = 256
      disk   = 4
      ip     = "10.0.0.10/24"
    }

    uptime-kuma = {
      vm_id  = 251
      cores  = 1
      memory = 1024
      disk   = 10
      ip     = "10.0.0.51/24"
    }
  }
}
