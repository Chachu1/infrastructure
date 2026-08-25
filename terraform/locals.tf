locals {
  network = {
    bridge  = "vmbr1"
    subnet  = "10.0.0.0/24"
    gateway = "10.0.0.1"
  }

  # LXC templates (on local directory storage)
  lxc_templates = {
    debian = "local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"
    ubuntu = "local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
  }

  # VM template IDs (auto-updated weekly by cron on Proxmox host)
  vm_templates = {
    debian = 9001
    ubuntu = 9002
  }

  services = {
    # Gateway - Caddy, WireGuard, CoreDNS, nftables
    gateway = {
      vm_id  = 100
      cores  = 4
      memory = 4096
      disk   = 4
      ip     = "10.0.0.10/24"
    }

    uptime-kuma = {
      vm_id  = 251
      cores  = 1
      memory = 1024
      disk   = 10
      ip     = "10.0.0.51/24"
      domain = "uptime.mhlab.me"
      port   = 3001
    }

    postgres = {
      type         = "lxc"
      distro       = "ubuntu"
      vm_id        = 252
      cores        = 8
      memory       = 32768
      disk         = 200
      ip           = "10.0.0.20/24"
      internal_dns = "postgres"
    }

    proxmox = {
      type   = "external"
      ip     = "10.0.0.1"
      domain = "proxmox.mhlab.me"
      port   = 8006
      scheme = "https"
    }

    coolify = {
      type   = "vm"
      vm_id  = 300
      cores  = 8
      memory = 8192
      disk   = 100
      ip     = "10.0.0.60/24"
      domain = "coolify.mhlab.me"
      port   = 80
      app_domains = [
        "jobs.mhlab.me",
        "screenshots.mhlab.me",
        "backfill.mhlab.me",
      ]
      # prod-match.mhlab.me moved to review-api LXC (native systemd) during
      # Docker-in-LXC migration - do not re-add here or Caddy gets a duplicate
      # site block.
      wildcard_domain = "*.backend.mhlab.me"
    }

    # App LXCs - 10.0.0.61-69 reserved for application LXCs
    categorizer = {
      vm_id        = 260
      cores        = 2
      memory       = 2048
      disk         = 10
      ip           = "10.0.0.61/24"
      internal_dns = "categorizer"
    }

    review-api = {
      vm_id        = 261
      cores        = 2
      memory       = 2048
      disk         = 10
      ip           = "10.0.0.62/24"
      domain       = "prod-match.mhlab.me"
      port         = 8013
      internal_dns = "review-api"
    }

    # ── Full LXC migration services (PRD_LXC_FULL_MIGRATION) ──────────────
    # LXCs are created WITHOUT a `domain` first (Caddy still routes to Coolify
    # at 10.0.0.60). After the app is deployed + health-checked on the LXC, a
    # follow-up commit moves `domain` here to cut traffic over (PRD §8).

    job-tracker-api = {
      vm_id        = 262
      cores        = 2
      memory       = 2048
      disk         = 10
      ip           = "10.0.0.63/24"
      port         = 8001
      internal_dns = "job-tracker-api"
    }

    dashboard-api = {
      vm_id        = 263
      cores        = 2
      memory       = 2048
      disk         = 10
      ip           = "10.0.0.64/24"
      port         = 8002
      internal_dns = "dashboard-api"
    }

    transform-worker = {
      vm_id        = 264
      cores        = 2
      memory       = 2048
      disk         = 10
      ip           = "10.0.0.65/24"
      internal_dns = "transform-worker"
    }

    backfill-ui = {
      vm_id        = 265
      cores        = 2
      memory       = 2048
      disk         = 10
      ip           = "10.0.0.66/24"
      port         = 8012
      internal_dns = "backfill-ui"
    }

    screenshot-service = {
      vm_id        = 266
      cores        = 2
      memory       = 4096
      disk         = 12
      ip           = "10.0.0.67/24"
      port         = 8010
      internal_dns = "screenshot-service"
    }

    local-scraper = {
      vm_id        = 267
      cores        = 2
      memory       = 4096
      disk         = 12
      ip           = "10.0.0.68/24"
      internal_dns = "local-scraper"
    }

    enrichment-worker = {
      vm_id        = 268
      cores        = 2
      memory       = 4096
      disk         = 12
      ip           = "10.0.0.69/24"
      internal_dns = "enrichment-worker"
    }

    frontend = {
      vm_id        = 269
      cores        = 2
      memory       = 2048
      disk         = 12
      ip           = "10.0.0.70/24"
      port         = 3000
      internal_dns = "frontend"
    }

    pg-backup = {
      vm_id        = 270
      cores        = 1
      memory       = 1024
      disk         = 10
      ip           = "10.0.0.71/24"
      internal_dns = "pg-backup"
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
