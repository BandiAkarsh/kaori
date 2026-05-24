#!/usr/bin/env bash
# Edge OS — Deploy Hyprland Theme Assets into Rootfs
#
# Copies pre-built Hyprland desktop configuration from assets/hyprland-theme/
# into a target rootfs directory at /etc/skel/.config/ (for new users) and
# /home/edge/.config/ (for the default live user).
#
# Usage:
#   sudo ./scripts/deploy-theme.sh [rootfs-path]
#   Default rootfs-path: build/edge-rootfs

set -Eeuo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/colors.sh

ROOTFS="${1:-build/edge-rootfs}"
ASSETS="assets/hyprland-theme/config"
SKEL_CONFIG="$ROOTFS/etc/skel/.config"
EDGE_CONFIG="$ROOTFS/home/edge/.config"

echo -e "${CYAN}═══════════════════════════════════════════════${NC}"
echo -e "${CYAN}  Edge OS — Theme Deployment${NC}"
echo -e "${CYAN}  Target rootfs: ${ROOTFS}${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════${NC}"

# ─── Validation ───
if [ ! -d "$ROOTFS" ]; then
    echo -e "${RED}❌ Rootfs directory not found: ${ROOTFS}${NC}"
    echo "   Run scripts/build-rootfs.sh first."
    exit 1
fi

if [ ! -d "$ASSETS" ]; then
    echo -e "${RED}❌ Theme assets not found: ${ASSETS}${NC}"
    echo "   Expected in project root under ${ASSETS}"
    exit 1
fi

# ─── Create target directories ───
mkdir -p "$SKEL_CONFIG" "$EDGE_CONFIG"

# ─── Mapping: source subdir → target config subdir ───
declare -A DEPLOY_MAP=(
    ["hypr"]="hypr"
    ["waybar"]="waybar"
    ["rofi"]="rofi"
    ["swaync"]="swaync"
    ["wlogout"]="wlogout"
    ["wallust"]="wallust"
    ["kitty"]="kitty"
    ["ags"]="ags"
    ["btop"]="btop"
    ["cava"]="cava"
    ["fastfetch"]="fastfetch"
    ["ghostty"]="ghostty"
    ["Kvantum"]="Kvantum"
    ["qt5ct"]="qt5ct"
    ["qt6ct"]="qt6ct"
    ["quickshell"]="quickshell"
    ["swappy"]="swappy"
    ["wezterm"]="wezterm"
)

deployed=0
skipped=0

