# Coolify Migration: Hetzner Cloud VM → Proxmox

**Created:** 2026-07-18
**Status:** In Progress — Phase 0–5 complete, Phase 6 pending (48-hr bake-in)

Migrate the Coolify instance running on a Hetzner Cloud VM (`price-tracker-vps`, 62.238.11.96) to
the Proxmox server (`germany1`, 168.119.81.167), replacing the existing Coolify VM (ID 300,
`coolify-h.mhlab.me`).

---

## Source VM (Hetzner Cloud)

| Detail | Value |
|---|---|
| Hostname | `price-tracker-vps` |
| Public IP | `62.238.11.96` |
| OS | Ubuntu 24.04.4 LTS |
| CPU | 2 vCPU |
| RAM | 4 GB |
| Disk | 38 GB (17 GB used) |
| SSH | `root@coolify.mhlab.me` |
| WireGuard | `192.168.12.5/32` (client) |
| Docker | Coolify stack + 7 app containers + 1 managed PostgreSQL 18 |

### Apps deployed via Coolify

| Domain | Coolify App UUID | Description | DB |
|---|---|---|---|
| `coolify.mhlab.me` | (dashboard) | Coolify dashboard + /app + /terminal/ws | coolify-db (pg:15) |
| `jobs.mhlab.me` | `kwg1nrr3v9pa1oaonxg2uird` | Job board / listing | — |
| `prod-match.mhlab.me` | `wc5ukkuskgsd59pe1sqnpdq0` | Review API (port 8013) | — |
| `screenshots.mhlab.me` | `ip9jpcvmexuec2hpdeeiu395` | Screenshot monitor frontend (8011) + service (8010) | — |
| `backfill.mhlab.me` | `hpeh22zmnqp890yuwil0k562` | Backfill service | — |
| `vpir1ay67lgphfcc1wnnuyxf.62.238.11.96.sslip.io` | `vpir1ay67lgphfcc1wnnuyxf` | Auto-generated sslip.io domain | — |
| (internal) | `inv0jy3ota4evbdwklkacze7` | Unknown | — |
| (internal) | `q2gv94nbtc3pne23l07xhz2z` | Categorizer | — |

### Managed databases

| Name | Image | Port | Notes |
|---|---|---|
| `jkprbb1mhpb9kvckev0318vg` | postgres:18-alpine | 5432 | App database (used by one of the services) |
| `jkprbb1mhpb9kvckev0318vg-proxy` | nginx:stable-alpine | 5544 | Nginx proxy in front of the DB |

### Coolify stack components

| Container | Image | Purpose |
|---|---|---|
| `coolify` | `ghcr.io/coollabsio/coolify:4.0.0-beta.474` | Main Coolify application |
| `coolify-db` | `postgres:15-alpine` | Coolify internal database |
| `coolify-redis` | `redis:7-alpine` | Session / queue cache |
| `coolify-realtime` | `ghcr.io/coollabsio/coolify-realtime:1.0.13` | WebSocket events |
| `coolify-proxy` | `traefik:v3.6` | Reverse proxy (80:80, 443:443, 8080:8080) |
| `coolify-sentinel` | `ghcr.io/coollabsio/sentinel:0.0.21` | Monitoring agent |

### Traefik config (for restoration reference)

Traefik uses Docker provider + file provider:
- HTTP entrypoint on `:80`
- HTTPS entrypoint on `:443` with HTTP/3
- Dashboard on `:8080` (insecure=false, managed by API)
- Let's Encrypt HTTP-01 challenge via `certificatesresolvers.letsencrypt`
- ACME storage: `/data/coolify/proxy/acme.json`
- Dynamic file config: `/data/coolify/proxy/dynamic/coolify.yaml`
- Docker socket mounted read-only for container discovery

### DNS (current)

All 5 app domains are **DNS-only A records on Cloudflare** pointing directly to `62.238.11.96`
(grey cloud). Cloudflare-proxied `coolify-h.mhlab.me` points to `168.119.81.167` (the existing
Proxmox Coolify VM).

---

## Target VM (Proxmox)

