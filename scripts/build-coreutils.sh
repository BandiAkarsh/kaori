#!/usr/bin/env bash
# Edge OS — Phase 2: Rust Core Utilities
#
# Builds uutils (Rust coreutils) and deploys to /usr/local/edge/bin/
# with symlinks for each utility.
#
# Dependencies: rustc, cargo, git
# Output: build/edge-rootfs/

set -Eeuo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/colors.sh

BUILD_DIR="build/edge-rootfs"
BIN_DIR="$BUILD_DIR/usr/local/edge/bin"
CACHE_DIR=".cache"
UUTILS_DIR="$CACHE_DIR/uutils-coreutils"
RELEASE_DIR="$UUTILS_DIR/target/release"

mkdir -p "$BIN_DIR"

echo "📦 Phase 2: Rust Core Utilities"
echo "=================================="

# ─── Step 1: Clone/Update uutils ───
if [ -d "$UUTILS_DIR/.git" ]; then
    echo "⬆️  Updating uutils..."
    cd "$UUTILS_DIR" && git pull --ff-only && cd "$OLDPWD"
else
    echo "⬇️  Cloning uutils/coreutils (tag 0.0.28)..."
    git clone --depth=1 --branch "0.0.28" "https://github.com/uutils/coreutils.git" "$UUTILS_DIR"
fi

# ─── Step 2: Build selected utilities ───
echo "🔨 Building uutils (this may take a while)..."

# Build the core utilities we want
UTILS=(
    "uu_arch"
    "uu_basename"
    "uu_cat"
    "uu_chmod"
    "uu_chown"
    "uu_cksum"
    "uu_cp"
    "uu_cut"
    "uu_date"
    "uu_df"
    "uu_dirname"
    "uu_du"
    "uu_echo"
    "uu_env"
    "uu_expand"
    "uu_expr"
    "uu_factor"
    "uu_false"
    "uu_fmt"
    "uu_fold"
    "uu_groups"
    "uu_head"
    "uu_hostid"
    "uu_hostname"
    "uu_id"
    "uu_install"
    "uu_join"
    "uu_kill"
    "uu_link"
    "uu_ln"
    "uu_logname"
    "uu_ls"
    "uu_mkdir"
    "uu_mkfifo"
    "uu_mknod"
    "uu_mktemp"
    "uu_more"
    "uu_mv"
    "uu_nl"
    "uu_nproc"
    "uu_numfmt"
    "uu_od"
    "uu_paste"
    "uu_pathchk"
    "uu_pinky"
    "uu_printenv"
    "uu_printf"
    "uu_ptx"
    "uu_pwd"
    "uu_readlink"
    "uu_realpath"
    "uu_rm"
    "uu_rmdir"
    "uu_seq"
    "uu_shred"
    "uu_shuf"
    "uu_sleep"
    "uu_sort"
    "uu_split"
    "uu_stat"
    "uu_sum"
    "uu_sync"
    "uu_tac"
    "uu_tail"
    "uu_tee"
    "uu_test"
    "uu_timeout"
    "uu_touch"
    "uu_tr"
    "uu_true"
    "uu_truncate"
    "uu_tsort"
    "uu_tty"
    "uu_uname"
    "uu_unexpand"
    "uu_uniq"
    "uu_unlink"
    "uu_uptime"
    "uu_users"
    "uu_wc"
    "uu_who"
    "uu_whoami"
    "uu_yes"
)

# Build all utilities in a single cargo invocation (shares dep compilation)
cd "$UUTILS_DIR" || { echo "  ❌ Cannot enter $UUTILS_DIR" >&2; exit 1; }
echo "  Building ${#UTILS[@]} utilities in parallel (single cargo invocation)..."
CARGO_ARGS=()
for u in "${UTILS[@]}"; do CARGO_ARGS+=("-p" "$u"); done
if ! cargo build --release "${CARGO_ARGS[@]}"; then
    echo "  ❌ Cargo build failed — check build logs above" >&2
    exit 1
fi
echo "  ✅ Build finished"
cd "$OLDPWD" || exit 1

# ─── Step 3: Deploy binaries and create symlinks ───
echo "📋 Deploying to $BIN_DIR..."
deployed=0
failed=0

for util in "${UTILS[@]}"; do
    # Strip uu_ prefix — that's the actual binary name
    name="${util#uu_}"
    src="$RELEASE_DIR/$name"
    dst="$BIN_DIR/$name"

    if [ -f "$src" ]; then
        # Copy and strip debug symbols
        cp "$src" "$dst"
        local size
        size=$(du -sh "$dst" | cut -f1)
        if strip --strip-all "$dst" 2>/dev/null; then
            echo "  ✅ $name ($size)"
        else
            echo "  ✅ $name ($size) [not stripped]"
        fi
        chmod 755 "$dst"
        deployed=$((deployed + 1))
    else
        echo "  ❌ $name not found (expected: $src)"
        failed=$((failed + 1))
    fi
done

# ─── Step 4: Create additional symlinks for aliased commands ───
ln -sf ls "$BIN_DIR/dir" 2>/dev/null || true
ln -sf ls "$BIN_DIR/vdir" 2>/dev/null || true
ln -sf uname "$BIN_DIR/arch" 2>/dev/null || true

echo ""
echo "📊 Deployed: $deployed utilities, $failed failed"
echo "📁 Location: $BIN_DIR"
echo ""
echo "Phase 2 complete — Rust coreutils ready for Edge OS."
