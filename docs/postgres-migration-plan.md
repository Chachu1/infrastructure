# Postgres Migration: Coolify-managed DB → Standalone LXC

**Created:** 2026-07-18
**Status:** Planned

Migrate the Coolify-managed standalone PostgreSQL (container `jkprbb1mhpb9kvckev0318vg`,
postgres:18-alpine, 11 GB `postgres` DB owned by `pricetracker`) off the Coolify VM
(`10.0.0.60`) and onto the existing dedicated Postgres LXC (`10.0.0.20`, VMID 252). After
migration all 7 Coolify apps reach the database at `postgres.internal.mhlab.me:5432`.

**Out of scope:** `coolify-db` (postgres:15-alpine, the Coolify application's own internal
metadata database — servers, applications, env vars, sessions) stays on the Coolify VM
untouched.

---

## Source (Coolify-managed standalone Postgres)

| Detail | Value |
|---|---|
| Container | `jkprbb1mhpb9kvckev0318vg` |
| Host VM | coolify (`10.0.0.60`, VMID 300) |
| Image | `postgres:18-alpine` (PG 18.4) |
| User / DB | `pricetracker` (password `pricetracker`) → `postgres` (11 GB, 28 tables, UTF8) |
| Network | Docker `coolify` bridge at `172.18.0.10` — not bound to host port |
| Volume | `jkprbb1mhpb9kvckev0318vg_jkprbb1mhpb9kvckev0318vg-data` (11 GB) |
| Proxy | `jkprbb1mhpb9kvckev0318vg-proxy` (nginx:stable-alpine, host `:5544`) — **non-functional** (nginx has no `stream` block; never worked) |

How 7 Coolify apps connect today: each app carries an `PG_DSN` env var
(AES-256-GCM encrypted in Coolify's `environment_variables` table, keyed by Coolify's
`APP_KEY`). Resolved plaintext looks like
`postgres://pricetracker:pricetracker@jkprbb1mhpb9kvckev0318vg:5432/postgres` — apps
reach the DB by container name over the `coolify` Docker network.

---

## Target (Postgres LXC)

| Detail | Value |
|---|---|
| Hostname | `postgres` (LXC VMID 252) |
| IP | `10.0.0.20/24` |
| OS | Ubuntu 24.04 LXC |
| Cores / RAM / Disk | 8 / 32 GB / 200 GB |
| Version Installed | postgresql-18 (PG 18.4) — via `ansible/roles/postgresql` |
| Current encoding | **SQL_ASCII** (default cluster, empty) — must reinit to UTF8 |
| Current roles | `postgres` (system), `mohsin` (superuser, from `POSTGRES_MOHSIN_PASSWORD`) |
| `listen_addresses` | `*` (Ansible-managed) |
| `pg_hba.conf` | `host all all 10.0.0.0/24 scram-sha-256` (Ansible-managed) |
| Public exposure | None (internal-only) |

---

## Post-Migration Architecture

### Coolify VM (10.0.0.60) — what stays

- `coolify-db` (postgres:15) — Coolify's own metadata DB — unchanged
- `coolify`, `coolify-redis`, `coolify-realtime`, `coolify-proxy`, `coolify-sentinel` — unchanged
- 7 app containers — unchanged containers, only their `PG_DSN` env var changes

### What moves

- `jkprbb1mhpb9kvckev0318vg` (postgres:18) — shut down and **not restarted after bake**
- `jkprbb1mhpb9kvckev0318vg-proxy` (nginx) — shut down immediately (it never worked)

### Connection path after migration

```
App container (on coolify VM, docker network `coolify`)
   │
   │  PG_DSN = postgres://pricetracker:<PW>@postgres.internal.mhlab.me:5432/postgres
   │
   ▼
Docker DNS (10.0.0.10 — CoreDNS on gateway)
   │  resolves postgres.internal.mhlab.me → 10.0.0.20
   ▼
Postgres LXC (10.0.0.20:5432, scram-sha-256, UTF8)
```

### DNS change required

CoreDNS on gateway (`10.0.0.10`) serves the `internal.mhlab.me` zone but currently
**does not include `postgres`**. Two problems to fix:

1. **Zone record missing** — add `postgres: 10.0.0.20` to the CoreDNS `hosts` block.
   Driven by IaC via a new `internal_dns` field on service definitions.
