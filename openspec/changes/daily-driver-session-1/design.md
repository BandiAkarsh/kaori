## Context

Edge OS currently packages a minimal Debian Trixie rootfs with Hyprland, SDDM, Btrfs snapshot tools, and Calamares. The theme configs (49 scripts in `assets/hyprland-theme/`) reference many tools that aren't installed — volume scripts call `pamixer`, screenshot scripts call `grim`/`slurp`, clipboard scripts call `cliphist`, and Waybar has click handlers for `blueman-manager` and `nm-applet`. The ISO boots to a desktop that looks polished but has broken features.

The build pipeline is in `scripts/build-rootfs.sh`, which runs inside a chroot against a debootstrapped Debian Trixie base. All package installation happens via `chroot_exec apt-get install`.

## Goals / Non-Goals

**Goals:**
- Add Brave browser with official repo (GPG key + apt source)
- Install Bluetooth stack (bluez + blueman) and enable it by default
- Install NetworkManager applet (network-manager-gnome)
- Install audio controls (pavucontrol, pamixer, playerctl)
- Install file manager (thunar) and archive tools (unzip, p7zip-full)
- Install screenshot tools (grim, slurp)
- Install clipboard manager (cliphist)
- All changes in one file: `scripts/build-rootfs.sh`
- Services enabled by default in the installed system

**Non-Goals:**
- No kernel changes (stays on Debian kernel)
- No initramfs changes
- No Calamares module changes
- No theme customization
- No file association / MIME type configuration
- No first-boot wizard

## Decisions

| Decision | Choice | Why |
|----------|--------|-----|
| Browser | Brave (official repo) | Not in Debian repos. Brave's repo is well-maintained, auto-updates, and is Chromium-based for broad compatibility. The GPG key setup in the build pipeline demonstrates third-party repo handling. |
| File manager | Thunar | Lightweight, GTK-based, works well under Hyprland. No GNOME/KDE dependency pull. |
| Bluetooth | bluez + blueman | Kernel already has `CONFIG_BT=y` with all USB/UART drivers. bluez is the standard Linux stack. blueman provides the tray icon that Waybar's Bluetooth module clicks. |
| Screenshot | grim + slurp | The standard Wayland screenshot combo. grim captures the screen, slurp selects regions. Both are used by the theme's ScreenShot.sh. |
| Clipboard | cliphist | Wayland-native clipboard manager. Used by the theme's ClipManager.sh. Lightweight, no dependencies. |
| Audio UI | pavucontrol + pamixer | pavucontrol is the PipeWire-compatible mixer GUI. pamixer is the CLI tool used by Volume.sh. playerctl handles media key bindings. |
| Build integration | Single block in build-rootfs.sh | Minimizes diff. All package installation happens in one place. The Brave repo setup is a separate step before package install. |

## Risks / Trade-offs

| Risk | Mitigation |
|------|------------|
| Brave repo GPG key may change or expire | Keys are pinned to specific URL on Brave's official servers. If the key changes, the build will fail at the curl step — obvious failure, not silent. |
| Brave package size (~300MB) increases ISO size | Expected and acceptable. The squashfs compression (zstd level 15) minimizes the impact. |
| Bluetooth service might not auto-start | We enable `bluetooth.service` via systemctl in the chroot. On first boot, systemd handles startup. |
| nm-applet doesn't auto-start in Hyprland | Hyprland autostart config handles this. We verify the autostart entry exists in the deployed theme config. |
| Cliphist needs a systemd user service or autostart | Same — verified via Hyprland config autostart or a systemd user service suggestion. |
