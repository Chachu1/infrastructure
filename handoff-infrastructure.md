# Handoff: Infrastructure Repo Setup

**Date:** 2026-07-10
**Repo:** https://github.com/Chachu1/infrastructure (private)
**Local path:** `/home/mohsin/Documents/git_repos/infrastructure/`

---

## What Was Done

Phase 1 of the implementation plan is complete:

1. Created private GitHub repo `Chachu1/infrastructure`
2. Initialized directory structure (`.github/workflows/`, `terraform/`, `ansible/`, `configs/`, `docs/`)
3. Added customized design document at `docs/infrastructure-design.md`
4. Added `.gitignore` (excludes Terraform state, vault files, SSH keys)
5. Committed and pushed to `main`

## What's Next

**Phase 2 — Manual prerequisites (user must complete):**

| # | Task | Where |
|---|------|-------|
| 1 | Download Debian 12 LXC template | Proxmox host: `pveam update && pveam download local debian-12-standard_12.7-1_amd64.tar.zst` |
| 2 | Create Terraform Cloud account, org, and workspace `proxmox-infra` | https://app.terraform.io |
| 3 | Generate Terraform Cloud API token | Terraform Cloud → User Settings → Tokens |
| 4 | Create self-hosted GitHub Actions runner LXC (ID 200) | Proxmox host — see design doc Section "Phase 1" |
| 5 | Install Terraform v1.7.5 + Ansible on runner | Inside runner LXC |
| 6 | Generate SSH keypair on runner | `ssh-keygen -t ed25519` |
| 7 | Set up `vmbr1` private bridge (10.0.0.0/24) on Proxmox host | `/etc/network/interfaces` |
| 8 | Configure DNAT rules for ports 80, 443, 51820 | iptables on Proxmox host |
| 9 | Add GitHub secrets to repo | See table below |

**GitHub Secrets required:**

| Secret | Description |
|--------|-------------|
| `PROXMOX_URL` | `https://<proxmox-ip>:8006` |
| `PROXMOX_USER` | e.g. `root@pam` |
| `PROXMOX_PASS` | Proxmox password |
| `SSH_PUBLIC_KEY` | Runner's `~/.ssh/id_ed25519.pub` |
| `SSH_PRIVATE_KEY` | Runner's `~/.ssh/id_ed25519` |
| `TF_API_TOKEN` | Terraform Cloud API token |

**Phase 3 — Terraform (next coding phase):**

Once Phase 2 is complete, implement Terraform configs for:
- Gateway LXC (vm_id=100, 256MB RAM, 4GB disk, 10.0.0.1, vmbr1)
- Uptime-kuma LXC (vm_id=251, 1 core, 1GB RAM, 10GB disk, 10.0.0.51, vmbr1)
- Terraform Cloud backend, Proxmox provider (bpg/proxmox ~> 0.62)
- Ansible inventory generation from Terraform outputs

**Phases 4-7** cover Ansible roles, GitHub Actions workflows, and verification. All details in the design doc.

## Environment Details

- **Proxmox node name:** `server` (not default `pve`)
- **Domain:** `mhlab.me`
- **DNS provider:** Cloudflare (ACME DNS challenge for Caddy)
- **Private subnet:** `10.0.0.0/24`
- **WireGuard subnet:** `10.10.0.0/24`
- **Priority service:** uptime-kuma (utility, port 3001)
- **State backend:** Terraform Cloud (free tier)

## Suggested Skills

- `implement` — When resuming Phase 3+ code implementation
- `diagnosing-bugs` — If Terraform/Ansible issues arise during deployment
- `research` — If you need to look up Proxmox provider docs or Ansible module details
- `tdd` — If adding any testable infrastructure validation logic

## Key Files

- `docs/infrastructure-design.md` — Full design document with all phases, code examples, and troubleshooting
- `.gitignore` — Already configured to exclude sensitive/state files

## Redacted

No sensitive values were exposed in this conversation. All credentials should be stored as GitHub Secrets or in Terraform Cloud variables.
