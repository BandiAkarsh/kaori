#!/usr/bin/env bash
# Edge OS — Btrfs Subvolume Layout Creator
#
# Creates the standard Edge OS Btrfs subvolume layout on a target device.
# Compatible with Snapper, Timeshift, and btrfs-assistant.
#
# Layout:
#   @           → /            (root subvolume, snapshotted)
#   @home       → /home        (user data, excluded from snapshots)
#   @snapshots  → /.snapshots  (snapshot storage)
#   @swap       → swap file    (avoids snapshot conflicts)
#   @cache      → /var/cache   (excluded from snapshots)
#   @log        → /var/log     (excluded from snapshots)
#
# Usage:
#   sudo ./system/btrfs/layout.sh /dev/sdX2 [/mnt/target]
#     /dev/sdX2  — Btrfs-capable block device (will be formatted!)
#     /mnt/target — optional mount point (default: /mnt/edge)

set -Eeuo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Cleanup on error
cleanup() {
    if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
        umount -R "$MOUNT_POINT" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# ─── Configuration ───
declare -a SUBVOLUMES=(
    "@"
    "@home"
    "@snapshots"
    "@swap"
    "@cache"
    "@log"
)

declare -A MOUNTS=(
    ["@"]="/"
    ["@home"]="/home"
    ["@snapshots"]="/.snapshots"
    ["@swap"]="/.swap"
    ["@cache"]="/var/cache"
    ["@log"]="/var/log"
)

# Exclude these subvolumes from snapper snapshots
declare -a SNAPSHOT_EXCLUDE=(
    "@home"
    "@cache"
    "@log"
    "@swap"
)

# ─── Help ───
usage() {
    cat <<EOF
Usage: $(basename "$0") <device> [mount_point]

Creates Edge OS Btrfs subvolume layout on <device>.
WARNING: This will FORMAT the target device!

Arguments:
  device       Block device (e.g. /dev/sda2)
  mount_point  Temporary mount point (default: /mnt/edge)

Example:
  sudo ./system/btrfs/layout.sh /dev/nvme0n1p2
EOF
    exit 0
}

# ─── Pre-flight ───
if [ $# -lt 1 ]; then
    usage
fi

DEVICE="$1"
MOUNT_POINT="${2:-/mnt/edge}"

if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}❌ This script must be run as root.${NC}"
    echo "   Usage: sudo $0 $DEVICE"
    exit 1
fi

if [ ! -b "$DEVICE" ]; then
    echo -e "${RED}❌ Not a block device: ${DEVICE}${NC}"
    exit 1
fi

# ─── Confirmation ───
echo -e "${YELLOW}⚠️  This will DESTROY all data on ${DEVICE}${NC}"
echo -e "${YELLOW}   and create Edge OS Btrfs subvolume layout.${NC}"
if [ -t 0 ]; then
    echo -n "Continue? [y/N] "
    read -r confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        echo "Aborted."
        exit 0
    fi
else
    echo -e "${YELLOW}   Non-interactive mode — proceeding. Set EDGE_BTRFS_FORCE=1 to skip this warning.${NC}"
    if [ "${EDGE_BTRFS_FORCE:-0}" != "1" ]; then
        echo -e "${RED}   Aborting. Set EDGE_BTRFS_FORCE=1 to proceed non-interactively.${NC}"
        exit 0
    fi
fi

# ─── Create Btrfs filesystem ───
echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  Edge OS — Btrfs Subvolume Layout${NC}"
echo -e "${CYAN}  Device: ${DEVICE}${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

echo -e "\n${GREEN}[1/4] Creating Btrfs filesystem on ${DEVICE}...${NC}"
mkfs.btrfs -f -L "edge-root" "$DEVICE"
echo -e "${GREEN}  ✅ Btrfs filesystem created${NC}"

# ─── Mount the top-level subvolume ───
echo -e "\n${GREEN}[2/4] Mounting top-level subvolume...${NC}"
mkdir -p "$MOUNT_POINT"
mount -t btrfs -o subvolid=5 "$DEVICE" "$MOUNT_POINT"
echo -e "${GREEN}  ✅ Top-level subvolume mounted at ${MOUNT_POINT}${NC}"

# ─── Create subvolumes ───
echo -e "\n${GREEN}[3/4] Creating subvolumes...${NC}"
for sv in "${SUBVOLUMES[@]}"; do
    if [ -d "$MOUNT_POINT/$sv" ]; then
        echo -e "${YELLOW}  ⚠ Subvolume ${sv} already exists, skipping${NC}"
    else
        btrfs subvolume create "$MOUNT_POINT/$sv"
        echo -e "${GREEN}  ✅ Created ${sv}${NC}"
    fi
done

# ─── Create mount points and set up fstab ───
echo -e "\n${GREEN}[4/4] Creating mount structure...${NC}"

# Mount @ as root
mkdir -p "$MOUNT_POINT/@"
mount -t btrfs -o subvol=@,compress=zstd:3,noatime,ssd "$DEVICE" "$MOUNT_POINT/@"

# Create sub-directory mount points inside @
for dir in home .snapshots .swap var/cache var/log; do
    mkdir -p "$MOUNT_POINT/@/$dir"
done

# Mount subvolumes at their respective paths
mount -t btrfs -o subvol=@home,compress=zstd:3,noatime,ssd "$DEVICE" "$MOUNT_POINT/@/home"
mount -t btrfs -o subvol=@snapshots,noatime,ssd "$DEVICE" "$MOUNT_POINT/@/.snapshots"
mount -t btrfs -o subvol=@swap,noatime,ssd,nodatacow "$DEVICE" "$MOUNT_POINT/@/.swap"
mount -t btrfs -o subvol=@cache,compress=zstd:3,noatime,ssd,nodatacow "$DEVICE" "$MOUNT_POINT/@/var/cache"
mount -t btrfs -o subvol=@log,compress=zstd:1,noatime,ssd,nodatacow "$DEVICE" "$MOUNT_POINT/@/var/log"

# Set @ as default subvolume (makes it mount without subvol= option)
ROOT_ID=$(btrfs subvolume list "$MOUNT_POINT" | grep ' @$' | awk '{print $2}')
if [ -n "$ROOT_ID" ]; then
    btrfs subvolume set-default "$ROOT_ID" "$MOUNT_POINT"
    echo -e "${GREEN}  ✅ Set @ (ID ${ROOT_ID}) as default subvolume${NC}"
fi

# Generate fstab entries
UUID=$(blkid -s UUID -o value "$DEVICE")
FSTAB_FILE="$MOUNT_POINT/@/etc/fstab"

mkdir -p "$(dirname "$FSTAB_FILE")"
cat > "$FSTAB_FILE" <<FSTAB
# /etc/fstab — Edge OS Btrfs subvolume mounts
# Generated by system/btrfs/layout.sh
# Device: ${DEVICE}  UUID: ${UUID}

# Root subvolume (@ is default, mounted without subvol=)
UUID=${UUID}  /  btrfs  compress=zstd:3,noatime,ssd  0  0

# /boot/efi (if EFI partition exists, user must add manually)
# UUID=XXXX-XXXX  /boot/efi  vfat  umask=0077  0  1

# Home (user data — excluded from snapshots)
UUID=${UUID}  /home  btrfs  subvol=@home,compress=zstd:3,noatime,ssd  0  0

# Snapshots storage
UUID=${UUID}  /.snapshots  btrfs  subvol=@snapshots,noatime,ssd  0  0

# Swap subvolume (nodatacow to avoid CoW issues with swap files)
UUID=${UUID}  /.swap  btrfs  subvol=@swap,noatime,ssd,nodatacow  0  0

# Cache (excluded from snapshots)
UUID=${UUID}  /var/cache  btrfs  subvol=@cache,compress=zstd:3,noatime,ssd,nodatacow  0  0

# Logs (excluded from snapshots)
UUID=${UUID}  /var/log  btrfs  subvol=@log,compress=zstd:1,noatime,ssd,nodatacow  0  0
FSTAB

echo -e "${GREEN}  ✅ fstab generated at ${FSTAB_FILE}${NC}"

# ─── Summary ───
echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}✅ Btrfs layout complete!${NC}"
echo -e "${CYAN}   Device: ${DEVICE}${NC}"
echo -e "${CYAN}   UUID:   ${UUID}${NC}"
echo -e "${CYAN}   Mount:  ${MOUNT_POINT}/@${NC}"
echo ""
echo -e "${CYAN}   Subvolumes:${NC}"
btrfs subvolume list "$MOUNT_POINT" | while read -r line; do
    echo -e "${CYAN}     ${line}${NC}"
done
echo ""
echo -e "${CYAN}   Next steps:${NC}"
echo -e "${CYAN}     1. Mount EFI partition at /boot/efi if needed${NC}"
echo -e "${CYAN}     2. rsync / to ${MOUNT_POINT}/@/ to populate rootfs${NC}"
echo -e "${CYAN}     3. Run: sudo system/btrfs/snapshot.sh init${NC}"
echo -e "${CYAN}     4. Run: sudo system/btrfs/grub-update.sh install${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
