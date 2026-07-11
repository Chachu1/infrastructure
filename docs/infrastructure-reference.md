# Infrastructure Reference

**Last updated:** 2026-07-11
**Proxmox host:** germany1 (168.119.81.167)
**Domain:** mhlab.me

---

## Architecture Overview

```
Internet
   │
   │  Public IP: 168.119.81.167
   │
┌──┴──────────────────────────────────────────────────────┐
│  Proxmox Host (germany1)                                │
│                                                         │
│  eno1 (public)                                          │
│    └─ DNAT → 10.0.0.10 (ports 80, 443)                 │
│                                                         │
│  vmbr1 (private: 10.0.0.0/24)                          │
│    ├─ gateway       (10.0.0.10) — Caddy, CoreDNS,      │
│    │                            nftables, WireGuard     │
│    ├─ uptime-kuma   (10.0.0.51) — monitoring           │
│    └─ github-runner (10.0.0.2)  — CI/CD                │
│                                                         │
│  WireGuard client → home network (192.168.12.0/24)      │
│    └─ gateway IP: 192.168.12.2                          │
└─────────────────────────────────────────────────────────┘
```

---

## Network Design

### Subnets

|       Subnet        |              Purpose              |
|---------------------|-----------------------------------|
|  `10.0.0.0/24`      |  Proxmox private network (vmbr1)  |
|  `192.168.12.0/24`  |  Home network (via WireGuard)     |

### IP Allocation


|       IP        |      Host       |                Role                |
|-----------------|-----------------|------------------------------------|
| `10.0.0.1`      |  vmbr1 bridge   |  Proxmox host (gateway for VMs)    |
| `10.0.0.2`      |  github-runner  |  GitHub Actions self-hosted runner |
| `10.0.0.10`     |  gateway        |  Reverse proxy, DNS, firewall, VPN |
| `10.0.0.51`     |  uptime-kuma    |  Monitoring dashboard              |
| `10.0.0.11-19`  |  —              |  Reserved for web applications     |
| `10.0.0.20-29`  |  —              |  Reserved for databases            |
| `10.0.0.30-39`  |  —              |  Reserved for monitoring           |
| `10.0.0.50-59`  |  —              |  Reserved for utilities            |



### Ports (Public)


| Port   |  Protocol  |   Destination   |                   Service                  |
|--------|------------|-----------------|--------------------------------------------|
| 80     |  TCP       |  10.0.0.10:80   |  Caddy (HTTP → HTTPS redirect)             |
| 443    |  TCP       |  10.0.0.10:443  |  Caddy (HTTPS)                             |
| 51820  |  UDP       |  —              |  WireGuard (currently unused, client mode) |



---

## Current Services


|   Service    |     IP      |   Port    |               URL              |
|--------------|-------------|-----------|--------------------------------|
| Caddy        |  10.0.0.10  |  80, 443  |  https://uptime.mhlab.me       |
| CoreDNS      |  10.0.0.10  |  53       |  Internal: *.internal.mhlab.me |
| Uptime Kuma  |  10.0.0.51  |  3001     |  https://uptime.mhlab.me       |



---

## Adding a New Service

Edit `terraform/locals.tf` — add a new entry with `domain` and `port`:

```hcl
locals {
  services = {
    # ... existing services ...

    my-app = {
      vm_id  = 252          # Unique VM ID (check Proxmox for available)
      cores  = 1
      memory = 1024         # MB
      disk   = 10           # GB
      ip     = "10.0.0.12/24"  # Pick an unused IP
      domain = "my-app.mhlab.me"
      port   = 8080         # App's internal port
    }
  }
}
```

That's it. On merge to `main`, CI automatically:

