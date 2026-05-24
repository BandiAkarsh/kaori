#!/usr/bin/env bash
# Edge OS — Btrfs Filesystem Benchmark Suite
#
# Measures Btrfs filesystem performance: subvolume layout, snapshot operations,
# compression ratios, and disk usage analysis.
#
# Usage:
#   ./scripts/benchmark-btrfs.sh                # Full Btrfs benchmark
#   ./scripts/benchmark-btrfs.sh --layout       # Subvolume layout analysis
#   ./scripts/benchmark-btrfs.sh --snapshots    # Snapshot performance
#   ./scripts/benchmark-btrfs.sh --compression  # Compression ratio analysis
#   ./scripts/benchmark-btrfs.sh --usage        # Disk usage & metadata
#   ./scripts/benchmark-btrfs.sh --json         # Export as JSON
#
# Some modes require root for btrfs device-level operations.

set -Eeuo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/colors.sh

BUILD_DIR="build"
JSON_OUTPUT="$BUILD_DIR/benchmarks/btrfs.json"
MODE="${1:-all}"

# Track temp dirs for cleanup on exit / error
_TEMP_DIRS=()
cleanup() {
    for d in "${_TEMP_DIRS[@]}"; do
        rm -rf "$d" 2>/dev/null || true
    done
}
trap cleanup EXIT

ensure_dir() {
    mkdir -p "$(dirname "$JSON_OUTPUT")"
}

# ─── Detect Btrfs root device ───
detect_btrfs_root() {
    local fstype
    local source

    fstype=$(findmnt -n -o FSTYPE / 2>/dev/null || echo "unknown")

    if [ "$fstype" != "btrfs" ]; then
        echo ""
        return 1
    fi

    source=$(findmnt -n -o SOURCE / 2>/dev/null | sed 's/\[.*\]//' || echo "")
    echo "$source"
}

# ─── Section: Subvolume Layout Analysis ───
section_layout() {
    echo -e "\n${CYAN}━━━ Btrfs Subvolume Layout ━━━${NC}"

    if ! command -v btrfs &>/dev/null; then
        echo -e "  ${YELLOW}btrfs command not available. Install btrfs-progs.${NC}"
        return
    fi

    local btrfs_device
    btrfs_device=$(detect_btrfs_root) || {
        echo -e "  ${YELLOW}Root filesystem is not Btrfs — skipping layout analysis.${NC}"
        return
    }

    echo "  Device: ${btrfs_device}"
    echo ""

    # UUID
    local uuid
    uuid=$(blkid -s UUID -o value "$btrfs_device" 2>/dev/null || echo "N/A")
    echo "  UUID: ${uuid}"

    # Label
    local label
    label=$(blkid -s LABEL -o value "$btrfs_device" 2>/dev/null || echo "N/A")
    echo "  Label: ${label}"

    # Subvolume listing
    echo ""
    echo "  Subvolumes:"
    local sv_count=0
    while IFS= read -r line; do
        echo "    $line"
        sv_count=$((sv_count + 1))
    done < <(btrfs subvolume list / 2>/dev/null | head -20)

    if [ "$sv_count" -eq 0 ]; then
        echo -e "    ${YELLOW}(no subvolumes found or permission denied)${NC}"
    else
        echo "    Total: ${sv_count} subvolumes"
    fi

    # Default subvolume
    local default_id
    default_id=$(btrfs subvolume get-default / 2>/dev/null | grep -oP 'ID \K\d+' || echo "N/A")
    local default_path
    default_path=$(btrfs subvolume list / 2>/dev/null | awk -v id="$default_id" '$2 == id {print $NF}')
    echo ""
    echo "  Default subvolume: ID ${default_id} → ${default_path:-/}"

    # Snapshot directory
    if [ -d /.snapshots ]; then
        local snap_count
        snap_count=$(ls -1 /.snapshots/ 2>/dev/null | wc -l)
        echo "  Snapshot directory: /.snapshots (${snap_count} entries)"
    fi
}

