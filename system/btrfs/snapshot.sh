#!/usr/bin/env bash
# Edge OS — Btrfs Snapshot Manager
#
# Manages Btrfs snapshots using snapper (primary) and btrfs commands (fallback).
# Integrates with APT hooks, systemd timers, and GRUB for rollback support.
#
# Usage:
#   ./system/btrfs/snapshot.sh init           # Initialize snapper config for @
#   ./system/btrfs/snapshot.sh create [desc]  # Create a snapshot with description
#   ./system/btrfs/snapshot.sh pre [desc]     # Create pre-update snapshot
#   ./system/btrfs/snapshot.sh post           # Create post-update snapshot (pairs with pre)
#   ./system/btrfs/snapshot.sh list           # List all snapshots
#   ./system/btrfs/snapshot.sh status         # Show snapshot status and disk usage
#   ./system/btrfs/snapshot.sh rollback <n>   # Rollback to snapshot number <n>
#   ./system/btrfs/snapshot.sh cleanup        # Remove old snapshots per retention policy
#   ./system/btrfs/snapshot.sh diff <pre> <post>  # Show changes between snapshots

set -Eeuo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

SNAPPER_CONFIG="edge_root"
BTRFS_ROOT="/"
SNAPSHOTS_DIR="/.snapshots"

# Retention policy
KEEP_DAILY=7
KEEP_WEEKLY=4
KEEP_MONTHLY=3

# ─── Help ───
usage() {
    cat <<EOF
Usage: $(basename "$0") <command> [args]

Commands:
  init                 Initialize snapper configuration for root subvolume
  create [description] Create a snapshot with optional description
  pre  <description>   Create pre-update snapshot (returns pair number)
  post <pair-number>   Create post-update snapshot for a pre snapshot
  list                 List all snapshots
  status               Show snapshot status and disk usage
  rollback <number>    Rollback to snapshot <number>
  cleanup              Remove old snapshots per retention policy
  diff <pre> <post>    Show file changes between two snapshots
  help                 Show this help message
EOF
    exit 0
}

# ─── Check prerequisites ───
check_prereqs() {
    local missing=0
    if ! command -v btrfs &>/dev/null; then
        echo -e "${RED}❌ btrfs command not found. Install btrfs-progs.${NC}" >&2
        missing=1
    fi
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}❌ This command must be run as root.${NC}" >&2
        missing=1
    fi
    if [ "$missing" -ne 0 ]; then
        exit 1
    fi
}

# ─── Check if root is on Btrfs ───
check_btrfs_root() {
    local fstype
    fstype=$(findmnt -n -o FSTYPE "$BTRFS_ROOT" 2>/dev/null || echo "unknown")
    if [ "$fstype" != "btrfs" ]; then
        echo -e "${RED}❌ Root filesystem is ${fstype}, not Btrfs.${NC}" >&2
        echo "   Snapshots require a Btrfs root filesystem." >&2
        exit 1
    fi
}

# ─── Command: init — Initialize snapper config ───
cmd_init() {
    check_btrfs_root

    if command -v snapper &>/dev/null; then
        echo -e "${GREEN}⚙️  Initializing snapper configuration...${NC}"

        # Check if config already exists
        if snapper -c "$SNAPPER_CONFIG" list &>/dev/null 2>&1; then
            echo -e "${YELLOW}  ⚠ Snapper config '${SNAPPER_CONFIG}' already exists${NC}"
        else
            # Create snapper config for root
            snapper -c "$SNAPPER_CONFIG" create-config "$BTRFS_ROOT"

            # Customize configuration
            local snapper_conf="/etc/snapper/configs/${SNAPPER_CONFIG}"
            if [ -f "$snapper_conf" ]; then
                sed -i "s/^ALLOW_USERS=\"\"/ALLOW_USERS=\"\"/" "$snapper_conf"
                sed -i "s/^TIMELINE_CREATE=.*/TIMELINE_CREATE=\"yes\"/" "$snapper_conf"
                sed -i "s/^TIMELINE_CLEANUP=.*/TIMELINE_CLEANUP=\"yes\"/" "$snapper_conf"
                sed -i "s/^TIMELINE_MIN_AGE=.*/TIMELINE_MIN_AGE=\"1800\"/" "$snapper_conf"
                sed -i "s/^TIMELINE_LIMIT_DAILY=.*/TIMELINE_LIMIT_DAILY=\"${KEEP_DAILY}\"/" "$snapper_conf"
                sed -i "s/^TIMELINE_LIMIT_WEEKLY=.*/TIMELINE_LIMIT_WEEKLY=\"${KEEP_WEEKLY}\"/" "$snapper_conf"
                sed -i "s/^TIMELINE_LIMIT_MONTHLY=.*/TIMELINE_LIMIT_MONTHLY=\"${KEEP_MONTHLY}\"/" "$snapper_conf"
                sed -i "s/^NUMBER_LIMIT=.*/NUMBER_LIMIT=\"10\"/" "$snapper_conf"
                sed -i "s/^NUMBER_LIMIT_IMPORTANT=.*/NUMBER_LIMIT_IMPORTANT=\"5\"/" "$snapper_conf"

                echo -e "${GREEN}  ✅ Snapper configuration tuned${NC}"
            fi

            echo -e "${GREEN}  ✅ Snapper initialized for ${BTRFS_ROOT}${NC}"
        fi

        # Enable and start snapper timers
        systemctl enable snapper-timeline.timer 2>/dev/null || true
        systemctl enable snapper-cleanup.timer 2>/dev/null || true
        systemctl start snapper-timeline.timer 2>/dev/null || true
        systemctl start snapper-cleanup.timer 2>/dev/null || true
        echo -e "${GREEN}  ✅ Snapper systemd timers enabled${NC}"

    else
        echo -e "${YELLOW}  ⚠ snapper not installed — using raw btrfs snapshots${NC}"
        echo -e "${YELLOW}  Install snapper: apt install snapper${NC}"
    fi

    # Verify snapshot directory
    if [ ! -d "$SNAPSHOTS_DIR" ]; then
        mkdir -p "$SNAPSHOTS_DIR"
        echo -e "${GREEN}  ✅ Created ${SNAPSHOTS_DIR}${NC}"
    fi

    echo -e "${GREEN}✅ Snapshot system initialized${NC}"
}