| Detail | Value |
|---|---|
| Host | `germany1` (168.119.81.167) |
| VM ID | 300 (replaces existing) |
| IP | `10.0.0.60/24` on `vmbr1` |
| OS | Debian 13 (Trixie — template default; Ubuntu was planned but template 9002 was Debian) |
| CPU | 8 vCPU |
| RAM | 8 GB |
| Disk | 100 GB on `lvmthin` |
| Access | `mohsin` (sudo NOPASSWD) or `root` via SSH key |
| Proxy | Caddy on gateway (`10.0.0.10`) terminates TLS, forwards to Traefik |

---

## Post-Migration Architecture

### Traffic flow

```
Internet
   │
   ▼
Cloudflare (proxied, orange cloud for all domains)
   │
   ▼
168.119.81.167 (Proxmox germany1)
   │
   └── DNAT 80/443 → 10.0.0.10 (gateway LXC)
                         │
                         ├── Caddy terminates TLS (Cloudflare DNS-01)
                         │     │
                          │     ├── coolify.mhlab.me           → 10.0.0.60:80    (Traefik HTTP → Coolify)
                         │     ├── /app, /terminal/ws         →    (websockets via dashboard)
                         │     ├── jobs.mhlab.me              → 10.0.0.60:80    (Traefik)
                         │     ├── prod-match.mhlab.me        → 10.0.0.60:80
                         │     ├── screenshots.mhlab.me       → 10.0.0.60:80
                         │     ├── backfill.mhlab.me          → 10.0.0.60:80
                         │     └── *.backend.mhlab.me (future) → 10.0.0.60:80
                         │
                         └── Other domains (uptime, proxmox) → unchanged
```

### Key change from source setup

**On the cloud VM**: Traefik binds `:80` and `:443`, terminates TLS itself with Let's Encrypt
HTTP-01 challenge, and routes all 5 domains.

**On Proxmox**: Caddy on the gateway terminates all TLS using a Cloudflare DNS-01 wildcard
certificate. Traefik inside the Coolify VM listens on `:80` **only** (plain HTTP) and routes by
Host header. No Let's Encrypt inside the VM — Caddy handles all certificates.

### Caddy routing (actual deployed)

The plan originally separated the dashboard on port 8080 from app domains on port 80. During
implementation, Traefik's dashboard and Coolify's container port conflicted (both wanted 8080).
**Resolution:** Coolify runs on host port 8000, Traefik on 80 + 8080 (dashboard). **All Caddy
routes point to 10.0.0.60:80** — Traefik's HTTP entrypoint handles routing by Host header.

```
coolify.mhlab.me, jobs.mhlab.me, prod-match.mhlab.me, screenshots.mhlab.me,
backfill.mhlab.me, *.backend.mhlab.me {
    reverse_proxy 10.0.0.60:80
}
```

### DNS after migration

| Record | Type | Value | Proxied? |
|---|---|---|---|
| `coolify.mhlab.me` | A | `168.119.81.167` | Yes |
| `jobs.mhlab.me` | A | `168.119.81.167` | Yes |
| `prod-match.mhlab.me` | A | `168.119.81.167` | Yes |
| `screenshots.mhlab.me` | A | `168.119.81.167` | Yes |
| `backfill.mhlab.me` | A | `168.119.81.167` | Yes |
| `*.backend.mhlab.me` | A | `168.119.81.167` | Yes |
| `coolify-h.mhlab.me` | A | removed | — |

(Existing records for `uptime.mhlab.me`, `proxmox.mhlab.me` remain unchanged.)

### Coolify proxy changes (actual)

1. **Disable HTTPS endpoint** — removed `443:443`, `443:443/udp` ports, `--entrypoints.https.*`, `--certificatesresolvers.letsencrypt.*` from Traefik proxy compose
2. **Disable per-app TLS routers** — removed `coolify-https`, `coolify-realtime-wss`, `coolify-terminal-wss` from dynamic config
3. **Traefik ports**: `80:80` (HTTP entrypoint) + `8080:8080` (dashboard)
4. **Coolify container**: `APP_PORT=8000` → `8000:8080` (avoids conflict with Traefik dashboard on 8080)
5. **Caddy routes all domains to** `10.0.0.60:80` — Traefik HTTP entrypoint handles Host-based routing

> **Note:** Coolify regenerates `coolify.yaml` + per-app Traefik labels on configuration
> changes. After initial migration, use Coolify's "Custom proxy" settings in the admin UI to
> prevent it from re-enabling TLS. Do NOT edit the generated YAML files long-term.

---