2. **Docker on coolify VM uses upstream DNS, not CoreDNS** — the VM's netplan points
   resolvers at Hetzner DNS (185.12.64.2), and Docker inherits the host resolv.conf.
   Add `"dns": ["10.0.0.10"]` to `/etc/docker/daemon.json` on the coolify VM so
   containers query CoreDNS. (Host processes don't need resolving the internal
   name — systemd-resolved is left alone.)

---

## Files to Modify

| File | Changes |
|---|---|
| `terraform/locals.tf` | Add `internal_dns = "postgres"` to the `postgres` service block |
| `terraform/outputs.tf` | Emit a new `internal_dns` map (`{ name => ip }`) for services with `internal_dns != ""` |
| `.github/workflows/deploy.yml` | (a) Merge `terraform output -json internal_dns` into `dns_records` in gateway_services.yml. (b) Add `POSTGRES_PRICETRACKER_PASSWORD` to the `ansible` job's `env:` block. |
| `ansible/roles/postgresql/tasks/main.yml` | Insert idempotent reinit-to-UTF8 step (only when cluster is SQL_ASCII and empty); append idempotent `pricetracker` superuser + DB creation step |
| `ansible/roles/docker_host/templates/daemon.json.j2` | New template: `{"dns": ["10.0.0.10"], "log-driver": "json-file"}` gated by `dns_configured: true` |
| `ansible/roles/docker_host/tasks/main.yml` | Render the daemon.json template when `dns_configured: true` is set. **Do NOT restart Docker in the role** — restart is a manual cutover step (Phase 4). |
| `ansible/inventory/group_vars/all/main.yml` | Add `dns_configured: true` (applies to postgres LXC and coolify VM via the `common`/`docker_host` roles) |
| `docs/infrastructure-reference.md` | Add postgres LXC to the service table (IP `10.0.0.20`, internal DB `postgres.internal.mhlab.me`, migration note) |

### Proposed `locals.tf` change (postgres block only)

```hcl
postgres = {
  type         = "lxc"
  distro       = "ubuntu"
  vm_id        = 252
  cores        = 8
  memory       = 32768
  disk         = 200
  ip           = "10.0.0.20/24"
  internal_dns = "postgres"           # serves postgres.internal.mhlab.me in CoreDNS
}
```

### Proposed `outputs.tf` addition

```hcl
output "internal_dns" {
  description = "Internal hostnames to add to CoreDNS (internal.mhlab.me zone)"
  value = {
    for name, svc in local.services : svc.internal_dns => split("/", svc.ip)[0]
    if try(svc.internal_dns, "") != ""
  }
}
```

### Proposed `deploy.yml` change (gateway services vars generation)

```python
# merge internal_dns into dns_records so CoreDNS serves it
internal_dns = json.loads(subprocess.check_output(
    ['terraform', 'output', '-json', 'internal_dns']
))  # { "postgres": "10.0.0.20", ... }
result['dns_records'].update(internal_dns)
```

### Proposed `postgresql` role additions (task ordering)

```yaml
# After "Install PostgreSQL 18" (line 34) and BEFORE "Configure listen addresses":

- name: Reinit cluster as UTF8 if currently SQL_ASCII (Idempotent — only runs once)
  block:
    - name: Check current cluster encoding
      become: yes
      become_user: postgres
      shell: psql -tAc "SELECT pg_encoding_to_char(encoding) FROM pg_database WHERE datname='template0'"
      register: pg_encoding
      changed_when: false

    - name: Reinit cluster as UTF8 (only if currently SQL_ASCII)
      when: pg_encoding.stdout | trim == 'SQL_ASCII'
      block:
        - name: Stop PostgreSQL
          systemd:
            name: postgresql
            state: stopped

        - name: Drop existing empty SQL_ASCII cluster
          shell: pg_dropcluster 18 main --stop

        - name: Recreate cluster as UTF8
          shell: pg_createcluster 18 main --encoding=UTF8 --locale=C.UTF-8 --start

# After existing "Create superuser mohsin" step:

- name: Create superuser pricetracker (idempotent)
  become: yes
  become_user: postgres
  shell:
    cmd: |
      psql -tc "SELECT 1 FROM pg_roles WHERE rolname='pricetracker'" | grep -q 1 || \
      psql -c "CREATE ROLE pricetracker WITH LOGIN SUPERUSER PASSWORD '{{ lookup('env', 'POSTGRES_PRICETRACKER_PASSWORD') }}'"
  changed_when: false
  no_log: true

- name: Ensure postgres database is owned by pricetracker (idempotent)
  become: yes
  become_user: postgres
  shell:
    cmd: |
      psql -tc "SELECT 1 FROM pg_database WHERE datname='postgres' AND pg_get_userbyid(pg_database_owner)='pricetracker'" | grep -q 1 || \
      ( psql -c "ALTER DATABASE postgres OWNER TO pricetracker" && \
        psql -c "GRANT ALL ON DATABASE postgres TO pricetracker" )
  changed_when: false
  no_log: true
```

