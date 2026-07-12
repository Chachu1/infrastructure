#!/usr/bin/env bash
set -euo pipefail

STORAGE_PATH="/var/lib/vz/images/cloudimg"
LOG_TAG="update-cloud-images"

log() {
  echo "$(date -Is) [$LOG_TAG] $*"
  logger -t "$LOG_TAG" "$*" 2>/dev/null || true
}

mkdir -p "$STORAGE_PATH"

declare -A IMAGES=(
  ["debian-13-generic-amd64.qcow2"]="https://cloud.debian.org/images/cloud/trixie/daily/latest/debian-13-generic-amd64-daily.qcow2"
  ["ubuntu-24.04-server-cloudimg-amd64.img"]="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
)

ERRORS=0

for filename in "${!IMAGES[@]}"; do
  url="${IMAGES[$filename]}"
  dest="$STORAGE_PATH/$filename"
  tmp="$dest.tmp"

  log "Downloading $filename from $url..."
  if ! curl -fSL --retry 3 --retry-delay 5 --connect-timeout 30 -o "$tmp" "$url"; then
    log "ERROR: Failed to download $filename"
    rm -f "$tmp"
    ERRORS=$((ERRORS + 1))
    continue
  fi

  if [ ! -s "$tmp" ]; then
    log "ERROR: Downloaded file is empty: $filename"
    rm -f "$tmp"
    ERRORS=$((ERRORS + 1))
    continue
  fi

  mv -f "$tmp" "$dest"
  size=$(du -h "$dest" | cut -f1)
  log "Updated: $dest ($size)"
done

if [ "$ERRORS" -gt 0 ]; then
  log "ERROR: $ERRORS image(s) failed to update"
  exit 1
fi

log "All cloud images updated successfully."
