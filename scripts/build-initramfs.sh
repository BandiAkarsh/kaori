#!/usr/bin/env bash
# Edge OS — Build Initramfs
#
# Creates the initramfs cpio archive. The init script supports two boot modes:
#
#   1. DESKTOP MODE (default): Finds edge-rootfs.squashfs, mounts it via
#      overlayfs, and switch_root's into the full Debian rootfs where
#      systemd starts SDDM → Hyprland.
#
#   2. FALLBACK MODE: If no squashfs found, drops to a busybox shell
#      (original Phase 1 behavior preserved).
#
# Usage:
#   ./scripts/build-initramfs.sh [kernel-version]
#   Default kernel-version: 7.0.10
#
# Output: build/initramfs-edge.cpio.xz

set -Eeuo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/colors.sh

KERNEL_VERSION="${1:-7.0.10}"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
ROOTFS_DIR="$BUILD_DIR/rootfs"

echo -e "${CYAN}═══════════════════════════════════════════════${NC}"
echo -e "${CYAN}  Edge OS — Build Initramfs${NC}"
echo -e "${CYAN}  Kernel: ${KERNEL_VERSION}${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════${NC}"

# ─── Clean and prepare ───
rm -rf "$ROOTFS_DIR"
mkdir -p "$ROOTFS_DIR"/{bin,sbin,dev,proc,sys,etc,root,mnt,tmp,run}

# ─── Download busybox if needed ───
CACHE_DIR=".cache"
mkdir -p "$CACHE_DIR"
BB="$CACHE_DIR/busybox-x86_64"
if [ ! -f "$BB" ]; then
    echo -e "${YELLOW}⬇️  Downloading busybox static binary...${NC}"
    curl -L -o "$BB" "https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox"
    chmod +x "$BB"
    echo -e "${GREEN}  ✅ busybox downloaded${NC}"
fi

# ─── Copy busybox ───
cp "$BB" "$ROOTFS_DIR/bin/busybox"
chmod 755 "$ROOTFS_DIR/bin/busybox"

# ─── Write init script ───
cat > "$ROOTFS_DIR/init" << 'INIT'
#!/bin/busybox sh
# Edge OS — initramfs init script
#
# Multi-stage boot:
#   Stage 1: Mount essentials, create devices
#   Stage 2: Find and mount rootfs (squashfs + overlayfs)
#   Stage 3: switch_root into full rootfs (or fallback to shell)

# ─── Stage 1: Mount essentials ───
/bin/busybox mount -t devtmpfs devtmpfs /dev
/bin/busybox mount -t proc proc /proc
/bin/busybox mount -t sysfs sysfs /sys
/bin/busybox mount -t tmpfs tmpfs /run

# Create device nodes
/bin/busybox mknod /dev/console c 5 1 2>/dev/null
/bin/busybox mknod /dev/null c 1 3 2>/dev/null
/bin/busybox mknod /dev/ttyS0 c 4 64 2>/dev/null
/bin/busybox mknod /dev/tty0 c 4 0 2>/dev/null
/bin/busybox mknod /dev/sr0 b 11 0 2>/dev/null   # CD/DVD (ISO boot)
/bin/busybox mknod /dev/loop0 b 7 0 2>/dev/null  # loop device (squashfs)
/bin/busybox mknod /dev/loop1 b 7 1 2>/dev/null

# Make busybox symlinks
/bin/busybox --install -s /bin

# ─── Stage 2: Find and mount rootfs ───
SQUASHFS_SRC=""
ROOT_MNT="/mnt/root"
SQUASHFS_MNT="/mnt/squashfs"
ISO_MNT="/mnt/iso"
LOWER_DIR="$SQUASHFS_MNT"
UPPER_DIR="/mnt/overlay_upper"
WORK_DIR="/mnt/overlay_work"