## Files to Modify

| File | Changes |
|---|---|---|
| `terraform/locals.tf` | Replace `coolify` stanza — new domain (`coolify.mhlab.me`), port 80, add `app_domains` + `wildcard_domain` fields |
| `terraform/dns.tf` | Extend to create A records for `app_domains` + `wildcard_domain` (proxied, `allow_overwrite=true`) |
| `terraform/outputs.tf` | Emit `app_domains` + `wildcard_domain` per service |
| `.github/workflows/deploy.yml` | Generate `caddy_hosts` entries for app domains (port 80) + wildcard (port 80) |
| `configs/caddy/Caddyfile.j2` | (No change — existing template iterates over `caddy_hosts`, which CI extends) |
| `docs/infrastructure-reference.md` | Update service table, add Coolify migration note |

### Proposed `locals.tf` diff (coolify stanza only)

```hcl
coolify = {
  type             = "vm"
  vm_id            = 300
  cores            = 8
  memory           = 8192
  disk             = 100
  ip               = "10.0.0.60/24"
  domain           = "coolify.mhlab.me"
  port             = 8080                               # dashboard port on Traefik
  app_domains      = [                                  # proxied to Traefik :80
    "jobs.mhlab.me",
    "prod-match.mhlab.me",
    "screenshots.mhlab.me",
    "backfill.mhlab.me",
  ]
  wildcard_domain  = "*.backend.mhlab.me"               # future Coolify-managed apps
}
```

### Proposed `dns.tf` extension

```hcl
# App domains for services with app routing (Traefik behind Caddy)
resource "cloudflare_record" "app_domains" {
  for_each = merge([
    for name, svc in local.services : {
      for d in try(svc.app_domains, []) : "${name}-${d}" => d
    } if try(svc.app_domains, []) != []
  ]...)

  zone_id         = var.cloudflare_zone_id
  name            = each.value
  value           = "168.119.81.167"
  type            = "A"
  proxied         = true
  allow_overwrite = true
}

# Wildcard domains for future service routing
resource "cloudflare_record" "wildcard_domains" {
  for_each = {
    for name, svc in local.services : name => svc.wildcard_domain
    if try(svc.wildcard_domain, "") != ""
  }

  zone_id         = var.cloudflare_zone_id
  name            = each.value
  value           = "168.119.81.167"
  type            = "A"
  proxied         = true
  allow_overwrite = true
}
```

### Proposed `Caddyfile.j2` extension

```jinja2
{% for host in caddy_hosts %}
{{ host.domain }} {
    reverse_proxy {{ host.backend }}:{{ host.port }}
}
{% endfor %}

{% for host in app_domains %}
{% if host.domains | length > 0 %}
{{ host.domains | join(", ") }}{% if host.wildcard %}, {{ host.wildcard }}{% endif %} {
    reverse_proxy {{ host.backend }}:80
}
{% endif %}
{% endfor %}
```

---

## Execution Plan

### Phase 0 — Prep on Proxmox host

```bash
# Run from dev machine
ssh root@10.0.0.1 'mkdir -p /mnt/backups'
```

### Phase 1 — Backup cloud VM

#### 1a. Authorize Proxmox host to SSH into cloud VM

The Proxmox host already has a keypair at `/root/.ssh/id_rsa`. Add its public key to the
cloud VM's authorized_keys:

```bash
# Run from dev machine (key flows directly, not through dev)
ssh root@10.0.0.1 'cat /root/.ssh/id_rsa.pub' | \
  ssh root@coolify.mhlab.me 'cat >> /root/.ssh/authorized_keys'
```

#### 1b. Verify direct SSH works

```bash
ssh root@10.0.0.1 'ssh -o StrictHostKeyChecking=accept-new root@coolify.mhlab.me hostname'
# Expected: price-tracker-vps
```

#### 1c. Generate database dumps on cloud VM

```bash
ssh root@coolify.mhlab.me '
  # Coolify internal DB (postgres:15)
  docker exec coolify-db pg_dumpall -U coolify > /tmp/coolify-db.sql &&

  # App database (postgres:18-alpine, managed by Coolify)
  docker exec jkprbb1mhpb9kvckev0318vg pg_dumpall -U postgres > /tmp/app-db.sql &&

  ls -lh /tmp/*.sql
'
```

#### 1d. Proxmox host pulls data directly (no home network hop)

