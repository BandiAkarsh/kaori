#!/usr/bin/env bash
# Edge OS — Phase 3: Desktop Rootfs Builder
#
# Creates a Debian Trixie rootfs with Hyprland, SDDM, Waybar, and all
# desktop components using debootstrap. Packages the result as a squashfs
# for live ISO boot.
#
# Usage:
#   sudo ./scripts/build-rootfs.sh           # Full build (rootfs dir + squashfs)
#   sudo ./scripts/build-rootfs.sh --no-squashfs  # Rootfs dir only (for theme overlay before squashfs)
#
# Output: build/edge-rootfs/  (directory, for inspection/theme overlay)
#         build/edge-rootfs.squashfs  (compressed image for ISO, omitted with --no-squashfs)
#
# Dependencies: debootstrap, sudo, squashfs-tools, rsync
# Run as root (or via sudo).

set -Eeuo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/colors.sh

# Parse flags
BUILD_SQUASHFS=1
for arg in "$@"; do
    case "$arg" in
        --no-squashfs) BUILD_SQUASHFS=0 ;;
    esac
done

ROOTFS_DIR="build/edge-rootfs"
SQUASHFS_FILE="build/edge-rootfs.squashfs"
CACHE_DIR=".cache"
DEBIAN_SUITE="trixie"
DEBIAN_MIRROR="http://deb.debian.org/debian"

# Step labels for consistent numbering
declare -a STEPS=(
    "Bootstrapping Debian ${DEBIAN_SUITE} base system"
    "Configuring APT sources"
    "Adding Brave Browser repository"
    "Mounting virtual filesystems for chroot"
    "Installing desktop packages"
    "Installing daily driver applications"
    "Installing Btrfs snapshot and management tools"
    "Configuring system"
    "Deploying Btrfs snapshot system"
    "Cleaning up"
)

step() {
    local n=$1; shift
    echo -e "\n${GREEN}[${n}/${#STEPS[@]}] $*${NC}"
}

# ─── Pre-flight checks ───
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}❌ This script must be run as root (debootstrap + chroot need root).${NC}"
    echo "   Usage: sudo ./scripts/build-rootfs.sh"
    exit 1
fi

echo -e "${CYAN}═══════════════════════════════════════════════${NC}"
echo -e "${CYAN}  Edge OS — Desktop Rootfs Builder${NC}"
echo -e "${CYAN}  Suite: ${DEBIAN_SUITE}${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════${NC}"

# ─── Check required tools ───
MISSING=""
for tool in debootstrap mksquashfs rsync chroot; do
    command -v "$tool" >/dev/null 2>&1 || MISSING="$MISSING $tool"
done
if [ -n "$MISSING" ]; then
    echo -e "${RED}❌ Missing tools:$MISSING${NC}" >&2
    echo "   Install: sudo apt install debootstrap squashfs-tools rsync"
    exit 1
fi

# ─── Clean previous build ───
if [ -d "$ROOTFS_DIR" ]; then
    echo -e "${YELLOW}🧹 Removing existing rootfs directory...${NC}"
    rm -rf "$ROOTFS_DIR"
fi
rm -f "$SQUASHFS_FILE"

mkdir -p "$(dirname "$ROOTFS_DIR")" "$CACHE_DIR"

# ─── Step 1: debootstrap ───
step 1 "$DEBIAN_SUITE base system..."
debootstrap --arch amd64 --variant=minbase \
    --include=apt-utils,locales,sudo,ca-certificates \
    "$DEBIAN_SUITE" "$ROOTFS_DIR" "$DEBIAN_MIRROR"
echo -e "${GREEN}  ✅ Base system bootstrapped${NC}"

# ─── Step 2: Configure apt sources ───
step 2 "APT sources..."
cat > "$ROOTFS_DIR/etc/apt/sources.list" <<EOF
deb $DEBIAN_MIRROR $DEBIAN_SUITE main contrib non-free-firmware
deb $DEBIAN_MIRROR ${DEBIAN_SUITE}-updates main contrib non-free-firmware
deb http://security.debian.org/debian-security ${DEBIAN_SUITE}-security main contrib non-free-firmware
EOF

# Copy host resolv.conf for apt in chroot
cp /etc/resolv.conf "$ROOTFS_DIR/etc/resolv.conf"
echo -e "${GREEN}  ✅ APT sources configured${NC}"

# ─── Step 3: Brave Browser repository ───
step 3 "Brave Browser repository..."
mkdir -p "$ROOTFS_DIR/usr/share/keyrings"
curl -fsSLo "$ROOTFS_DIR/usr/share/keyrings/brave-browser-archive-keyring.gpg" \
    "https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg" || {
    echo -e "${RED}  ❌ Failed to download Brave GPG key${NC}" >&2
    exit 1
}
cat > "$ROOTFS_DIR/etc/apt/sources.list.d/brave-browser-release.list" <<EOF
deb [signed-by=/usr/share/keyrings/brave-browser-archive-keyring.gpg] https://brave-browser-apt-release.s3.brave.com/ stable main
EOF
echo -e "${GREEN}  ✅ Brave repository configured${NC}"

