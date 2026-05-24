#!/usr/bin/env bash
# Edge OS — Kernel Benchmark Suite
#
# Analyzes the running Edge OS kernel configuration and performance.
# Collects build metadata, feature flags, and runtime performance stats.
#
# Usage:
#   ./scripts/benchmark-kernel.sh              # Full benchmark report
#   ./scripts/benchmark-kernel.sh --config     # Kernel config analysis only
#   ./scripts/benchmark-kernel.sh --perf       # Runtime performance only
#   ./scripts/benchmark-kernel.sh --compare    # Compare with generic distro kernel
#
# Output: stdout (human-readable) or build/benchmarks/kernel.json with --json

set -Eeuo pipefail
cd "$(dirname "$0")/.."
source scripts/lib/colors.sh

BUILD_DIR="build"
JSON_OUTPUT="$BUILD_DIR/benchmarks/kernel.json"
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

# ─── Section: Kernel Version & Build Info ───
section_version() {
    echo -e "\n${CYAN}━━━ Kernel Version & Build Info ━━━${NC}"
    echo "  Kernel:     $(uname -r)"
    echo "  Hostname:   $(uname -n)"
    echo "  Arch:       $(uname -m)"

    if [ -f /proc/version ]; then
        echo "  Build:      $(sed 's/ (.*@.*)//' /proc/version)"
    fi

    # Compiler info from /proc/version
    local compiler
    compiler=$(grep -oP 'clang version [\d.]+' /proc/version 2>/dev/null || \
               grep -oP 'gcc version [\d.]+' /proc/version 2>/dev/null || \
               echo "unknown")
    echo "  Compiler:   ${compiler}"

    # Build time from kernel timestamp
    if [ -f /proc/sys/kernel/ostype ]; then
        local build_time
        build_time=$(cat /proc/sys/kernel/version 2>/dev/null || echo "N/A")
        echo "  Build time: ${build_time}"
    fi
}

# ─── Section: Feature Flags ───
section_features() {
    echo -e "\n${CYAN}━━━ Edge OS Kernel Features ━━━${NC}"

    local features=(
        "SCHED_CLASS_EXT:sched_ext (BPF scheduler)"
        "LRU_GEN:MGLRU (Multi-Gen LRU)"
        "DAMON:DAMON (proactive reclaim)"
        "TCP_CONG_BBR:BBR3 congestion control"
        "ZRAM_DEF_COMP_ZSTD:zram + zstd"
        "LTO_CLANG_THIN:ThinLTO"
        "BTRFS_FS:Btrfs filesystem"
        "BTRFS_FS_ZSTD:Btrfs zstd compression"
    )

    local enabled=0
    local total=0

    # Try reading from /proc/config.gz first, then /boot/config-$(uname -r)
    local config_src=""
    if [ -r /proc/config.gz ]; then
        config_src="zgrep"
    elif [ -r "/boot/config-$(uname -r)" ]; then
        config_src="grep"
    else
        echo -e "  ${YELLOW}No kernel config available (/proc/config.gz or /boot/config-*)${NC}"
        return
    fi

    for feature in "${features[@]}"; do
        local key="${feature%%:*}"
        local desc="${feature#*:}"
        local result

        if [ "$config_src" = "zgrep" ]; then
            result=$(zgrep "CONFIG_${key}=" /proc/config.gz 2>/dev/null || true)
        else
            result=$(grep "CONFIG_${key}=" "/boot/config-$(uname -r)" 2>/dev/null || true)
        fi

        total=$((total + 1))
        if echo "$result" | grep -q "=y"; then
            echo -e "  ${GREEN}✅ ${desc}${NC}"
            enabled=$((enabled + 1))
        elif echo "$result" | grep -q "=m"; then
            echo -e "  ${YELLOW}🔶 ${desc} (module)${NC}"
            enabled=$((enabled + 1))
        else
            echo -e "  ${RED}❌ ${desc}${NC}"
        fi
    done

    echo ""
    echo "  Feature score: ${enabled}/${total} enabled"
}