> **Note on ordering:** the reinit block runs *before* `Configure listen addresses` and
> `Configure pg_hba.conf` because `pg_dropcluster`+`pg_createcluster` wipes those config
> files. The existing lineinfile tasks then re-apply them and queue `restart postgresql`
> notifications; `meta: flush_handlers` (already present at line 58) dedupes them to one
> restart. The existing `Create superuser mohsin` step then runs against the fresh UTF8
> cluster and recreates `mohsin` because its idempotency guard `SELECT 1 FROM pg_roles`
> will now return nothing.

### Proposed `daemon.json.j2` (new, in `docker_host` role)

```json
{
  "dns": [{% for ns in dns_servers %}"{{ ns }}"{% if not loop.last %}, {% endif %}{% endfor %}],
  "log-driver": "json-file"
}
```

Gated by `dns_configured: true`:

```yaml
- name: Configure Docker daemon (DNS + log driver)
  template:
    src: daemon.json.j2
    dest: /etc/docker/daemon.json
    mode: "0644"
  when: dns_configured | default(false) | bool
  # NOTE: Do NOT restart Docker here — applies on next manual `systemctl restart docker`
  #       during Phase 4 cutover. Restarting mid-CI would tank Coolify + apps.
```

---

## Execution Plan

### Phase 0 — Secrets bootstrap (~5 min)

Generate the new `pricetracker` password and wire it through CI / Ansible before any
IaC commit so the first run that includes the new `postgresql` role step succeeds.

```bash
# Dev machine — generate and set as GitHub Actions secret
PW=$(openssl rand -base64 24 | tr -d '=+/' | head -c 32)
echo "$PW" | gh secret set POSTGRES_PRICETRACKER_PASSWORD --repo Chachu1/infrastructure

# Encrypt into Ansible vault (reuse existing vault password workflow)
ansible-vault encrypt_string --name POSTGRES_PRICETRACKER_PASSWORD "$PW" \
  >> ansible/inventory/group_vars/all/vault.yml
```

**Verify** before proceeding: `gh secret list --repo Chachu1/infrastructure | grep POSTGRES_PRICETRACKER_PASSWORD`

### Phase 1 — IaC / Ansible changes (commit + push → CI runs)

Order matters — do them as separate commits so a failed CI run can be scoped to one
cause.

**1a. Add `internal_dns = "postgres"` to `terraform/locals.tf`** (postgres block) and
the new `internal_dns` output in `terraform/outputs.tf`. Extend
`.github/workflows/deploy.yml` to merge that output into `dns_records` in
`gateway_services.yml`. Push and merge. CI will run terraform (no infra changes,
postgres LXC already exists) and update the Corefile on the gateway via Ansible.

**Verify:** On gateway, `dig @127.0.0.1 postgres.internal.mhlab.me` returns `10.0.0.20`.

**1b. Add `POSTGRES_PRICETRACKER_PASSWORD` to the `ansible` job's `env:` block in
`deploy.yml`.** (Only relevant once the postgresql role references it — bundle this
commit with 1d.)

**1c. Add the new `daemon.json.j2` template + task to the `docker_host` role** (gated by
`dns_configured`). Set `dns_configured: true` in
`ansible/inventory/group_vars/all/main.yml`. Push and merge. CI applies the file but
**does not restart Docker** — only writes `/etc/docker/daemon.json` on the coolify VM.