1. **Terraform** creates the LXC container + Cloudflare DNS A record (`my-app.mhlab.me` → `168.119.81.167`, proxied)
2. **CI script** generates `gateway_services.yml` from Terraform output
3. **Ansible** configures Caddy reverse proxy with automatic TLS (Let's Encrypt via Cloudflare DNS-01 challenge) and CoreDNS internal record

### Without a public domain (internal-only services)

Omit `domain` and `port` — Terraform only creates the LXC, no DNS or proxy:

```hcl
my-db = {
  vm_id = 253; cores = 2; memory = 2048; disk = 20; ip = "10.0.0.21/24"
}
```

### Create a branch and PR

```bash
git checkout -b add-my-app
git add terraform/locals.tf
git commit -m "Add my-app service"
git push origin add-my-app
```

Open a PR → GitHub Actions will run `terraform plan` and post the diff.

### Merge to deploy

After reviewing the plan, merge to `main`. The pipeline handles everything.

---

## Managing Services

### SSH into a VM

From the Proxmox host:
```bash
pct enter 100          # Gateway
pct enter 251          # Uptime-kuma
pct enter 200          # GitHub runner
```

From the runner or via Ansible:
```bash
ssh root@10.0.0.10     # Gateway
ssh root@10.0.0.51     # Uptime-kuma
```

### View logs

```bash
# On Proxmox host
pct exec 100 -- journalctl -u caddy -f
pct exec 100 -- journalctl -u coredns -f

# On gateway LXC
journalctl -u caddy -f
journalctl -u coredns -f
journalctl -u wg-quick@wg0 -f
```

### Restart a service

```bash
# On gateway LXC
systemctl restart caddy
systemctl restart coredns
systemctl restart wg-quick@wg0
```

### Check WireGuard status

```bash
# On gateway LXC
wg show
```

---

## GitHub Actions

### Workflows

| Workflow | Trigger | What it does |
|----------|---------|--------------|
| `plan.yml` | PR → main | Runs `terraform plan`, posts diff as comment |
| `apply.yml` | Push to main | Runs `terraform apply` + `ansible-playbook` |
| `ansible.yml` | Push to main (ansible/) | Runs `ansible-playbook` only |
| `destroy.yml` | Manual | Runs `terraform destroy` |

### Self-hosted runner

- LXC ID: 200
- IP: 10.0.0.2
- Labels: `self-hosted`, `proxmox`
- Service: `systemctl status actions.runner.Chachu1-infrastructure.github-runner.service`

### Secrets (GitHub)

| Secret | Description |
|--------|-------------|
| `PROXMOX_URL` | https://168.119.81.167:8006 |
| `PROXMOX_USER` | root@pam |
| `PROXMOX_PASS` | Proxmox password |
| `SSH_PUBLIC_KEY` | Runner's public key |
| `SSH_PRIVATE_KEY` | Runner's private key |
| `TF_API_TOKEN` | Terraform Cloud API token |
| `CLOUDFLARE_API_TOKEN` | Cloudflare API token (DNS + Caddy TLS) |
| `CLOUDFLARE_ZONE_ID` | Cloudflare zone ID for mhlab.me |

---

## Terraform Cloud

- **Organization:** mhlab
- **Workspace:** proxmox-infra
- **URL:** https://app.terraform.io/app/mhlab/proxmox-infra

---

## Ansible Structure

```
ansible/
├── ansible.cfg
├── inventory/
│   ├── hosts.yml                    # Auto-generated by Terraform
│   └── group_vars/
│       ├── all/
│       │   ├── main.yml             # Shared variables
│       │   └── vault.yml            # Encrypted secrets
│       ├── gateway.yml              # Gateway static config (wireguard, nftables)
│       ├── gateway_services.yml     # Auto-generated: caddy_hosts, dns_records
│       └── apps.yml                 # App VM config
├── playbooks/
│   ├── site.yml                     # Master playbook
│   ├── gateway.yml                  # Gateway only
│   └── apps.yml                     # Apps only
└── roles/
    ├── common/                      # Base: packages, SSH, DNS
    ├── gateway_network/             # nftables firewall
    ├── caddy/                       # Reverse proxy (auto-TLS via Cloudflare)
    ├── wireguard/                   # VPN client
    ├── dns/                         # CoreDNS
    └── docker_host/                 # Docker for app VMs
```

---

## WireGuard

The gateway LXC connects to your home network as a WireGuard **client**.

### Gateway config

- Client IP: `192.168.12.2`
- Server: `server.mhlab.me:51820`
- Public key: `CPYgwb54Ciard/gBqdIgJ9N3AOxpP7InWjsSqM1IPm4=`

### Accessing VMs from home

1. Add static route on Unifi:
   - Destination: `10.0.0.0/24`
   - Next hop: `192.168.12.2`

2. Update WireGuard peer on Unifi:
   - AllowedIPs: `192.168.12.2/32, 10.0.0.0/24`

3. Access VMs:
   ```bash
   ssh root@10.0.0.10    # Gateway
   ssh root@10.0.0.51    # Uptime-kuma
   curl http://10.0.0.10 # Caddy
   ```

---

## DNS

### Public DNS (Cloudflare)

Per-service A records are created automatically by Terraform (proxied through Cloudflare).

| Record | Type | Content |
|--------|------|---------|
| `*.mhlab.me` | A | 168.119.81.167 |

### Internal DNS (CoreDNS on gateway)

| Record | IP |
|--------|-----|
| `gateway.internal.mhlab.me` | 10.0.0.10 |
| `uptime-kuma.internal.mhlab.me` | 10.0.0.51 |

All VMs use `10.0.0.10` as their DNS resolver (configured via DHCP on vmbr1).

---

## Troubleshooting

### VM can't reach internet

```bash
# Check DNS
nslookup google.com 10.0.0.10

# Check gateway
ping 10.0.0.1

# Check NAT
iptables -t nat -L POSTROUTING -v
```

### Caddy not proxying

```bash
# Check Caddy status
systemctl status caddy

# Check Caddy config
caddy validate --config /etc/caddy/Caddyfile

# Check Caddy logs
journalctl -u caddy -f
```

### CoreDNS not resolving

```bash
# Check CoreDNS status
systemctl status coredns

# Test DNS
dig @10.0.0.10 uptime-kuma.internal.mhlab.me

# Check CoreDNS logs
journalctl -u coredns -f
```

### WireGuard not connecting

```bash
# Check WireGuard status
wg show

# Check config
cat /etc/wireguard/wg0.conf

# Check logs
journalctl -u wg-quick@wg0 -f

# Restart
systemctl restart wg-quick@wg0
```

### GitHub Actions runner not picking up jobs

```bash
# On runner LXC (200)
systemctl status actions.runner.Chachu1-infrastructure.github-runner.service
journalctl -u actions.runner.Chachu1-infrastructure.github-runner.service -f
```

### Terraform apply fails

```bash
# Check Terraform Cloud
https://app.terraform.io/app/mhlab/proxmox-infra/runs

# Check Proxmox connectivity
curl -k https://168.119.81.167:8006/api2/json/version
```

---

## Emergency Access

1. **Hetzner Robot panel** → KVM-over-IP (LARA)
2. **Proxmox host SSH** → `ssh root@168.119.81.167`
3. **Rescue system** → Hetzner rescue boot

---

## Useful Commands

```bash
# Proxmox host
pct list                              # List all LXCs
pct status <vmid>                     # Check LXC status
pct enter <vmid>                      # Enter LXC shell
pct start <vmid>                      # Start LXC
pct stop <vmid>                       # Stop LXC

# Inside gateway
systemctl status caddy                # Caddy status
systemctl status coredns              # CoreDNS status
systemctl status wg-quick@wg0         # WireGuard status
nft list ruleset                      # Firewall rules
wg show                               # WireGuard status
cat /etc/caddy/Caddyfile              # Caddy config
cat /etc/coredns/Corefile             # CoreDNS config

# From runner
cd ~/infrastructure
git pull
terraform plan                        # Preview changes
ansible all -m ping                   # Test connectivity
ansible-playbook playbooks/site.yml   # Run all playbooks
```