# ─── Section: Snapshot Performance ───
section_snapshots() {
    echo -e "\n${CYAN}━━━ Snapshot Performance ━━━${NC}"

    if ! command -v snapper &>/dev/null; then
        echo -e "  ${YELLOW}snapper not installed. Check raw btrfs snapshots.${NC}"
    else
        echo -e "\n${GREEN}Snapper Configuration:${NC}"
        for config in /etc/snapper/configs/*; do
            if [ -f "$config" ]; then
                local name
                local snap_count
                name=$(basename "$config")
                snap_count=$(snapper -c "$name" list 2>/dev/null | tail -n +3 | wc -l || echo "0")

                # Get retention policy
                local daily weekly monthly
                daily=$(grep '^TIMELINE_LIMIT_DAILY' "$config" | cut -d= -f2 || echo "?")
                weekly=$(grep '^TIMELINE_LIMIT_WEEKLY' "$config" | cut -d= -f2 || echo "?")
                monthly=$(grep '^TIMELINE_LIMIT_MONTHLY' "$config" | cut -d= -f2 || echo "?")

                echo "  Config: ${name}"
                echo "    Snapshots:  ${snap_count}"
                echo "    Retention:  daily=${daily}, weekly=${weekly}, monthly=${monthly}"

                # Latest snapshot
                local latest
                latest=$(snapper -c "$name" list 2>/dev/null | tail -1 | awk '{print $1, $3, $4}' || echo "N/A")
                echo "    Latest:     ${latest}"
                echo ""
            fi
        done
    fi

    # Raw Btrfs snapshots
    if [ -d /.snapshots ]; then
        echo -e "${GREEN}Raw Btrfs Snapshots:${NC}"
        local raw_count=0
        for snap in /.snapshots/@-*; do
            if [ -d "$snap" ]; then
                local snap_name
                local snap_size
                snap_name=$(basename "$snap")
                snap_size=$(du -sh "$snap" 2>/dev/null | cut -f1 || echo "?")
                echo "  📸 ${snap_name} (${snap_size})"
                raw_count=$((raw_count + 1))
            fi
        done
        [ "$raw_count" -eq 0 ] && echo "  (none)"
        echo ""
    fi

    # Snapshot space usage
    if command -v snapper &>/dev/null; then
        echo -e "${GREEN}Snapshot Disk Usage:${NC}"
        local total_size
        total_size=$(du -sh /.snapshots 2>/dev/null | cut -f1 || echo "?")
        echo "  Snapshot storage: ${total_size}"

        # Number of files in snapshots
        local snap_files
        snap_files=$(find /.snapshots -type f 2>/dev/null | wc -l)
        echo "  Total snapshot files: ${snap_files}"
    fi
}

# ─── Section: Compression Ratio Analysis ───
section_compression() {
    echo -e "\n${CYAN}━━━ Compression Ratio Analysis ━━━${NC}"

    local btrfs_device
    btrfs_device=$(detect_btrfs_root) || {
        echo -e "  ${YELLOW}Root is not Btrfs — skipping compression analysis.${NC}"
        return
    }

    # Check compression status on key subvolumes
    echo -e "\n${GREEN}Compression Status:${NC}"
    for mount_point in "/" "/home" "/var/cache" "/var/log"  "/.snapshots"; do
        if mountpoint -q "$mount_point" 2>/dev/null; then
            local opts
            opts=$(findmnt -n -o OPTIONS "$mount_point" 2>/dev/null || echo "")
            if echo "$opts" | grep -q "compress="; then
                local alg
                alg=$(echo "$opts" | grep -oP 'compress=\K[^,]*' || echo "unknown")
                local ratio_saved
                ratio_saved=$(btrfs filesystem usage "$mount_point" 2>/dev/null | grep -i "compress" | grep -oP '[\d.]+%' | head -1 || echo "N/A")
                echo "  ${mount_point}: ${alg} (saved: ${ratio_saved})"
            else
                echo "  ${mount_point}: no compression"
            fi
        fi
    done

    # Compression ratio from btrfs filesystem usage
    if command -v btrfs &>/dev/null; then
        echo ""
        echo -e "${GREEN}Btrfs Compression Stats:${NC}"
        btrfs filesystem usage / 2>/dev/null | grep -i "compress" || echo "  (not available)"

    # Per-subvolume compressed size estimate
    echo ""
    echo "  Compressed vs uncompressed:"

    # Parse btrfs fi usage for compression ratio
        local ratio_line
        ratio_line=$(btrfs filesystem usage / 2>/dev/null | grep -i "Ratio" || true)
        if [ -n "$ratio_line" ]; then
            echo "    ${ratio_line}"
        fi

        # Check for physical vs logical usage
        local phys_used
        local logical_used
        phys_used=$(btrfs filesystem usage / 2>/dev/null | grep -i "Used" | head -1 | grep -oP '[\d.]+GiB' || echo "?")
        logical_used=$(btrfs filesystem usage -b / 2>/dev/null | grep -i "Used" | grep -oP '[\d.]+GiB' || echo "?")
        echo "    Physical used:  ${phys_used}"
        echo "    Logical used:   ${logical_used}"
    fi
}

# ─── Section: Disk Usage & Metadata ───
section_usage() {
    echo -e "\n${CYAN}━━━ Disk Usage & Metadata ━━━${NC}"

    local btrfs_device
    btrfs_device=$(detect_btrfs_root) || {
        echo -e "  ${YELLOW}Root is not Btrfs — skipping usage analysis.${NC}"
        return
    }

    # Overall filesystem usage
    echo -e "\n${GREEN}Filesystem Overview:${NC}"
    df -h / /home /.snapshots 2>/dev/null | while read -r line; do
        echo "  $line"
    done

    # Btrfs-specific usage
    if command -v btrfs &>/dev/null; then
        echo -e "\n${GREEN}Btrfs Device Usage:${NC}"
        btrfs filesystem usage / 2>/dev/null | grep -E "Device|Overall|Used|Free|Ratio" | while read -r line; do
            echo "  $line"
        done

        # Metadata usage
        echo -e "\n${GREEN}Btrfs Metadata:${NC}"
        btrfs filesystem show "$btrfs_device" 2>/dev/null | while read -r line; do
            echo "  $line"
        done

        # Data profile
        echo -e "\n${GREEN}Allocation Profile:${NC}"
        btrfs filesystem df / 2>/dev/null | while read -r line; do
            echo "  $line"
        done

        # Per-subvolume disk usage
        echo -e "\n${GREEN}Per-Subvolume Disk Usage:${NC}"
        while IFS= read -r line; do
            local subvol_id
            local subvol_path
            subvol_id=$(echo "$line" | awk '{print $2}' 2>/dev/null || true)
            subvol_path=$(echo "$line" | awk '{print $NF}' 2>/dev/null || true)

            if [ -n "$subvol_id" ] && [ "$subvol_id" != "ID" ] 2>/dev/null; then
                local subvol_size
                subvol_size=$(du -sh "/${subvol_path#?}" 2>/dev/null | cut -f1 || echo "?")
                if [ -n "$subvol_size" ]; then
                  printf "  %-5s %-20s %s\n" "${subvol_id}" "${subvol_path}" "${subvol_size}"
                fi
            fi
        done < <(btrfs subvolume list / 2>/dev/null | head -20)
    fi
}

# ─── Section: Performance Benchmarks (read/write) ───
section_perf() {
    echo -e "\n${CYAN}━━━ Btrfs I/O Benchmark ━━━${NC}"

    local btrfs_device
    btrfs_device=$(detect_btrfs_root) || {
        echo -e "  ${YELLOW}Root is not Btrfs — skipping I/O benchmark.${NC}"
        return
    }

    if ! command -v dd &>/dev/null; then
        echo -e "  ${YELLOW}dd not available.${NC}"
        return
    fi

    local bench_dir
    bench_dir=$(mktemp -d)
    _TEMP_DIRS+=("$bench_dir")
    local bench_file="$bench_dir/benchmark"
    local bench_size="1G"

    echo "  Benchmark directory: ${bench_dir}"
    echo "  File size: ${bench_size}"
    echo ""

    # Sequential write (1GB, 1M block, direct I/O to bypass cache)
    echo -e "${GREEN}Sequential Write:${NC}"
    local write_result
    write_result=$(dd if=/dev/zero of="$bench_file" bs=1M count=1024 oflag=direct 2>&1 | tail -1)
    echo "    $write_result"

    # Sequential read (1GB, 1M block, direct I/O)
    echo -e "${GREEN}Sequential Read:${NC}"
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
    local read_result
    read_result=$(dd if="$bench_file" of=/dev/null bs=1M iflag=direct 2>&1 | tail -1)
    echo "    $read_result"

    # Cleanup
    rm -rf "$bench_dir"

    echo ""
    echo -e "${YELLOW}Note: These are rough sequential I/O benchmarks.${NC}"
    echo -e "${YELLOW}For precise numbers, use fio: apt install fio${NC}"
}

# ─── Main ───
echo -e "${CYAN}═══════════════════════════════════════════════${NC}"
echo -e "${CYAN}  Edge OS — Btrfs Benchmark Suite${NC}"
echo -e "${CYAN}  $(date -u '+%Y-%m-%d %H:%M:%S UTC')${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════${NC}"

case "$MODE" in
    all)
        section_layout
        section_snapshots
        section_compression
        section_usage
        section_perf
        ;;
    --layout)
        section_layout
        ;;
    --snapshots)
        section_snapshots
        ;;
    --compression)
        section_compression
        ;;
    --usage)
        section_usage
        ;;
    --perf)
        section_perf
        ;;
    --json)
        ensure_dir
        {
            local btrfs_dev
            btrfs_dev=$(detect_btrfs_root || echo "none")
            echo "{\"device\": \"${btrfs_dev}\", \"date\": \"$(date -u -Iseconds)\", \"mode\": \"btrfs\"}"
        } > "$JSON_OUTPUT"
        echo -e "${GREEN}✅ Benchmarks saved to ${JSON_OUTPUT}${NC}"
        ;;
    *)
        echo -e "${RED}❌ Unknown mode: ${MODE}${NC}" >&2
        echo "  Usage: $0 [--layout|--snapshots|--compression|--usage|--perf|--json]" >&2
        exit 1
        ;;
esac

echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}✅ Btrfs benchmark complete${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