**Verify:** On coolify VM, `cat /etc/docker/daemon.json` shows the new file; `systemctl
status docker` shows it still running with old config (no restart yet).

**1d. Extend the `postgresql` role** with the two new task blocks above (reinit to UTF8
and create `pricetracker`). Push and merge. CI runs against the postgres LXC:

- Reinit detects SQL_ASCII → drops empty cluster → recreates as UTF8 → starts
- Re-applies `listen_addresses = '*'` and `pg_hba.conf` entries (existing lineinfile
  tasks still run after the reinit)
- Flush handler → one restart
- `Create superuser mohsin` runs (existing) → recreates `mohsin` on the fresh cluster
- `Create superuser pricetracker` runs (new) → creates with new password
- `Ensure postgres DB owned by pricetracker` runs (new)

**Verify before Phase 3:**
```bash
ssh root@10.0.0.1 'pct exec 252 -- bash -c "sudo -u postgres psql -c \"\l\""'
# Expect: postgres | pricetracker | UTF8
ssh root@10.0.0.1 'pct exec 252 -- bash -c "sudo -u postgres psql -c \"\du\""'
# Expect: mohsin, postgres, pricetracker all present
```

### Phase 2 — REMOVED (handled by Phase 1d via CI)

### Phase 3 — Data migration (downtime begins, ~10 min dump + ~20 min restore)

All commands from the dev machine via `ssh root@10.0.0.1` (Proxmox host) then
`ssh root@10.0.0.60` (coolify VM). Coolify VM can reach `10.0.0.20:5432` directly
(verified).

**3a. Stop the 7 app containers** so no writes are missed:

```bash
ssh root@10.0.0.1 'ssh root@10.0.0.60 "
  docker ps --filter label=coolify.type=application -q | xargs -r docker stop"
"
```

> **Note:** Coolify dashboard itself stays up. Apps show "paused/unreachable" in the
> UI — expected.

**3b. Dump from the Coolify-managed container:**

```bash
ssh root@10.0.0.1 'ssh root@10.0.0.60 "
  mkdir -p /data/migration &&
  docker exec jkprbb1mhpb9kvckev0318vg \
    pg_dump -U pricetracker -d postgres --no-owner --no-privileges \
    | gzip > /data/migration/pg-migration-dump.sql.gz &&
  ls -lh /data/migration/pg-migration-dump.sql.gz
"
```

**3c. Restore to the Postgres LXC from the coolify VM** (no second hop — coolify VM
can reach `10.0.0.20:5432` directly per pg_hba.conf):

```bash
# Get the vaulted password locally for the restore (or pull from Vault)
PGPASSWORD='<NEW_PASSWORD>'  # filled in from Ansible vault
ssh root@10.0.0.1 "ssh root@10.0.0.60 'zcat /data/migration/pg-migration-dump.sql.gz \
  | PGPASSWORD=\"$PGPASSWORD\" psql -h 10.0.0.20 -U pricetracker -d postgres -v ON_ERROR_STOP=1'"
```

**3d. Verify data parity**:

```bash
ssh root@10.0.0.1 'ssh root@10.0.0.60 "
  echo \"Source:\"; docker exec jkprbb1mhpb9kvckev0318vg psql -U pricetracker -d postgres -c \"SELECT count(*) FROM <largest_table>\" '
ssh root@10.0.0.1 'pct exec 252 -- bash -c "sudo -u postgres psql -d postgres -c \"\dt\" | head -30"'
ssh root@10.0.0.1 'pct exec 252 -- bash -c "sudo -u postgres psql -d postgres -c \"SELECT count(*) FROM <largest_table>\""'
```

Spot-check at least one row containing non-ASCII text to confirm UTF8 round-trip.

### Phase 4 — Cutover app env vars (downtime continues, ~15 min)

**4a. Manually update `PG_DSN` on each of the 7 apps via the Coolify UI:**

For each application (`Price-Tracker-Jobs`, `transform-worker`,
`price-tracker-frontend`, `price-tracker-screenshots`, `Backfill Price`,
`price_-tracker:categorizer`, `price-tracker:matchin-review-api`):

1. Open app → Environment Variables
2. Edit `PG_DSN` to:
   ```
   postgres://pricetracker:<NEW_PASSWORD>@postgres.internal.mhlab.me:5432/postgres
   ```
