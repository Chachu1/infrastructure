#!/usr/bin/env bash
# Markdown disk report for every LXC on a Proxmox host.
#
# Run on the Proxmox host (it uses pct). The daily GitHub Actions workflow
# pipes this into $GITHUB_STEP_SUMMARY so the fleet trend is visible without
# logging into each container.
#
#   ssh root@10.0.0.1 'bash -s' < scripts/lxc-disk-report.sh
#
# Thresholds mirror the cleanup process: WATCH >= 75, HIGH >= 85,
# CRITICAL >= 90.

set -uo pipefail

WARN_PCT=75
HIGH_PCT=85
CRIT_PCT=90

printf '| VMID | Name | Size | Used | Avail | Use | Status |\n'
printf '|---:|---|---:|---:|---:|---:|---|\n'

worst=0
worst_name=""

while IFS= read -r id; do
  [ -n "$id" ] || continue

  name=$(timeout 5 pct config "$id" 2>/dev/null | awk -F': ' '/^hostname:/{print $2}')
  [ -n "$name" ] || name="ct-$id"

  size=""
  used=""
  avail=""
  pct=""
  read -r size used avail pct < <(
    timeout 10 pct exec "$id" -- df -BM --output=size,used,avail,pcent / 2>/dev/null | tail -1
  )

  if [ -z "${pct:-}" ]; then
    printf '| %s | %s | - | - | - | - | UNREADABLE |\n' "$id" "$name"
    continue
  fi

  num=${pct%\%}
  if [ "$num" -ge "$CRIT_PCT" ]; then
    status="CRITICAL"
  elif [ "$num" -ge "$HIGH_PCT" ]; then
    status="HIGH"
  elif [ "$num" -ge "$WARN_PCT" ]; then
    status="WATCH"
  else
    status="OK"
  fi

  printf '| %s | %s | %s | %s | %s | %s | %s |\n' \
    "$id" "$name" "$size" "$used" "$avail" "$pct" "$status"

  if [ "$num" -gt "$worst" ]; then
    worst=$num
    worst_name=$name
  fi
done < <(pct list 2>/dev/null | awk 'NR > 1 {print $1}')

printf '\nWorst: **%s** at **%s%%**.\n' "${worst_name:-n/a}" "$worst"