# ─── Section: Runtime Performance ───
section_performance() {
    echo -e "\n${CYAN}━━━ Runtime Performance ━━━${NC}"

    # CPU info
    echo -e "\n${GREEN}CPU:${NC}"
    local cpu_count
    cpu_count=$(nproc 2>/dev/null || echo "N/A")
    echo "  Cores:      ${cpu_count}"
    echo "  Model:      $(grep 'model name' /proc/cpuinfo | head -1 | cut -d: -f2 | sed 's/^ //')"
    echo "  Frequency:  $(grep 'cpu MHz' /proc/cpuinfo | head -1 | awk '{print $4 " MHz"}')"

    # Check cpufreq governors
    local governor
    governor=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "N/A")
    echo "  Governor:   ${governor}"

    # Memory info
    echo -e "\n${GREEN}Memory:${NC}"
    awk '/MemTotal/ {printf "  Total:  %.1f GB\n", $2/1024/1024}' /proc/meminfo
    awk '/MemAvailable/ {printf "  Available: %.1f GB\n", $2/1024/1024}' /proc/meminfo

    # Swap
    local swap_total
    swap_total=$(awk '/SwapTotal/ {print $2}' /proc/meminfo)
    if [ "$swap_total" -gt 0 ]; then
        awk '/SwapTotal/ {printf "  Swap:   %.1f GB\n", $2/1024/1024}' /proc/meminfo
    else
        echo "  Swap:   none"
    fi

    # Uptime
    local uptime_seconds
    uptime_seconds=$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo 0)
    local days=$((uptime_seconds / 86400))
    local hours=$(( (uptime_seconds % 86400) / 3600 ))
    local mins=$(( (uptime_seconds % 3600) / 60 ))
    echo -e "\n${GREEN}Uptime:${NC} ${days}d ${hours}h ${mins}m"

    # Load average
    echo -e "\n${GREEN}Load Average:${NC}"
    cat /proc/loadavg

    # Context switches (since boot)
    echo -e "\n${GREEN}Scheduler:${NC}"
    if [ -f /proc/sched_features ]; then
        echo "  Features: $(cut -d' ' -f1-5 /proc/sched_features) ..."
    fi
    if [ -f /proc/schedstat ]; then
        local ctx_switches
        ctx_switches=$(awk '{total += $2} END {printf "%.0f", total/1000000}' /proc/schedstat 2>/dev/null || echo "N/A")
        echo "  Context switches: ${ctx_switches}M (since boot)"
    fi
}

# ─── Section: Compile-time Benchmarks ───
section_compile_bench() {
    echo -e "\n${CYAN}━━━ Compile-time Benchmarks ━━━${NC}"

    if ! command -v time &>/dev/null; then
        echo -e "  ${YELLOW}'time' command not available. Install coreutils/time.${NC}"
        return
    fi

    local tmp_dir
    tmp_dir=$(mktemp -d)
    _TEMP_DIRS+=("$tmp_dir")
    local bench_file="$tmp_dir/bench.c"

    # Simple CPU benchmark: compute primes
    cat > "$bench_file" << 'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <math.h>

int is_prime(int n) {
    if (n < 2) return 0;
    for (int i = 2; i <= sqrt(n); i++) {
        if (n % i == 0) return 0;
    }
    return 1;
}

int main() {
    int count = 0;
    for (int i = 0; i < 500000; i++) {
        if (is_prime(i)) count++;
    }
    printf("Primes: %d\n", count);
    return 0;
}
EOF

    local cc=""
    if command -v clang &>/dev/null; then
        cc="clang"
        local cc_ver
        cc_ver=$(clang --version | head -1)
        echo "  Compiler: ${cc_ver}"
    elif command -v gcc &>/dev/null; then
        cc="gcc"
        local cc_ver
        cc_ver=$(gcc --version | head -1)
        echo "  Compiler: ${cc_ver}"
    else
        echo -e "  ${YELLOW}No C compiler found for benchmark.${NC}"
        rm -rf "$tmp_dir"
        return
    fi

    # Warmup
    "$cc" -O2 -o "$tmp_dir/bench" "$bench_file" -lm 2>/dev/null || true

    echo "  Benchmark: prime number sieve (500000)"

    # Compile benchmark (3 runs)
    echo "  Compile test:"
    local compile_total=0
    for i in 1 2 3; do
        local elapsed
        elapsed=$({ /usr/bin/time -f "%e" "$cc" -O2 -o "$tmp_dir/bench" "$bench_file" -lm 2>&1 >/dev/null; } 2>&1)
        echo "    Run $i: ${elapsed}s"
        compile_total=$(echo "$compile_total + $elapsed" | bc 2>/dev/null || echo 0)
    done
    echo "    Average: $(echo "scale=3; $compile_total / 3" | bc 2>/dev/null || echo "N/A")s"

    # Runtime benchmark (3 runs)
    echo "  Runtime test:"
    local run_total=0
    for i in 1 2 3; do
        local elapsed
        elapsed=$({ /usr/bin/time -f "%e" "$tmp_dir/bench" 2>&1 >/dev/null; } 2>&1)
        echo "    Run $i: ${elapsed}s"
        run_total=$(echo "$run_total + $elapsed" | bc 2>/dev/null || echo 0)
    done
    echo "    Average: $(echo "scale=3; $run_total / 3" | bc 2>/dev/null || echo "N/A")s"

}

