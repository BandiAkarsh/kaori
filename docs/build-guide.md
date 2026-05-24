# Edge OS — Build Guide

## Prerequisites

### Required Packages

```bash
# Debian/Ubuntu
sudo apt install build-essential clang llvm lld curl xz-utils \
                 debootstrap squashfs-tools rsync git python3

# Zig 0.14+ (download from https://ziglang.org/download/)
wget https://ziglang.org/download/0.14.0/zig-linux-x86_64-0.14.0.tar.xz
tar -xf zig-linux-x86_64-0.14.0.tar.xz
export PATH="$PWD/zig-linux-x86_64-0.14.0:$PATH"

# Rust (for coreutils)
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
```

### Hardware Requirements

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| RAM | 8 GB | 16 GB |
| CPU Cores | 4 | 8+ |
| Disk Free | 20 GB | 40 GB |
| Internet | Broadband | Broadband |

## Build Commands

### Full Build (Everything)

```bash
zig build
```

This runs all 6 phases in order and produces `build/edge.iso` — a bootable live ISO with the Edge OS desktop environment.

### Phase-by-Phase

```bash
# Phase 1: Kernel (standalone, no root required)
zig build kernel
# Output: build/vmlinuz-edge

# Phase 2: Rust coreutils (standalone, no root required)
zig build coreutils
# Output: build/edge-rootfs/usr/local/edge/bin/

# Phase 3: Desktop rootfs (requires root for debootstrap)
sudo zig build rootfs
# Output: build/edge-rootfs/ (directory)
#         build/edge-rootfs.squashfs (compressed image)

# Phase 3b: Deploy theme (embedded in zig build rootfs)
# Theme deployment runs automatically during zig build rootfs.
# To deploy manually after a --no-squashfs build:
sudo ./scripts/deploy-theme.sh
# Applies Hyprland desktop config into rootfs

# Phase 1b: Initramfs (depends on kernel version info)
zig build initramfs
# Output: build/initramfs-edge.cpio.xz

# Phase 4: ISO (combines all phases)
zig build iso
# Output: build/edge.iso

# Quick test in QEMU
zig build qemu
```

### Build Artifacts

| Artifact | Path | Size (approx) |
|----------|------|---------------|
| Kernel image | `build/vmlinuz-edge` | 15 MB |
| Initramfs | `build/initramfs-edge.cpio.xz` | 5 MB |
| Rootfs directory | `build/edge-rootfs/` | 2 GB |
| Rootfs squashfs | `build/edge-rootfs.squashfs` | 1.5 GB |
| ISO image | `build/edge.iso` | 1.6 GB |

## Build Options

### Zig Build Steps

```
zig build --help

Steps:
  install        Build everything (default)
  kernel         Phase 1: Build custom Linux kernel
  coreutils      Phase 2: Build Rust core utilities
  rootfs         Phase 3: Build Debian desktop rootfs (needs root)
  rootfs         Phase 3: Build rootfs + deploy theme + create squashfs
  initramfs      Phase 1b: Build initramfs
  iso            Phase 4: Create bootable ISO
  qemu           Boot the ISO in QEMU

  clean          Remove build artifacts
```

### Target Rootfs Without Squashfs

For development, you can build the rootfs without creating the squashfs:

```bash
sudo ./scripts/build-rootfs.sh --no-squashfs
# Deploy theme on top
sudo ./scripts/deploy-theme.sh build/edge-rootfs
# Then manually create squashfs later
sudo mksquashfs build/edge-rootfs build/edge-rootfs.squashfs \
  -comp zstd -Xcompression-level 15 -b 1M -noappend
```

## QEMU Testing

### Default (UEFI)

```bash
zig build qemu
```

Uses OVMF UEFI firmware with 4 GB RAM and KVM acceleration.

### Custom QEMU Invocation

```bash
qemu-system-x86_64 -enable-kvm -m 4G \
  -cpu host -smp 4 \
  -drive file=build/edge.iso,format=raw,media=cdrom \
  -boot d \
  -vga virtio \
  -display gtk
```

### Kernel Debugging with QEMU

```bash
# Build debug kernel (no ThinLTO for faster iteration)
./scripts/build-kernel.sh
# Boot with serial console for kernel logs
qemu-system-x86_64 -enable-kvm -m 4G \
  -kernel build/vmlinuz-edge \
  -initrd build/initramfs-edge.cpio.xz \
  -append "console=ttyS0 edge_skip_rootfs" \
  -serial stdio
```

## Troubleshooting

### "debootstrap: command not found"

Install debootstrap: `sudo apt install debootstrap`

### "Permission denied" on rootfs scripts

Phase 3 (rootfs) requires root for debootstrap and chroot operations. Always use `sudo`:

```bash
sudo zig build rootfs
```

### Kernel build fails with "clang: not found"

The kernel build requires LLVM/Clang 18+. If your distro ships an older version:

```bash
# Install LLVM 18 from apt.llvm.org
wget https://apt.llvm.org/llvm.sh
chmod +x llvm.sh
sudo ./llvm.sh 18
sudo apt install clang-18 lld-18
```

### "Cannot find -lLLVM" during kernel build

The kernel's Thinline LTO build needs LLVMgold.so or ld.lld:

```bash
# Ensure lld is installed
sudo apt install lld-18
# Or configure kernel to use lld directly:
scripts/config --file kernel/config --set-val LLD_VERSION 180000
```

### ISO won't boot in QEMU

1. Ensure OVMF firmware is installed: `sudo apt install ovmf`
2. Try legacy BIOS boot: `qemu-system-x86_64 -m 4G -cdrom build/edge.iso -boot d`
3. Check serial console output for kernel panic details

### "findmnt not found" in Calamares script

The create-btrfs-layout.sh script uses `findmnt` to detect mount points. If running outside Calamares (e.g., manually debugging), install:

```bash
apt install util-linux
```

## Development Workflow

### Quick Iteration Cycle

1. Edit source files (scripts, configs, modules)
2. Rebuild affected phase: `zig build <phase>`
3. Test in QEMU: `zig build qemu`
4. Verify with benchmarks: `./scripts/benchmark-boot.sh`

### Adding a Build Step

To add a new build step to the Zig build system:

1. Add the shell script in `scripts/`
2. Add a new step in `build.zig` referencing the script
3. Wire dependencies to ensure proper ordering
4. Run `zig build <new-step>` to test

### CI Pipeline

Pull requests to `main` trigger GitHub Actions:

- **Lint**: ShellCheck on all `.sh` files
- **Build Verify**: Ensures `build.zig` parses and kernel config is valid
- **Calamares Verify**: Checks YAML config structure and module references
