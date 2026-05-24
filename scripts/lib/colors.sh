#!/usr/bin/env bash
# Edge OS — Shared Color Codes
# Source this file in any script:  source "$(dirname "$0")/lib/colors.sh"

if [ -z "${EDGE_COLORS_LOADED:-}" ]; then
    export RED='\033[0;31m'
    export GREEN='\033[0;32m'
    export YELLOW='\033[1;33m'
    export CYAN='\033[0;36m'
    export NC='\033[0m'
    export EDGE_COLORS_LOADED=1
fi
