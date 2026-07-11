# Handoff: Infrastructure Repo

**Last updated:** 2026-07-11
**Repo:** https://github.com/Chachu1/infrastructure (private)
**Local path:** `/home/mohsin/Documents/git_repos/infrastructure/`

---

## Current State

Infrastructure is fully deployed and operational:

| Service | Status | URL |
|---------|--------|-----|
| Proxmox host | Running | 168.119.81.167:8006 |
| Gateway (vm_id=100) | Running | 10.0.0.10 |
| Uptime Kuma (vm_id=251) | Running | https://uptime.mhlab.me |
| GitHub Runner (vm_id=200) | Running | 10.0.0.2 |
| Cloudflare DNS | Active | uptime.mhlab.me → 168.119.81.167 (proxied) |

---

## What Was Done

### Infrastructure
1. Created private GitHub repo `Chachu1/infrastructure`
2. Terraform provisions 3 LXC containers on Proxmox via `bpg/proxmox` provider
3. Cloudflare DNS A records created automatically (proxied)
4. DNAT rules forward ports 80/443 to gateway, 51820 for WireGuard

### Configuration
5. Caddy reverse proxy with auto-TLS (HTTP-01 challenge) on gateway
6. CoreDNS for internal DNS (*.internal.mhlab.me → 10.0.0.x)
7. WireGuard client connecting to home network (192.168.12.0/24)
8. nftables firewall on gateway (ports 22, 80, 443, private subnets)
9. Uptime Kuma deployed via Docker Compose on container 251

### CI/CD
10. GitHub Actions workflows: plan (PR), apply (push to main), ansible (ansible changes)
11. Ansible inventory auto-generated from Terraform outputs
12. `gateway_services.yml` auto-generated with `caddy_hosts` and `dns_records`

---

## Key Decisions & Gotchas

| Topic | Decision | Why |
|-------|----------|-----|
| Caddy TLS | HTTP-01 challenge | Standard Caddy package; no Cloudflare DNS plugin needed |
| WireGuard AllowedIPs | `192.168.12.0/24` only | `0.0.0.0/0` breaks reply routing → Cloudflare 522 |
| Docker Compose | v2 plugin (`docker compose`) | v1 (`docker-compose`) not installed on Debian 12 |
| AppArmor | `security_opt: apparmor:unconfined` | Docker in LXC requires unconfined AppArmor |
| Cloudflare resource | `cloudflare_record` (not `cloudflare_dns_record`) | Correct Terraform resource type |
| Ansible lineinfile | Use `copy` module for multi-line content | `lineinfile` doesn't support `content` parameter |

---

## Environment Details

- **Proxmox node name:** `server` (not default `pve`)
- **Domain:** `mhlab.me`
- **DNS provider:** Cloudflare (proxied A records)
- **Private subnet:** `10.0.0.0/24` (vmbr1)
- **WireGuard subnet:** `192.168.12.0/24` (home network)
- **WireGuard gateway IP:** `192.168.12.2`
- **State backend:** Terraform Cloud (org: mhlab, workspace: proxmox-infra)

---

## SSH Access

```bash
# From local machine
ssh root@168.119.81.167              # Proxmox host

# From Proxmox host
pct enter 100                        # Gateway
pct enter 251                        # Uptime Kuma
pct enter 200                        # GitHub Runner

# From gateway
ssh root@10.0.0.51                   # Uptime Kuma
ssh root@192.168.12.1                # Home network (via WireGuard)
```

---

## Common Tasks

### Adding a new service
1. Edit `terraform/locals.tf` — add entry with `vm_id`, `ip`, `domain`, `port`
2. Push to `main` — Terraform creates LXC + DNS, Ansible configures Caddy + CoreDNS

### Checking uptime-kuma
```bash
pct exec 251 -- docker ps
pct exec 251 -- curl -s -o /dev/null -w '%{http_code}' http://localhost:3001
```

### Checking Caddy
```bash
pct exec 100 -- systemctl status caddy
pct exec 100 -- journalctl -u caddy -f
```

### Checking WireGuard
```bash
pct exec 100 -- wg show
pct exec 100 -- ip rule list
```

---

## Key Files

| File | Purpose |
|------|---------|
| `terraform/locals.tf` | Service definitions (source of truth) |
| `terraform/dns.tf` | Cloudflare DNS records |
| `terraform/outputs.tf` | Ansible inventory generation |
| `ansible/inventory/group_vars/gateway_services.yml` | Auto-generated Caddy + DNS config |
| `ansible/roles/caddy/templates/Caddyfile.j2` | Caddy reverse proxy config |
| `ansible/roles/wireguard/templates/wg0.conf.j2` | WireGuard client config |
| `ansible/roles/uptime_kuma/templates/docker-compose.yml.j2` | Uptime Kuma container |
| `ansible/roles/gateway_network/templates/nftables.conf.j2` | Firewall rules |
| `docs/infrastructure-design.md` | Full design document |
| `docs/infrastructure-reference.md` | Operational reference |

---

## Suggested Skills

- `implement` — When adding new services or infrastructure
- `diagnosing-bugs` — If Terraform/Ansible issues arise during deployment
- `research` — If you need to look up Proxmox provider docs or Ansible module details
