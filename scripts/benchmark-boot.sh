#!/usr/bin/env bash
# Edge OS — Boot Time Benchmark Suite
#
# Measures boot time performance using systemd-analyze, dmesg timelines,
# and initramfs phase analysis.
#
# Usage:
#   ./scripts/benchmark-boot.sh              # Full boot analysis
#   ./scripts/benchmark-boot.sh --summary    # systemd-analyze summary only
#   ./scripts/benchmark-boot.sh --blame      # Per-service boot time breakdown
#   ./scripts/benchmark-boot.sh --dmesg      # Kernel boot timeline from dmesg
#   ./scripts/benchmark-boot.sh --initramfs  # Initramfs phase timing
#   ./scripts/benchmark-boot.sh --history    # Historical boot time comparison
#   ./scripts/benchmark-boot.sh --json       # Export as JSON
#
# All modes require systemd (systemd-analyze) and root for dmesg access.

set -Eeuo pipefail
cd "$(dirname "$0")/.."

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

BUILD_DIR="build"
JSON_OUTPUT="$BUILD_DIR/benchmarks/boot.json"
MODE="${1:-all}"

ensure_dir() {
    mkdir -p "$(dirname "$JSON_OUTPUT")"
}

# ─── Section: systemd-analyze summary ───
section_summary() {
    echo -e "\n${CYAN}━━━ Boot Time Summary (systemd-analyze) ━━━${NC}"

    if ! command -v systemd-analyze &>/dev/null; then
        echo -e "  ${YELLOW}systemd-analyze not available. Is systemd running?${NC}"
        return
    fi

    local summary
    summary=$(systemd-analyze time 2>/dev/null || true)
    if [ -z "$summary" ]; then
        echo -e "  ${YELLOW}No boot time data available (systemd-analyze failed).${NC}"
        return
    fi

    echo "  $summary"

    # Parse the summary for structured output
    local kernel_time
    local initrd_time
    local userspace_time
    local total_time

    # systemd-analyze time output: "Startup finished in 2.345s (kernel) + 1.234s (initrd) + 5.678s (userspace) = 9.257s"
    # shellcheck disable=SC2086 # Intentional: spaces separate the fields
    kernel_time=$(echo "$summary" | grep -oP '[\d.]+s(?= \(kernel\))' || echo "N/A")
    # shellcheck disable=SC2086
    initrd_time=$(echo "$summary" | grep -oP '[\d.]+s(?= \(initrd\))' || echo "N/A")
    # shellcheck disable=SC2086
    userspace_time=$(echo "$summary" | grep -oP '[\d.]+s(?= \(userspace\))' || echo "N/A")
    # shellcheck disable=SC2086
    total_time=$(echo "$summary" | grep -oP '[\d.]+s(?= \()' | tail -1 || echo "N/A")

    echo ""
    echo "  Breakdown:"
    echo "    Kernel:     ${kernel_time}"
    echo "    Initramfs:  ${initrd_time}"
    echo "    Userspace:  ${userspace_time}"
    echo "    Total:      ${total_time}"
}

# ─── Section: Per-service blame ───
section_blame() {
    echo -e "\n${CYAN}━━━ Per-Service Boot Time (systemd-analyze blame) ━━━${NC}"

    if ! command -v systemd-analyze &>/dev/null; then
        echo -e "  ${YELLOW}systemd-analyze not available.${NC}"
        return
    fi

    local blame
    blame=$(systemd-analyze blame 2>/dev/null || true)
    if [ -z "$blame" ]; then
        echo -e "  ${YELLOW}No blame data available.${NC}"
        return
    fi

    echo "  Top 15 slowest services:"
    echo "$blame" | head -15 | while read -r line; do
        echo "    $line"
    done

    # Identify slow services (>1s)
    echo ""
    local slow_count
    slow_count=$(echo "$blame" | awk '{if ($1 ~ /^[0-9.]+s$/ && $1+0 > 1.0) count++} END {print count+0}')
    if [ "$slow_count" -gt 0 ]; then
        echo -e "  ${YELLOW}⚠  ${slow_count} service(s) took longer than 1 second${NC}"
    else
        echo -e "  ${GREEN}✅ No services exceeded 1 second threshold${NC}"
    fi
}

