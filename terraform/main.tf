provider "proxmox" {
  endpoint = var.proxmox_url
  username = var.proxmox_username
  password = var.proxmox_password

  insecure = true

  ssh {
    agent    = false
    username = "root"
    password = var.proxmox_password
  }
}