# ─── Command: create — Create a snapshot ───
cmd_create() {
    check_btrfs_root
    local description="${1:-manual-snapshot-$(date +%Y%m%d-%H%M%S)}"

    if command -v snapper &>/dev/null; then
        echo -e "${GREEN}📸 Creating snapper snapshot: ${description}${NC}"
        snapper -c "$SNAPPER_CONFIG" create -d "$description"
    else
        # Fallback: raw btrfs snapshot
        local snap_name="@-${description}"
        echo -e "${GREEN}📸 Creating btrfs snapshot: ${snap_name}${NC}"
        btrfs subvolume snapshot -r "$BTRFS_ROOT" "${SNAPSHOTS_DIR}/${snap_name}"
        echo -e "${GREEN}  ✅ Snapshot created: ${SNAPSHOTS_DIR}/${snap_name}${NC}"
    fi
}

# ─── Command: pre — Create pre-update snapshot ───
cmd_pre() {
    check_btrfs_root
    local description="${1:-pre-update-$(date +%Y%m%d-%H%M%S)}"

    if command -v snapper &>/dev/null; then
        echo -e "${GREEN}📸 Creating PRE snapshot: ${description}${NC}"
        snapper -c "$SNAPPER_CONFIG" create -d "$description" --type pre
    else
        cmd_create "pre-${description}"
    fi
}

# ─── Command: post — Create post-update snapshot ───
cmd_post() {
    check_btrfs_root
    local pair_number="${1:-}"

    if command -v snapper &>/dev/null; then
        if [ -z "$pair_number" ]; then
            echo -e "${YELLOW}  ⚠ Usage: $(basename "$0") post <pair-number>${NC}" >&2
            echo "  Find pair number from 'list' output (look for pre snapshots)" >&2
            exit 1
        fi
        echo -e "${GREEN}📸 Creating POST snapshot for pair #${pair_number}${NC}"
        snapper -c "$SNAPPER_CONFIG" create -d "post-update-$(date +%Y%m%d-%H%M%S)" \
            --type post --pre-number "$pair_number"
    else
        echo -e "${YELLOW}  ⚠ Post snapshot requires snapper.${NC}" >&2
        echo "  Install snapper: apt install snapper" >&2
        exit 1
    fi
}

# ─── Command: list — List snapshots ───
cmd_list() {
    check_btrfs_root

    if command -v snapper &>/dev/null; then
        snapper -c "$SNAPPER_CONFIG" list
    else
        echo -e "${CYAN}📋 Btrfs snapshots in ${SNAPSHOTS_DIR}:${NC}"
        if [ -d "$SNAPSHOTS_DIR" ]; then
            ls -1tr "$SNAPSHOTS_DIR" 2>/dev/null || echo "  (none)"
        else
            echo "  (none)"
        fi
    fi
}