# ─── Section: Critical chain ───
section_chain() {
    echo -e "\n${CYAN}━━━ Boot Critical Chain (systemd-analyze critical-chain) ━━━${NC}"

    if ! command -v systemd-analyze &>/dev/null; then
        return
    fi

    local chain
    chain=$(systemd-analyze critical-chain 2>/dev/null || true)
    if [ -z "$chain" ]; then
        return
    fi

    echo "$chain" | head -10 | while read -r line; do
        echo "    $line"
    done
}

# ─── Section: Kernel boot timeline from dmesg ───
section_dmesg() {
    echo -e "\n${CYAN}━━━ Kernel Boot Timeline (dmesg) ━━━${NC}"

    if ! command -v dmesg &>/dev/null; then
        echo -e "  ${YELLOW}dmesg not available. Try running as root.${NC}"
        return
    fi

    # Get first and last timestamp
    local first_ts
    local last_ts
    local boot_seconds

    first_ts=$(dmesg 2>/dev/null | head -1 | grep -oP '\[\s*\K[\d.]+' | head -1 || echo "0")
    last_ts=$(dmesg 2>/dev/null | tail -1 | grep -oP '\[\s*\K[\d.]+' | tail -1 || echo "0")

    boot_seconds=$(echo "$last_ts - $first_ts" | bc 2>/dev/null || echo "0")

    echo "  Kernel ring buffer:"
    echo "    First entry:  ${first_ts}s"
    echo "    Last entry:   ${last_ts}s"
    echo "    Kernel phase: ${boot_seconds}s"

    # Key kernel boot milestone extraction (using systemd's dmesg timestamps)
    echo ""
    echo "  Key milestones:"

    local milestones=(
        "Linux version.*:kernel start"
        "Command line.*:kernel cmdline"
        "clocksource.*:clocksource"
        "tsc: TSC.*:TSC calibration"
        "smpboot.*Brought up.*:CPUs online"
        "Btrfs loaded.*:Btrfs loaded"
        "EXT4.*mounted.*:rootfs mounted"
        "Run /init.*:init started"
        "systemd.*running.*:systemd running"
    )

    for milestone in "${milestones[@]}"; do
        local pattern="${milestone%%:*}"
        local label="${milestone#*:}"
        local match
        match=$(dmesg 2>/dev/null | grep -E "$pattern" | tail -1 || true)
        if [ -n "$match" ]; then
            local ts
            ts=$(echo "$match" | grep -oP '\[\s*\K[\d.]+' | head -1 || echo "?")
            echo "    [${ts}s] ${label}"
        fi
    done

    # Filesystem initialization timing
    echo ""
    echo "  Filesystem init time:"
    local fs_start
    local fs_end
    fs_start=$(dmesg 2>/dev/null | grep -n "Btrfs\|EXT4.*mounted\|XFS.*mounted" | head -1 | grep -oP '\[\s*\K[\d.]+' || echo "0")
    fs_end=$(dmesg 2>/dev/null | grep "Run /init\|systemd.*running" | head -1 | grep -oP '\[\s*\K[\d.]+' || echo "0")
    if [ "$(echo "$fs_end - $fs_start > 0" | bc 2>/dev/null)" = "1" ]; then
        local fs_time
        fs_time=$(echo "$fs_end - $fs_start" | bc 2>/dev/null || echo "N/A")
        echo "    Filesystem init: ${fs_time}s (from ${fs_start}s to ${fs_end}s)"
    fi
}

# ─── Section: Initramfs phase analysis ───
section_initramfs() {
    echo -e "\n${CYAN}━━━ Initramfs Phase Analysis ━━━${NC}"

    # Check for initramfs timing markers in dmesg
    if ! command -v dmesg &>/dev/null; then
        return
    fi

    # Detect the start of initramfs (after kernel start, before rootfs mounted)
    local kernel_end
    local initramfs_end

    kernel_end=$(dmesg 2>/dev/null | grep "Run /init\|Freeing.*kernel memory" | head -1 | grep -oP '\[\s*\K[\d.]+' || echo "?")
    initramfs_end=$(dmesg 2>/dev/null | grep "systemd.*running\|overlayfs.*mounted\|switch_root" | head -1 | grep -oP '\[\s*\K[\d.]+' || echo "?")

    if [ "$kernel_end" != "?" ] && [ "$initramfs_end" != "?" ]; then
        local initramfs_time
        initramfs_time=$(echo "$initramfs_end - $kernel_end" | bc 2>/dev/null || echo "N/A")
        echo "  Initramfs start:  ${kernel_end}s"
        echo "  Initramfs end:    ${initramfs_end}s"
        echo "  Initramfs time:   ${initramfs_time}s"
    else
        echo -e "  ${YELLOW}Initramfs timing markers not found (may use overlayfs or busybox init).${NC}"
    fi

    # Check initramfs compression
    for initramfs in /boot/initramfs-* /boot/initramfs*.cpio.xz; do
        if [ -f "$initramfs" ]; then
            local size
            local decompressed
            size=$(ls -lh "$initramfs" 2>/dev/null | awk '{print $5}')
            if command -v xz &>/dev/null; then
                decompressed=$(xz -l "$initramfs" 2>/dev/null | tail -1 | awk '{print $3}' || echo "N/A")
                echo ""
                echo "  Initramfs file: $(basename "$initramfs")"
                echo "    Compressed size:   ${size}"
                echo "    Decompressed size: ${decompressed}"
            else
                echo "  Initramfs file: $(basename "$initramfs") (${size})"
            fi
            break
        fi
    done
}

