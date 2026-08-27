# Infrastructure Reference

**Last updated:** 2026-08-25
**Proxmox host:** germany1 (168.119.81.167)
**Domain:** mhlab.me

> **Routing model (post-cutover):** public traffic now reaches application LXCs
> through the gateway Caddy, **not** through Coolify. Coolify (10.0.0.60) only
> serves `coolify.mhlab.me` (admin UI) and the `*.backend.mhlab.me` catch-all for
> any future Coolify-deployed app. See [Public routing](#public-routing) below.

---

## Architecture Overview

```
Internet
   │
   │  Public IP: 168.119.81.167  (Cloudflare proxy, orange cloud)
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
│    ├─ postgres      (10.0.0.20) — PostgreSQL 18         │
│    ├─ uptime-kuma   (10.0.0.51) — monitoring           │
│    ├─ github-runner (10.0.0.2)  — CI/CD                │
│    ├─ coolify       (10.0.0.60) — Coolify admin only   │
│    └─ app LXCs      (10.0.0.61–72) — Price Tracker svc │
│                                                         │
│  WireGuard client → home network (192.168.12.0/24)      │
│    └─ gateway IP: 192.168.12.2                          │
└─────────────────────────────────────────────────────────┘
```

### Public routing (Cloudflare → gateway Caddy → service LXC)

Cloudflare proxies each public domain (orange cloud) to `168.119.81.167`. The host
DNATs 80/443 to the gateway LXC (`10.0.0.10`), where Caddy terminates TLS and
reverse-proxies to the target LXC over the private bridge. Coolify is **no longer**
in the public path for application services.

| Public domain | Backend | Port | Served by |
|---|---|---|---|
| `uptime.mhlab.me` | 10.0.0.51 | 3001 | uptime-kuma LXC |
| `proxmox.mhlab.me` | 10.0.0.1 | 8006 (https) | Proxmox host |
| `prod-match.mhlab.me` | 10.0.0.62 | 8013 | review-api LXC |
| `jobs.mhlab.me` | 10.0.0.63 | 8001 | job-tracker-api LXC |
| `dashboard-api.mhlab.me` | 10.0.0.64 | 8002 | dashboard-api LXC |
| `backfill.mhlab.me` | 10.0.0.66 | 8012 | backfill-ui LXC |
| `screenshots.mhlab.me` | 10.0.0.67 | 8010 | screenshot-service LXC |
| `frontend.mhlab.me` | 10.0.0.70 | 3000 | frontend LXC |
| `graylog.mhlab.me` | 10.0.0.72 | 9000 | graylog LXC |
| `coolify.mhlab.me` | 10.0.0.60 | 80 | Coolify VM (admin) |
| `*.backend.mhlab.me` | 10.0.0.60 | 80 | Coolify VM (future apps) |

> Routes are generated from Terraform `locals.tf` (`domain`/`port`) into
> `ansible/inventory/group_vars/gateway_services.yml` (`caddy_hosts`), then rendered
> by `configs/caddy/Caddyfile.j2`. Do **not** edit the Caddyfile by hand.

---

## Network Design

### Subnets

|       Subnet        |              Purpose              |
|---------------------|-----------------------------------|
|  `10.0.0.0/24`      |  Proxmox private network (vmbr1)  |
|  `192.168.12.0/24`  |  Home network (via WireGuard)     |

### IP Allocation


|       IP        |      Host        |                Role                |
|-----------------|-----------------|------------------------------------|
| `10.0.0.1`      |  vmbr1 bridge   |  Proxmox host (gateway for VMs)    |
| `10.0.0.2`      |  github-runner  |  GitHub Actions self-hosted runner |
| `10.0.0.10`     |  gateway        |  Reverse proxy, DNS, firewall, VPN |
| `10.0.0.20`     |  postgres       |  PostgreSQL database (VMID 252)    |
| `10.0.0.51`     |  uptime-kuma    |  Monitoring dashboard              |
| `10.0.0.60`     |  coolify        |  Coolify admin VM (app hosting being retired) |
| `10.0.0.61`     |  categorizer    |  Categorizer worker (internal)     |
| `10.0.0.62`     |  review-api     |  prod-match.mhlab.me (LXC)         |
| `10.0.0.63`     |  job-tracker-api|  jobs.mhlab.me (LXC)               |
| `10.0.0.64`     |  dashboard-api  |  dashboard-api.mhlab.me (LXC)      |
| `10.0.0.65`     |  transform-worker | Transform worker (internal)      |
| `10.0.0.66`     |  backfill-ui    |  backfill.mhlab.me (LXC)           |
| `10.0.0.67`     |  screenshot-service | screenshots.mhlab.me (LXC)     |
| `10.0.0.68`     |  local-scraper  |  Local scraper (internal)          |
| `10.0.0.69`     |  enrichment-worker | Enrichment worker (internal)    |
| `10.0.0.70`     |  frontend       |  frontend.mhlab.me (LXC)           |
| `10.0.0.71`     |  pg-backup      |  PostgreSQL backup (internal)      |
| `10.0.0.72`     |  graylog        |  graylog.mhlab.me (LXC)            |
| `10.0.0.11-19`  |  —              |  Reserved for web applications     |
| `10.0.0.21-29`  |  —              |  Reserved for databases            |
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

Publicly routed services (Cloudflare → gateway Caddy → LXC):

|   Service    |     IP      |   Port    |               URL              |
|--------------|-------------|-----------|--------------------------------|
| Caddy        |  10.0.0.10  |  80, 443  |  (TLS termination / reverse proxy) |
| CoreDNS      |  10.0.0.10  |  53       |  Internal: *.internal.mhlab.me |
| Uptime Kuma  |  10.0.0.51  |  3001     |  https://uptime.mhlab.me       |
| Postgres     |  10.0.0.20  |  5432     |  postgres.internal.mhlab.me    |
| Review API (prod-match) | 10.0.0.62 | 8013 | https://prod-match.mhlab.me |
| Job Tracker API | 10.0.0.63 | 8001  | https://jobs.mhlab.me          |
| Dashboard API | 10.0.0.64  | 8002      | https://dashboard-api.mhlab.me |
| Backfill UI  | 10.0.0.66  | 8012      | https://backfill.mhlab.me      |
| Screenshot Service | 10.0.0.67 | 8010 | https://screenshots.mhlab.me |
| Frontend     | 10.0.0.70  |  3000     |  https://frontend.mhlab.me     |
| Graylog      | 10.0.0.72  |  9000     |  https://graylog.mhlab.me      |
| Coolify      | 10.0.0.60  |  80       |  https://coolify.mhlab.me (admin only) |

Internal-only services (no public domain): categorizer (61), transform-worker
(65), local-scraper (68), enrichment-worker (69), pg-backup (71).

> **Routing ownership:** application domains listed above are routed by the gateway
> Caddy (generated from Terraform). `coolify.mhlab.me` and `*.backend.mhlab.me`
> remain on the Coolify VM. Keep Coolify's `app_domains` empty in `locals.tf` or
> Caddy gets duplicate site blocks.



---

## Adding a New Service

Edit `terraform/locals.tf` — add a new entry. Set `type` to `"vm"` for a cloud-init VM,
or omit it (defaults to `"lxc"`).

### LXC container (default)

```hcl
locals {
  services = {
    # ... existing services ...

    my-app = {
      # type defaults to "lxc", distro defaults to "debian"
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

### VM (cloud-init)

```hcl
my-vm = {
  type   = "vm"
  distro = "ubuntu"         # or "debian" (default)
  vm_id  = 300
  cores  = 2
  memory = 2048
  disk   = 50               # minimum 50GB
  ip     = "10.0.0.60/24"
  domain = "app.mhlab.me"
  port   = 8080
}
```

That's it. On merge to `main`, CI automatically:

1. **Terraform** creates the LXC/VM + Cloudflare DNS A record (proxied)
2. **CI script** generates `gateway_services.yml` from Terraform output
3. **Ansible** configures Caddy reverse proxy with automatic TLS and CoreDNS internal record

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

## Storage

### LVM-Thin Pool

All LXC rootfs and VM disks live on an LVM-thin pool (`thin_pool` on `vg0`).

| Storage | Type | Content | Purpose |
|---------|------|---------|---------|
| `lvmthin` | lvmthin | `rootdir`, `images` | LXC rootfs + VM disks |
| `local` | dir | `backup`, `rootdir`, `vztmpl`, `images`, `snippets`, `iso` | Templates, ISOs, backups, cloud images |

### Cloud Images

Cloud images are stored at `/var/lib/vz/images/cloudimg/` on the Proxmox host
(mapped to `local:cloudimg/` in Proxmox). A systemd timer updates them weekly
(Sunday 03:00 with up to 5 min random delay).

Available images:
- `debian-13-generic-amd64.qcow2` — Debian 13 Trixie (daily)
- `ubuntu-24.04-server-cloudimg-amd64.img` — Ubuntu 24.04 Noble (daily)

To trigger a manual update:
```bash
ssh root@10.0.0.1 /usr/local/bin/update-cloud-images.sh
```

To check timer status:
```bash
ssh root@10.0.0.1 systemctl status update-cloud-images.timer
```

### Thin Pool Monitoring

Check utilization:
```bash
ssh root@10.0.0.1 lvs vg0/thin_pool
```

Alert if Data% exceeds 80%. To add capacity, extend the pool:
```bash
lvextend -L +1T vg0/thin_pool
```

---

## Managing Services

### SSH Access

#### LXC containers

From the Proxmox host:
```bash
pct enter 100          # Gateway
pct enter 252          # Postgres
pct enter 251          # Uptime-kuma
pct enter 200          # GitHub runner
```

From the runner or via Ansible:
```bash
ssh root@10.0.0.10     # Gateway
ssh root@10.0.0.51     # Uptime-kuma
```

#### VMs (cloud-init)

VMs have two users configured via cloud-init:

| User | Sudo | Password | Usage |
|------|------|----------|-------|
| `root` | Full root | Yes (`PROXMOX_PASS`) | Direct root access |
| `mohsin` | `NOPASSWD: ALL` | No (key-only) | Day-to-day, sudo when needed |

```bash
ssh root@<vm-ip>       # root with SSH key
ssh mohsin@<vm-ip>     # mohsin with SSH key
sudo -i                # switch to root from mohsin
```

Cloud-init config source: `terraform/cloud-init.yml`
Proxmox snippet: `local:snippets/cloud-init-app.yml`

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
| `CLOUDFLARE_API_TOKEN` | Cloudflare API token (DNS record management) |
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
    ├── caddy/                       # Reverse proxy (auto-TLS via HTTP-01 challenge)
    ├── wireguard/                   # VPN client
    ├── dns/                         # CoreDNS
    ├── docker_host/                 # Docker for app VMs
    └── uptime_kuma/                 # Uptime Kuma monitoring (Docker Compose)
```

---

## WireGuard

The gateway LXC connects to your home network as a WireGuard **client**.

### Gateway config

- Client IP: `192.168.12.2`
- Server: `server.mhlab.me:51820`
- Public key: `CPYgwb54Ciard/gBqdIgJ9N3AOxpP7InWjsSqM1IPm4=`
- AllowedIPs: `192.168.12.0/24` (home network only — do NOT use `0.0.0.0/0`)

> **Warning:** Setting `AllowedIPs = 0.0.0.0/0` routes ALL outbound traffic through the
> tunnel, including reply packets to Cloudflare. This causes HTTP 522 (origin timeout)
> for all proxied services. Always restrict AllowedIPs to only the subnets you need.

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

Per-service **A records** are created automatically by Terraform from each service's
`domain` field in `terraform/locals.tf` (proxied / orange cloud, pointing at
`168.119.81.167`). There is **no** wildcard `*.mhlab.me` record — each public domain
is an explicit A record. Coolify's `coolify.mhlab.me` and `*.backend.mhlab.me` are
the only records that still point at the Coolify VM (`10.0.0.60`).

| Record | Type | Content | Proxied? |
|--------|------|---------|----------|
| `uptime.mhlab.me` | A | 168.119.81.167 | Yes |
| `proxmox.mhlab.me` | A | 168.119.81.167 | Yes |
| `prod-match.mhlab.me` | A | 168.119.81.167 | Yes |
| `jobs.mhlab.me` | A | 168.119.81.167 | Yes |
| `dashboard-api.mhlab.me` | A | 168.119.81.167 | Yes |
| `backfill.mhlab.me` | A | 168.119.81.167 | Yes |
| `screenshots.mhlab.me` | A | 168.119.81.167 | Yes |
| `frontend.mhlab.me` | A | 168.119.81.167 | Yes |
| `graylog.mhlab.me` | A | 168.119.81.167 | Yes |
| `coolify.mhlab.me` | A | 168.119.81.167 | Yes |
| `*.backend.mhlab.me` | A | 168.119.81.167 | Yes |

### Internal DNS (CoreDNS on gateway)

| Record | IP |
|--------|-----|
| `gateway.internal.mhlab.me` | 10.0.0.10 |
| `uptime-kuma.internal.mhlab.me` | 10.0.0.51 |
| `postgres.internal.mhlab.me` | 10.0.0.20 |

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

# TLS uses HTTP-01 challenge (Cloudflare must have port 80 open to the origin)
# No Cloudflare DNS plugin needed — standard Caddy package works
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

### Cloudflare 522 (origin timeout)

This usually means reply packets are being routed through WireGuard instead of back
to the client. Check:

```bash
# Verify AllowedIPs is NOT 0.0.0.0/0
grep AllowedIPs /etc/wireguard/wg0.conf
# Should be: AllowedIPs = 192.168.12.0/24

# Check routing rules — if you see "lookup 51820" the tunnel is hijacking traffic
ip rule list

# Check WireGuard routing table
ip route show table 51820
# Should NOT exist if AllowedIPs is restricted to 192.168.12.0/24
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
# Proxmox host - LXCs
pct list                              # List all LXCs
pct status <vmid>                     # Check LXC status
pct enter <vmid>                      # Enter LXC shell
pct start <vmid>                      # Start LXC
pct stop <vmid>                       # Stop LXC
pct move <vmid> rootfs lvmthin        # Migrate LXC to thin pool

# Proxmox host - VMs
qm list                                # List all VMs
qm status <vmid>                       # Check VM status
qm start <vmid>                        # Start VM
qm stop <vmid>                         # Stop VM
qm terminal <vmid>                     # VM console

# Proxmox host - Storage
pvesm status                           # Storage status
lvs vg0/thin_pool                      # Thin pool utilization

# Proxmox host - Cloud images
systemctl status update-cloud-images.timer  # Check image update timer
/usr/local/bin/update-cloud-images.sh       # Manual image update
ls -lh /var/lib/vz/images/cloudimg/         # List cloud images

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
