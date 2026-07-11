# Proxmox provider configuration
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

# Cloudflare provider configuration
provider "cloudflare" {
  api_token = var.cloudflare_api_token
}
