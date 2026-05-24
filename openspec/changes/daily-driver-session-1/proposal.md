## Why

Edge OS currently builds, boots, and installs — but it's not usable as a daily driver. The ISO has a desktop shell (Hyprland + SDDM) but no browser, no Bluetooth, no file manager, no screenshot tool, no clipboard manager. The theme configs reference tools that aren't installed. Without a browser, you can't even download anything on first boot. This change turns Edge OS from "tech demo that boots" into "a system you could actually use for a day."

## What Changes

- Add Brave browser (from official repo, not Debian — requires GPG key + repo setup)
- Install essential desktop packages: Bluetooth stack (bluez + blueman), NetworkManager applet, audio controls (pavucontrol, pamixer), file manager (thunar), archive tools (unzip, p7zip), screenshot tools (grim, slurp), clipboard manager (cliphist), media controls (playerctl)
- Enable Bluetooth and NetworkManager services by default in the installed system
- All changes happen in `scripts/build-rootfs.sh` — no kernel changes, no initramfs changes, no structural modifications

## Capabilities

### New Capabilities
- `daily-driver-packages`: Core desktop application set that makes the OS usable day-to-day — browser, Bluetooth, file management, media, screenshots, clipboard
- `third-party-repo-management`: Adding and verifying third-party package repositories (Brave Browser) in an automated build pipeline

### Modified Capabilities
*(none — this is the first capability being added to the project)*

## Impact

**Build system**: One new `chroot_exec apt-get install` block in `scripts/build-rootfs.sh`. The Brave repo setup requires a new step before package installation (GPG key download + repo config). No changes to `build.zig`, kernel config, initramfs, or Calamares.

**Dependencies**: Brave repo requires curl and GPG in the build chroot (both available in the minbase debootstrap). All other packages are from Debian main repos.

**Size impact**: ~300-400MB additional in the rootfs squashfs (browser is the bulk).
