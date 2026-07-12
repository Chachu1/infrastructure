#!/usr/bin/env bash
set -euo pipefail

TMPDIR=$(mktemp -d)
LOG_TAG="update-cloud-images"

log() {
  echo "$(date -Is) [$LOG_TAG] $*"
  logger -t "$LOG_TAG" "$*" 2>/dev/null || true
}

cleanup() {
  rm -rf "$TMPDIR"
}
trap cleanup EXIT

STORAGE_PATH="/var/lib/vz"
mkdir -p "$STORAGE_PATH"

IMAGES=(
  "debian|https://cloud.debian.org/images/cloud/trixie/daily/latest/debian-13-generic-amd64-daily.qcow2|debian-13-generic-amd64.qcow2"
  "ubuntu|https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img|ubuntu-24.04-server-cloudimg-amd64.img"
)

ERRORS=0

for entry in "${IMAGES[@]}"; do
  IFS='|' read -r name url filename <<< "$entry"
  tmppath="$TMPDIR/$filename"
  destpath="$STORAGE_PATH/$filename"

  log "Downloading $filename from $url..."
  if ! curl -fSL --retry 3 --retry-delay 5 --connect-timeout 30 -o "$tmppath" "$url"; then
    log "ERROR: Failed to download $filename"
    ERRORS=$((ERRORS + 1))
    continue
  fi

  if [ ! -s "$tmppath" ]; then
    log "ERROR: Downloaded file is empty: $filename"
    ERRORS=$((ERRORS + 1))
    continue
  fi

  mv -f "$tmppath" "$destpath"
  size=$(du -h "$destpath" | cut -f1)
  log "Updated: $destpath ($size)"
done

if [ "$ERRORS" -gt 0 ]; then
  log "ERROR: $ERRORS image(s) failed to update"
  exit 1
fi

log "All cloud images updated successfully."
