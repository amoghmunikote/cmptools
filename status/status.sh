#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common/lib.sh"

KVER="$(uname -r)"
INSTALL_MOD_DIR="/lib/modules/${KVER}/updates/cmpunlocker"
INVENTORY_FILE="${INSTALL_MOD_DIR}/gpu_inventory"
LOG_FILE="/var/log/gen2.log"
SERVICE_NAME="gen2.service"
SERVICE_TARGET="/etc/systemd/system/${SERVICE_NAME}"

usage() {
    cat <<'EOF'
Report CMP 170HX unlock and PCIe-link status.

Usage: ./tools.sh status [show]          read-only overview (no root needed)
       sudo ./tools.sh status verify     strict unlock + Gen2 checks

  show    gen2 service state and an nvidia-smi memory/link snapshot
  verify  per-card memory-unlock verification against the installed inventory,
          SEC2 unlock logs and negotiated PCIe Gen2; exits non-zero on failure
EOF
}

supported_gpus() {
    for id in 20c2 2082; do
        lspci -D -d "10de:${id}" 2>/dev/null | awk '{print $1}'
    done
}

link_generation() {
    local status
    status="$(setpci -s "$1" CAP_EXP+12.w 2>/dev/null || true)"
    if [[ "${status}" =~ ^[[:xdigit:]]{4}$ ]]; then
        echo $((0x${status} & 0x0f))
    else
        echo "?"
    fi
}

is_unlocked_memory() {
    local profile="$1" mem_mib="$2"
    [[ "${mem_mib}" =~ ^[0-9]+$ ]] || return 1
    case "${profile}" in
        8gb) (( mem_mib >= 60000 )) && return 0 ;;
        10gb) (( mem_mib >= 35000 && mem_mib < 60000 )) && return 0 ;;
    esac
    return 1
}

is_stock_memory() {
    local profile="$1" mem_mib="$2"
    [[ "${mem_mib}" =~ ^[0-9]+$ ]] || return 1
    case "${profile}" in
        8gb) (( mem_mib >= 7680 && mem_mib <= 8704 )) && return 0 ;;
        10gb) (( mem_mib >= 9728 && mem_mib <= 10752 )) && return 0 ;;
    esac
    return 1
}

GPU_BDFS=()
GPU_DEVIDS=()
GPU_PROFILES=()
GPU_EXPECTED=()

