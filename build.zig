//! Edge OS — Build System
//!
//! Orchestrates the full OS build:
//!   1. Desktop rootfs (Debian Trixie + Hyprland + SDDM via debootstrap)
//!   2. Kernel extracted from Debian rootfs (no custom compile)
//!   3. Initramfs (busybox-based multi-stage boot: desktop or fallback shell)
//!   4. Rust coreutils (uutils)
//!   5. Bootable ISO (GRUB, BIOS+UEFI)
//!   6. QEMU test
//!
//! Requirements: zig 0.14+, clang, llvm, make, curl, xz, grub-mkrescue,
//!               xorriso, qemu, debootstrap, squashfs-tools, rsync

const std = @import("std");

pub fn build(b: *std.Build) void {
    _ = b.standardTargetOptions(.{});
    _ = b.standardOptimizeOption(.{});

    const kernel_version = b.option([]const u8, "kernel", "Kernel version (unused with Debian kernel)")
        orelse "6.12";

    // ─── Step 1: Build desktop rootfs (Phase 3) ───
    // Rootfs must exist before we can extract the Debian kernel from it.
    const rootfs_step = buildRootfs(b);

    // ─── Step 2: Extract Debian kernel from rootfs ───
    const kernel_step = extractDebianKernel(b);
    kernel_step.dependOn(rootfs_step);

    // ─── Step 3: Build initramfs ───
    const initramfs_step = buildInitramfs(b, kernel_version);
    initramfs_step.dependOn(kernel_step);

    // Default: rootfs + kernel + initramfs
    b.default_step.dependOn(rootfs_step);
    b.default_step.dependOn(kernel_step);
    b.default_step.dependOn(initramfs_step);

    // ─── Step 4: Build Rust coreutils (no kernel dependency) ───
    const coreutils_step = buildCoreutils(b);
    b.default_step.dependOn(coreutils_step);

    // ─── Step 5: Build ISO ───
    const iso_step = buildISO(b, kernel_version);
    iso_step.dependOn(kernel_step);
    iso_step.dependOn(initramfs_step);
    iso_step.dependOn(rootfs_step);       // ISO includes desktop squashfs

    // ─── Step 6: QEMU test ───
    const qemu_step = b.step("qemu", "Boot ISO in QEMU");
    const qemu_cmd = b.addSystemCommand(&.{
        "bash", "-c",
        \\ISO="build/edge.iso"; \
        \\if [ ! -f "$ISO" ]; then \
        \\  echo "❌ $ISO not found. Run 'zig build iso' first."; \
        \\  exit 1; \
        \\fi; \
        \\echo "🖥️  Booting Edge OS in QEMU..."; \
        \\exec qemu-system-x86_64 \
        \\  -cdrom "$ISO" -m 4G -accel kvm \
        \\  -cpu host -smp 4 \
        \\  -serial stdio -vga virtio \
        \\  -display gtk
        ,
    });
    qemu_cmd.has_side_effects = true;
    qemu_cmd.step.dependOn(iso_step);
    qemu_step.dependOn(&qemu_cmd.step);
}

/// Extract the Debian kernel from the built rootfs (replaces custom kernel compile).
/// Copies rootfs/boot/vmlinuz-* → build/vmlinuz-edge.
/// The custom kernel config at kernel/config is retained as reference only.
fn extractDebianKernel(b: *std.Build) *std.Build.Step {
    const step = b.step("kernel", "Extract Debian kernel from rootfs");

    const mkdir = b.addSystemCommand(&.{ "mkdir", "-p", "build" });
    mkdir.has_side_effects = true;
    step.dependOn(&mkdir.step);

    const extract = b.addSystemCommand(&.{
        "bash", "-c",
        \\ROOTFS="build/edge-rootfs"; \
        \\KERNEL=$(ls "$ROOTFS/boot/vmlinuz-"* 2>/dev/null | head -1); \
        \\if [ -z "$KERNEL" ]; then \
        \\  echo "❌ No kernel found in $ROOTFS/boot/" >&2; \
        \\  exit 1; \
        \\fi; \
        \\cp "$KERNEL" build/vmlinuz-edge && \
        \\echo "✅ Kernel extracted: $(basename "$KERNEL") → build/vmlinuz-edge ($(ls -lh build/vmlinuz-edge | awk '{print $5}'))"
        ,
    });
    extract.has_side_effects = true;
    extract.step.dependOn(&mkdir.step);
    step.dependOn(&extract.step);

    return step;
}