3. Save (Coolify re-encrypts with `APP_KEY` on save — no manual decryption needed)

**4b. Apply the daemon.json change on the coolify VM** (this is the deferred restart
from Phase 1c):

```bash
ssh root@10.0.0.1 'ssh root@10.0.0.60 "systemctl restart docker"'
```

All containers (Coolify + apps) restart. `coolify-db` and Coolify itself come back up
with state intact (its volume was never touched).

**4c. Trigger a redeploy on each app from the Coolify UI** so fresh containers pick up
both the new env and the new DNS configuration.

### Phase 5 — Verify (~10 min)

```bash
# 5a. App container can reach the new DB (pick any running app container)
ssh root@10.0.0.1 'ssh root@10.0.0.60 "
  C=\$(docker ps --filter label=coolify.type=application -q | head -1) &&
  docker exec \$C sh -c 'apk add --no-cache postgresql-client >/dev/null 2>&1 || apt-get install -y postgresql-client >/dev/null 2>&1; psql \"\$PG_DSN\" -c \"SELECT version()\"'
"

# 5b. No app still references the old managed container name in fresh logs
ssh root@10.0.0.1 'ssh root@10.0.0.60 "
  for c in \$(docker ps --filter label=coolify.type=application -q); do
    docker logs --since 30m \$c 2>&1 | grep -i jkprbb1mhpb9kvckev0318vg && echo \"FAIL: \$c\" || true
  done
"
```

**5c. Public domain responses:**

```bash
for d in jobs.mhlab.me prod-match.mhlab.me screenshots.mhlab.me backfill.mhlab.me coolify.mhlab.me; do
  echo -n "\$d: "; curl -sI https://\$d | head -1
done
# Expected: each returns 2xx/3xx — apps reading/writing from the new DB
```

### Phase 6 — Cleanup (after 24-hour bake-in)

**6a.** Stop & remove the managed postgres and its nginx proxy on the coolify VM:

```bash
ssh root@10.0.0.1 'ssh root@10.0.0.60 "
  cd /data/coolify/databases/jkprbb1mhpb9kvckev0318vg &&
  docker compose down
"
```

**6b.** Remove the 11 GB Docker volume:

```bash
ssh root@10.0.0.1 'ssh root@10.0.0.60 "
  docker volume rm jkprbb1mhpb9kvckev0318vg_jkprbb1mhpb9kvckev0318vg-data
"
```

**6c.** Remove the Coolify-managed postgres record + clean up FK orphans:

```sql
-- Remove the standalone postgres record
DELETE FROM standalone_postgresqls WHERE uuid = 'jkprbb1mhpb9kvckev0318vg';

-- Check + clean orphans before deleting
SELECT 'ssl_certificates' AS tbl, count(*) FROM ssl_certificates WHERE server_id IN (
  SELECT id FROM servers WHERE uuid = 'jkprbb1mhpb9kvckev0318vg'
);
SELECT 'application_settings' AS tbl, count(*) FROM application_settings WHERE destination_id IN (
  SELECT id FROM standalone_dockers WHERE server_id IN (
    SELECT id FROM servers WHERE uuid = 'jkprbb1mhpb9kvckev0318vg'
  )
);
-- If counts > 0, re-point the FK to the localhost server (id 0) or DELETE the rows.

-- Verify applications now reference the localhost standalone docker destination
SELECT a.id, a.name, a.destination_id
  FROM applications a JOIN standalone_dockers sd ON a.destination_id = sd.id
  WHERE sd.server_id = 0;
-- All 7 apps should appear here with destination pointing at the localhost.
```

**6d.** Keep the dump on the coolify VM for one week as a rollback safety net, then
remove:

```bash
ssh root@10.0.0.1 'ssh root@10.0.0.60 "rm /data/migration/pg-migration-dump.sql.gz"'
```

**6e.** Update `docs/infrastructure-reference.md` — add postgres LXC to the service
table:

| Service | Host | IP | Type | Notes |
|---|---|---|---|---|
| Postgres | LXC (252) | 10.0.0.20 | Internal DB | Hosts price-tracker data; `postgres.internal.mhlab.me` (CoreDNS); Coolify-managed postgres decommissioned 2026-07 |