The Proxmox host is on Hetzner bare-metal; the cloud VM is on Hetzner Cloud. Both are in
Germany. Transfer goes directly over the internet — the SSH control channel spans from
your dev machine to the Proxmox host, but the tarball data flows:

```
cloud VM (62.238.11.96) ─── Internet ─── Proxmox host (168.119.81.167)
```

```bash
# Run from dev machine
ssh root@10.0.0.1 '
  mkdir -p /mnt/backups &&

  # Coolify data directory (preserves permissions, owner 9999:root)
  ssh root@coolify.mhlab.me "tar -czf - --same-owner /data/coolify" \
    > /mnt/backups/coolify-data.tar.gz &&

  # Database dumps
  ssh root@coolify.mhlab.me "cat /tmp/coolify-db.sql" \
    > /mnt/backups/coolify-db.sql &&
  ssh root@coolify.mhlab.me "cat /tmp/app-db.sql" \
    > /mnt/backups/app-db.sql &&

  # Container inspect (for reference/recovery)
  ssh root@coolify.mhlab.me "
    docker ps -aq | xargs -I{} docker inspect {}
  " > /mnt/backups/container-inspect.json &&

  ls -lh /mnt/backups/
'
```

#### 1e. Capture container compose/env/config for reference

```bash
ssh root@coolify.mhlab.me '
  # Coolify compose
  cat /data/coolify/source/docker-compose.yml
  echo "=== .env ==="
  cat /data/coolify/source/.env
  echo "=== proxy compose ==="
  cat /data/coolify/proxy/docker-compose.yml
  echo "=== traefik dynamic config ==="
  cat /data/coolify/proxy/dynamic/coolify.yaml
  echo "=== managed DB compose ==="
  find /data/coolify/databases/ -name docker-compose.yml -exec echo "{}:" \; -exec cat {} \;
' > /tmp/cloud-vm-config-reference.txt
```

### Phase 2 — Update Infra-as-Code

#### 2a. Modify `terraform/locals.tf`

Replace the `coolify` service block (currently lines 58–67) with the proposed stanza above.
Remove the old `coolify-h.mhlab.me` domain reference.

#### 2b. Modify `terraform/dns.tf`

Add `cloudflare_record.app_domains` and `cloudflare_record.wildcard_domains` resources
as shown above.

#### 2c. Modify `terraform/outputs.tf`

Extend the services output to include `app_domains` and `wildcard_domain`.

In the `caddy_hosts` output generated by CI (see `deploy.yml`), add entries for app domains.

#### 2d. Modify `configs/caddy/Caddyfile.j2`

Extend the template to render per-service app-proxy rules, as shown above.

#### 2e. Remove `coolify-h.mhlab.me` references

The old `coolify-h` entries in `gateway_services.yml` will be auto-regenerated by the CI
pipeline after Terraform apply. No manual change needed for that file — it's generated
from Terraform output.

#### 2f. Commit and push

```bash
git checkout -b migrate-coolify
git add terraform/locals.tf terraform/dns.tf terraform/outputs.tf \
        configs/caddy/Caddyfile.j2
git commit -m "Migrate Coolify from cloud VM, add app domain routing"
git push origin migrate-coolify
```

Open a PR against `main`. CI will run `terraform plan` and post the diff. Review carefully.

### Phase 3 — Provision & configure

#### 3a. Terraform apply (via PR merge or manual CI trigger)

This will:
1. Destroy VM 300 (existing coolify-h)
2. Create new cloud-init VM 300 from Ubuntu 24.04 template (9002)
3. Cloud-init creates `root` (key+password) and `mohsin` (key-only, sudo NOPASSWD)
4. Assign IP `10.0.0.60/24` on `vmbr1`, gateway `10.0.0.1`
5. Create/update Cloudflare DNS A records for all 5 app domains + wildcard
6. Create/update the `coolify.mhlab.me` A record

#### 3b. Wait for VM to boot and install base packages

```bash
# Verify VM is reachable
ssh -o ConnectTimeout=10 root@10.0.0.60 'hostname && cat /etc/os-release | head -2'
```

#### 3c. Run Ansible to install Docker

Either via CI pipeline (pushes to ansible/ on main trigger it) or manually:

```bash
ansible-playbook -i ansible/inventory/hosts.yml ansible/playbooks/hosts/coolify.yml
```