/// Build a minimal initramfs with busybox static binary.
/// Supports two boot modes:
///   1. Desktop: mounts squashfs + overlayfs → switch_root → systemd → SDDM → Hyprland
///   2. Fallback: drops to busybox shell (Phase 1 compat)
fn buildInitramfs(
    b: *std.Build,
    kernel_version: []const u8,
) *std.Build.Step {
    const step = b.step("initramfs", "Build initramfs cpio archive");

    const build_initramfs = b.addSystemCommand(&.{
        "bash", "-c",
        b.fmt(
            \\exec bash scripts/build-initramfs.sh "{s}"
            ,
            .{kernel_version},
        ),
    });
    build_initramfs.has_side_effects = true;
    step.dependOn(&build_initramfs.step);

    return step;
}

/// Build Rust core utilities (uutils) for Edge OS.
fn buildCoreutils(b: *std.Build) *std.Build.Step {
    const step = b.step("coreutils", "Build Rust coreutils (uutils)");

    const build_cu = b.addSystemCommand(&.{
        "bash", "-c",
        \\echo "📦 Phase 2: Rust Core Utilities" && \
        \\exec bash scripts/build-coreutils.sh
        ,
    });
    build_cu.has_side_effects = true;
    step.dependOn(&build_cu.step);

    return step;
}

/// Build Debian Trixie rootfs with Hyprland desktop (Phase 3).
/// Uses debootstrap + Debian main repos — no source compilation needed.
fn buildRootfs(b: *std.Build) *std.Build.Step {
    const step = b.step("rootfs", "Build Debian rootfs with Hyprland desktop");

    const build_rfs = b.addSystemCommand(&.{
        "bash", "-c",
        \\echo "📦 Phase 3: Desktop Rootfs" && \
        \\sudo bash scripts/build-rootfs.sh --no-squashfs && \
        \\sudo bash scripts/deploy-theme.sh && \
        \\echo "📦 Creating squashfs..." && \
        \\sudo mksquashfs build/edge-rootfs build/edge-rootfs.squashfs \
        \\  -comp zstd -Xcompression-level 15 -b 1M -noappend && \
        \\echo "✅ Desktop rootfs: build/edge-rootfs.squashfs ($(ls -lh build/edge-rootfs.squashfs | awk '{print $5}'))"
        ,
    });
    build_rfs.has_side_effects = true;
    step.dependOn(&build_rfs.step);

    return step;
}