# ─── Step 4: Mount essential filesystems for chroot ───
step 4 "virtual filesystems for chroot..."
mount --types proc /proc "$ROOTFS_DIR/proc" 2>/dev/null || true
mount --rbind /sys "$ROOTFS_DIR/sys" 2>/dev/null || true
mount --rbind /dev "$ROOTFS_DIR/dev" 2>/dev/null || true
mount --bind /run "$ROOTFS_DIR/run" 2>/dev/null || true
echo -e "${GREEN}  ✅ Virtual filesystems mounted${NC}"

# Cleanup function
cleanup() {
    echo -e "\n${YELLOW}🧹 Cleaning up mounted filesystems...${NC}"
    umount -l "$ROOTFS_DIR/run" 2>/dev/null || true
    umount -l "$ROOTFS_DIR/dev" 2>/dev/null || true
    umount -l "$ROOTFS_DIR/sys" 2>/dev/null || true
    umount -l "$ROOTFS_DIR/proc" 2>/dev/null || true
    rm -f /tmp/edge-chpasswd 2>/dev/null || true
}
trap cleanup EXIT

# ─── Step 5: Install ALL packages (batched for speed) ───
step 5 "desktop packages (this may take a while)..."

chroot_exec() {
    chroot "$ROOTFS_DIR" env DEBIAN_FRONTEND=noninteractive \
        DEBCONF_NONINTERACTIVE_SEEN=true \
        LC_ALL=C LANGUAGE=C LANG=C \
        "$@"
}

# Update package lists
chroot_exec apt-get update -qq

# ─── Batch 1: Desktop + Daily Driver + Btrfs tools ───
# Uses --no-install-recommends to avoid pulling KDE Plasma
chroot_exec apt-get install -y -qq \
    dbus systemd systemd-sysv sudo locales network-manager \
    pipewire pipewire-pulse wireplumber \
    fonts-noto fonts-noto-cjk fonts-noto-color-emoji \
    sddm qt6-wayland \
    hyprland waybar rofi-wayland swaync wallust wlogout \
    kitty polkit-kde-agent-1 xdg-desktop-portal-hyprland plymouth calamares \
    brave-browser bluez bluez-utils blueman network-manager-gnome \
    pavucontrol pamixer playerctl thunar \
    unzip p7zip-full grim slurp cliphist \
    swww swaybg \
    zathura zathura-pdf-poppler imv geany btop \
    power-profiles-daemon tlp tlp-rdw ufw \
    cups cups-browsed printer-driver-all \
    btrfs-progs snapper btrfs-assistant timeshift btrfsmaintenance grub-btrfs \
    --no-install-recommends

echo -e "${GREEN}  ✅ All packages installed${NC}"

# ─── Step 6: Configure the system ───
step 6 "system..."

# Set locale
sed -i 's/# en_US.UTF-8/en_US.UTF-8/' "$ROOTFS_DIR/etc/locale.gen"
chroot_exec locale-gen
chroot_exec update-locale LANG=en_US.UTF-8

# Create default user 'edge' with secure password setup
PWFILE=/tmp/edge-chpasswd
chroot_exec useradd -m -s /bin/bash -G sudo,audio,video,input edge 2>/dev/null || true

# Write passwords to temp file (avoids exposing in ps aux)
printf 'edge:edge\nroot:edge' > "$PWFILE"
chroot_exec chpasswd < "$PWFILE"
rm -f "$PWFILE"

# Enable services
chroot_exec systemctl enable sddm

# Set hostname
echo "edge-os" > "$ROOTFS_DIR/etc/hostname"

# Configure /etc/hosts
cat > "$ROOTFS_DIR/etc/hosts" <<'EOF'
127.0.0.1 localhost
127.0.1.1 edge-os
::1     localhost ip6-localhost ip6-loopback
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF

chroot_exec systemctl enable NetworkManager
chroot_exec systemctl enable bluetooth 2>/dev/null || true
chroot_exec systemctl set-default graphical.target

# Enable UFW (firewall) — default deny incoming, allow outgoing
chroot_exec ufw --force enable 2>/dev/null || true
chroot_exec ufw default deny incoming 2>/dev/null || true
chroot_exec ufw default allow outgoing 2>/dev/null || true

# Enable system services
chroot_exec systemctl enable cups 2>/dev/null || true
chroot_exec systemctl enable power-profiles-daemon 2>/dev/null || true
chroot_exec systemctl enable tlp 2>/dev/null || true

echo -e "${GREEN}  ✅ System configured${NC}"

# ─── Step 7: Configure Btrfs snapshot system ───
step 7 "Btrfs snapshot system..."

# Deploy snapshot management script
mkdir -p "$ROOTFS_DIR/usr/local/sbin"
cp system/btrfs/snapshot.sh "$ROOTFS_DIR/usr/local/sbin/edge-btrfs-snapshot"
chmod 755 "$ROOTFS_DIR/usr/local/sbin/edge-btrfs-snapshot"
echo -e "${GREEN}  ✅ edge-btrfs-snapshot deployed${NC}"

