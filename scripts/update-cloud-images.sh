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

# Template VM IDs for each distro
declare -A TEMPLATES=(
  ["debian"]="9001"
  ["ubuntu"]="9002"
)

IMAGES=(
  "debian|https://cloud.debian.org/images/cloud/trixie/daily/latest/debian-13-generic-amd64-daily.qcow2"
  "ubuntu|https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
)

ERRORS=0

for entry in "${IMAGES[@]}"; do
  IFS='|' read -r name url <<< "$entry"
  vmid="${TEMPLATES[$name]}"
  tmpfile="$TMPDIR/${name}.qcow2"

  log "Downloading $name cloud image from $url..."
  if ! curl -fSL --retry 3 --retry-delay 5 --connect-timeout 30 -o "$tmpfile" "$url"; then
    log "ERROR: Failed to download $name image"
    ERRORS=$((ERRORS + 1))
    continue
  fi

  if [ ! -s "$tmpfile" ]; then
    log "ERROR: Downloaded file is empty: $name"
    ERRORS=$((ERRORS + 1))
    continue
  fi

  size=$(du -h "$tmpfile" | cut -f1)
  log "Downloaded: $name ($size)"

  # Destroy existing template if it exists
  if qm status "$vmid" &>/dev/null; then
    log "Destroying existing template VM $vmid..."
    qm stop "$vmid" 2>/dev/null || true
    sleep 2
    qm destroy "$vmid" --purge 2>/dev/null || true
  fi

  # Create template VM
  log "Creating template VM $vmid for $name..."
  qm create "$vmid" \
    --name "template-${name}" \
    --memory 512 \
    --cores 1 \
    --net0 virtio,bridge=vmbr1 \
    --scsihw virtio-scsi-single \
    --agent enabled=1

  # Import disk
  log "Importing disk into lvmthin storage..."
  if ! qm disk import "$vmid" "$tmpfile" lvmthin --format qcow2; then
    log "ERROR: Failed to import disk for $name"
    ERRORS=$((ERRORS + 1))
    continue
  fi

  # Attach disk to VM
  qm set "$vmid" --scsi0 lvmthin:vm-${vmid}-disk-0,iothread=on,discard=on
  qm set "$vmid" --boot order=scsi0
  qm set "$vmid" --ide2 local:cloudinit
  qm set "$vmid" --serial0 socket
  qm set "$vmid" --vga serial0

  # Convert to template
  qm template "$vmid"

  log "Template VM $vmid ($name) created successfully"
done

if [ "$ERRORS" -gt 0 ]; then
  log "ERROR: $ERRORS image(s) failed to update"
  exit 1
fi

log "All cloud image templates updated successfully."