---

## Risks & Mitigations

| Risk | Severity | Mitigation |
|---|---|---|
| Reinit wipes `mohsin` and breaks other systems relying on it | Medium | `mohsin` is re-created by the existing idempotent step in the `postgresql` role — task ordering verified: reinit runs *before* `Create superuser mohsin` |
| Reinit runs a second time and wipes restored app data | High | Idempotent guard checks encoding: only reinitializes when `template0` encoding is `SQL_ASCII`. Once Phase 1d has run once, encoding is `UTF8` and the block is skipped forever. |
| `pricetracker` password exposed in Vault or CI logs | Medium | `no_log: true` on the Ansible task that uses it; GitHub secret is not echoed. Vault is encrypted at rest. |
| App env-var update fails for some apps → partial cutover | Medium | Update is manual per-app via UI — order independent. If any fails, revert that app's `PG_DSN` back to the old Coolify-managed DSN (container still running until Phase 6). |
| Docker restart in Phase 4b tanks all coolify containers unexpectedly | Low | Phase 4b is a scheduled, manual cutover step — by design. Apps are already stopped at this point. |
| DNS orphans in `ssl_certificates` / `application_settings` break Coolify UI after Phase 6c | Low | Phase 6c explicitly checks FK references and re-points to localhost server (id 0) before deleting. |
| Restored table migrations history causes Laravel to skip schema changes | Low | All 28 tables including `migrations` table are restored verbatim. Max batch number is preserved, so redeployed apps won't re-run completed migrations. (Spot-check in Phase 5.) |
| Encoded strings (UTF8 → SQL_ASCII) corruption during restore | High | Cluster reinitialized as UTF8 in Phase 1d, well before Phase 3 restore. Restore target is UTF8-native. |
| Rollback | — | Until Phase 6 runs (24 hr after cutover), the Coolify-managed postgres container is still running with all 11 GB of data intact. Rollback = revert `PG_DSN` per app, redeploy. Zero data loss window. |

---

## Timeline

| Phase | Duration | Notes |
|---|---|---|
| Phase 0 (secrets) | ~5 min | Generate password, set GH secret, vault entry |
| Phase 1 (IaC) | ~20 min | 4 commits, each waits for CI (~2 min each) |
| Phase 1d verification | ~5 min | Confirm UTF8 cluster + users |
| Phase 3 (downtime begins) | ~30 min | Stop apps → dump → restore → verify |
| Phase 4 (env var cutover) | ~15 min | 7 apps × UI edit + Docker restart + redeploy |
| Phase 5 (verify) | ~10 min | spot-check from inside containers |
| Phase 6 (cleanup) | After 24 hr bake-in | ~10 min live work + doc update |

**Total estimated migration window (downtime): ~45 min** (Phases 3 + 4 + initial verify).

---

## Rollback Plan

If Phase 5 verification fails:

1. **Revert each app's `PG_DSN`** in the Coolify UI back to:
   ```
   postgres://pricetracker:pricetracker@jkprbb1mhpb9kvckev0318vg:5432/postgres
   ```
   (The old password `pricetracker` and container name still work — nothing has changed
   on the source side until Phase 6 cleanup.)
2. **Redeploy each app** from the Coolify UI to pick up the reverted env var.
3. **Do NOT run Phase 6** — leave the managed postgres container running.
4. **Investigate** the failure (likely DNS resolution from inside containers, or pg_hba
   rejection).
5. Once confirmed working in a separate test (e.g. from a one-off `docker run --rm` with
   the new DSN), re-attempt Phase 4.

If Phase 1d (cluster reinit) breaks the LXC: re-run the `postgresql` Ansible role from
a clean state. The role is fully idempotent and will recreate `mohsin` and `pricetracker`
and the `postgres` DB on the next CI run. Any restored app data (if Phase 3 had already
run) would be lost and would need re-restoring from `/data/migration/pg-migration-dump.sql.gz`
on the coolify VM.

If you want to revert the IaC commits entirely:
```bash
git revert <phase-1d-commit> <phase-1c-commit> <phase-1b-commit> <phase-1a-commit>
git push origin main
```
CI re-runs Ansible, restoring the LXC to its pre-migration state (the postgresql role
without the new steps). No data is destroyed by an IaC revert.