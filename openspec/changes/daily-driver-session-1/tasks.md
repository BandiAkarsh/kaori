## 1. Brave Browser Repository Setup

- [x] 1.1 Add Brave GPG key download and apt source configuration to `scripts/build-rootfs.sh` before the package installation section
- [x] 1.2 Brave repo will be picked up by existing `apt-get update` — the repo is added at Step 2b, before Step 4's `apt-get update`

## 2. Essential Desktop Packages

- [x] 2.1 Added `chroot_exec apt-get install` block in `scripts/build-rootfs.sh` as Step 5/10 with all daily driver packages
- [ ] 2.2 Build and verify (requires sudo + build time — user action step)

## 3. Service Enablement

- [x] 3.1 Added `chroot_exec systemctl enable bluetooth` in the system config step
- [x] 3.2 NetworkManager was already enabled — confirmed
- [x] 3.3 nm-applet already in Startup_Apps.conf (uncommented). Blueman-applet was commented — uncommented it. cliphist store already in Startup_Apps.conf (uncommented).

## 4. Verification

- [ ] 4.1 Rebuild rootfs: `sudo ./scripts/build-rootfs.sh --no-squashfs`
- [ ] 4.2 Deploy theme: `sudo ./scripts/deploy-theme.sh`
- [ ] 4.3 Create squashfs: `sudo mksquashfs build/edge-rootfs build/edge-rootfs.squashfs -comp zstd -Xcompression-level 15 -b 1M -noappend`
- [ ] 4.4 Build ISO: `zig build iso`
- [ ] 4.5 Boot in QEMU and verify: Brave launches, Bluetooth service is active, nm-applet runs, thunar opens, grim/slurp takes screenshots, cliphist stores clipboard, pamixer reports volume