The existing `docker_host` role installs Docker CE + compose plugin.

#### 3d. Run Ansible to update Caddy config

```bash
ansible-playbook -i ansible/inventory/hosts.yml ansible/playbooks/hosts/gateway.yml
```

Caddy reloads with the new routing rules. At this point, `coolify.mhlab.me` will return
a connection error (no Coolify dashboard running yet — expected).

### Phase 4 — Install Coolify and restore data

All commands in this phase run against `root@10.0.0.60`.

#### 4a. Restore Coolify data

```bash
# Pull backups from Proxmox host to the VM (same box, fast)
scp root@10.0.0.1:/mnt/backups/coolify-data.tar.gz /tmp/
scp root@10.0.0.1:/mnt/backups/coolify-db.sql /tmp/
scp root@10.0.0.1:/mnt/backups/app-db.sql /tmp/

# Extract Coolify data directory
mkdir -p /data
tar -xzf /tmp/coolify-data.tar.gz -C /
# /data/coolify/ is now restored

# Verify expected structure
ls /data/coolify/{applications,databases,proxy,ssh,source,sentinel,services}
```

#### 4b. Configure Docker networks

Restore the `coolify` Docker network (required by Traefik to discover app containers):

```bash
docker network create coolify 2>/dev/null || true
```

#### 4c. Patch Coolify proxy config for HTTP-only operation

Before starting Coolify, reconfigure Traefik to run behind Caddy (no TLS termination):

```bash
cd /data/coolify/proxy

# Backup original compose
cp docker-compose.yml docker-compose.yml.bak

# Remove HTTPS entrypoint and Let's Encrypt config from Traefik command args.
# The key changes:
#  - Remove `- '443:443'` from ports
#  - Remove `- '--entrypoints.https.address=:443'` from command
#  - Remove `- '--entrypoints.https.http3'` from command
#  - Remove `- '--certificatesresolvers.letsencrypt.*'` from command
#  Keep `- '8080:8080'` (dashboard) and `- '80:80'` (app routing).
```

Example patched `docker-compose.yml` for Traefik service:

```yaml
services:
  traefik:
    container_name: coolify-proxy
    image: 'traefik:v3.6'
    restart: unless-stopped
    extra_hosts:
      - 'host.docker.internal:host-gateway'
    networks:
      - coolify
    ports:
      - '80:80'
      - '8080:8080'
    healthcheck:
      test: 'wget -qO- http://localhost:80/ping || exit 1'
      interval: 4s
      timeout: 2s
      retries: 5
    volumes:
      - '/var/run/docker.sock:/var/run/docker.sock:ro'
      - '/data/coolify/proxy/:/traefik'
    command:
      - '--ping=true'
      - '--ping.entrypoint=http'
      - '--api.dashboard=true'
      - '--entrypoints.http.address=:80'
      - '--entrypoints.http.http.encodequerysemicolons=true'
      - '--entryPoints.http.http2.maxConcurrentStreams=250'
      - '--providers.file.directory=/traefik/dynamic/'
      - '--providers.file.watch=true'
      - '--api.insecure=false'
      - '--providers.docker=true'
      - '--providers.docker.exposedbydefault=false'
    labels:
      - traefik.enable=true
      - traefik.http.routers.traefik.entrypoints=http
      - traefik.http.routers.traefik.service=api@internal
      - traefik.http.services.traefik.loadbalancer.server.port=8080
      - coolify.managed=true
      - coolify.proxy=true
```

Also remove HTTPS-related routers from `/data/coolify/proxy/dynamic/coolify.yaml`:

```yaml
# Remove these routers:
#   coolify-https (entrypoint: https)
#   coolify-realtime-wss (entrypoint: https)
#   coolify-terminal-wss (entrypoint: https)
#
# Keep these:
#   coolify-http (entrypoint: http, service: coolify)
#   coolify-realtime-ws (entrypoint: http, service: coolify-realtime)
#   coolify-terminal-ws (entrypoint: http, service: coolify-terminal)
```

#### 4d. Start Coolify

