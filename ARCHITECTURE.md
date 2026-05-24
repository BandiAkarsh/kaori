# Edge OS Architecture

## Overview

Edge OS is a custom Linux distribution built in 6 phases, orchestrated by a Zig build system. The output is a bootable live ISO with a Debian Trixie desktop environment and a Calamares-based system installer.

```
┌─────────────────────────────────────────────────────────────┐
│                    Edge OS Build Pipeline                     │
├──────────┬──────────┬──────────┬──────────┬──────────┬───────┤
│ Phase 1  │ Phase 2  │ Phase 3  │ Phase 4  │ Phase 5  │ P.6   │
│ Kernel   │ Coreutils│ Rootfs   │ Installer│ Snapshots│Polish │
│ (LLVM)   │ (Rust)   │ (Debian) │(Calamares)│ (Btrfs)  │       │
└──────────┴──────────┴──────────┴──────────┴──────────┴───────┘
         │          │          │          │          │
         └──────────┴──────────┴──────────┴──────────┘
                              │
                         ┌────┴────┐
                         │   ISO   │
                         └─────────┘
```

## Build System

The build is orchestrated by `build.zig` using Zig 0.14+ as a build system (not a system language). Each phase is a Zig `step` with dependency ordering:

```
kernel → initramfs
  ↓
coreutils
  ↓
rootfs → theme → squashfs → iso
  ↓
calamares (embedded in rootfs)
```

See [docs/build-guide.md](docs/build-guide.md) for detailed build instructions.

## Phase 1: Kernel

A custom Linux 7.0.10 kernel built with LLVM ThinLTO for optimized binaries. The kernel config (`kernel/config`) enables modern performance features:

- **sched_ext (CONFIG_SCHED_CLASS_EXT)** — BPF-programmable CPU scheduler for workload-tuned scheduling
- **MGLRU (CONFIG_LRU_GEN)** — Multi-Gen LRU for improved memory reclaim performance
- **DAMON (CONFIG_DAMON)** — Data Access MONitor for proactive memory reclaim
- **BBR3 (CONFIG_TCP_CONG_BBR)** — TCP congestion control optimized for modern networks
- **zram + zstd (CONFIG_ZRAM_DEF_COMP_ZSTD)** — Compressed RAM swap for memory efficiency
- **ThinLTO (CONFIG_LTO_CLANG_THIN)** — Link-Time Optimization for smaller, faster kernel
- **Btrfs (CONFIG_BTRFS_FS)** — Native Btrfs support with zstd compression

### Kernel Modules

All drivers (filesystem, network, graphics) are compiled into the kernel (`=y`) rather than as loadable modules (`=m`), producing a monolithic binary that doesn't require an initramfs module loader. The initramfs exists only for rootfs discovery and overlayfs setup.

### Build Script

`scripts/build-kernel.sh` handles:
1. Downloading kernel source from kernel.org
2. Extracting and applying Edge OS config
3. Building with `make LLVM=1 LLVM_IAS=1 bzImage`
4. Outputting to `build/vmlinuz-edge`

## Phase 2: Rust Core Utilities