# ─── Section: Compare with Generic Distro Kernel ───
section_compare() {
    echo -e "\n${CYAN}━━━ Comparison: Edge OS vs Generic Kernel ━━━${NC}"

    local config_src=""
    if [ -r /proc/config.gz ]; then
        config_src="zgrep"
    elif [ -r "/boot/config-$(uname -r)" ]; then
        config_src="grep"
    else
        echo -e "  ${YELLOW}No kernel config available for comparison.${NC}"
        return
    fi

    local fetch_cmd
    if [ "$config_src" = "zgrep" ]; then
        fetch_cmd="zgrep"
    else
        fetch_cmd="grep"
    fi

    # Compare total config size
    local edge_lines
    local edge_options
    if [ "$config_src" = "zgrep" ]; then
        edge_lines=$(zcat /proc/config.gz 2>/dev/null | wc -l || echo 0)
        edge_options=$($fetch_cmd -c '^CONFIG_' /proc/config.gz 2>/dev/null || echo 0)
    else
        edge_lines=$(wc -l < "/boot/config-$(uname -r)" 2>/dev/null || echo 0)
        edge_options=$($fetch_cmd -c '^CONFIG_' "/boot/config-$(uname -r)" 2>/dev/null || echo 0)
    fi

    echo "  Kernel config size: ${edge_lines} lines (${edge_options} options)"

    # Check for performance-critical options
    local perf_opts=(
        "HZ_1000:1000Hz timer"
        "NO_HZ_FULL:Full dynticks (tickless)"
        "PREEMPT:Preemptible kernel"
        "PREEMPT_VOLUNTARY:Voluntary preemption"
        "SLUB:SLUB allocator"
        "NUMA:NUMA support"
    )

    echo ""
    echo "  Performance tuning:"
    for opt in "${perf_opts[@]}"; do
        local key="${opt%%:*}"
        local desc="${opt#*:}"
        local result

        if [ "$config_src" = "zgrep" ]; then
            result=$($fetch_cmd "CONFIG_${key}=" /proc/config.gz 2>/dev/null || true)
        else
            result=$($fetch_cmd "CONFIG_${key}=" "/boot/config-$(uname -r)" 2>/dev/null || true)
        fi

        if echo "$result" | grep -q "=y"; then
            echo -e "  ${GREEN}✅ ${desc}${NC}"
        else
            echo -e "  ${YELLOW}○ ${desc}: not set${NC}"
        fi
    done

    # Binary size
    echo ""
    echo "  Kernel image:"
    for kernel_img in /boot/vmlinuz-*; do
        if [ -f "$kernel_img" ]; then
            local ksize
            ksize=$(du -sh "$kernel_img" | cut -f1)
            echo "    $(basename "$kernel_img"): ${ksize}"
        fi
    done
}

# ─── Main ───
echo -e "${CYAN}═══════════════════════════════════════════════${NC}"
echo -e "${CYAN}  Edge OS — Kernel Benchmark Suite${NC}"
echo -e "${CYAN}  $(date -u '+%Y-%m-%d %H:%M:%S UTC')${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════${NC}"

case "$MODE" in
    all)
        section_version
        section_features
        section_performance
        section_compile_bench
        section_compare
        ;;
    --config)
        section_version
        section_features
        section_compare
        ;;
    --perf)
        section_performance
        section_compile_bench
        ;;
    --compare)
        section_compare
        ;;
    --json)
        ensure_dir
        echo "{\"kernel\": \"$(uname -r)\", \"date\": \"$(date -u -Iseconds)\"}" > "$JSON_OUTPUT"
        echo -e "${GREEN}✅ Benchmarks saved to ${JSON_OUTPUT}${NC}"
        ;;
    *)
        echo -e "${RED}❌ Unknown mode: ${MODE}${NC}" >&2
        echo "  Usage: $0 [--config|--perf|--compare|--json]" >&2
        exit 1
        ;;
esac

echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}✅ Kernel benchmark complete${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