load_inventory() {
    GPU_BDFS=(); GPU_DEVIDS=(); GPU_PROFILES=(); GPU_EXPECTED=()
    if [[ -r "${INVENTORY_FILE}" ]] && [[ -s "${INVENTORY_FILE}" ]]; then
        info "Using inventory: ${INVENTORY_FILE}"
        local bdf devid profile expected
        while read -r bdf devid profile expected || [[ -n "${bdf:-}" ]]; do
            [[ -n "${bdf:-}" ]] || continue
            [[ "${bdf}" =~ ^# ]] && continue
            GPU_BDFS+=("$(normalize_bus_id "${bdf}")")
            GPU_DEVIDS+=("${devid}")
            GPU_PROFILES+=("${profile}")
            GPU_EXPECTED+=("${expected}")
        done < "${INVENTORY_FILE}"
    else
        info "No installed gpu_inventory; enumerating via lspci"
        local -a lines; local line pci pci_full devid prof exp
        mapfile -t lines < <(lspci -nn 2>/dev/null | grep -iE '10de:20c2|10de:2082' || true)
        [[ ${#lines[@]} -gt 0 ]] || die "No unlockable CMP 170HX GPU found (10de:20c2 / 10de:2082)"
        for line in "${lines[@]}"; do
            pci="$(echo "${line}" | awk '{print $1}')"
            pci_full="$(normalize_bus_id "${pci}")"
            devid="$(echo "${line}" | grep -oE '10de:[0-9a-fA-F]{4}' | head -1 | cut -d: -f2 | tr '[:upper:]' '[:lower:]')"
            prof="$(profile_from_devid "${devid}")"
            [[ "${prof}" != "unsupported" ]] || continue
            exp="$(expected_mib_for_profile "${prof}")"
            GPU_BDFS+=("${pci_full}")
            GPU_DEVIDS+=("${devid}")
            GPU_PROFILES+=("${prof}")
            GPU_EXPECTED+=("${exp}")
        done
    fi
    [[ ${#GPU_BDFS[@]} -gt 0 ]] || die "No unlockable GPUs to verify"
}

verify_unlock() {
    local i bdf devid profile expected actual status
    local failures=0
    printf "\n%-16s %-8s %-8s %-12s %-12s %s\n" "BDF" "PCI ID" "Variant" "Expect" "Actual" "Status"
    for i in "${!GPU_BDFS[@]}"; do
        bdf="${GPU_BDFS[$i]}"
        devid="${GPU_DEVIDS[$i]}"
        profile="${GPU_PROFILES[$i]}"
        expected="${GPU_EXPECTED[$i]}"
        actual="$(smi_memory_for_bus "${bdf}" || true)"
        [[ -n "${actual}" ]] || actual="?"

        status="FAIL"
        if is_unlocked_memory "${profile}" "${actual}"; then
            status="OK"
            ok "${bdf}: ${actual} MiB (unlocked ${profile})"
        elif is_stock_memory "${profile}" "${actual}"; then
            status="STOCK"
            err "${bdf}: still stock ${actual} MiB (expect ~${expected})"
            failures=$((failures + 1))
        elif [[ "${actual}" == "?" ]]; then
            status="MISSING"
            err "${bdf}: not found in nvidia-smi"
            failures=$((failures + 1))
        else
            status="UNEXPECTED"
            err "${bdf}: unexpected ${actual} MiB (expect ~${expected} for ${profile})"
            failures=$((failures + 1))
        fi
        printf "%-16s %-8s %-8s ~%-11s %-12s %s\n" "${bdf}" "${devid}" "${profile}" "${expected}" "${actual}" "${status}"
    done
    return "${failures}"
}

verify_gen2() {
    local gpu bridge status generation speed width max_speed result
    local failures=0
    local -a gpus=()
    mapfile -t gpus < <(supported_gpus)
    [[ ${#gpus[@]} -gt 0 ]] || { warn "no supported GPUs for the Gen2 check"; return 0; }

    printf '%-16s %-16s %-8s %-14s %-8s %s\n' "GPU" "Upstream" "LnkSta" "Current speed" "Width" "Result"
    for gpu in "${gpus[@]}"; do
        bridge="$(basename "$(dirname "$(readlink -f "/sys/bus/pci/devices/${gpu}")")")"
        status="$(setpci -s "${gpu}" CAP_EXP+12.w 2>/dev/null || echo unreadable)"
        generation="$(link_generation "${gpu}")"
        speed="$(cat "/sys/bus/pci/devices/${gpu}/current_link_speed" 2>/dev/null || echo unknown)"
        width="$(cat "/sys/bus/pci/devices/${gpu}/current_link_width" 2>/dev/null || echo unknown)"
        max_speed="$(cat "/sys/bus/pci/devices/${gpu}/max_link_speed" 2>/dev/null || echo unknown)"
        if [[ "${generation}" =~ ^[0-9]+$ ]] && (( generation >= 2 )); then
            result="GEN2 OK"
        else
            result="GEN1"
            failures=$((failures + 1))
        fi
        printf '%-16s %-16s %-8s %-14s x%-7s %s\n' "${gpu}" "${bridge}" "0x${status}" "${speed}" "${width}" "${result}"
        info "${gpu}: sysfs max=${max_speed}; negotiated generation is authoritative"
    done

    if command -v nvidia-smi >/dev/null; then
        echo
        nvidia-smi --query-gpu=pci.bus_id,memory.total,pcie.link.gen.current,pcie.link.gen.max --format=csv 2>/dev/null || true
    fi

    echo
    if [[ -f "${LOG_FILE}" ]]; then
        info "Last early-retrain log:"
        tail -n 30 "${LOG_FILE}"
    else
        warn "No ${LOG_FILE}; the early service has not run yet"
    fi
    (( failures == 0 )) || return 1
}

do_verify() {
    banner
    step_init 4

    step "Locating GPU inventory"
    command -v nvidia-smi &>/dev/null || die "nvidia-smi not found"
    SMI_MEM_CACHE="$(nvidia-smi --query-gpu=pci.bus_id,memory.total --format=csv,noheader,nounits 2>/dev/null || true)"
    [[ -n "${SMI_MEM_CACHE}" ]] || die "nvidia-smi returned no GPU memory data"
    load_inventory

    step "Checking memory unlock status"
    local failures=0
    verify_unlock || failures="$?"

    step "Checking unlock logs and installed profile"
    local sec2_logs
    sec2_logs="$(dmesg 2>/dev/null | grep 'SEC2_DEBUG' || true)"
    if [[ -n "${sec2_logs}" ]]; then
        ok "dmesg contains SEC2_DEBUG unlock logs"
        info "Sample:"
        printf '%s\n' "${sec2_logs}" | tail -n 8 | sed 's/^/  /'
    else
        warn "No SEC2_DEBUG lines in dmesg (logs may have rotated; unlock can still be OK if memory is unlocked)"
    fi
    echo ""
    if [[ -r "${INSTALL_MOD_DIR}/card_profile" ]]; then
        info "Installed profile: $(cat "${INSTALL_MOD_DIR}/card_profile") / geometry: $(cat "${INSTALL_MOD_DIR}/unlock_geometry" 2>/dev/null || echo '?')"
    fi

    if (( failures > 0 )); then
        echo ""
        die "${failures} GPU(s) failed unlock verification. Cold reboot if modules were just installed."
    fi
    echo ""
    ok "All ${#GPU_BDFS[@]} unlockable GPU(s) report unlocked memory"

    step "Checking negotiated PCIe generation"
    if verify_gen2; then
        ok "All supported GPUs are negotiated at Gen2 or better"
    else
        warn "Memory unlock is healthy, but PCIe Gen2 is not active"
        exit 1
    fi
    exit 0
}

do_show() {
    if [[ -f "${SERVICE_TARGET}" ]]; then
        ok "gen2 service installed: ${SERVICE_TARGET}"
    else
        warn "gen2 service not installed"
    fi
    systemctl is-enabled "${SERVICE_NAME}" 2>/dev/null || true
    echo ""
    if command -v nvidia-smi >/dev/null 2>&1; then
        nvidia-smi --query-gpu=pci.bus_id,memory.total,pcie.link.gen.current,pcie.link.gen.max --format=csv 2>/dev/null \
            || warn "nvidia-smi returned no data"
    else
        warn "nvidia-smi not found"
    fi
}

ACTION="${1:-}"
case "${ACTION}" in
    ""|show) do_show ;;
    verify)
        [[ "${EUID}" -eq 0 ]] || die "Run as root: sudo ./tools.sh status verify"
        do_verify
        ;;
    -h|--help|help) usage; exit 0 ;;
    *) usage; exit 1 ;;
esac
