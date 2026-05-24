# Edge OS

A custom Linux distribution built from source — modern kernel, Rust coreutils, Debian Trixie desktop with Hyprland, and Btrfs A/B snapshot system for atomic updates and rollback.

**Version**: 0.1.0
**Status**: Alpha — bootable ISO with live desktop and Calamares installer.

## Features

- **Custom Kernel** — Linux 7.0.10 with LLVM ThinLTO, sched_ext (BPF scheduler), MGLRU, DAMON, BBR3, and Btrfs support
- **Rust Coreutils** — [uutils](https://github.com/uutils/coreutils) replaces GNU coreutils for safer memory management
- **Debian Desktop** — Trixie base with Hyprland, SDDM, Waybar, Rofi, and pre-configured desktop theme
- **Btrfs Snapshots** — A/B update model via snapper + raw btrfs snapshots with APT hooks, systemd timers, and GRUB boot entries
- **Calamares Installer** — Graphical installation with guided partitioning supporting Btrfs subvolume layout
- **Live ISO** — Overlayfs-based live environment with squashfs rootfs for try-before-install

## Quick Start

### Build from Source

```bash
# Prerequisites: Zig 0.14+, clang, llvm, curl, xz, debootstrap, squashfs-tools, rsync
zig build       # Build everything: kernel + initramfs + rootfs + ISO
zig build qemu  # Boot the ISO in QEMU
```

### Build Individual Phases

```bash
zig build kernel     # Custom kernel with ThinLTO
zig build coreutils  # Rust core utilities
zig build rootfs     # Debian desktop rootfs
zig build theme      # Deploy Hyprland desktop theme
zig build initramfs  # Initramfs with overlayfs support
zig build iso        # Bootable ISO (combines all phases)
```

### Install on Hardware

1. Boot the Edge OS ISO
2. Launch the installer from the desktop (Calamares)
3. Follow guided partitioning — Btrfs with subvolumes is the default
4. Complete installation, reboot, and enjoy Edge OS

## Project Structure

```
├── build.zig                 # Master build orchestrator (Zig 0.14+)
├── kernel/config             # Custom Linux kernel configuration
├── scripts/                  # Build and utility scripts
│   ├── build-kernel.sh       # Kernel compilation with LLVM ThinLTO
│   ├── build-coreutils.sh    # Rust coreutils build
│   ├── build-rootfs.sh       # Debian Trixie rootfs builder
│   ├── deploy-theme.sh       # Hyprland theme deployment
│   ├── build-initramfs.sh    # Initramfs with overlayfs fallback
│   ├── benchmark-kernel.sh   # Kernel performance analysis
│   ├── benchmark-boot.sh     # Boot time measurement
│   └── benchmark-btrfs.sh    # Btrfs filesystem benchmarks
├── system/                   # System configuration and services
│   ├── btrfs/                # Btrfs snapshot system
│   │   ├── layout.sh         # Subvolume layout creator
│   │   ├── snapshot.sh       # Snapshot manager (snapper + fallback)
│   │   └── grub-update.sh    # GRUB snapshot boot entries
│   ├── apt-hooks/            # APT pre/post snapshot hooks
│   └── systemd/              # Systemd timer for daily snapshots
├── installer/                # Calamares installer configuration
│   └── calamares/            # Modules, branding, scripts
├── assets/                   # Desktop theme assets (Hyprland configs)
├── desktop/                  # Desktop environment configs
└── docs/                     # Documentation
    ├── build-guide.md        # Detailed build instructions
    ├── btrfs-snapshots.md    # Btrfs snapshot system guide
    └── calamares-install.md   # Calamares installer reference
```

## Requirements

| Component | Requirement |
|-----------|-------------|
| **Build** | Zig 0.14+, LLVM 18+, curl, xz-utils |
| **Rootfs** | debootstrap, squashfs-tools, rsync (root) |
| **Runtime** | 4 GB RAM, 20 GB disk, x86-64 CPU with SSE4.2 |
| **Boot** | UEFI or BIOS, GRUB 2.x |

## License

GNU General Public License v3.0 — see [LICENSE](LICENSE) for details.

Edge OS is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