# Parse kernel cmdline for edge_root= parameter
# shellcheck disable=SC2013 # Intentional: /proc/cmdline is space-separated, word-splitting is desired
for param in $(cat /proc/cmdline); do
    case "$param" in
        edge_root=*)
            SQUASHFS_SRC="${param#edge_root=}"
            echo "edge_root: $SQUASHFS_SRC"
            ;;
        edge_skip_rootfs)
            echo "edge_skip_rootfs: forcing fallback to shell"
            SQUASHFS_SRC="SKIP"
            ;;
    esac
done

# Search for squashfs if not specified
try_mount_rootfs() {
    local src="$1"

    # Create mount points
    /bin/busybox mkdir -p "$SQUASHFS_MNT" "$ROOT_MNT" "$UPPER_DIR" "$WORK_DIR"

    # Mount the squashfs
    if echo "$src" | /bin/busybox grep -q "\.squashfs"; then
        # Direct squashfs file path (loopback)
        /bin/busybox mount -t squashfs -o loop,ro "$src" "$SQUASHFS_MNT" 2>/dev/null
    elif [ -b "$src" ]; then
        # Block device — try to mount ISO first, then find squashfs inside
        /bin/busybox mkdir -p "$ISO_MNT"
        /bin/busybox mount -t iso9660 -o ro "$src" "$ISO_MNT" 2>/dev/null || return 1

        # Look for squashfs on the ISO
        if [ -f "$ISO_MNT/boot/edge-rootfs.squashfs" ]; then
            /bin/busybox mount -t squashfs -o loop,ro "$ISO_MNT/boot/edge-rootfs.squashfs" "$SQUASHFS_MNT" 2>/dev/null
        elif [ -f "$ISO_MNT/live/filesystem.squashfs" ]; then
            /bin/busybox mount -t squashfs -o loop,ro "$ISO_MNT/live/filesystem.squashfs" "$SQUASHFS_MNT" 2>/dev/null
        else
            echo "No squashfs found on ISO"
            /bin/busybox umount "$ISO_MNT" 2>/dev/null
            return 1
        fi
    else
        return 1
    fi

    # Verify squashfs is mounted
    if ! /bin/busybox mountpoint -q "$SQUASHFS_MNT"; then
        return 1
    fi

    # Create overlayfs: squashfs (lower) + writable tmpfs (upper)
    /bin/busybox mount -t tmpfs tmpfs "$UPPER_DIR"
    /bin/busybox mkdir -p "$UPPER_DIR/upper" "$UPPER_DIR/work"
    /bin/busybox mount -t overlay overlay \
        -o lowerdir="$LOWER_DIR",upperdir="$UPPER_DIR/upper",workdir="$UPPER_DIR/work" \
        "$ROOT_MNT"

    echo "Mounted overlayfs at $ROOT_MNT"
    return 0
}

ROOTFS_FOUND=0

if [ -z "$SQUASHFS_SRC" ] || [ "$SQUASHFS_SRC" = "SKIP" ]; then
    # No edge_root specified — search common locations
    echo "Searching for rootfs..."

    # Check /dev/sr0 (ISO boot in QEMU)
    if [ -b /dev/sr0 ] && try_mount_rootfs "/dev/sr0"; then
        ROOTFS_FOUND=1
    fi

    # Check /dev/vdb (secondary disk)
    if [ "$ROOTFS_FOUND" -eq 0 ] && [ -b /dev/vdb ]; then
        echo "Trying /dev/vdb..."
        try_mount_rootfs "/dev/vdb" && ROOTFS_FOUND=1
    fi

    # Check /dev/sda1 (USB boot)
    if [ "$ROOTFS_FOUND" -eq 0 ] && [ -b /dev/sda1 ]; then
        echo "Trying /dev/sda1..."
        try_mount_rootfs "/dev/sda1" && ROOTFS_FOUND=1
    fi
elif [ "$SQUASHFS_SRC" != "SKIP" ]; then
    # Use specified edge_root
    echo "Using specified root: $SQUASHFS_SRC"
    try_mount_rootfs "$SQUASHFS_SRC" && ROOTFS_FOUND=1
fi