uutils (Rust rewrite of GNU coreutils) provides memory-safe replacements for standard Unix utilities. Built from the [uutils/coreutils](https://github.com/uutils/coreutils) repository at tag 0.0.28.

### Build Script

`scripts/build-coreutils.sh` handles:
1. Cloning/updating the uutils repository
2. Building selected utilities with `cargo build --release`
3. Deploying to `build/edge-rootfs/usr/local/edge/bin/`
4. Stripping debug symbols and creating symlinks

80+ utilities are built including: `cp`, `mv`, `ls`, `rm`, `cat`, `chmod`, `chown`, `mkdir`, `ln`, `find`, `grep`, `sort`, `uniq`, `wc`, `head`, `tail`, `date`, `sleep`, `echo`, `printf`, and many more.

## Phase 3: Desktop Rootfs

A Debian Trixie rootfs built with debootstrap, containing Hyprland, SDDM, and all desktop components. The rootfs is packaged as a compressed squashfs image for live ISO boot.

### Packages

| Component | Package | Purpose |
|-----------|---------|---------|
| Display Server | Hyprland | Wayland compositor with wlroots |
| Display Manager | SDDM | Graphical login, auto-login for live |
| Panel | Waybar | Status bar with workspaces, system tray |
| Launcher | Rofi | Application launcher and window switcher |
| Notifications | swaync | Notification daemon |
| Terminal | Kitty | GPU-accelerated terminal |
| Wallpaper | wallust | pywal-compatible wallpaper color extraction |
| Logout | wlogout | Session logout screen |
| Audio | PipeWire | Audio server with WirePlumber |
| Network | NetworkManager | Network configuration |

### Build Script

`scripts/build-rootfs.sh` handles:
1. debootstrap minbase Debian Trixie
2. Installing desktop packages via chroot
3. Configuring locale, users, hostname, systemd services
4. Deploying Btrfs snapshot tools (Phase 5)
5. Creating squashfs image with zstd compression

## Phase 4: Calamares Installer

A pre-configured Calamares system installer for installing Edge OS to disk. Located in `installer/calamares/` with:

- **settings.conf** — Module sequence: welcome → locale → keyboard → partition → users → summary → (install) → finished
- **Branding** — Edge OS themed installer with logo and styling
- **Module Configs** — Pre-configured modules for Btrfs partitioning, GRUB bootloader, and services

### Install Sequence

1. **welcome** — Hardware compatibility check
2. **locale** — Language and timezone selection
3. **keyboard** — Keyboard layout
4. **partition** — Guided/manual partitioning (Btrfs default)
5. **users** — User creation
6. **summary** — Install summary
7. **partition** (exec) — Format and partition
8. **btrfs-layout** (exec) — Create subvolumes on Btrfs partition
9. **unpack** (exec) — Unpack squashfs to target
10. **networkcfg** — Copy network config
11. **services** — Enable systemd services
12. **grubcfg** — Configure GRUB
13. **bootloader** — Install GRUB
14. **initramfs** — Rebuild initramfs
15. **packages** — Post-install packages
16. **finished** — Installation complete

See [docs/calamares-install.md](docs/calamares-install.md) for detailed Calamares reference.

## Phase 5: Btrfs Snapshot System

An A/B snapshot model inspired by openSUSE Tumbleweed using snapper as the primary backend with raw btrfs fallback. Provides:

- **Automatic snapshots** — Pre/post snapshot pairs around every APT operation
- **Daily snapshots** — Systemd timer for periodic snapshots at 3:00 AM
- **GRUB integration** — Boot-into-snapshot entries in the GRUB menu
- **Rollback** — Snapper-based rollback with reboot activation

### Subvolume Layout

```
@           → /            (root — snapshotted)
@home       → /home        (user data — excluded from snapshots)
@snapshots  → /.snapshots  (snapshot storage)
@swap       → /.swap       (swap files — nodatacow)
@cache      → /var/cache   (package cache — excluded)
@log        → /var/log     (system logs — excluded)
```

### Components

| File | Deployed As | Purpose |
|------|-------------|---------|
| `system/btrfs/layout.sh` | `/usr/local/lib/edge/btrfs-layout` | Create subvolume layout |
| `system/btrfs/snapshot.sh` | `/usr/local/sbin/edge-btrfs-snapshot` | Snapshot management CLI |
| `system/btrfs/grub-update.sh` | `/usr/local/sbin/edge-grub-snapshot` | GRUB snapshot boot entries |
| `system/apt-hooks/btrfs-snapshot` | `/usr/lib/edge/btrfs-apt-hook` | APT pre/post snapshot hook |
| `system/apt-hooks/80edge-btrfs-snapshots` | `/etc/apt/apt.conf.d/` | APT hook configuration |
| `system/systemd/edge-btrfs-snapshot.service` | `/etc/systemd/system/` | Oneshot snapshot service |
| `system/systemd/edge-btrfs-snapshot.timer` | `/etc/systemd/system/` | Daily snapshot timer |

See [docs/btrfs-snapshots.md](docs/btrfs-snapshots.md) for full usage guide.

## Phase 6: Polish, Benchmarks, Documentation

Quality-of-life improvements including CI, license, gitignore, benchmarks, and documentation.

### CI Pipeline

GitHub Actions workflow (`.github/workflows/build.yml`) validates:
- **lint** — ShellCheck on all shell scripts
- **build-verify** — Build system integrity (Zig parse, kernel config)
- **calamares-verify** — Calamares YAML config validation

### Benchmark Scripts

| Script | Purpose |
|--------|---------|
| `scripts/benchmark-kernel.sh` | Kernel feature analysis, runtime performance, compile benchmarks |
| `scripts/benchmark-boot.sh` | Boot time analysis via systemd-analyze and dmesg |
| `scripts/benchmark-btrfs.sh` | Btrfs layout, snapshot, compression, and I/O benchmarks |

### Live ISO vs Installed System

| Aspect | Live ISO | Installed System |
|--------|----------|-----------------|
| **Root filesystem** | Overlayfs over squashfs (read-only) | Btrfs with subvolumes |
| **Persistence** | None (resets on reboot) | Full persistence |
| **Snapshots** | Not available | Snapper + btrfs snapshots |
| **Boot** | GRUB from ISO | GRUB from disk with snapshot entries |
| **Swap** | zram | Btrfs subvolume (`@swap`) |

## Initramfs Boot Flow

The initramfs (`scripts/build-initramfs.sh`) implements a three-stage boot:

```
Stage 1: Mount essentials (devtmpfs, proc, sysfs, tmpfs)
    │         Create device nodes, install busybox symlinks
    ▼
Stage 2: Parse kernel cmdline for edge_root= parameter
    │         Search /dev/sr0, /dev/vdb, /dev/sda1 for squashfs
    │         Mount squashfs + overlayfs (tmpfs upper)
    ▼
Stage 3: switch_root into full rootfs
          Fallback: Busybox shell with kernel feature info
```

The `edge_root=` kernel parameter specifies a custom squashfs path (e.g., `edge_root=/dev/sda1`). The `edge_skip_rootfs` parameter forces fallback to shell for debugging.

## Development

### Prerequisites

- Zig 0.14+ (for build system)
- LLVM/Clang 18+ (for kernel build)
- Rust/Cargo (for coreutils)
- debootstrap, squashfs-tools (for rootfs, root access required)
- QEMU (for testing)

### Adding a New Script

1. Place in `scripts/` for build tools or `system/` for runtime components
2. Use `#!/usr/bin/env bash` with `set -Eeuo pipefail`
3. Follow ShellCheck rules per `.shellcheckrc`
4. Add deployment to `scripts/build-rootfs.sh` if needed at runtime
5. Add as a Zig build step in `build.zig` if part of the build pipeline

### Code Standards

- Shell scripts pass ShellCheck (SC2086 and SC2181 enabled)
- Variables are quoted (`"$VAR"`) unless intentionally unquoted
- Error messages go to stderr with descriptive context
- Cleanup traps handle all mount points and temp files
- Strict mode: `set -Eeuo pipefail` with `trap cleanup EXIT`
