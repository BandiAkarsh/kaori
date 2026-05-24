# Edge OS — Calamares Installer Reference

## Overview

Edge OS ships with a customized [Calamares](https://calamares.io/) system installer for installing the live system to disk. The installer is pre-configured with Edge OS branding, Btrfs subvolume layout, and optimized defaults.

## Install Sequence

The installer runs modules in two phases: a configuration phase (shown to the user as wizard pages) and an execution phase (progress bar with automatic steps).

### Configuration Phase (User Interaction)

```
1. Welcome    — Language selection, hardware requirements check
2. Locale     — Timezone via GeoIP, locale selection
3. Keyboard   — Keyboard layout detection and selection
4. Partition  — Guided or manual disk partitioning
5. Users      — Create user account (password, hostname)
6. Summary    — Review installation choices before proceeding
```

### Execution Phase (Automatic)

```
7.  Partition     — Format partitions, create filesystems
8.  btrfs-layout  — Create Btrfs subvolume layout (shellprocess)
9.  Unpack        — Extract squashfs to target system
10. Network       — Copy live network configuration
11. Services      — Enable systemd services on target
12. GRUB Config   — Generate GRUB configuration
13. Bootloader    — Install GRUB to disk
14. Initramfs     — Rebuild initramfs for target kernel
15. Packages      — Post-install package operations
16. Finished      — Installation complete, offer reboot
```

## Module Configuration

All module configs are in `installer/calamares/modules/`.

### Partition Configuration (`partition.conf`)

```yaml
defaultFileSystemType: "btrfs"
```

The default filesystem is Btrfs, which triggers the `btrfs-layout` shellprocess module after partitioning to create subvolumes.

### Btrfs Layout Module (`btrfs-layout.conf`)

```yaml
instance: btrfs-layout
module: shellprocess
script: "../scripts/create-btrfs-layout.sh"
dontChroot: true
timeout: 120
```

This runs after partitioning but before unpackfs, creating the subvolume layout on the formatted Btrfs partition. It runs outside the chroot (`dontChroot: true`) because it needs direct device access for `btrfs subvolume` commands.

### Shellprocess Script (`create-btrfs-layout.sh`)

The script performs these steps:

1. **Detect Btrfs device** — Searches common Calamares mount points for a Btrfs filesystem
2. **Create subvolumes** — Mounts the Btrfs top-level (subvolid=5) and creates all 6 subvolumes
3. **Set default** — Sets `@` as the default subvolume
4. **Mount subvolumes** — Remounts `@` as root and mounts each subvolume at its correct path
5. **Generate fstab** — Creates `/etc/fstab` with UUID-based mount entries

### Settings (`settings.conf`)

Key configuration:

```yaml
modules-search: [ local ]
branding: edge
prompt-install: false
dont-chroot: false
oem-setup: false
quit-at-end: true
```

- `branding: edge` uses custom Edge OS branding (logo, colors, product name)
- `quit-at-end: true` automatically quits the installer when installation completes
- `dont-chroot: false` runs execution modules inside chroot by default

## Branding

Calamares branding files are in `installer/calamares/branding/edge/`:

| File | Purpose |
|------|---------|
| `branding.desc` | Product name, version, organization info |
| `show.qml` | Slideshow shown during installation |
| `edge-logo.svg` | Product logo |
| `stylesheet.qss` | Qt stylesheet for installer appearance |

The branding descriptor sets:

```
productName = Edge OS
version = 0.1.0
shortProductName = Edge
bootloaderEntryName = Edge OS
productUrl = (placeholder — update when website is live)
supportUrl = (placeholder)
```

## Adding a New Module

To add a new Calamares module:

1. **Create module config** — Add `installer/calamares/modules/<module>.conf`
2. **Add instance** — Register in `settings.conf` under `instances`
3. **Add to sequence** — Add to the `sequence` in `settings.conf` under either `show` (user-facing) or `exec` (automatic)
4. **Deploy** — `deploy-theme.sh` copies all module configs to the rootfs

Example: Adding a "post-copy" module that runs user scripts after installation:

```yaml
# In installer/calamares/modules/postcopy.conf
---
module: shellprocess
script: "../scripts/post-install.sh"
dontChroot: false

# In settings.conf instances:
- id: post-copy
  module: shellprocess
  config: postcopy.conf

# In settings.conf sequence exec:
- post-copy  # after packages, before finished
```

## Troubleshooting

### Installer Fails at "btrfs-layout" Step

The `btrfs-layout` module requires a Btrfs-formatted root partition. Possible causes:

1. **Manual partitioning with ext4** — If you selected ext4 in manual partitioning, the btrfs-layout step will detect it's not Btrfs and skip subvolume creation. The installation continues with a flat ext4 layout.
2. **Missing `findmnt`** — The script uses `findmnt` to detect mount points. In minimal environments, `util-linux` may not be available. The script handles this with a fallback search.
3. **Device not found** — If the script can't find a Btrfs device, it exits silently (exit 0) and continues the installation without subvolumes.

### Installer Freezes or Crashes

1. Check system logs: `journalctl -f` in a terminal during installation
2. Check Calamares debug output: `sudo calamares -d`
3. Ensure sufficient disk space: The rootfs needs at least 4 GB after unpacking
4. Check memory: 4 GB RAM minimum, 2 GB swap recommended

### Partition Table Issues

Edge OS uses GPT partition tables by default. If you have an existing MBR disk:

1. In the partition module, select "Manual partitioning"
2. Create a new GPT partition table (this erases the disk)
3. Create partitions manually (EFI system partition + root)

### GRUB Installation Fails

If GRUB installation fails:

1. Verify the target is bootable: EFI system partition must be FAT32 with `esp` flag
2. For BIOS boot, ensure a BIOS boot partition exists (1 MB, unformatted, `bios_grub` flag)
3. The bootloader module logs to `/var/log/calamares/`

### Re-running the Installer

From the live desktop, you can restart the installer:

```bash
calamares -d 2>&1 | tee /tmp/calamares-debug.log
```

The `-d` flag enables debug output. The log file is helpful for troubleshooting.

## Development

### Testing Module Changes

1. Build the rootfs: `sudo ./scripts/build-rootfs.sh --no-squashfs`
2. Deploy updated configs: `sudo ./scripts/deploy-theme.sh build/edge-rootfs`
3. Create squashfs: `sudo mksquashfs build/edge-rootfs build/edge-rootfs.squashfs -comp zstd -Xcompression-level 15 -b 1M -noappend`
4. Build ISO: `zig build iso`
5. Test in QEMU: `zig build qemu`

### Debugging btrfs-layout Outside Calamares

The create-btrfs-layout.sh script can be tested manually:

```bash
# Mount a test Btrfs filesystem
sudo mkfs.btrfs -f /dev/loop0
sudo mkdir /tmp/test-btrfs
sudo mount -t btrfs /dev/loop0 /tmp/test-btrfs

# Set ROOTFS_DIR for the script
export ROOTFS_DIR=/tmp/test-btrfs
sudo installer/calamares/scripts/create-btrfs-layout.sh

# Check the result
btrfs subvolume list /tmp/test-btrfs
cat /tmp/test-btrfs/etc/fstab

# Cleanup
sudo umount /tmp/test-btrfs
sudo rmdir /tmp/test-btrfs
```

## Module Reference

| Module | Type | Purpose |
|--------|------|---------|
| `welcome` | view | Hardware requirements, language |
| `locale` | view | Timezone, locale selection |
| `keyboard` | view | Keyboard layout |
| `partition` | view+exec | Disk partitioning (default: Btrfs) |
| `btrfs-layout` | shellprocess | Create Btrfs subvolumes (Edge OS custom) |
| `users` | view | User account creation |
| `summary` | view | Installation summary |
| `unpack` | unpackfs | Extract squashfs to target |
| `networkcfg` | copy | Copy network config from live |
| `services` | services | Enable systemd services |
| `grubcfg` | grubcfg | Generate GRUB config |
| `bootloader` | bootloader | Install GRUB to disk |
| `initramfs` | debian-initramfs | Rebuild initramfs |
| `packages` | packages | Post-install package ops |
| `finished` | view | Completion screen |

## File Layout

```
installer/calamares/
├── settings.conf                # Top-level installer config
├── branding/
│   └── edge/                    # Edge OS branding (logo, slideshow)
├── modules/
│   ├── welcome.conf
│   ├── locale.conf
│   ├── keyboard.conf
│   ├── partition.conf           # Default filesystem: Btrfs
│   ├── btrfs-layout.conf        # Shellprocess: subvolume creation
│   ├── users.conf
│   ├── summary.conf
│   ├── unpackfs.conf
│   ├── networkcfg.conf
│   ├── services.conf
│   ├── grubcfg.conf
│   ├── bootloader.conf
│   ├── initramfs.conf
│   ├── packages.conf
│   └── finished.conf
├── scripts/
│   └── create-btrfs-layout.sh   # Btrfs subvolume creation script
└── edge-install.desktop         # Desktop launcher for live session
```