for src_dir in "${!DEPLOY_MAP[@]}"; do
    dst_dir="${DEPLOY_MAP[$src_dir]}"
    src_path="$ASSETS/$src_dir"
    skel_dst="$SKEL_CONFIG/$dst_dir"
    edge_dst="$EDGE_CONFIG/$dst_dir"

    if [ ! -d "$src_path" ]; then
        echo -e "${YELLOW}  ⚠ Source not found: ${src_path} — skipping${NC}"
        skipped=$((skipped + 1))
        continue
    fi

    # Deploy to /etc/skel/.config/ (template for new users)
    mkdir -p "$skel_dst"
    cp -r "$src_path"/* "$skel_dst/" 2>/dev/null || true

    # Deploy to /home/edge/.config/ (live user)
    mkdir -p "$edge_dst"
    cp -r "$src_path"/* "$edge_dst/" 2>/dev/null || true

    echo -e "${GREEN}  ✅ ${src_dir} → .config/${dst_dir}${NC}"
    deployed=$((deployed + 1))
done

# ─── Set proper ownership ───
# Use numeric UID 1000 (edge's UID in rootfs) to avoid relying on host user database
chown -R root:root "$SKEL_CONFIG" 2>/dev/null || true
chown -R 1000:1000 "$EDGE_CONFIG" 2>/dev/null || true

echo ""
echo -e "${GREEN}📊 Deployed: $deployed config directories, $skipped skipped${NC}"
echo -e "${CYAN}   /etc/skel/.config/ — template for new users${NC}"
echo -e "${CYAN}   /home/edge/.config/ — live user${NC}"

# ─── Additional: SDDM theme config ───
mkdir -p "$ROOTFS/etc/sddm.conf.d"
if [ -f "desktop/hyprland/sddm.conf.d/edge.conf" ]; then
    cp "desktop/hyprland/sddm.conf.d/edge.conf" "$ROOTFS/etc/sddm.conf.d/edge.conf"
    chown root:root "$ROOTFS/etc/sddm.conf.d/edge.conf"
    echo -e "${GREEN}  ✅ SDDM autologin config deployed${NC}"
fi

# ─── Additional: Hyprland Wayland session file ───
if [ -d "$ROOTFS/usr/share" ]; then
    mkdir -p "$ROOTFS/usr/share/wayland-sessions"
    if [ -f "desktop/hyprland/usr/share/wayland-sessions/hyprland.desktop" ]; then
        cp "desktop/hyprland/usr/share/wayland-sessions/hyprland.desktop" \
            "$ROOTFS/usr/share/wayland-sessions/hyprland.desktop"
        chown root:root "$ROOTFS/usr/share/wayland-sessions/hyprland.desktop"
        echo -e "${GREEN}  ✅ Hyprland Wayland session file deployed${NC}"
    fi
fi

# ─── Phase 4: Calamares Installer Configs ───
CALAMAres_ETC="$ROOTFS/etc/calamares"
CALAMAres_USR="$ROOTFS/usr/share/calamares"
CALAMAres_SRC="installer/calamares"

if [ -d "$CALAMAres_SRC" ]; then
    echo -e "\n${CYAN}--- Phase 4: Calamares Installer ---${NC}"

    # Deploy settings.conf
    mkdir -p "$CALAMAres_ETC"
    if [ -f "$CALAMAres_SRC/settings.conf" ]; then
        cp "$CALAMAres_SRC/settings.conf" "$CALAMAres_ETC/settings.conf"
        chown root:root "$CALAMAres_ETC/settings.conf"
        echo -e "${GREEN}  ✅ Calamares settings.conf deployed${NC}"
    fi

    # Deploy module configs
    mkdir -p "$CALAMAres_ETC/modules"
    for mod_conf in "$CALAMAres_SRC/modules/"*.conf; do
        if [ -f "$mod_conf" ]; then
            cp "$mod_conf" "$CALAMAres_ETC/modules/"
            chown root:root "$CALAMAres_ETC/modules/$(basename "$mod_conf")"
            echo -e "${GREEN}  ✅ Calamares module: $(basename "$mod_conf")${NC}"
        fi
    done

    # Deploy Calamares scripts (btrfs-layout, etc)
    if [ -d "$CALAMAres_SRC/scripts" ]; then
        mkdir -p "$CALAMAres_ETC/scripts"
        for script_file in "$CALAMAres_SRC/scripts/"*.sh; do
            if [ -f "$script_file" ]; then
                cp "$script_file" "$CALAMAres_ETC/scripts/"
                chmod 755 "$CALAMAres_ETC/scripts/$(basename "$script_file")"
                echo -e "${GREEN}  ✅ Calamares script: $(basename "$script_file")${NC}"
            fi
        done
    fi

    # Deploy branding
    if [ -d "$CALAMAres_SRC/branding/edge" ]; then
        mkdir -p "$CALAMAres_USR/branding/edge"
        cp -r "$CALAMAres_SRC/branding/edge/"* "$CALAMAres_USR/branding/edge/"
        chown -R root:root "$CALAMAres_USR/branding/edge"
        echo -e "${GREEN}  ✅ Calamares branding deployed${NC}"
    fi

    # Deploy desktop launcher
    if [ -f "$CALAMAres_SRC/edge-install.desktop" ]; then
        # System-wide launcher
        mkdir -p "$ROOTFS/usr/share/applications"
        cp "$CALAMAres_SRC/edge-install.desktop" "$ROOTFS/usr/share/applications/"
        chown root:root "$ROOTFS/usr/share/applications/edge-install.desktop"

        # Live user desktop
        mkdir -p "$ROOTFS/home/edge/Desktop"
        cp "$CALAMAres_SRC/edge-install.desktop" "$ROOTFS/home/edge/Desktop/"
        chown 1000:1000 "$ROOTFS/home/edge/Desktop/edge-install.desktop"
        chmod +x "$ROOTFS/home/edge/Desktop/edge-install.desktop"

        echo -e "${GREEN}  ✅ Calamares desktop launcher deployed${NC}"
    fi
fi

# ─── Default Wallpaper ───
echo -e "\n${CYAN}--- Setting up default wallpaper ---${NC}"

# Create wallpapers directory
mkdir -p "$ROOTFS/home/edge/Pictures/wallpapers"

# Copy theme wallpapers into home
if [ -d "assets/hyprland-theme/wallpapers" ]; then
    cp -r assets/hyprland-theme/wallpapers/* "$ROOTFS/home/edge/Pictures/wallpapers/" 2>/dev/null || true
    echo -e "${GREEN}  ✅ Theme wallpapers deployed${NC}"
fi

# Pick first wallpaper as default
DEFAULT_WALL=$(ls "$ROOTFS/home/edge/Pictures/wallpapers/" 2>/dev/null | grep -iE '\.(png|jpg|jpeg)' | head -1)
if [ -n "$DEFAULT_WALL" ]; then
    # Add swww wallpaper set to Startup_Apps.conf
    cat >> "$ROOTFS/home/edge/.config/hypr/configs/Startup_Apps.conf" <<WALL

# Edge OS — default wallpaper
exec-once = swww img \$HOME/Pictures/wallpapers/${DEFAULT_WALL}
WALL
    chown 1000:1000 "$ROOTFS/home/edge/.config/hypr/configs/Startup_Apps.conf"
    echo -e "${GREEN}  ✅ Default wallpaper set: ${DEFAULT_WALL}${NC}"
else
    echo -e "${YELLOW}  ⚠ No wallpapers found to set as default${NC}"
fi

# Also add to skel for new users
if [ -d "$ROOTFS/etc/skel/.config/hypr/configs" ]; then
    WALL_NAME="${DEFAULT_WALL:-}"
    if [ -n "$WALL_NAME" ]; then
        cat >> "$ROOTFS/etc/skel/.config/hypr/configs/Startup_Apps.conf" <<WALL2

# Edge OS — default wallpaper
exec-once = swww img \$HOME/Pictures/wallpapers/${WALL_NAME}
WALL2
    fi
fi

# ─── Touchpad Configuration ───
echo -e "\n${CYAN}--- Configuring touchpad ---${NC}"
TOUCHPAD_CONF="$ROOTFS/home/edge/.config/hypr/configs/touchpad.conf"
mkdir -p "$(dirname "$TOUCHPAD_CONF")"
cat > "$TOUCHPAD_CONF" <<'TOUCHPAD'
# Edge OS — Touchpad Configuration
# Natural scrolling + tap-to-click enabled

input {
    touchpad {
        natural_scroll = true
        tap-to-click = true
        tap-and-drag = true
        drag_lock = true
        accel_profile = adaptive
        scroll_factor = 0.5
    }
}
TOUCHPAD
chown 1000:1000 "$TOUCHPAD_CONF"
echo -e "${GREEN}  ✅ Touchpad config deployed${NC}"

# Add include to hyprland.conf if not already present
HYPR_CONF="$ROOTFS/home/edge/.config/hypr/hyprland.conf"
if [ -f "$HYPR_CONF" ]; then
    if ! grep -q 'touchpad.conf' "$HYPR_CONF" 2>/dev/null; then
        echo "source = ~/.config/hypr/configs/touchpad.conf" >> "$HYPR_CONF"
        chown 1000:1000 "$HYPR_CONF"
        echo -e "${GREEN}  ✅ Touchpad config sourced in hyprland.conf${NC}"
    fi
fi

echo -e "\n${GREEN}✅ Deployment complete!${NC}"
echo -e "${CYAN}   Next: create squashfs with: sudo mksquashfs build/edge-rootfs build/edge-rootfs.squashfs -comp zstd -Xcompression-level 15 -b 1M -noappend${NC}"