/// Build a bootable hybrid ISO (BIOS+UEFI) with GRUB.
fn buildISO(b: *std.Build, kernel_version: []const u8) *std.Build.Step {
    _ = kernel_version;
    const step = b.step("iso", "Build bootable ISO");

    // Clean and create staging
    const clean = b.addSystemCommand(&.{ "rm", "-rf", "build/edge-iso" });
    clean.has_side_effects = true;

    const mkdir = b.addSystemCommand(&.{ "mkdir", "-p", "build/edge-iso/boot/grub" });
    mkdir.has_side_effects = true;
    mkdir.step.dependOn(&clean.step);
    step.dependOn(&mkdir.step);

    // Copy kernel
    const cp_kernel = b.addSystemCommand(&.{
        "bash", "-c",
        \\mkdir -p build/edge-iso/boot && \
        \\cp build/vmlinuz-edge build/edge-iso/boot/vmlinuz-edge
        ,
    });
    cp_kernel.has_side_effects = true;
    cp_kernel.step.dependOn(&mkdir.step);
    step.dependOn(&cp_kernel.step);

    // Copy initramfs
    const cp_initrd = b.addSystemCommand(&.{
        "bash", "-c",
        \\cp build/initramfs-edge.cpio.xz build/edge-iso/boot/initramfs-edge.cpio.xz
        ,
    });
    cp_initrd.has_side_effects = true;
    cp_initrd.step.dependOn(&mkdir.step);
    step.dependOn(&cp_initrd.step);

    // Copy desktop rootfs (squashfs) — optional, may not exist
    const cp_squashfs = b.addSystemCommand(&.{
        "bash", "-c",
        \\if [ -f build/edge-rootfs.squashfs ]; then \
        \\  cp build/edge-rootfs.squashfs build/edge-iso/boot/edge-rootfs.squashfs && \
        \\  echo "✅ Desktop squashfs copied ($(ls -lh build/edge-rootfs.squashfs | awk '{print $5}'))"; \
        \\else \
        \\  echo "⚠️  No desktop squashfs found — ISO will boot to fallback shell"; \
        \\fi
        ,
    });
    cp_squashfs.has_side_effects = true;
    cp_squashfs.step.dependOn(&mkdir.step);
    step.dependOn(&cp_squashfs.step);

    // Write GRUB config
    const write_grub = b.addSystemCommand(&.{
        "bash", "-c",
        \\cat > build/edge-iso/boot/grub/grub.cfg << 'GRUB'
        \\# Edge OS — GRUB Configuration
        \\# Hybrid BIOS+UEFI boot
        \\# Desktop entry (default) boots into Hyprland via SDDM.
        \\# Fallback entry boots to busybox shell (Phase 1 compat).
        \\
        \\set default="0"
        \\set timeout=10
        \\
        \\insmod part_gpt
        \\insmod part_msdos
        \\insmod iso9660
        \\insmod ext2
        \\insmod btrfs
        \\insmod loopback
        \\insmod linux
        \\insmod echo
        \\insmod serial
        \\insmod gfxterm
        \\insmod gfxmenu
        \\insmod all_video
        \\
        \\serial --unit=0 --speed=115200
        \\terminal_input console serial
        \\terminal_output console serial
        \\
        \\set gfxmode=auto
        \\set gfxpayload=keep
        \\
        \\menuentry "Edge OS — Desktop Mode" --id desktop {
        \\  linux /boot/vmlinuz-edge \
        \\    root=/dev/ram0 rw \
        \\    console=tty0 console=ttyS0,115200n8 \
        \\    loglevel=3 quiet splash \
        \\    edge_root=/dev/sr0
        \\  initrd /boot/initramfs-edge.cpio.xz
        \\}
        \\
        \\menuentry "Edge OS — Fallback Shell" --id fallback {
        \\  linux /boot/vmlinuz-edge \
        \\    root=/dev/ram0 rw \
        \\    console=tty0 console=ttyS0,115200n8 \
        \\    loglevel=3 quiet splash \
        \\    edge_skip_rootfs
        \\  initrd /boot/initramfs-edge.cpio.xz
        \\}
        \\
        \\menuentry "Edge OS — Debug Mode" --id debug {
        \\  linux /boot/vmlinuz-edge \
        \\    root=/dev/ram0 rw \
        \\    console=tty0 console=ttyS0,115200n8 \
        \\    loglevel=7 \
        \\    edge_root=/dev/sr0
        \\  initrd /boot/initramfs-edge.cpio.xz
        \\}
        \\
        \\menuentry "Boot from first disk" --id disk {
        \\  set root=(hd0)
        \\  chainloader +1
        \\}
        \\GRUB
        \\
        \\echo "✅ GRUB config written"
        ,
    });
    write_grub.has_side_effects = true;
    write_grub.step.dependOn(&mkdir.step);
    step.dependOn(&write_grub.step);

    // Build ISO with grub-mkrescue
    const grub_mkrescue = b.addSystemCommand(&.{
        "grub-mkrescue", "-v",
        "--product-name=Edge OS",
        "--product-version=0.1.0",
        "--compress=xz",
        "-o", "build/edge.iso",
        "build/edge-iso",
    });
    grub_mkrescue.has_side_effects = true;
    grub_mkrescue.step.dependOn(&cp_kernel.step);
    grub_mkrescue.step.dependOn(&cp_initrd.step);
    grub_mkrescue.step.dependOn(&cp_squashfs.step);
    grub_mkrescue.step.dependOn(&write_grub.step);
    step.dependOn(&grub_mkrescue.step);

    // Print success
    const success = b.addSystemCommand(&.{
        "bash", "-c",
        \\echo "✅ ISO built: build/edge.iso ($(ls -lh build/edge.iso | awk '{print $5}'))" && \
        \\echo "   Run: zig build qemu"
        ,
    });
    success.has_side_effects = true;
    success.step.dependOn(&grub_mkrescue.step);
    step.dependOn(&success.step);

    return step;
}
