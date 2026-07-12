#!/usr/bin/env bash
set -euo pipefail

SCRATCH_VM_ID="9000"
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

# Download and import in fixed order for predictable volume naming
IMAGES=(
  "debian|https://cloud.debian.org/images/cloud/trixie/daily/latest/debian-13-generic-amd64-daily.qcow2|debian-13-generic-amd64.qcow2"
  "ubuntu|https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img|ubuntu-24.04-server-cloudimg-amd64.img"
)

ERRORS=0
DEBIAN_VOL=""
UBUNTU_VOL=""

# Remove old disk references from scratch VM config
VMCONF="/etc/pve/qemu-server/${SCRATCH_VM_ID}.conf"
if [ -f "$VMCONF" ]; then
  sed -i '/^scsi[0-9]\+:/d; /^sata[0-9]\+:/d; /^ide[0-9]\+:/d; /^virtio[0-9]\+:/d; /^unused[0-9]\+:/d' "$VMCONF"
fi

# Create scratch VM if it doesn't exist
if ! qm status "$SCRATCH_VM_ID" &>/dev/null; then
  qm create "$SCRATCH_VM_ID" --memory 512 --cores 1 --net0 virtio,bridge=vmbr1
fi

for entry in "${IMAGES[@]}"; do
  IFS='|' read -r name url filename <<< "$entry"
  dest="$TMPDIR/$filename"

  log "Downloading $filename from $url..."
  if ! curl -fSL --retry 3 --retry-delay 5 --connect-timeout 30 -o "$dest" "$url"; then
    log "ERROR: Failed to download $filename"
    ERRORS=$((ERRORS + 1))
    continue
  fi

  if [ ! -s "$dest" ]; then
    log "ERROR: Downloaded file is empty: $filename"
    ERRORS=$((ERRORS + 1))
    continue
  fi

  size=$(du -h "$dest" | cut -f1)
  log "Downloaded: $filename ($size)"

  log "Importing $filename into lvmthin storage..."
  if ! qm disk import "$SCRATCH_VM_ID" "$dest" lvmthin --format qcow2; then
    log "ERROR: Failed to import $filename into lvmthin"
    ERRORS=$((ERRORS + 1))
    continue
  fi
done

if [ "$ERRORS" -gt 0 ]; then
  log "ERROR: $ERRORS image(s) failed to update"
  exit 1
fi

# Discover volumes from scratch VM config
if [ -f "$VMCONF" ]; then
  mapfile -t VOLS < <(grep -oP '(?:scsi|sata|ide|virtio|unused)\d+:\s*\K[^,\s]+' "$VMCONF" | sort)
  
  for vol in "${VOLS[@]}"; do
    if [[ "$vol" == *"-disk-0"* ]]; then
      DEBIAN_VOL="$vol"
    elif [[ "$vol" == *"-disk-1"* ]]; then
      UBUNTU_VOL="$vol"
    fi
  done
fi

if [ -z "$DEBIAN_VOL" ] || [ -z "$UBUNTU_VOL" ]; then
  log "ERROR: Could not find imported disk volumes in lvmthin"
  exit 1
fi

log "Debian volume: $DEBIAN_VOL"
log "Ubuntu volume: $UBUNTU_VOL"

# Update Terraform locals.tf with lvmthin volume references
LOCALS_FILE="/opt/infrastructure/terraform/locals.tf"

if [ ! -f "$LOCALS_FILE" ]; then
  log "ERROR: locals.tf not found at $LOCALS_FILE"
  exit 1
fi

sed -i "s|debian = \"local:cloudimg/[^\"]*\"|debian = \"$DEBIAN_VOL\"|" "$LOCALS_FILE"
sed -i "s|ubuntu = \"local:cloudimg/[^\"]*\"|ubuntu = \"$UBUNTU_VOL\"|" "$LOCALS_FILE"

log "Updated locals.tf with lvmthin volume references"
log "All cloud images updated successfully."