# ─── Command: status — Show snapshot status ───
cmd_status() {
    check_btrfs_root

    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  Btrfs Snapshot Status${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    # Filesystem info
    echo -e "\n${GREEN}Filesystem:${NC}"
    df -h "$BTRFS_ROOT" | tail -1
    btrfs filesystem usage "$BTRFS_ROOT" 2>/dev/null | grep -E "(Overall|Used|Free)"

    # Subvolumes
    echo -e "\n${GREEN}Subvolumes:${NC}"
    btrfs subvolume list "$BTRFS_ROOT" | grep -E '@' | while read -r line; do
        echo "  $line"
    done

    # Snapshots
    echo -e "\n${GREEN}Snapshots:${NC}"
    if command -v snapper &>/dev/null; then
        local snap_count
        snap_count=$(snapper -c "$SNAPPER_CONFIG" list 2>/dev/null | tail -n +3 | wc -l)
        echo "  Snapper snapshots: ${snap_count} (config: ${SNAPPER_CONFIG})"

        # Show latest 3
        snapper -c "$SNAPPER_CONFIG" list 2>/dev/null | tail -5
    else
        local count=0
        if [ -d "$SNAPSHOTS_DIR" ]; then
            count=$(find "$SNAPSHOTS_DIR" -maxdepth 1 -name '@-*' 2>/dev/null | wc -l)
        fi
        echo "  Raw snapshots: ${count} (in ${SNAPSHOTS_DIR})"
    fi

    # Default subvolume
    local default_id
    default_id=$(btrfs subvolume get-default "$BTRFS_ROOT" | grep -oP 'ID \K\d+')
    local default_path
    default_path=$(btrfs subvolume list "$BTRFS_ROOT" | awk -v id="$default_id" '$2 == id {print $NF}')
    echo -e "\n${GREEN}Default subvolume:${NC} ID ${default_id} → ${default_path:-/}"
}

# ─── Command: rollback — Rollback to a snapshot ───
cmd_rollback() {
    check_btrfs_root
    local target="${1:-}"

    if [ -z "$target" ]; then
        echo -e "${RED}❌ Usage: $(basename "$0") rollback <snapshot-number>${NC}" >&2
        echo "  Find snapshot number from 'list' output" >&2
        exit 1
    fi

    if command -v snapper &>/dev/null; then
        echo -e "${YELLOW}⚠️  Rolling back to snapshot #${target}...${NC}"
        echo -e "${YELLOW}   A reboot is required to complete the rollback.${NC}"
        echo -n "Continue? [y/N] "
        read -r confirm
        if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
            echo "Aborted."
            exit 0
        fi
        snapper -c "$SNAPPER_CONFIG" rollback "$target"
        echo -e "${GREEN}✅ Rollback to snapshot #${target} prepared.${NC}"
        echo -e "${GREEN}   Reboot to activate the snapshot.${NC}"
    else
        echo -e "${YELLOW}  ⚠ Rollback requires snapper.${NC}" >&2
        echo "  Install snapper: apt install snapper" >&2
        exit 1
    fi
}

# ─── Command: cleanup — Remove old snapshots ───
cmd_cleanup() {
    check_btrfs_root

    if command -v snapper &>/dev/null; then
        echo -e "${GREEN}🧹 Running snapper cleanup...${NC}"
        snapper -c "$SNAPPER_CONFIG" cleanup
        echo -e "${GREEN}✅ Cleanup complete${NC}"
    else
        echo -e "${YELLOW}  ⚠ Cleanup requires snapper.${NC}" >&2
        echo "  Install snapper: apt install snapper" >&2
        exit 1
    fi
}

# ─── Command: diff — Show changes between snapshots ───
cmd_diff() {
    check_btrfs_root
    local pre="${1:-}"
    local post="${2:-}"

    if [ -z "$pre" ] || [ -z "$post" ]; then
        echo -e "${RED}❌ Usage: $(basename "$0") diff <pre-number> <post-number>${NC}" >&2
        exit 1
    fi

    if command -v snapper &>/dev/null; then
        echo -e "${CYAN}📊 Changes between snapshot #${pre} and #${post}:${NC}"
        snapper -c "$SNAPPER_CONFIG" status "$pre".."$post"
    else
        echo -e "${YELLOW}  ⚠ Diff requires snapper.${NC}" >&2
        echo "  Install snapper: apt install snapper" >&2
        exit 1
    fi
}

# ─── Main ───
check_prereqs

COMMAND="${1:-help}"
shift 2>/dev/null || true

case "$COMMAND" in
    init)
        cmd_init
        ;;
    create)
        cmd_create "$@"
        ;;
    pre)
        cmd_pre "$@"
        ;;
    post)
        cmd_post "$@"
        ;;
    list)
        cmd_list
        ;;
    status)
        cmd_status
        ;;
    rollback)
        cmd_rollback "$@"
        ;;
    cleanup)
        cmd_cleanup
        ;;
    diff)
        cmd_diff "$@"
        ;;
    help|--help|-h)
        usage
        ;;
    *)
        echo -e "${RED}❌ Unknown command: ${COMMAND}${NC}" >&2
        usage
        ;;
esac
