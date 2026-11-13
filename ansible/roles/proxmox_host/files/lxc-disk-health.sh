#!/usr/bin/env bash
# Push the worst LXC root-filesystem usage on this Proxmox host to Uptime Kuma.
#
# Runs from a systemd timer on the Proxmox host every 15 minutes. A missing
# heartbeat (dead timer, broken host, unreachable Uptime Kuma) alerts by design
# because the monitor is a push monitor.
#
# Environment (from /etc/lxc-disk-health.env):
#   PUSH_URL   Uptime Kuma push URL
#   WARN_PCT   warning threshold (default 75)
#   CRIT_PCT   critical threshold (default 85)

set -uo pipefail

: "${PUSH_URL:?PUSH_URL is not set}"
WARN_PCT="${WARN_PCT:-75}"
CRIT_PCT="${CRIT_PCT:-85}"

worst=0
worst_name=""
total=0
errors=0

while IFS= read -r id; do
  [ -n "$id" ] || continue
  total=$((total + 1))

  name=$(timeout 5 pct config "$id" 2>/dev/null | awk -F': ' '/^hostname:/{print $2}')
  [ -n "$name" ] || name="ct-$id"

  pct=$(timeout 10 pct exec "$id" -- df --output=pcent / 2>/dev/null | tail -1 | tr -dc '0-9')
  if [ -z "$pct" ]; then
    errors=$((errors + 1))
    continue
  fi

  if [ "$pct" -gt "$worst" ]; then
    worst=$pct
    worst_name=$name
  fi
done < <(pct list 2>/dev/null | awk 'NR > 1 && $2 == "running" {print $1}')

if [ "$total" -eq 0 ]; then
  status=down
  msg="no running containers found"
elif [ "$errors" -gt 0 ]; then
  status=down
  msg="${errors}/${total} containers unreadable; worst ${worst_name} ${worst}%"
elif [ "$worst" -ge "$CRIT_PCT" ]; then
  status=down
  msg="CRITICAL ${worst_name} ${worst}%"
elif [ "$worst" -ge "$WARN_PCT" ]; then
  status=down
  msg="WARN ${worst_name} ${worst}%"
else
  status=up
  msg="OK worst ${worst_name} ${worst}%"
fi

curl -fsS --max-time 10 -G "$PUSH_URL" \
  --data-urlencode "status=$status" \
  --data-urlencode "msg=$msg"
