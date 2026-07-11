variable "proxmox_url" {
  description = "Proxmox API endpoint"
  type        = string
}

variable "proxmox_username" {
  description = "Proxmox username (e.g. root@pam)"
  type        = string
}

variable "proxmox_password" {
  description = "Proxmox password"
  type        = string
  sensitive   = true
}

variable "ssh_public_key" {
  description = "SSH public key for VM/LXC access"
  type        = string
}

variable "proxmox_node" {
  description = "Proxmox node name"
  type        = string
  default     = "germany1"
}

variable "template_storage" {
  description = "Storage for LXC templates"
  type        = string
  default     = "local"
}

variable "disk_storage" {
  description = "Storage for LXC rootfs"
  type        = string
  default     = "local"
}

variable "cloudflare_api_token" {
  description = "Cloudflare API token for DNS management"
  type        = string
  sensitive   = true
}

variable "cloudflare_zone_id" {
  description = "Cloudflare zone ID for mhlab.me"
  type        = string
}