```bash
# Start coolify-db first, wait for it to be healthy
docker compose -f /data/coolify/source/docker-compose.yml up -d coolify-db
sleep 5

# Restore Coolify internal DB
cat /tmp/coolify-db.sql | docker exec -i coolify-db psql -U coolify

# Restore Redis volume if needed (or let it rebuild)
docker compose -f /data/coolify/source/docker-compose.yml up -d coolify-redis

# Start proxy (Traefik)
docker compose -f /data/coolify/proxy/docker-compose.yml up -d

# Start remaining Coolify services
docker compose -f /data/coolify/source/docker-compose.yml up -d
```

#### 4e. Restore the app database

```bash
# Start the managed PostgreSQL container
docker compose \
  -f /data/coolify/databases/jkprbb1mhpb9kvckev0318vg/docker-compose.yml \
  up -d

sleep 5

# Restore data
cat /tmp/app-db.sql | \
  docker exec -i jkprbb1mhpb9kvckev0318vg psql -U postgres
```

#### 4f. Re-deploy apps via Coolify dashboard

1. Open `https://coolify.mhlab.me` (should now show the Coolify login page)
2. Log in (credentials from the restored Coolify DB — same as source)
3. For each app listed in the dashboard:
   - Go to app settings → ensure "Use Custom Proxy" or proxy type is set
     to "None" / "Disabled" (no TLS termination by Traefik)
   - Use the built-in terminal/restart to re-deploy the app
4. Verify each app starts healthy:
   - `docker ps` should show all containers running
   - Check Coolify dashboard for green status indicators

#### 4g. Configure proxy settings in Coolify for long-term stability

In Coolify admin (Settings → Proxy):
- Set proxy type / mode so Coolify **does not** re-enable Let's Encrypt
- Ensure apps use the `coolify` network for Traefik discovery
- Each app's Traefik labels should reference `Host(`jobs.mhlab.me`)` etc. without
  `tls.certResolver=letsencrypt`

### Phase 5 — Verify

#### 5a. Dashboard

```bash
# External
curl -sI https://coolify.mhlab.me | head -5

# Should return 200, TLS via Caddy, backend is Coolify
```

- [ ] `https://coolify.mhlab.me` returns the Coolify login/dashboard page
- [ ] Login works
- [ ] Dashboard lists all apps
- [ ] `/terminal/ws` websocket works (open a terminal in Coolify)

#### 5b. App domains

```bash
for domain in jobs.mhlab.me prod-match.mhlab.me screenshots.mhlab.me backfill.mhlab.me; do
  echo -n "$domain: "
  curl -sI "https://$domain" | head -1
done
```

- [ ] `https://jobs.mhlab.me` responds (HTTP 200 or app-specific response)
- [ ] `https://prod-match.mhlab.me` responds
- [ ] `https://screenshots.mhlab.me` responds
- [ ] `https://backfill.mhlab.me` responds

#### 5c. Wildcard (future apps)

```bash
# Should route through Caddy → Traefik → default 503 (no app configured yet)
curl -sI -H "Host: test.backend.mhlab.me" https://168.119.81.167/
```

Expected: HTTP 503 or 404 from Traefik (catch-all router), but TLS from Caddy.

#### 5d. Internal network

```bash
# From gateway
ssh root@10.0.0.10 'curl -sI http://10.0.0.60:8080'   # Coolify dashboard (Traefik API)
ssh root@10.0.0.10 'curl -sI http://10.0.0.60:80'      # Traefik app routing
```

#### 5e. Existing services unaffected

- [ ] `https://uptime.mhlab.me` — still works
- [ ] `https://proxmox.mhlab.me` — still works
- [ ] `https://coolify-h.mhlab.me` — no longer exists (expected)

### Phase 6 — Cleanup

#### 6a. Cancel the Hetzner Cloud VM

