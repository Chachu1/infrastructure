# PostgreSQL Offsite Backups (pgBackRest) — Restore Runbook

**Created:** 2026-10-01
**Status:** Live
**Database:** `postgres` LXC (VMID 252, `10.0.0.20`) — PostgreSQL 18.6, stanza `pt`
**Repository:** `pgbackrest-repo` LXC (VMID 150, `192.168.1.150`) on the home Proxmox host (`pve1`)
**Tooling:** pgBackRest 2.59.1 (must be identical on both ends, installed from PGDG)

> This is the DR runbook for the Price Tracker PostgreSQL database. Read the
> [Important caveats](#important-caveats) before running any restore.

---

## Architecture

```
 LXC 252 (postgres, 10.0.0.20)              existing site-to-site WireGuard
 ┌────────────────────────────┐             (gateway LXC 100  ⇄  home router)
 │ PostgreSQL 18.6  :5432     │  SSH (pgbackrest@192.168.1.150, key-based)
 │ pgbackrest (agent)  ───────┼─────────────────────────────┐
 │  • archive-push (WAL)      │                             │
 │  • backup (full/diff)      │                             ▼
 └────────────────────────────┘             ┌───────────────────────────────┐
                                            │ LXC 150 pgbackrest-repo        │
                                            │ repo1: /var/lib/pgbackrest     │
                                            │ AES-256-CBC + zstd, 15d retain │
                                            └───────────────────────────────┘
```

- **Backups + WAL archiving are driven from the database host** (LXC 252). No new VPN was
  needed — 252 reaches `192.168.1.150` through the gateway LXC's existing WireGuard tunnel.
- Repository is **encrypted** (`repo1-cipher-type=aes-256-cbc`); zstd compression.

### Key facts

| Item | Value |
|---|---|
| Stanza | `pt` |
| Repo host | `192.168.1.150` (LXC 150, user `pgbackrest`) |
| Repo path | `/var/lib/pgbackrest` (196 GB thin LV, `local-lvm`) |
| PGDATA | `/var/lib/postgresql/18/main` |
| Backup schedule | daily **03:00 UTC** — `full` on Sunday, `diff` otherwise |
| Check / Verify timers | weekly `check` (Sun 06:00 UTC), monthly `verify` (1st 06:30 UTC) |
| Retention | time-based **15 days** (`repo1-retention-full-type=time`) |
| First full | `20260930-142307F` — 26.1 GB DB → 3.8 GB on repo |

---

## Access

All `pgbackrest` commands run **as the `postgres` user inside LXC 252**:

```bash
ssh root@10.0.0.1                       # main Proxmox host (germany1)
pct exec 252 -- runuser -u postgres -- <command>
# or get a shell in the container:
# pct enter 252
```

The repo LXC is managed from the home host:

```bash
ssh root@192.168.1.149
pct exec 150 -- <command>
```

---

## Health checks (safe, read-only)

```bash
# Summary of backups and WAL range
pct exec 252 -- runuser -u postgres -- pgbackrest --stanza=pt info

# Validate config, connectivity to repo, and WAL archiving
pct exec 252 -- runuser -u postgres -- pgbackrest --stanza=pt check

# Full repository integrity check (scheduled monthly; can be slow)
pct exec 252 -- runuser -u postgres -- pgbackrest --stanza=pt verify
```

`info` should show *at least* one `full backup` and a `status: ok`. A healthy `check`
exits `0` and reports a WAL segment archived to `repo1`.

---

## Restore scenarios

> **Before you start:** every restore writes into `pg1-path`
> (`/var/lib/postgresql/18/main`). **Stop the cluster first.** The commands below are
> written to run as `root` on the main host `germany1` via `pct exec`.

### 1. Restore the latest backup (in place)

Use this to roll the database back to the most recent backup.

```bash
# 1. Stop PostgreSQL
pct exec 252 -- pg_ctlcluster 18 main stop

# 2. Restore latest backup, keeping unchanged files (--delta = checksum based)
pct exec 252 -- runuser -u postgres -- pgbackrest --stanza=pt restore --delta

# 3. Start PostgreSQL (recovery replays archived WAL to a consistent state)
pct exec 252 -- pg_ctlcluster 18 main start

# 4. Confirm
pct exec 252 -- runuser -u postgres -- pg_lsclusters
pct exec 252 -- runuser -u postgres -- psql -tAc "select pg_is_in_recovery();"
```

### 2. Point-in-time recovery (PITR)

Roll back to a specific timestamp (e.g. just before a bad migration). Timestamps are
**UTC**.

```bash
pct exec 252 -- pg_ctlcluster 18 main stop

pct exec 252 -- runuser -u postgres -- pgbackrest --stanza=pt restore \
  --delta \
  --type=time \
  --target="2026-10-01 03:00:00+00" \
  --target-action=promote

pct exec 252 -- pg_ctlcluster 18 main start
```

- `--target-action=promote` promotes the instance once the target is reached.
- Add `--target-exclusive` to stop **just before** the target.
- Omit `--target` with `--type=immediate` to recover only to the backup's consistent point
  (fastest; useful for drills).
- Use `pgbackrest --stanza=pt info` to pick a valid target inside the available WAL range.

### 3. Restore to an alternate path (non-destructive drill)

Exercises a real restore **without touching the live cluster**. Validated 2026-10-01.

```bash
RP=/var/lib/postgresql/restore-test

# 1. Empty target and restore into it
pct exec 252 -- runuser -u postgres -- rm -rf "$RP"
pct exec 252 -- runuser -u postgres -- mkdir -p "$RP"
pct exec 252 -- runuser -u postgres -- pgbackrest --stanza=pt restore \
  --pg1-path="$RP" --type=immediate

# 2. Minimal config (Debian config lives in /etc, not PGDATA). Pointing
#    data_directory at $RP avoids the live-directory trap in caveats.
cat > /tmp/drill-postgresql.conf <<EOF
data_directory = '$RP'
hba_file = '$RP/pg_hba.conf'
ident_file = '$RP/pg_ident.conf'
unix_socket_directories = '/tmp'
port = 5434
listen_addresses = ''
archive_mode = off
archive_command = ''
EOF
pct push 252 /tmp/drill-postgresql.conf "$RP/postgresql.conf"
pct exec 252 -- bash -c "cp /etc/postgresql/18/main/pg_hba.conf /etc/postgresql/18/main/pg_ident.conf '$RP/'; chown -R postgres:postgres '$RP'"

# 3. Start the temporary instance (log path must be writable by postgres)
pct exec 252 -- runuser -u postgres -- /usr/lib/postgresql/18/bin/pg_ctl -D "$RP" -w \
  -l /var/lib/postgresql/pg-temp.log start

# 4. Verify
pct exec 252 -- runuser -u postgres -- psql -h /tmp -p 5434 -tAc "select datname from pg_database order by 1;"

# 5. Stop and clean up
pct exec 252 -- runuser -u postgres -- /usr/lib/postgresql/18/bin/pg_ctl -D "$RP" -m fast stop
pct exec 252 -- runuser -u postgres -- rm -rf "$RP"
```

> The app database is named `postgres` (role `pricetracker`), so restored tables appear in
> `psql`'s default database.

### 4. Full disaster recovery (rebuild the database host)

If LXC 252 is lost:

1. Create/attach a replacement host with a matching **PostgreSQL 18** install.
2. Install **pgBackRest 2.59.1** from PGDG (version must match the repo host exactly).
3. Restore the SSH access: create a key for the `postgres` user and add its public key to
   `pgbackrest@192.168.1.150:/var/lib/pgbackrest/.ssh/authorized_keys`.
4. Create `/etc/pgbackrest/pgbackrest.conf` with the **same cipher passphrase** (see
   [Secrets](#secrets)) and `repo1-host=192.168.1.150`, `pg1-path=<new PGDATA>`.
5. `pgbackrest --stanza=pt restore --delta` into the new PGDATA, then start PostgreSQL.

---

## Configuration reference

**LXC 252 — `/etc/pgbackrest/pgbackrest.conf`** (`root:postgres`, `0640`):

```ini
[global]
repo1-host=192.168.1.150
repo1-host-user=pgbackrest
repo1-path=/var/lib/pgbackrest
repo1-cipher-type=aes-256-cbc
repo1-cipher-pass=<SECRET — see below>
repo1-retention-full=15
repo1-retention-full-type=time
compress-type=zst
process-max=4
archive-async=y
spool-path=/var/spool/pgbackrest
log-path=/var/log/pgbackrest
log-level-console=info

[pt]
pg1-path=/var/lib/postgresql/18/main
pg1-port=5432
```

**LXC 252 — WAL archiving** (`/etc/postgresql/18/main/conf.d/pgbackrest.conf`):

```ini
archive_mode = on
archive_command = 'pgbackrest --stanza=pt archive-push %p'
```

> `archive_mode` is a **postmaster setting** — changing it requires a PostgreSQL restart.

**LXC 252 — SSH (dedicated key)**:

| Item | Path |
|---|---|
| Private key | `/var/lib/postgresql/.ssh/id_ed25519_pgbackrest` (owner `postgres`, `0600`) |
| SSH client config | `/var/lib/postgresql/.ssh/config` (`Host 192.168.1.150 → User pgbackrest`) |
| Authorized key | `pgbackrest@192.168.1.150:/var/lib/pgbackrest/.ssh/authorized_keys` (restricted) |

**LXC 252 — scheduling** (`systemctl list-timers 'pgbackrest-*'`):

| Timer | Unit | Runs |
|---|---|---|
| `pgbackrest-backup.timer` | `pgbackrest-backup.service` → `/usr/local/sbin/pgbackrest-backup.sh` | daily 03:00 UTC (full Sun / diff otherwise) |
| `pgbackrest-check.timer` | `pgbackrest-check.service` | Sun 06:00 UTC |
| `pgbackrest-verify.timer` | `pgbackrest-verify.service` | 1st of month 06:30 UTC |

**LXC 150 — `/etc/pgbackrest/pgbackrest.conf`**:

```ini
[global]
repo1-path=/var/lib/pgbackrest
```

---

## Important caveats

- **Version pinning:** the pgBackRest version on LXC 252 and LXC 150 must match **exactly**
  (`2.59.1`). A mismatch stops WAL archiving and backups with a `ProtocolError`. Upgrade
  both together.
- **`data_directory` trap:** Debian's `/etc/postgresql/18/main/postgresql.conf` contains
  `data_directory = '/var/lib/postgresql/18/main'`. If you copy that file into an
  alternate restore path and start a second instance, PostgreSQL will try to open the
  **live** data directory. Always override `data_directory` (as in scenario 3) or use a
  minimal config file.
- **Tunnel dependency:** WAL archiving and backups traverse the gateway LXC's WireGuard
  tunnel. If it is down, `archive_command` fails and PostgreSQL spools WAL in
  `/var/spool/pgbackrest` (async mode) / `pg_wal`. **Monitor** spool and `pg_wal` growth;
  see [Troubleshooting](#troubleshooting). The gateway LXC is a single point of failure.
- **Repository is the backup, not the database host.** Never `expire` or delete from the
  repo manually unless you understand retention; the scheduled `expire` runs after each
  backup.
- **Restore speed:** ~50 min for the 26 GB database over the tunnel (network-bound). Plan
  DR windows accordingly. Increasing `process-max` on the backup/restore increases
  parallel streams.

### Secrets

The repository encryption passphrase (`repo1-cipher-pass`) lives **only** in
`/etc/pgbackrest/pgbackrest.conf` on LXC 252. **Without it the backups cannot be
decrypted** — store it in the password manager now. It is deliberately not committed to
this repository.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `ERROR: [087]: archive_mode must be enabled` | archiving not active | check `SHOW archive_mode;` — requires PG restart after config change |
| `ProtocolError ... expected value '2.x' ... got '2.y'` | pgBackRest version mismatch 252 vs 150 | install identical versions on both |
| `check` fails reaching repo | tunnel down / SSH key issue | `ping 192.168.1.150` from 252; verify key in `pgbackrest@.ssh/authorized_keys` |
| `pg_wal` / spool growing | WAL archiving failing | `pgbackrest --stanza=pt check`; resolve archive errors, old WAL is re-pushed automatically |
| Restore fails: `pg1-path is not empty` | missing `--delta` | re-run with `--delta` |
| Restore refuses alternate path | wrong/absent config | supply minimal `postgresql.conf` (scenario 3) |

Logs: `/var/log/pgbackrest/` on LXC 252 (e.g. `pt-backup.log`, `pt-restore.log`,
`pt-archive-push-async.log`), and `journalctl -u pgbackrest-*` for timer runs.