# Deploy APT hook script
mkdir -p "$ROOTFS_DIR/usr/lib/edge"
cp system/apt-hooks/btrfs-snapshot "$ROOTFS_DIR/usr/lib/edge/btrfs-apt-hook"
chmod 755 "$ROOTFS_DIR/usr/lib/edge/btrfs-apt-hook"
echo -e "${GREEN}  ✅ APT snapshot hook deployed${NC}"

# Deploy APT config
mkdir -p "$ROOTFS_DIR/etc/apt/apt.conf.d"
cp system/apt-hooks/80edge-btrfs-snapshots "$ROOTFS_DIR/etc/apt/apt.conf.d/80edge-btrfs-snapshots"
echo -e "${GREEN}  ✅ APT snapshot config deployed${NC}"

# Deploy systemd timer and service
mkdir -p "$ROOTFS_DIR/etc/systemd/system"
cp system/systemd/edge-btrfs-snapshot.service "$ROOTFS_DIR/etc/systemd/system/"
cp system/systemd/edge-btrfs-snapshot.timer "$ROOTFS_DIR/etc/systemd/system/"
echo -e "${GREEN}  ✅ Systemd timer deployed${NC}"

# Enable periodic snapshot timer
chroot_exec systemctl enable edge-btrfs-snapshot.timer 2>/dev/null || true

# Enable snapper timers (if snapper is available)
chroot_exec systemctl enable snapper-timeline.timer 2>/dev/null || true
chroot_exec systemctl enable snapper-cleanup.timer 2>/dev/null || true

# Deploy GRUB snapshot integration script
cp system/btrfs/grub-update.sh "$ROOTFS_DIR/usr/local/sbin/edge-grub-snapshot"
chmod 755 "$ROOTFS_DIR/usr/local/sbin/edge-grub-snapshot"
echo -e "${GREEN}  ✅ GRUB snapshot script deployed${NC}"

# Deploy Btrfs layout script (for installed system use)
mkdir -p "$ROOTFS_DIR/usr/local/lib/edge"
cp system/btrfs/layout.sh "$ROOTFS_DIR/usr/local/lib/edge/btrfs-layout"
chmod 755 "$ROOTFS_DIR/usr/local/lib/edge/btrfs-layout"
echo -e "${GREEN}  ✅ Btrfs layout script deployed${NC}"

# Create snapshot directory
mkdir -p "$ROOTFS_DIR/.snapshots"
echo -e "${GREEN}  ✅ /.snapshots directory created${NC}"

# Enable grub-btrfsd service for automatic snapshot detection in GRUB
chroot_exec systemctl enable grub-btrfsd 2>/dev/null || true

echo -e "${GREEN}  ✅ Btrfs snapshot system configured${NC}"

# ─── Step 8: Clean up ───
step 8 "up..."
chroot_exec apt-get clean
chroot_exec apt-get autoremove --purge -y

# Remove apt lists to reduce size
rm -rf "$ROOTFS_DIR/var/lib/apt/lists"/*
rm -f "$ROOTFS_DIR/etc/resolv.conf"

echo -e "${GREEN}  ✅ Cleanup done${NC}"

# ─── Extract Debian kernel for ISO ───
echo -e "\n${GREEN}[Extra] Extracting Debian kernel for ISO...${NC}"
DEBIAN_KERNEL=""
for f in "$ROOTFS_DIR/boot/vmlinuz-"*; do
    if [ -f "$f" ]; then
        DEBIAN_KERNEL="$f"
        break
    fi
done
if [ -n "$DEBIAN_KERNEL" ]; then
    cp "$DEBIAN_KERNEL" build/vmlinuz-edge
    echo -e "${GREEN}  ✅ Kernel extracted: $(basename "$DEBIAN_KERNEL") → build/vmlinuz-edge${NC}"
else
    echo -e "${YELLOW}  ⚠ No kernel found in rootfs/boot — install linux-image-amd64 failed?${NC}"
fi

# ─── Create squashfs (optional) ───
if [ "$BUILD_SQUASHFS" -eq 1 ]; then
    echo -e "\n${GREEN}[Extra] Creating squashfs image...${NC}"
    mksquashfs "$ROOTFS_DIR" "$SQUASHFS_FILE" \
        -comp zstd -Xcompression-level 15 \
        -b 1M -noappend
    echo -e "${GREEN}  ✅ Squashfs created: ${SQUASHFS_FILE}${NC}"
    echo -e "${GREEN}     Size: $(du -sh "$SQUASHFS_FILE" | cut -f1)${NC}"
else
    echo -e "\n${YELLOW}[Extra] Skipping squashfs (--no-squashfs). Run deploy-theme.sh first, then create squashfs.${NC}"
fi

echo -e "\n${CYAN}═══════════════════════════════════════════════${NC}"
echo -e "${GREEN}  Phase 3 rootfs build complete!${NC}"
echo -e "${CYAN}  Directory: ${ROOTFS_DIR}${NC}"
if [ "$BUILD_SQUASHFS" -eq 1 ]; then
    echo -e "${CYAN}  Squashfs:  ${SQUASHFS_FILE}${NC}"
fi
echo -e "${CYAN}  Next: run deploy-theme.sh to apply Hyprland configs${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════${NC}"
