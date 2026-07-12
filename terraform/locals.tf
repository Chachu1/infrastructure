locals {
  network = {
    bridge  = "vmbr1"
    subnet  = "10.0.0.0/24"
    gateway = "10.0.0.1"
  }

  # LXC templates (on local directory storage)
  lxc_templates = {
    debian = "local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"
  }

  # VM cloud images (auto-updated weekly by cron on Proxmox host)
  vm_images = {
    debian = "local:images/debian-13-generic-amd64.qcow2"
    ubuntu = "local:images/ubuntu-24.04-server-cloudimg-amd64.img"
  }

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
      port   = 3001
    }


    testing-vm = {
      type = "vm"
      distro = "debian"
      vm_id = 301
      cores = 4
      memory = 4096
      disk = 50
      ip = "10.0.0.61/24"    
    }

    # Example VM (uncomment to add a VM service):
    # my-vm = {
    #   type   = "vm"
    #   distro = "ubuntu"    # or "debian" (default)
    #   vm_id  = 300
    #   cores  = 2
    #   memory = 2048
    #   disk   = 50          # minimum 50GB for VMs
    #   ip     = "10.0.0.60/24"
    #   domain = "app.mhlab.me"
    #   port   = 8080
    # }
  }
}
