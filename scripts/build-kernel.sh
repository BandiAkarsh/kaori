#!/usr/bin/env bash
# Edge OS — Build Kernel
#
# Standalone kernel build (without Zig build system).
# Requires: clang, llvm, make, curl, xz
#
# Usage:
#   ./scripts/build-kernel.sh [version]
#   Default version: 7.0.10

set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)" || exit 1
source "$SCRIPT_DIR/lib/colors.sh"
# build-kernel.sh also needs BLUE
BLUE='\033[0;34m'

KERNEL_VERSION="${1:-7.0.10}"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CACHE_DIR="$PROJECT_DIR/.cache"
BUILD_DIR="$PROJECT_DIR/build"
NUM_JOBS="$(nproc)"

log()  { echo -e "${GREEN}✅${NC} $1"; }
info() { echo -e "${BLUE}ℹ️${NC}  $1"; }
err()  { echo -e "${RED}❌${NC} $1" >&2; exit 1; }

# ── Check tools ──
info "Checking build tools..."
for tool in curl xz make clang ld.lld llvm-ar llvm-nm llvm-objcopy llvm-objdump llvm-readelf llvm-strip; do
    command -v "$tool" >/dev/null 2>&1 || err "Missing: $tool"
done
log "All tools found"

# ── Prepare directories ──
mkdir -p "$CACHE_DIR" "$BUILD_DIR"

# ── Download kernel source ──
MAJOR="${KERNEL_VERSION%%.*}"
TARBALL="linux-$KERNEL_VERSION.tar.xz"
TARBALL_PATH="$CACHE_DIR/$TARBALL"
SRC_DIR="$CACHE_DIR/linux-$KERNEL_VERSION"

if [ ! -f "$TARBALL_PATH" ] || [ "$(stat -c%s "$TARBALL_PATH" 2>/dev/null || echo 0)" -lt 10000000 ]; then
    info "Downloading Linux $KERNEL_VERSION..."
    curl -L -o "$TARBALL_PATH" \
        "https://cdn.kernel.org/pub/linux/kernel/v${MAJOR}.x/$TARBALL" || \
        err "Download failed"
    log "Downloaded $(stat -c%s "$TARBALL_PATH") bytes"
fi

# ── Extract ──
if [ ! -d "$SRC_DIR" ] || [ ! -f "$SRC_DIR/Makefile" ]; then
    info "Extracting Linux $KERNEL_VERSION..."
    xz -t "$TARBALL_PATH" || err "Corrupt tarball: $TARBALL_PATH"
    tar -xf "$TARBALL_PATH" -C "$CACHE_DIR"
    log "Extracted"
fi

# ── Configure with Edge OS config ──
info "Configuring kernel..."
cp "$PROJECT_DIR/kernel/config" "$SRC_DIR/.config"
cd "$SRC_DIR" || err "Cannot enter source directory $SRC_DIR"
make LLVM=1 LLVM_IAS=1 olddefconfig
log "Kernel configured (Edge OS custom config)"

# ── Show feature status ──
echo ""
info "Edge OS Kernel Features:"
grep -q "CONFIG_SCHED_CLASS_EXT=y" .config && echo "  - sched_ext (BPF scheduler): ON" || echo "  - sched_ext: OFF"
grep -q "CONFIG_LRU_GEN=y" .config && echo "  - MGLRU (Multi-Gen LRU): ON" || echo "  - MGLRU: OFF"
grep -q "CONFIG_DAMON=y" .config && echo "  - DAMON (proactive reclaim): ON" || echo "  - DAMON: OFF"
grep -q "CONFIG_TCP_CONG_BBR=y" .config && echo "  - BBR3 congestion control: ON" || echo "  - BBR3: OFF"
grep -q "CONFIG_ZRAM_DEF_COMP_ZSTD=y" .config && echo "  - zram + zstd: ON" || echo "  - zram: OFF"
grep -q "CONFIG_LTO_CLANG_THIN=y" .config && echo "  - ThinLTO: ON" || echo "  - ThinLTO: OFF"
echo ""

# ── Build kernel ──
info "Building kernel with LLVM ThinLTO ($NUM_JOBS cores)..."
make -j"$NUM_JOBS" LLVM=1 LLVM_IAS=1 bzImage

# ── Copy output ──
cp "$SRC_DIR/arch/x86/boot/bzImage" "$BUILD_DIR/vmlinuz-edge"
log "Kernel built: build/vmlinuz-edge ($(ls -lh "$BUILD_DIR/vmlinuz-edge" | awk '{print $5}'))"

info "Next steps:"
echo "  zig build initramfs    # Build initramfs"
echo "  zig build iso          # Build bootable ISO"
echo "  zig build qemu         # Boot in QEMU"