Once all services are verified for at least 24–48 hours, cancel the cloud VM via
[Hetzner Cloud Console](https://console.hetzner.cloud/).

#### 6b. Remove temporary SSH access (optional)

If you plan to keep the cloud VM for a transition period, remove the Proxmox host's key:

```bash
ssh root@coolify.mhlab.me "
  sed -i '/$(ssh root@10.0.0.1 cat /root/.ssh/id_rsa.pub | awk '{print \$2}' | head -c 20)/d' \
    /root/.ssh/authorized_keys
"
```

If you're decommissioning the cloud VM entirely, this step is unnecessary.

#### 6c. Remove backup files (optional, after verification)

```bash
ssh root@10.0.0.1 'rm -rf /mnt/backups/coolify-* /mnt/backups/app-*'
```

Recommend keeping backups for at least one week post-migration.

#### 6d. Remove `coolify-h` DNS record

The `coolify-h.mhlab.me` A record will be removed by Terraform as part of the IaC changes in
Phase 2. The record was previously managed via `dns.tf` and will be cleaned up on apply.

#### 6e. Update docs

Update `docs/infrastructure-reference.md`:
- Add Coolify to the service table
- Update IP allocation table with `10.0.0.60`
- Add a note about Coolify's proxy architecture (Caddy → Traefik)

---

## Risks & Mitigations

| Risk | Severity | Mitigation / Resolution |
|---|---|---|
| Coolify regenerates TLS config after migration | Medium | Use Coolify's "Custom proxy" / "Disabled proxy" settings per-app to prevent Traefik from re-enabling certresolver. Monitor with `docker inspect` on containers after deploys. |
| App DB credentials mismatch after restore | Low | Credentials are in `/data/coolify/databases/*/docker-compose.yml` and `.env`. Restoring from backup preserves them. |
| DNS propagation delay | Low | All DNS changes are within the same Cloudflare zone. TTL typically low (~1 min for proxied records). Cloudflare proxying adds negligible delay. |
| Websocket breakage | Low | Caddy supports WebSocket passthrough natively. No extra config needed. |
| Port conflict between Coolify container and Traefik dashboard | Medium (hit) | **Hit.** Both wanted host port 8080. **Resolved:** Coolify on 8000 (`APP_PORT=8000`), Traefik dashboard on 8080, all Caddy routes → Traefik HTTP :80. |
| Coolify SSH key invalid on new VM | Medium (hit) | **Hit.** Keys from cloud VM weren't in new VM's `authorized_keys`. **Resolved:** extracted public keys via `ssh-keygen -y` and added to `/root/.ssh/authorized_keys`. |
| Stale server entries in Coolify DB | Low (hit) | **Hit.** `coolify3` server (old `coolify3.mhlab.me`) still referenced. **Resolved:** deleted after reassigning SSL cert to `localhost` server. |
| Rollback | — | Until cloud VM is cancelled, you can revert DNS back to the cloud IP and all services return. Proxmox VM can be destroyed with `terraform destroy`. |

---

## Timeline

| Phase | Planned | Actual | Notes |
|---|---|---|---|
| Phase 0 (prep) | < 1 min | < 1 min | |
| Phase 1 (backup) | ~5–10 min | ~15 min | App DB (14GB) took longer to dump + compress |
| Phase 2 (IaC) | ~15 min | ~10 min | 4 files modified + 1 CI workflow |
| Phase 3 (provision) | ~5 min | ~3 min | CI completed in ~90s (Terraform 17s + Ansible 66s) |
| Phase 4 (restore) | ~15–20 min | ~45 min | App DB restore (14GB uncompressed → 11GB) took ~30 min; SSH key + server fixes added time |
| Phase 5 (verify) | ~10 min | ~5 min | All services verified green |
| Phase 6 (cleanup) | After 48 hr bake-in | Pending | |

**Actual migration window:** ~1.5 hours (excluding 48-hr bake-in).

---

## Rollback Plan

If migration fails for any reason:

1. **DNS**: Point all 5 app domains back to `62.238.11.96` (Cloudflare API or manually)
2. **Cloud VM**: It's still running — services resume immediately
3. **Proxmox VM 300**: Run `terraform destroy` to clean up
4. **IaC**: Revert `terraform/locals.tf` to the old `coolify-h.mhlab.me` config, merge to main

---

## Execution Log (2026-07-18)

### Phase 0 — Complete
`/mnt/backups` created on Proxmox host.

### Phase 1 — Complete
- Proxmox host SSH authorized on cloud VM.
- Coolify DB dumped (33MB).
- App DB dumped with gzip (1.8GB, DB user `pricetracker` — not `postgres` as planned).
- `/data/coolify` tarball (2.4GB) + DB dumps + container-inspect.json pulled to Proxmox.
- Config reference captured and saved.

### Phase 2 — Complete
- `terraform/locals.tf`: `coolify-h.mhlab.me` → `coolify.mhlab.me`, added `app_domains` + `wildcard_domain`.
- `terraform/dns.tf`: Added `app_domains` + `wildcard_domains` Cloudflare A records.
- `terraform/outputs.tf`: Extended `services` output with `app_domains` + `wildcard_domain`.
- `.github/workflows/deploy.yml`: CI generates `caddy_hosts` entries for app domains + wildcard.
- Pushed to `main`, CI ran Terraform + Ansible successfully.

### Phase 3 — Complete
- Terraform destroyed VM 300 (old `coolify-h`) and recreated it.
- VM booted with Debian 13 (template 9001 — the default `debian` template, not Ubuntu 9002 as planned).
- Ansible installed Docker CE 26.1.5, configured Caddy on gateway.
- Gateway SSH key added to VM via `qm guest exec` (cloud-init only had CI runner key).

### Phase 4 — Complete
- Coolify data tarball extracted. Backups initially copied to `/tmp` (tmpfs) which filled up; moved to `/data`.
- `coolify` Docker network created.
- Proxy compose patched for HTTP-only: removed port 443, HTTPS entrypoint, Let's Encrypt resolver.
- Dynamic config patched: removed HTTPS routers (`coolify-https`, `coolify-realtime-wss`, `coolify-terminal-wss`).
- Coolify DB restored (postgres:15).
- Coolify started (`APP_PORT=8000` to avoid conflict with Traefik on 8080).
- Traefik proxy started on :80 and :8080.
- Managed app DB compose changed from `/mnt/postgres-data` bind mount to Docker volume (original mount point didn't exist on new VM).
- App DB restored (postgres:18, 14GB source → 11GB after fresh import).
- **Issue:** "Server is not functional" — Coolify SSH keys from cloud VM weren't authorized on new VM. Extracted public keys via `ssh-keygen -y` and added to `/root/.ssh/authorized_keys`.
- **Issue:** Stale `coolify3` server (old cloud VM `coolify3.mhlab.me`) in Coolify DB. Deleted after reassigning its SSL cert to `localhost`. Localhost server unreachable counter reset.
- Sentinel auto-started by Coolify after server became reachable.
- All 7 apps redeployed via Coolify dashboard.

### Phase 5 — Complete
- `https://coolify.mhlab.me` — 302 to login, dashboard functional.
- `https://uptime.mhlab.me` — unaffected.
- `https://proxmox.mhlab.me` — unaffected.
- `coolify-h.mhlab.me` DNS record — removed by Terraform.
- App domains (`jobs.mhlab.me`, `prod-match.mhlab.me`, `screenshots.mhlab.me`, `backfill.mhlab.me`) — all responding after app redeployment.
- All 8 containers healthy: `coolify-db`, `coolify-redis`, `coolify-realtime`, `coolify-proxy`, `coolify`, `coolify-sentinel`, `jkprbb1mhpb9kvckev0318vg`, `jkprbb1mhpb9kvckev0318vg-proxy`.

### Phase 6 — Pending (waiting 48-hr bake-in)
- [ ] Cancel Hetzner cloud VM (`price-tracker-vps`, 62.238.11.96)
- [ ] Remove Proxmox host SSH key from cloud VM (if keeping VM for transition)
- [ ] Remove backup files from `/mnt/backups`
- [ ] Update `docs/infrastructure-reference.md`

### Plan deviations
| Deviation | Reason |
|---|---|
| OS is Debian 13, not Ubuntu 24.04 | Template `distro` defaults to `debian` (9001) when not specified in service config |
| All Caddy routes point to port 80, not split 80/8080 | Port 8080 conflict between Coolify container and Traefik dashboard; resolved by routing everything through Traefik HTTP entrypoint on :80 |
| Coolify runs on host port 8000, not 8080 | Same port conflict — Coolify default APP_PORT (8000) avoids collision |
| App DB dump user is `pricetracker`, not `postgres` | The managed DB was configured with `POSTGRES_USER=pricetracker` |
| Managed DB uses Docker volume, not `/mnt/postgres-data` bind mount | The original `/mnt/postgres-data` path didn't exist on new VM; data restored from SQL dump |
| IaC port is 80, not 8080 in `locals.tf` | Updated to reflect actual routing |
| Deleted stale `coolify3` server from Coolify DB | Legacy server from previous setup pointing to `coolify3.mhlab.me` |
| Used `qm guest exec` to add SSH keys | Cloud-init only deployed CI runner's key; needed additional access
