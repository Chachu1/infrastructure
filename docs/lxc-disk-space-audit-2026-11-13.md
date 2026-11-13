# LXC Disk Space Audit — 2026-11-13

**Scope:** Proxmox host `germany1` (PVE 9.2.10) and all 20 LXC containers.
**Mode:** Read-only analysis. No cleanup, resize, or configuration change was applied.
**Data source:** live `pct exec` measurements on 2026-11-13 (UTC), `df`, `du`,
`journalctl --disk-usage`, `lvs`, `git count-objects -vH`.
**Units:** 1024-based (as reported by `df -BM` / `du -sm`). “GB” below means GiB.

**Contents:** [1. Executive summary](#1-executive-summary) ·
[2. Fleet snapshot](#2-fleet-snapshot) ·
[3. Where the space went](#3-where-the-space-actually-went) ·
[4. Immediate runbook](#4-immediate-cleanup-runbook-no-code-changes) ·
[5. Cleanup process](#5-cleanup-process-implemented) ·
[6. Structural fixes](#6-structural-fixes-app-repo--deploy-artifact) ·
[7. What not to delete](#7-what-not-to-delete) ·
[8. Appendix](#8-appendix--method-and-raw-numbers) ·
[9. Security observation](#9-additional-observation-not-disk-related)

---

## 1. Executive summary

The workers are **not full of application data**. They are full of **build and
deploy residue** that accumulated on the container root filesystem:

| Finding | Measured | Why it matters |
|---|---:|---|
| Total provisioned for the 15 app LXCs | **172 GB** | Only ~10–12 GB per container, shared with OS + builds |
| Total used by the 15 app LXCs | **101 GB** | 59% average, but concentrated in 5 containers |
| Safe, no-code-change reclaim | **~47 GB** on app LXCs / **~51 GB fleet-wide** | Can be done today with cache/log cleanup |
| Of that, `uv` build cache | **37.9 GB** | 24.1 GB is stale PyTorch/CUDA wheels, referenced by no venv |
| Stale ML/CUDA wheels on 5 LXCs | **24.1 GB** | Root cause of the 85–100% containers |
| Unrelated monorepo payload in releases | **~12.4 GB** | Every release exports a 462 MB `pipelines/matcher` tree |
| Git bare clones | **6.3 GB** | ~500 MB on the 13 current repos; dominated by the 462 MB matcher dataset on `main` |
| APT archive cache | **6.5 GB fleet-wide** | Includes 1.7 GB of old Chromium `.deb` on uptime-kuma |
| Journald above a 200 MB cap | **3.1 GB** | Default 10%-of-filesystem cap; no cap configured |
| Old Playwright browser revisions | **2.0 GB present** | Rollback-safe pruning keeps revisions referenced by retained releases |

**Most urgent:** `review-api` (261) and `transform-worker` (264) are at **100%,
0 bytes free**, and are already logging `No space left on device`. `categorizer`
(260) is at **97% with 287 MB free**. These three can fail a deploy, an apt
upgrade, or a log write at any time.

**The good news:** none of this is application data. The data stores are healthy
(`postgres` 29%, `graylog` 16%), and the Proxmox thin pool is only **8.6% used**
(627 GB of 7.15 TB). The problem is per-container filesystem exhaustion, not
host capacity.

**Recommended approach:** a small immediate cleanup (Section 4), followed by a
deploy-time + weekly cleanup process (Section 5, now implemented in the repo),
plus two structural fixes: stop exporting the whole monorepo into every release,
and keep ML dependencies out of the deploy path (Section 6).

---

## 2. Fleet snapshot

`Reclaim` is the conservative “safe now” estimate: `uv` cache + APT archives +
journald above 200 MB + old Playwright revisions + npm cache + leaked `/tmp`
profiles + git garbage. It does **not** include release pruning, removing the
checked-in `pipelines/` payload, or resizing disks.

| VMID | LXC | Disk | Used | Free | Use | Status | Main consumer | Safe reclaim | Projected |
|---:|---|---:|---:|---:|---:|---|---|---:|---:|
| 100 | gateway | 4G | 1.9G | 1.8G | 52% | OK | OS + Caddy | 0.3 GB | 40% |
| 200 | github-runner | 10G | 3.7G | 5.5G | 41% | OK | runner work dirs | 0.1 GB | 37% |
| 251 | uptime-kuma | 10G | 5.2G | 4.0G | 57% | OK | APT cache (1.7 GB) | 1.6 GB | 37% |
| 252 | postgres | 196G | 52.5G | 133.3G | 29% | OK | Postgres data (expected) | 0.2 GB | 27% |
| 260 | categorizer | 10G | 9.0G | 0.3G | **97%** | **CRITICAL** | uv cache (6.0 GB, 77% ML) | 6.3 GB | 27% |
| 261 | review-api | 10G | 9.2G | 0.0G | **100%** | **CRITICAL** | uv cache (6.1 GB, 76% ML) | 6.4 GB | 29% |
| 262 | job-tracker-api | 10G | 5.6G | 3.7G | 61% | WATCH | uv cache (1.0 GB) | 1.8 GB | 39% |
| 263 | dashboard-api | 10G | 4.9G | 4.3G | 54% | OK | uv cache (0.9 GB) | 1.2 GB | 38% |
| 264 | transform-worker | 10G | 9.2G | 0.0G | **100%** | **CRITICAL** | uv cache (5.9 GB, 78% ML) | 6.2 GB | 31% |
| 265 | backfill-ui | 10G | 4.8G | 4.5G | 52% | OK | uv cache (0.9 GB) | 1.1 GB | 37% |
| 266 | screenshot-service | 12G | 9.4G | 1.7G | 85% | **HIGH** | uv cache (5.6 GB, 82% ML) | 6.6 GB | 24% |
| 267 | local-scraper | 12G | 6.2G | 4.8G | 57% | OK | uv cache (1.3 GB) | 2.4 GB | 33% |
| 268 | enrichment-worker | 12G | 8.5G | 2.6G | 77% | **HIGH** | uv cache (1.7 GB) | 3.8 GB | 40% |
| 269 | frontend | 12G | 6.6G | 4.5G | 60% | WATCH | npm cache + 3 releases | 1.3 GB | 45% |
| 270 | pg-backup | 10G | 2.1G | 7.1G | 23% | OK | OS + releases | 0.3 GB | 19% |
| 271 | pdp-enricher | 12G | 5.5G | 5.6G | 50% | OK | uv cache (0.8 GB) | 1.7 GB | 32% |
| 272 | carrefour-scraper | 12G | 6.2G | 4.9G | 56% | OK | uv cache (1.2 GB) | 2.4 GB | 33% |
| 273 | tailoring-erp | 10G | 1.7G | 7.5G | 19% | OK | OS + sqlite | 0.2 GB | 15% |
| 274 | pvl-verifier | 24G | 12.0G | 10.4G | 54% | OK | uv cache (6.2 GB, 86% ML) | 6.6 GB | 23% |
| 280 | graylog | 59G | 8.9G | 46.9G | 16% | OK | Graylog/OpenSearch (expected) | 0.4 GB | 14% |

Five containers (`260`, `261`, `264`, `266`, `268`) account for **45.3 GB** of
the 101 GB used and **29.2 GB** of the 47 GB safe reclaim.

> **Playwright caveat:** the 2.0 GB is the total present on disk. The implemented
> cleanup keeps every revision referenced by a retained release, so it does not
> reclaim the 676 MB used by `carrefour-scraper` and `enrichment-worker` until
> those releases rotate out. Immediate Playwright reclaim today is ~651 MB
> (`screenshot-service`). The table's Playwright component is therefore an
> upper bound.

---

## 3. Where the space actually went

### 3.1 `uv` build cache — 37.9 GB (the dominant cause)

Every Python LXC has an unbounded `uv` cache at:

```
/opt/<app>/.cache/uv
```

`uv` uses `$HOME` to locate its cache. The app users have `HOME=/opt/<app>`
(`getent passwd categorizer` → `/opt/categorizer`), so all deploys write there.
The cache is **never pruned** by the deploy role, and `uv` keeps every package
version it has ever resolved.

Measured cache sizes (MB):

| LXC | `uv` cache | Of which ML/CUDA | Share |
|---|---:|---:|---:|
| categorizer | 6,182 | 4,788 | 77% |
| review-api | 6,273 | 4,788 | 76% |
| transform-worker | 6,089 | 4,791 | 78% |
| screenshot-service | 5,780 | 4,791 | 82% |
| pvl-verifier | 6,317 | 5,483 | 86% |
| job-tracker-api | 1,073 | 0 | 0% |
| local-scraper | 1,339 | 0 | 0% |
| enrichment-worker | 1,775 | 0 | 0% |
| carrefour-scraper | 1,253 | 0 | 0% |
| dashboard-api | 947 | 0 | 0% |
| backfill-ui | 890 | 0 | 0% |
| pdp-enricher | 847 | 0 | 0% |
| tailoring-erp | 4 | 0 | 0% |
| **Total** | **37,860** | **24,641** | 65% |

The ML entries are **PyTorch 2.13/2.15 + Triton + CUDA 13 wheels**:

```
1077 MB  torch 2.13.0
 689 MB  triton 3.7.1
 570 MB  nvidia-cublas 13.1.1.3
 472 MB  nvidia-cudnn-cu13 9.20.0.48
 275 MB  nvidia-cufft 12.0.0.61
 235 MB  nvidia-cusolver 12.0.4.66
 227 MB  nvidia-nccl-cu13 2.29.7
 224 MB  nvidia-cusparselt-cu13 0.8.1
 218 MB  nvidia-cuda-nvrtc 13.0.88
 ...
```

**They are not used.** No current venv on any LXC imports `torch`, `triton`,
`scipy`, or `numpy`:

```
260 categorizer        torch=False numpy=False
261 review-api         torch=False numpy=False
...
274 pvl-verifier       torch=False numpy=False
```

The cache entries are stale: the torch entry on `categorizer` dates from
**2026-08-21**, on `screenshot-service` from **2026-08-29**. A sample torch file
inside the cache has **hardlink count 1**, i.e. it is referenced only by the
cache and by no release or venv.

**Why it happened:** the app repo's root `pyproject.toml` declares heavy ML
dependencies as *base* dependencies:

```toml
# Price_Tracker/pyproject.toml
dependencies = [
  ...
  "numpy>=1.26.0",
  "scipy>=1.13.0",
  "pandas>=3.0.1",
  "playwright>=1.60.0",
  "sentence-transformers>=5.6.0",   # -> torch + CUDA
]
```

Any deploy path that falls back to `uv pip install .` at the repo root resolves
that tree and downloads ~5 GB of CUDA wheels into the cache. The normal
`deploy.yml` path uses per-service `requirements.txt`, so the wheels are not
installed in the venv — but they stay in the cache forever.

**Safe to delete?** Yes. `uv` hardlinks package files into each release venv
(link count 4 = cache + 3 releases for normal packages). Deleting cache entries
does not remove the venv copies. The hardlinked set is only ~90 MB per LXC, so
`du` overstates the freeable amount by less than 2%.

### 3.2 Playwright browser cache — 2.0 GB of accumulated revisions

Browser workers keep every Chromium revision ever installed:

| LXC | Present revisions | Active revision | Old, reclaimable |
|---|---|---|---:|
| screenshot-service | 1187, 1234 | 1187 (Playwright 1.55.0) | 651 MB (1234) |
| enrichment-worker | 1248, 1254 | 1254 (Playwright 1.65.1) | 676 MB (1248) |
| carrefour-scraper | 1228, 1248 | 1228 (patchright 1.61.2) | 676 MB (1248) |
| local-scraper | 1248 | 1248 | 0 |
| pvl-verifier | 1187 | 1187 | 0 |

`playwright install` never removes old revisions when the pinned version bumps.
The active revision is recorded in a release venv's `browsers.json`
(`playwright` or `patchright`). The implemented cleanup keeps the **union of
revisions referenced by every retained release**, not just the current one:
`deploy.yml` skips `playwright install` when an old release's venv already
exists, so deleting its browser would make a rollback fail at launch. An old
revision is reclaimed only after the release that references it is pruned.

The `uv`-managed Python at `/opt/<app>/.local/share/uv/python/` (~109 MB per LXC)
looks like a cache but **is not** — the current venvs symlink to it. Do not
delete it.

### 3.3 APT archive cache — 6.5 GB

`/var/cache/apt/archives` is never cleaned. The weekly maintenance playbook runs
`apt upgrade` but has no `apt-get clean` step.

- `uptime-kuma`: **1.7 GB**, almost entirely old Chromium `.deb` files
  (152 → 156, 78 MB each).
- App LXCs: **269–450 MB** each, including a 67 MB `filebeat` `.deb`, old
  gcc/g++ packages, and multiple Chromium versions on `pvl-verifier`.
- `postgres`, `graylog`, `gateway`, `runner`: 142–361 MB each.

All of it is cache; `apt-get clean` is safe. Adding
`APT::Periodic::AutocleanInterval "7";` to `20auto-upgrades` prevents the
build-up.

### 3.4 Journald — 3.1 GB above a sensible cap

None of the containers configure `SystemMaxUse`, so journald uses its default
10%-of-filesystem cap:

| LXC | Journal | 10% cap on that FS |
|---|---:|---:|
| enrichment-worker | 1,228 MB | 1.2 GB |
| local-scraper | 1,024 MB | 1.2 GB |
| pdp-enricher | 866 MB | 1.2 GB |
| job-tracker-api | 712 MB | 1.0 GB |
| carrefour-scraper | 333 MB | 1.2 GB |
| others | 48–227 MB | — |

On a 10–12 GB worker, a 1.2 GB local journal is a poor use of space, especially
since logs are already shipped to Graylog by filebeat. A 200 MB cap reclaims
**3.1 GB** across the fleet and still keeps plenty of local history.

### 3.5 Release artifacts — 17.7 GB, and ~12.4 GB is unrelated monorepo payload

The deploy model keeps 3 immutable releases per app. That is reasonable, but
each release is a `git archive` of the **entire repository**, not just the
service being deployed.

For `categorizer`, the current release is 540 MB:

```
462 MB  pipelines/matcher/...   <- FAISS indexes, embeddings, notebooks
 69 MB  venv
 25 MB  legacy/hetzner/.terraform/providers/...
  2 MB  services/                <- the actual categorizer code
  2 MB  shared/
```

The deployed services do **not** import `pipelines` or read
`pipelines/matcher/data` (checked across all service directories). The only
runtime data path outside the service is `dashboard-api`'s
`data/labeling/v1`; that is `data/`, not `pipelines/`.

Across all current releases:

| Payload | Size |
|---|---:|
| `pipelines/` copied into releases | **11.4 GB** |
| `legacy/` copied into releases | **1.0 GB** |
| Total unrelated per-LXC payload | **~12.4 GB** |

The current release for services deployed after the matcher data landed contains
~462 MB of `pipelines/` and ~25 MB of `legacy/`. With 3 releases retained, that
is ~1.4 GB per LXC. Path-limited `git archive` (or removing the data from git)
is the single biggest structural win after the `uv` cache.

**Incomplete releases:** `review-api` and `transform-worker` each have a 4th
release from a failed deploy on 2026-11-09 (`c7987eff…`) with **no venv** (89 MB
and 228 MB). The Ansible `deploy.yml` runs the release-prune task at the end of
the success block; the `always` block only releases the lock. A failure before
prune therefore leaves the partial release behind. The helper script
`/usr/local/bin/deploy-<app>.sh` does prune in an `EXIT` trap, so the Ansible
path is the gap.

### 3.6 Git bare clones — 6.3 GB, ~500 MB each

Each app keeps `/opt/<app>/shared/repo.git`, a full bare clone used for
`git archive` on every deploy.

| Metric | Typical app | screenshot-service | pg-backup |
|---|---:|---:|---:|
| Repo size | ~500 MB | 95 MB | 83 MB |
| Pack size | 494 MB | 94 MB | 82 MB |
| Pack files | 8–16 | 3 | 2 |
| Refs fetched | 29–32 branches | 22 | 18 |
| Loose “prune-packable” objects | 42–294 | 3 | 2 |
| Garbage | 0 (273 MB on categorizer) | 0 | 0 |

The clone is created with `--bare --branch main`, but the fetch refspec is
`+refs/heads/*:refs/heads/*`, so it also pulls every branch. **That is not what
makes it 500 MB.** On a current repo (`categorizer`), `main` alone contains
**655 MB of blobs**, while all refs contain **657 MB** — the branches add only
~2.5 MB. The size is the checked-in `pipelines/matcher` dataset (~462 MB) plus
the rest of the monorepo.

The smaller repos are **stale, not optimized**: `screenshot-service` (95 MB)
last fetched `main` at 2026-10-22, and `pg-backup` (83 MB) at 2026-08-29, both
before the matcher data landed. Their current releases match those older
commits. Do not use them as the target state.

`categorizer` also has two interrupted `objects/pack/tmp_pack_*` files
totalling **273 MB**. `git gc --prune=now` removes that garbage and consolidates
the 8–16 packs, but it will not shrink the ~494 MB of live matcher history.
The only real repo-size fix is to remove the matcher data from git (or move to
a shared mirror / blobless partial clone); fetching only `main` would save
almost nothing.

### 3.7 Frontend-specific

| Item | Size |
|---|---:|
| 3 releases (1.4 GB, 906 MB, 906 MB) | 3.2 GB |
| `/opt/frontend/.npm/_cacache` | 1.0 GB |
| `/opt/frontend/shared/repo.git` | 498 MB |

The frontend release includes the same 462 MB `pipelines/` and 25 MB `legacy/`
payload as the Python services. The npm cache is pure build acceleration and is
safe to clear. `next start` needs `node_modules` and `.next`, so those cannot be
removed from the current release; `npm prune --omit=dev` after the build is a
possible small win.

### 3.8 `/tmp` leaks

- `enrichment-worker`: **470** `playwright_chromiumdev_profile-*` directories,
  ~106 MB, left behind by crashed/restarted Chromium instances.
- `local-scraper`: ~54 stale spike scripts and one-off files (small).
- `carrefour-scraper`: ~73 `xvfb-run.*` and Playwright profile dirs (~29 MB).
- `pvl-verifier`: ~22 entries, ~35 MB under the FlareSolverr private tmp.

These are not large today, but they grow with every crash. A `PrivateTmp=true`
on browser workers (or a weekly age-based cleanup) keeps them bounded.

### 3.9 Thin-LV allocation vs guest usage (TRIM)

`df` inside the container and `lvs` `Data%` tell different stories on several
hosts:

| LXC | Guest `df` | LVM LV `Data%` | Interpretation |
|---|---:|---:|---|
| local-scraper | 57% | 97% | deleted blocks not TRIMmed |
| pg-backup | 23% | 96% | deleted backup blocks not TRIMmed |
| frontend | 60% | 91% | old release blocks not TRIMmed |
| carrefour-scraper | 56% | 97% | old release blocks not TRIMmed |
| review-api | 100% | 100% | genuinely full |
| transform-worker | 100% | 99.96% | genuinely full |

`fstrim.timer` is enabled in the containers but **never runs**: it has
`ConditionVirtualization=!container`, so systemd skips it on 2026-09-04 and it
stays inactive. Proxmox provides the correct host-side command:

```bash
pct fstrim <vmid>
```

Run it after deleting files. It does not change data and reduces thin-LV
allocation to match real usage. It is hygiene rather than an emergency: the
thin pool is only 8.6% used, so the host is not at risk of running out.

---

## 4. Immediate cleanup runbook (no code changes)

Run on the Proxmox host. This is the order that creates free space first, so the
later commands have room to work.

> **Guard:** never run during a deploy. Check
> `/tmp/deploy-<app>.lock` inside the container first. All commands below are
> per-container; there is no fleet-wide “delete everything” step.

| Step | Command (per LXC) | Frees | Notes |
|---|---|---|---|
| 1. APT cache | `pct exec <vmid> -- apt-get clean` | 0.27–0.45 GB; 1.7 GB on 251 | Removes downloaded `.deb` files only |
| 2. Journald | `pct exec <vmid> -- journalctl --vacuum-size=200M` | up to 1.0 GB | Keeps the last 200 MB |
| 3. `uv` cache | `pct exec <vmid> -- runuser -u <app> -- env HOME=/opt/<app> /usr/local/bin/uv cache clean --force` | 0.8–6.2 GB | Venvs keep hardlinked copies; verified |
| 4. Playwright | `ansible/roles/app_maintenance/files/prune-playwright.sh` | ~0.65 GB immediately; more after releases rotate out | Rollback-safe: keeps revisions used by retained releases |
| 5. npm cache | `pct exec 269 -- runuser -u frontend -- env HOME=/opt/frontend npm cache clean --force` | ~1.0 GB | Frontend only |
| 6. `/tmp` | `pct exec <vmid> -- find /tmp -maxdepth 1 -name 'playwright_chromiumdev_profile-*' -mtime +1 -exec rm -rf {} +` | ~0.1 GB on 268 | `xvfb-run.*` and spike files can be included with care |
| 7. Git | `pct exec <vmid> -- runuser -u <app> -- git --git-dir=/opt/<app>/shared/repo.git gc --prune=now` and remove `tmp_pack_*` | ~0.3 GB on 260 | Do not run concurrently with a deploy/fetch |
| 8. Incomplete release | remove a release dir that is not `current` and has no `venv/bin/python` | 0.1–0.2 GB on 261/264 | Confirm `readlink /opt/<app>/current` first |
| 9. TRIM | `pct fstrim <vmid>` (host-side) | thin-LV allocation only | Online, no reboot |

Skip the app-specific steps on hosts with no `/opt/<app>` tree (`gateway`,
`github-runner`, `postgres`, `uptime-kuma`, `graylog`). Steps 1, 2 and 9 are safe
on every container; steps 3–8 apply to the 15 app LXCs. `pg-backup` has no `uv`
cache, so step 3 is a no-op there.

### Playwright prune (tested dry-run on screenshot-service)

The implemented pruner is `ansible/roles/app_maintenance/files/prune-playwright.sh`.
It keeps the union of revisions referenced by every retained release, so a
rollback does not lose its browser. For a one-off run on the host:

```bash
ssh root@168.119.81.167 \
  "pct exec <vmid> -- bash -s -- /opt/<app>" \
  < ansible/roles/app_maintenance/files/prune-playwright.sh
```

Dry-run result on `screenshot-service` (the 1234 revision is unreferenced):

```
KEEP chromium-1187
WOULD REMOVE chromium-1234 (389M)
KEEP chromium_headless_shell-1187
WOULD REMOVE chromium_headless_shell-1234 (262M)
KEEP ffmpeg-1011
```

### Expected result for the five pressured containers

| LXC | Now | Safe reclaim | After |
|---|---:|---:|---:|
| review-api | 100% / 0 B free | ~6.4 GB | ~29% |
| transform-worker | 100% / 0 B free | ~6.2 GB | ~31% |
| categorizer | 97% / 287 MB | ~6.3 GB | ~27% |
| screenshot-service | 85% / 1.7 GB | ~6.6 GB | ~24% |
| enrichment-worker | 77% / 2.7 GB | ~3.1 GB | ~46% |

The other containers drop by 0.2–2.4 GB each; see Section 2.

### Verification after cleanup

```bash
pct exec <vmid> -- df -h /
pct exec <vmid> -- systemctl is-active <app>
pct exec <vmid> -- curl -fsS http://127.0.0.1:<port>/health   # HTTP services
pct exec <vmid> -- journalctl -u <app> -n 20 --no-pager
```

For workers, `systemctl is-active` is the health check. All 15 app services are
currently `active`; cleanup is non-disruptive.

---

## 5. Cleanup process (implemented)

The goal is that a worker never reaches 90% again without an alert, and that
steady-state usage stays around 3–5 GB on a 10–12 GB rootfs.

### 5.1 What was added

| Piece | Location | Trigger |
|---|---|---|
| Reusable cleanup role | `ansible/roles/app_maintenance/` | deploy + maintenance |
| Post-deploy cleanup | `ansible/playbooks/deploy.yml` | every successful deploy |
| Release pruning in `always` | `ansible/playbooks/deploy.yml` | every deploy, success or failure |
| Weekly/monthly cleanup | `ansible/playbooks/maintenance.yml` | GitHub Actions schedule |
| Workflow modes | `.github/workflows/maintenance.yml` | weekly clean, monthly aggressive, manual |
| Daily report | `.github/workflows/disk-report.yml` + `scripts/lxc-disk-report.sh` | daily 06:00 UTC |
| Host TRIM | `maintenance.yml` (`proxmox_host` play) | monthly aggressive |
| Disk alert | `proxmox_host` role (`lxc-disk-health.timer`) | every 15 minutes |
| Journald + APT caps | `common` role + `group_vars/apps.yml` | site run |
| Uptime Kuma monitor | `uptime_kuma/defaults/main.yml` | site run |

### 5.2 Deploy-time cleanup

`deploy.yml` now:

- Checks for **at least 2 GiB free** before building a release and fails with a
  clear message instead of dying halfway through with ENOSPC.
- Runs `app_maintenance` in `deploy` mode after the health checks. It clears the
  `uv` cache, prunes Playwright revisions, and removes leaked Chromium profiles.
- Prunes old and incomplete releases in `always`, so a failed deploy cannot
  leave a directory behind. The current release is never touched.
- Wraps post-deploy cleanup and release pruning in `block`/`rescue`, so a
  cleanup problem does not mark an otherwise healthy deploy as failed or skip
  the deploy-lock release.

Playwright pruning is **rollback-safe**: it keeps the union of revisions
referenced by every retained release. An old revision is reclaimed only after
the release that references it is pruned.

### 5.3 Weekly and monthly runs

`maintenance.yml` now:

1. Checks the deploy lock (existing behaviour).
2. Runs `app_maintenance` `pre_apt` (APT clean + journal vacuum + app build
   caches) to make room. This matters on a 100%-full host: it cannot even
   `apt update` after only removing the APT cache.
3. Runs the existing apt update/upgrade.
4. Runs `app_maintenance` in `clean` mode: APT clean again, journal vacuum,
   `uv` cache clean, Playwright prune, `/tmp` cleanup. In `aggressive` mode it
   also prunes old/incomplete releases first, then removes the now-unreferenced
   browser revisions and runs `git gc`.
5. Reports `df` before and after.
6. Runs the `proxmox_host` `pct fstrim` play when `app_maintenance_trim=true`.

The maintenance workflow runs:

| Schedule | Mode | What happens |
|---|---|---|
| Sunday 03:00 UTC | `clean` | safe cleanup + apt upgrade |
| 1st of month 04:00 UTC | `aggressive` | clean + release prune + git gc + fstrim |
| Manual dispatch | `report` / `clean` / `aggressive` | choose `limit` and `dry_run` |

`workflow_dispatch` inputs: `mode`, `limit`, `dry_run`, `git_gc`,
`prune_releases`, `trim`. `dry_run=true` skips apt and every destructive
command; `mode=report` is read-only.

The role uses `stat` guards, so it is safe on the non-app hosts in `lxc_apps`
(`postgres`, `uptime-kuma`, `graylog`, `pg-backup`). The per-task deploy-lock
check is disabled only for the deploy-time invocation, where the lock is
intentionally held.

### 5.4 Alerting and reporting

- `lxc-disk-health.timer` on the Proxmox host runs every 15 minutes, reads
  `df` for each running container via `pct exec`, and pushes the worst
  percentage to the `lxc-disk-health` Uptime Kuma monitor.
- The monitor interval is 20 minutes, so a dead timer or broken Proxmox host
  alerts by missing heartbeat. This is independent of GitHub Actions.
- `.github/workflows/disk-report.yml` runs daily at 06:00 UTC and writes the
  Markdown table to the GitHub Actions summary. It is read-only.
- Thresholds: WATCH 75%, HIGH 85%, CRITICAL 90%.

### 5.5 Guardrails

| Control | Where | Effect |
|---|---|---|
| `SystemMaxUse=200M`, `SystemMaxFileSize=50M` | `common` role via `group_vars/apps.yml` | Bounds local journals; Graylog remains the long-term store |
| `APT::Periodic::AutocleanInterval "7";` | `common/templates/20auto-upgrades.j2` | Removes obsolete `.deb` weekly |
| Release retention | `app_maintenance_keep_releases` (default 3) | Current + two rollback candidates |
| Free-space pre-flight | `deploy.yml` | Requires 2 GiB free before a release |
| Rollback-safe browser prune | `app_maintenance/files/prune-playwright.sh` | Keeps revisions used by retained releases |
| Deploy-lock guard | `app_maintenance/tasks/facts.yml` | Periodic cleanup skips a host with an in-flight deploy |
| Non-app host guards | `app_maintenance` stat checks | Safe on postgres, uptime-kuma, graylog, pg-backup |

### 5.6 First rollout

The code is in place but **not yet applied to the hosts**. The first run should be:

1. `workflow_dispatch` with `mode=report`, no limit: verify the daily table.
2. `mode=clean`, `dry_run=true`, `limit=tailoring-erp`: verify the dry-run
   output on one low-risk host.
3. `mode=clean`, `limit=review-api,transform-worker,categorizer,screenshot-service,enrichment-worker`:
   apply the first cleanup to the five pressured containers.
4. Verify `df -h /`, `systemctl is-active`, and the health endpoint on each.
5. Let the weekly schedule take over; run `mode=aggressive` monthly (or wait for
   the 1st). The next normal `site.yml` run applies the journald/APT caps and
   creates the Uptime Kuma monitor and Proxmox timer.

---

## 6. Structural fixes (app repo / deploy artifact)

These are the changes that remove the root causes rather than just cleaning up.

1. **Stop exporting the whole monorepo into every release.**
   `git archive <sha>` currently exports everything, including the 462 MB
   `pipelines/matcher` tree and 25 MB `legacy/`. The deployed services are 1–2 MB
   each and do not import `pipelines`. Export only:
   - `services/<service>` (or `workers/<worker>` for `pdp-enricher`)
   - `shared/python`
   - `sql/` where the service runs migrations (`review-api`,
     `job-tracker-api`, `dashboard-api`)
   - `frontend/` for the frontend
   - `data/labeling/` only if `dashboard-api` enables that feature
   - any other path confirmed by a runtime import/read audit

   Expected: release size drops from ~540 MB to ~10–100 MB for Python
   services. This alone removes ~12.4 GB of current release payload and prevents
   ~1.4 GB per LXC of future growth.

2. **Remove large data from git, or keep it out of the deploy path.**
   `pipelines/matcher/data/faiss` and `data/encodings` are model artifacts, not
   source. They already have an S3 home (`ml-models` prefix). Store them in S3
   and fetch on the matcher host; do not check them into the deploy repo.
   `legacy/hetzner/.terraform/providers/...` is a 25 MB vendored provider that
   has no place in a deploy artifact either.

3. **Move ML dependencies out of the root base dependencies.**
   `sentence-transformers`, `numpy`, `scipy`, `pandas` should be in the `ml`
   extra, not `[project].dependencies`. This prevents any accidental
   `uv pip install .` from pulling 5 GB of CUDA wheels. Also audit the fallback
   in the deploy helper: `uv pip install .` at the repo root is never the right
   action for a service LXC.

4. **Prefer `uv pip install --no-cache` for deploys, or a bounded cache.**
   If deploy speed matters, keep a cache but clear it after the release is
   healthy. `uv cache clean` is the simplest. `UV_NO_CACHE=1` is viable for
   services with small requirements (most of these venvs are 70–250 MB).

5. **Fix the 500 MB bare clones by removing the matcher data, not by
   branch-pruning.** On a current repo, `main` holds 655 MB of blobs and all
   refs hold 657 MB; `--single-branch` would save ~2.5 MB. The win comes from
   taking `pipelines/matcher/data` out of git (S3 already hosts the models), or
   from a shared mirror on one host / a blobless partial clone if the data must
   stay. Keep `git gc --prune=now` for the interrupted `tmp_pack_*` garbage
   (273 MB on categorizer) and pack consolidation.

6. **Frontend-specific:** keep 2 releases, run `npm prune --omit=dev` after
   `next build`, and remove `.next/cache` from non-current releases if the
   runtime does not need it. Measure before deleting; `next start` needs
   `node_modules` and `.next`.

7. **Disk sizing.** With cleanup in place, 10 GB is workable for the Python
   APIs/workers and 12 GB for browser workers. If deploys are frequent or the
   matcher data stays in git, move to 12–16 GB for Python services and 16–24 GB
   for browser workers. The thin pool has ~6.5 TB free, so resizing is cheap;
   do it only after the cleanup process is in place, otherwise the extra space
   just delays the next full disk.

---

## 7. What not to delete

| Path | Why |
|---|---|
| `/opt/<app>/current` and the release it points to | Running service |
| `/opt/<app>/current/venv` | Runtime Python environment |
| `/opt/<app>/.local/share/uv/python/` | Managed CPython that the venv symlinks to (~109 MB) |
| Active Playwright revision in `browsers.json` | Browser workers need it |
| `/opt/<app>/shared/repo.git` | Required for the next `git archive` deploy |
| `/opt/flaresolverr/` and `/app/chromedriver` | Local FlareSolverr runtime |
| Postgres data on 252 | Application data |
| Graylog/OpenSearch data on 280 | Log data |
| Docker volumes on gateway/uptime-kuma | Application state |
| `/tmp/systemd-private-*/` on a running service | Live private tmp namespace |

Safe to delete: old `uv` cache entries, obsolete `.deb` files, journald above
the cap, old Playwright revisions, npm cache, leaked `playwright_chromiumdev_profile-*`
dirs older than a day, git `tmp_pack_*` and unreachable objects, incomplete
release dirs with no venv that are not `current`.

Do **not** run `playwright uninstall --all` on a live host: it removes the
active browser too. Use the revision-aware prune in Section 4.

---

## 8. Appendix — method and raw numbers

### Method

For each VMID:

```bash
pct exec <vmid> -- df -hT /
pct exec <vmid> -- du -x -d1 / | sort -rn | head
pct exec <vmid> -- du -sm /opt /opt/<app>/.cache/uv /opt/<app>/.cache/ms-playwright \
  /opt/<app>/releases /opt/<app>/shared/repo.git /var/cache/apt/archives /var/log
pct exec <vmid> -- journalctl --disk-usage
pct exec <vmid> -- git --git-dir=/opt/<app>/shared/repo.git count-objects -vH
lvs --noheadings -o lv_name,lv_size,data_percent vg0
pvesm status
```

Hardlink verification (example, categorizer):

```bash
f=$(find /opt/categorizer/.cache/uv/archive-v0 -type f -path '*psycopg2*' | head -1)
stat -c 'links=%h inode=%i' "$f"      # links=4
find /opt/categorizer/current/venv -samefile "$f"
```

Torch cache verification (example, categorizer):

```bash
f=$(find /opt/categorizer/.cache/uv/archive-v0 -type f -path '*torch*' | head -1)
stat -c 'links=%h' "$f"                # links=1, cache-only
/opt/categorizer/current/venv/bin/python -c \
  'import importlib.util as u; print(u.find_spec("torch"))'   # None
```

### Raw totals

| Metric | Value |
|---|---:|
| Proxmox thin pool | 7.15 TB total, 627 GB used (8.57%) |
| Host root filesystem | 98 GB, 20 GB used (21%) |
| 15 app LXCs provisioned | 171.8 GB |
| 15 app LXCs used | 100.9 GB |
| 15 app LXCs free | 62.0 GB |
| App LXC `uv` cache | 37.9 GB |
| App LXC `releases/` | 17.7 GB |
| App LXC `shared/repo.git` | 6.3 GB |
| App LXC APT archives | 4.0 GB |
| App LXC journald above 200 MB | 3.1 GB |
| Fleet-wide safe reclaim | ~51 GB |

### Evidence of impact

`review-api` and `transform-worker` are at 0 bytes free and have been logging:

```
Nov 10 10:42:15 review-api mandb[192357]: /usr/bin/mandb: can't create index cache /var/cache/man/192357: No space left on device
Nov 11 05:10:06 review-api mandb[192706]: /usr/bin/mandb: can't write to /var/cache/man/192706: No space left on device
Nov 12 10:26:06 review-api mandb[193339]: /usr/bin/mandb: can't write to /var/cache/man/193339: No space left on device
...
Nov 12 11:00:14 transform-worker mandb[176735]: /usr/bin/mandb: can't create index cache /var/cache/man/176735: No space left on device
```

All 15 app services are still `active`, so the services themselves have not
crashed yet. But any deploy, package update, or log write can fail now.

---

## 9. Additional observation (not disk-related)

While inspecting the deploy clones, I found that `repo.git/config` stores a
GitHub PAT in plaintext in `remote.origin.url`:

```
https://x-access-token:github_pat_…@github.com/Chachu1/Price_Tracker.git
```

The file is mode `0644`, owned by the app user, on every app LXC. Any process
running as that user — or anyone who can read a container backup or a process
environment — can recover the token. The deploy passes it as an environment
variable and then writes it into the clone.

This is outside the disk cleanup, but worth fixing:

- Rotate the PAT if this audit or any shell output has been shared.
- Use a GitHub App installation token or a per-repo read-only deploy key, not a
  long-lived PAT embedded in the URL.
- Scrub the remote URL after cloning (`git remote set-url origin
  https://github.com/Chachu1/Price_Tracker.git`) and authenticate from a
  short-lived credential helper or an SSH key.
- Restrict the token to `Contents: Read` on `Chachu1/Price_Tracker` only.

