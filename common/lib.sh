#!/bin/bash
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
else
    RED=""; GREEN=""; YELLOW=""; CYAN=""; NC=""
fi

info() { echo -e "${CYAN}==>${NC} $*"; }
ok()   { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}!${NC} $*"; }
err()  { echo -e "${RED}✗${NC} $*" >&2; }
die()  { err "$*"; exit 1; }

banner() {
    echo ""
    echo -e "${CYAN}╔════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                cmptools                ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════╝${NC}"
    echo ""
}

STEP_NUM=0
STEP_TOTAL=0
step_init() { STEP_TOTAL="$1"; STEP_NUM=0; }

step() {
    STEP_NUM=$((STEP_NUM + 1))
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}Step ${STEP_NUM}/${STEP_TOTAL}: $*${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

normalize_bus_id() {
    local raw="$1"
    raw="$(echo "${raw}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
    if [[ "${raw}" =~ ^([0-9a-f]+):([0-9a-f]{2}):([0-9a-f]{2})\.([0-9a-f])$ ]]; then
        printf '%04x:%s:%s.%s\n' "$((16#${BASH_REMATCH[1]}))" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}"
    elif [[ "${raw}" =~ ^[0-9a-f]{2}:[0-9a-f]{2}\.[0-9a-f]$ ]]; then
        echo "0000:${raw}"
    else
        echo "${raw}"
    fi
}
