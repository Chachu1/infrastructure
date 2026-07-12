# Proxmox Infrastructure — Design Document

> GitHub-driven infrastructure provisioning and configuration for a Hetzner bare-metal
> Proxmox server running services behind a single public IP.

---

## Table of Contents

1. [Overview](#overview)
2. [Architecture](#architecture)
3. [Technology Decisions](#technology-decisions)
4. [Prerequisites](#prerequisites)
5. [Repository Structure](#repository-structure)
6. [Phase 1: Self-Hosted GitHub Actions Runner](#phase-1-self-hosted-github-actions-runner)
7. [Phase 2: Terraform — Infrastructure Provisioning](#phase-2-terraform--infrastructure-provisioning)
8. [Phase 3: Ansible — Configuration Management](#phase-3-ansible--configuration-management)
9. [Phase 4: GitHub Actions — CI/CD Workflows](#phase-4-github-actions--cicd-workflows)
10. [Network Design](#network-design)
11. [Adding a New Service](#adding-a-new-service)
12. [Secrets Management](#secrets-management)
13. [Troubleshooting](#troubleshooting)

---

## Overview

### Problem

Running a Proxmox host on Hetzner with a single public IP address and multiple services.
Need a way to:

- Provision VMs and LXCs declaratively
- Configure networking, reverse proxy, VPN, and DNS
- Have all changes reviewed and deployed through Git

### Solution

A fully Git-driven workflow using three tools:

| Tool | Responsibility |
|------|---------------|
| **Terraform** | Infrastructure provisioning (what exists) |
| **Ansible** | Configuration management (how it's set up) |
| **GitHub Actions** | CI/CD pipeline (when and how to deploy) |

Every change to infrastructure starts as a Git branch, gets reviewed via a PR with a
`terraform plan` diff, and deploys automatically on merge to `main`.

---

## Architecture

```
Internet
   │
   │  Single public IP (Hetzner)
   │
┌──┴──────────────────────────────────────────────────────┐
│  Proxmox Host (Hetzner bare metal)                      │
│                                                         │
│  vmbr0 (public bridge)                                  │
│    └─ Gateway LXC (10.0.0.1)                            │
│        ├── Caddy (reverse proxy, TLS termination)       │
│        ├── WireGuard (site-to-site VPN)                 │
│        ├── CoreDNS (internal DNS)                       │
│        └── nftables (firewall, NAT, forwarding)         │
│                                                         │
│  vmbr1 (private bridge: 10.0.0.0/24)                   │
│    ├─ uptime-kuma        (10.0.0.51)                    │
│    ├─ ...                 (10.0.0.xx)                    │
│    └─ github-runner       (on vmbr0, DHCP)               │
│                                                         │
│  WireGuard tunnel (10.10.0.0/24)                        │
│    ├─ laptop              (10.10.0.2)                    │
│    └─ phone               (10.10.0.3)                    │
└─────────────────────────────────────────────────────────┘
```

### Traffic flow

1. Request hits Hetzner public IP on port 80/443
2. Gateway LXC receives it, nftables allows it through
3. Caddy terminates TLS, reads the domain name, reverse-proxies to the correct internal VM
4. Internal VM responds, response flows back through the gateway

### Deployment flow

1. Developer creates a branch, edits Terraform/Ansible/Config files
2. Opens a PR → GitHub Actions runs `terraform plan`, posts diff as PR comment
3. Review and merge to `main`
4. GitHub Actions runs `terraform apply` → provisions infrastructure
5. GitHub Actions runs `ansible-playbook` → configures everything
6. New service is live

---

## Technology Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Provisioning | Terraform | Declarative, stateful, Proxmox provider is mature |
| Configuration | Ansible | Agentless, SSH-based, huge role ecosystem |
| CI/CD | GitHub Actions | Git-native, self-hosted runner avoids inbound access |
| State backend | Terraform Cloud | Managed state, locking, free tier is sufficient |
| Gateway OS | Debian 12 | systemd + apt + massive ecosystem |
| Reverse proxy | Caddy | Auto-TLS, simple config, HTTP/3 support |
| VPN | WireGuard | Kernel-native, fast, simple config |
| DNS | CoreDNS | Lightweight, plugin-based, easy template integration |
| Firewall | nftables | Modern Linux native, replaces iptables |
| DNS provider | Cloudflare | Proxied A records, managed by Terraform |

---

## Prerequisites

- [x] Hetzner bare-metal server with Proxmox installed
- [x] One public IP address assigned
- [x] Proxmox API accessible (for Terraform)
- [ ] Debian 12 template uploaded to Proxmox local storage
- [x] GitHub account with a repository created
- [ ] Terraform Cloud account (free tier)
- [x] Cloudflare account (for DNS challenge)
- [x] Domain name (`mhlab.me`) pointed at the Hetzner public IP

### Proxmox host setup (manual, one-time)

Before anything automated, configure the private bridge on the Proxmox host:

```bash
# /etc/network/interfaces
# ... existing vmbr0 config ...

auto vmbr1
iface vmbr1 inet static
    address 10.0.0.1/24
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    post-up   iptables -t nat -A POSTROUTING -s '10.0.0.0/24' -o vmbr0 -j MASQUERADE
    post-down iptables -t nat -D POSTROUTING -s '10.0.0.0/24' -o vmbr0 -j MASQUERADE
```

```bash
# Enable IP forwarding on host
echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.d/99-forwarding.conf
sysctl -p /etc/sysctl.d/99-forwarding.conf

# DNAT: forward ports 80, 443, 51820 to gateway LXC
iptables -t nat -A PREROUTING -i vmbr0 -p tcp --dport 80 -d <PUBLIC_IP> -j DNAT --to-destination 10.0.0.1:80
iptables -t nat -A PREROUTING -i vmbr0 -p tcp --dport 443 -d <PUBLIC_IP> -j DNAT --to-destination 10.0.0.1:443
iptables -t nat -A PREROUTING -i vmbr0 -p udp --dport 51820 -d <PUBLIC_IP> -j DNAT --to-destination 10.0.0.1:51820
```

---

## Repository Structure

```
infrastructure/
│
├── .github/
│   └── workflows/
│       ├── plan.yml                # PR → terraform plan (preview)
│       ├── apply.yml               # merge to main → deploy
│       └── destroy.yml             # manual trigger → tear down
│
├── terraform/
│   ├── terraform.tf                # Terraform Cloud backend + provider versions
│   ├── main.tf                     # Proxmox provider config
│   ├── variables.tf                # All input variables
│   ├── network.tf                  # Firewall rules
│   ├── gateway.tf                  # Gateway LXC
│   ├── app_vms.tf                  # Application VMs/LXCs
│   ├── outputs.tf                  # Ansible inventory generation
│   └── locals.tf                   # Service definitions
│
├── ansible/
│   ├── ansible.cfg
│   ├── inventory/
│   │   └── hosts.yml               # Generated from Terraform outputs
│   ├── playbooks/
│   │   ├── site.yml                # Master playbook (runs everything)
│   │   ├── gateway.yml             # Gateway only
│   │   └── apps.yml                # Application VMs only
│   ├── roles/
│   │   ├── common/                 # Base: users, ssh, packages, hardening
│   │   ├── gateway_network/        # nftables, NAT, IP forwarding
│   │   ├── caddy/                  # Reverse proxy
│   │   ├── wireguard/              # VPN tunnels
│   │   ├── dns/                    # Internal DNS
│   │   └── docker_host/            # Docker for app VMs that need it
│   └── group_vars/
│       ├── all.yml                 # Shared variables
│       ├── gateway.yml             # Gateway config (Caddy hosts, WG peers, DNS)
│       └── apps.yml                # App VM config
│
├── configs/
│   ├── caddy/
│   │   └── Caddyfile.j2
│   ├── wireguard/
│   │   └── wg0.conf.j2
│   └── dns/
│       └── Corefile.j2
│
└── docs/
    └── infrastructure-design.md    # This document
```

---

## Phase 1: Self-Hosted GitHub Actions Runner

The runner is the bootstrap — it runs on your network so GitHub Actions can reach
Proxmox and your VMs over the private network. No inbound ports needed (it polls GitHub).

### Create the runner LXC (manual)

```bash
# On Proxmox host
pct create 200 local:vztmpl/debian-12-standard.tar.zst \
  --hostname github-runner \
  --memory 1024 \
  --cores 2 \
  --rootfs local-lvm:10 \
  --net0 name=eth0,bridge=vmbr0,ip=dhcp

pct start 200
pct enter 200
```

### Install the runner

```bash
# Inside the runner LXC
apt update && apt install -y curl git sudo jq unzip

# Create runner user
useradd -m -s /bin/bash runner
usermod -aG sudo runner

# Download GitHub Actions runner
mkdir -p /home/runner/actions-runner && cd /home/runner/actions-runner
curl -o actions-runner-linux-x64.tar.gz -L \
  https://github.com/actions/runner/releases/download/v2.319.1/actions-runner-linux-x64-2.319.1.tar.gz
tar xzf actions-runner-linux-x64.tar.gz

# Configure — get token from:
# GitHub → Repo → Settings → Actions → Runners → New self-hosted runner
chown -R runner:runner /home/runner
su - runner
cd actions-runner
./config.sh \
  --url https://github.com/Chachu1/infrastructure \
  --token <TOKEN> \
  --labels proxmox

# Install as a systemd service
sudo ./svc.sh install runner
sudo ./svc.sh start
```

### Install Terraform and Ansible on the runner

```bash
# Terraform
curl -fsSL https://releases.hashicorp.com/terraform/1.7.5/terraform_1.7.5_linux_amd64.zip \
  -o /tmp/tf.zip
unzip /tmp/tf.zip -d /usr/local/bin/
rm /tmp/tf.zip

# Ansible
apt install -y ansible python3-pip
pip install proxmoxer requests

# Generate SSH key for Ansible to reach VMs
su - runner
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ""
cat ~/.ssh/id_ed25519.pub
# ↑ Add this as a GitHub secret: SSH_PUBLIC_KEY
# ↑ Also store the private key as: SSH_PRIVATE_KEY
```

---

## Phase 2: Terraform — Infrastructure Provisioning

### terraform/terraform.tf — Backend and providers

```hcl
terraform {
  cloud {
    organization = "your-org-name"

    workspaces {
      name = "proxmox-infra"
    }
  }

  required_version = ">= 1.7.0"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.62"
    }
  }
}
```

### terraform/main.tf — Provider config

```hcl
provider "proxmox" {
  endpoint = var.proxmox_url
  username = var.proxmox_username
  password = var.proxmox_password

  insecure = true  # Self-signed cert on Proxmox

  ssh {
    agent    = false
    username = "root"
    password = var.proxmox_password
  }
}
```

### terraform/locals.tf — Service definitions

Edit this file to add/remove services. This is the single source of truth for what
infrastructure exists.

```hcl
locals {
  services = {
    # --- Utilities ---
    uptime-kuma = {
      cores   = 1
      memory  = 1024       # MB
      disk    = 10         # GB
      ip_last = 51         # → 10.0.0.51
      type    = "lxc"
    }

    # Add more services here...
    # Convention:
    #   10.0.0.1     = gateway
    #   10.0.0.11-19 = web applications
    #   10.0.0.20-29 = databases
    #   10.0.0.30-39 = monitoring
    #   10.0.0.40-49 = storage / infrastructure
    #   10.0.0.50-59 = utilities
    #   10.0.0.60-69 = misc
    #   10.0.0.100+  = reserved
  }
}
```

---

## Network Design

### IP address allocation

| Range | Purpose |
|-------|---------|
| `10.0.0.1` | Gateway LXC |
| `10.0.0.11–19` | Web applications |
| `10.0.0.20–29` | Databases |
| `10.0.0.30–39` | Monitoring stack |
| `10.0.0.40–49` | Infrastructure services |
| `10.0.0.50–59` | Utilities |
| `10.0.0.60–69` | Misc / experimental |
| `10.0.0.100+` | Reserved for future |
| `10.10.0.1` | WireGuard gateway |
| `10.10.0.2–99` | WireGuard peers (laptops, phones) |

### Port allocation (public)

| Port | Protocol | Destination | Service |
|------|----------|-------------|---------|
| 22 | TCP | Proxmox host | SSH (for emergency) |
| 80 | TCP | Gateway → Caddy | HTTP (redirects to HTTPS) |
| 443 | TCP | Gateway → Caddy | HTTPS (all web services) |
| 51820 | UDP | Gateway → WireGuard | VPN |

### DNS architecture

- **Public DNS:** Cloudflare — points `*.mhlab.me` to Hetzner public IP
- **Internal DNS:** CoreDNS on gateway — resolves `*.internal.mhlab.me` to `10.0.0.x`
- **All VMs** use `10.0.0.1` as their DNS resolver

---

## Adding a New Service

Each service is defined in `terraform/locals.tf` with a `type` field (`lxc` or `vm`)
and an optional `distro` field (`debian` or `ubuntu`).

### Adding an LXC container

Example: adding a service called `blog` on IP `10.0.0.15` with port `8080`.

#### Step 1 — Create a branch

```bash
git checkout -b add-blog
```

#### Step 2 — Add the service to Terraform

Edit `terraform/locals.tf`:

```hcl
blog = {
  # type defaults to "lxc", distro defaults to "debian"
  vm_id  = 252
  cores  = 1
  memory = 1024
  disk   = 10
  ip     = "10.0.0.15/24"
  domain = "blog.mhlab.me"
  port   = 8080
}
```

#### Step 3 — Open a PR, review, merge

GitHub Actions handles everything automatically:

1. **Terraform** creates the LXC + Cloudflare DNS A record (proxied)
2. **CI script** generates `gateway_services.yml` from Terraform output
3. **Ansible** configures Caddy reverse proxy with auto-TLS and CoreDNS internal record

No manual Ansible config needed — `caddy_hosts` and `dns_records` are derived from
the `domain` and `port` fields in `locals.tf`.

### Adding a VM (cloud-init)

```hcl
my-vm = {
  type   = "vm"
  distro = "ubuntu"    # or "debian" (default)
  vm_id  = 300
  cores  = 2
  memory = 2048
  disk   = 50          # minimum 50GB for VMs
  ip     = "10.0.0.60/24"
  domain = "app.mhlab.me"
  port   = 8080
}
```

VM defaults: q35 machine, seabios BIOS, virtio-scsi disk, virtio NIC, cloud-init with
SSH key, qemu-guest-agent. Cloud images (Debian 13, Ubuntu 24.04) are auto-updated
weekly on the Proxmox host via a systemd timer.

### Available distros

| `distro` | LXC template | VM cloud image |
|----------|-------------|----------------|
| `debian` | Debian 12 (Bookworm) | Debian 13 (Trixie) |
| `ubuntu` | — | Ubuntu 24.04 (Noble) |

---

## Secrets Management

### GitHub Secrets (Settings → Secrets → Actions)

| Secret | Description |
|--------|-------------|
| `PROXMOX_URL` | `https://<proxmox-host>:8006` |
| `PROXMOX_USER` | Proxmox username (e.g., `root@pam`) |
| `PROXMOX_PASS` | Proxmox password |
| `SSH_PUBLIC_KEY` | Public key for VM access |
| `SSH_PRIVATE_KEY` | Private key (on the runner, stored as file) |
| `TF_API_TOKEN` | Terraform Cloud API token |

### Ansible Vault (for application secrets)

```bash
ansible-vault create ansible/group_vars/all/vault.yml
```

Reference vault variables in playbooks:

```yaml
cloudflare_api_token: "{{ vault_cloudflare_api_token }}"
```

---

## Troubleshooting

### Common issues

#### "Connection refused" to Proxmox API from GitHub Actions

- Ensure the self-hosted runner can reach Proxmox on port 8006
- Check `PROXMOX_URL` includes `https://` and port

#### LXC won't start after Terraform creates it

```bash
pct status <vmid>
pct enter <vmid>
journalctl -xe
```

#### Ansible can't SSH into new VMs

- Wait for cloud-init to finish (adds the SSH key)
- Verify the SSH key matches

#### Caddy can't get TLS certificates

- Ensure port 80 is open and forwarded to the gateway (HTTP-01 challenge)
- Cloudflare proxy must be enabled (grey cloud) for the domain
- Check Caddy logs: `journalctl -u caddy -f`

#### Cloudflare 522 (origin timeout)

- Check WireGuard `AllowedIPs` is NOT `0.0.0.0/0` — it should be `192.168.12.0/24`
- `AllowedIPs = 0.0.0.0/0` routes reply packets through the VPN tunnel, breaking responses
- Verify: `grep AllowedIPs /etc/wireguard/wg0.conf`

### Emergency access

1. **Hetzner Robot panel** → KVM-over-IP (LARA)
2. **Proxmox host SSH** → port 22 forwarded directly
3. **Rescue system** → Hetzner rescue boot

### Useful commands

```bash
# On Proxmox host
pct list
pct status <vmid>
pct enter <vmid>

# On gateway
systemctl status caddy
systemctl status wg-quick@wg0
systemctl status coredns
nft list ruleset
wg show

# From runner
terraform plan
terraform apply
ansible all -m ping
ansible-playbook ansible/playbooks/site.yml
```