# ─── Stage 3: Boot ───
if [ "$ROOTFS_FOUND" -eq 1 ]; then
    # ─── Desktop mode: switch_root into full rootfs ───
    echo ""
    echo "💠 Edge OS — Desktop Mode"
    echo "   Booting into full rootfs..."

    # Mount essential filesystems in the new root
    /bin/busybox mount --rbind /dev "$ROOT_MNT/dev" 2>/dev/null
    /bin/busybox mount --rbind /proc "$ROOT_MNT/proc" 2>/dev/null
    /bin/busybox mount --rbind /sys "$ROOT_MNT/sys" 2>/dev/null
    /bin/busybox mount --rbind /run "$ROOT_MNT/run" 2>/dev/null

    # Bind-mount ISO into new root so Calamares can find squashfs
    if /bin/busybox mountpoint -q "$ISO_MNT" 2>/dev/null; then
        /bin/busybox mkdir -p "$ROOT_MNT/run/live"
        /bin/busybox mount --bind "$ISO_MNT" "$ROOT_MNT/run/live"
    fi

    # Clean up old rootfs
    /bin/busybox cd "$ROOT_MNT"

    # switch_root to the new root (exec /sbin/init or /lib/systemd/systemd)
    if [ -x "$ROOT_MNT/sbin/init" ]; then
        /bin/busybox exec switch_root "$ROOT_MNT" /sbin/init
    elif [ -x "$ROOT_MNT/lib/systemd/systemd" ]; then
        /bin/busybox exec switch_root "$ROOT_MNT" /lib/systemd/systemd
    else
        echo "No init found in rootfs! Falling back to shell."
    fi
fi

# ─── Fallback mode: Busybox shell ───
echo ""
echo "💠 Edge OS initramfs v0.1.0 (fallback mode)"
echo "   Kernel: $(uname -r)"
echo "   CPU: $(grep 'model name' /proc/cpuinfo | head -1 | cut -d: -f2)"
echo "   Mem: $(grep MemTotal /proc/meminfo | awk '{print $2 " " $3}')"
echo ""
echo "   Advanced features:"
echo "   - sched_ext (BPF scheduler): $(grep -q ext /proc/sched_features && echo 'YES' || echo 'no')"
echo "   - MGLRU: $(grep -q lru_gen /sys/kernel/mm/lru_gen/enabled 2>/dev/null && echo 'YES' || echo 'no')"
echo "   - DAMON: $(ls /sys/kernel/mm/damon 2>/dev/null && echo 'YES' || echo 'no')"
echo "   - BBR3: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo 'N/A')"
echo "   - zram: $(ls /dev/zram0 2>/dev/null && echo 'YES' || echo 'no')"
echo "   - ThinLTO: kernel built with LLVM"
echo ""
echo "      /$$$$$$$  /$$$$$$ /$$$$$$$   /$$$$$$ "
echo "     /$$_____/|_  $$_/| $$__  $$ /$$__  $$"
echo "    |  $$$$$$   | $$  | $$  \\ $$| $$  \\ $$"
echo "     \\____  $$  | $$  | $$  | $$| $$  | $$"
echo "     /$$$$$$$/  | $$  | $$  | $$|  $$$$$$/"
echo "    |_______/   |__/  |__/  |__/ \\______/ "
echo ""
echo "Type 'exit' to power off."
echo ""

export PATH=/bin:/sbin
exec /bin/sh
INIT

chmod 755 "$ROOTFS_DIR/init"

# ─── Create cpio archive ───
echo -e "${GREEN}📦 Creating initramfs cpio archive...${NC}"
cd "$ROOTFS_DIR"
find . -print0 | bsdcpio -0o -H newc | xz -9 --check=crc32 > "$BUILD_DIR/initramfs-edge.cpio.xz"
cd "$OLDPWD"

SIZE=$(du -sh "$BUILD_DIR/initramfs-edge.cpio.xz" | cut -f1)
echo -e "${GREEN}✅ Initramfs built: build/initramfs-edge.cpio.xz (${SIZE})${NC}"