# ─── Section: Historical boot times ───
section_history() {
    echo -e "\n${CYAN}━━━ Historical Boot Times ━━━${NC}"

    if ! command -v journalctl &>/dev/null; then
        echo -e "  ${YELLOW}journalctl not available.${NC}"
        return
    fi

    # Extract boot times from journal
    local history
    history=$(journalctl --boot=-1 --no-pager -o json -u systemd-analyze 2>/dev/null || true)
    if [ -z "$history" ]; then
        # Fallback: use last 5 boots from systemd-analyze (not directly available)
        # Instead, try to get boot IDs
        echo "  Previous boot times (from journal):"
        local boot_count=0
        for boot_id in $(journalctl --list-boots 2>/dev/null | tail -6 | awk '{print $1}' | head -5 || true); do
            if [ "$boot_id" != "0" ]; then
                local boot_time
                boot_time=$(journalctl --boot="$boot_id" --no-pager -o short-iso 2>/dev/null | head -1 | cut -d' ' -f1 || true)
                if [ -n "$boot_time" ]; then
                    echo "    Boot -${boot_count}: ${boot_time}"
                    boot_count=$((boot_count + 1))
                fi
            fi
        done

        if [ "$boot_count" -eq 0 ]; then
            echo -e "  ${YELLOW}No historical boot data available.${NC}"
        fi
    fi

    # Current boot time from dmesg
    local last_dmesg
    last_dmesg=$(dmesg 2>/dev/null | tail -1 | grep -oP '\[\s*\K[\d.]+' || echo "0")
    echo ""
    echo "  Current boot kernel time: ${last_dmesg}s"
}

# ─── Main ───
echo -e "${CYAN}═══════════════════════════════════════════════${NC}"
echo -e "${CYAN}  Edge OS — Boot Time Benchmark Suite${NC}"
echo -e "${CYAN}  $(date -u '+%Y-%m-%d %H:%M:%S UTC')${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════${NC}"

case "$MODE" in
    all)
        section_summary
        section_blame
        section_chain
        section_dmesg
        section_initramfs
        section_history
        ;;
    --summary)
        section_summary
        ;;
    --blame)
        section_blame
        section_chain
        ;;
    --dmesg)
        section_dmesg
        section_initramfs
        ;;
    --initramfs)
        section_initramfs
        ;;
    --history)
        section_history
        ;;
    --json)
        ensure_dir
        {
            echo "{"
            echo "  \"kernel\": \"$(uname -r)\","
            echo "  \"date\": \"$(date -u -Iseconds)\","
            if command -v systemd-analyze &>/dev/null; then
                echo "  \"summary\": $(systemd-analyze time 2>/dev/null | jq -Rs '.' 2>/dev/null || echo '\"unavailable\"'),"
            fi
            echo "  \"mode\": \"boot\""
            echo "}"
        } > "$JSON_OUTPUT" 2>/dev/null || {
            # Fallback without jq
            echo "{\"kernel\": \"$(uname -r)\", \"date\": \"$(date -u -Iseconds)\", \"mode\": \"boot\"}" > "$JSON_OUTPUT"
        }
        echo -e "${GREEN}✅ Benchmarks saved to ${JSON_OUTPUT}${NC}"
        ;;
    *)
        echo -e "${RED}❌ Unknown mode: ${MODE}${NC}" >&2
        echo "  Usage: $0 [--summary|--blame|--dmesg|--initramfs|--history|--json]" >&2
        exit 1
        ;;
esac

echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}✅ Boot benchmark complete${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
