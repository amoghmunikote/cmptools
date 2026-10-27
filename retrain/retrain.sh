#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common/lib.sh"

usage() {
    cat <<'EOF'
Force a one-shot PCIe Gen2 retrain on a CMP 170HX.

Usage: sudo ./tools.sh retrain <BDF> [UPSTREAM_BDF]

  <BDF>           the GPU, e.g. 0000:0a:00.0
  UPSTREAM_BDF    its upstream bridge; auto-detected from sysfs when omitted

The card must report a max link gen of 2 or higher and currently sit below Gen2.
This clears DIS_G2, sets the target link speed to Gen2 on both the GPU and its
upstream port, then triggers a link retrain. It refuses any device that is not a
CMP 170HX.
EOF
}

check_is_cmp() {
    local bdf="$1" vd
    vd="$(cat "/sys/bus/pci/devices/${bdf}/vendor" 2>/dev/null):$(cat "/sys/bus/pci/devices/${bdf}/device" 2>/dev/null)"
    case "${vd}" in
        0x10de:0x20c2|0x10de:0x2082) ;;
        *) die "${bdf} is not a CMP 170HX (${vd})" ;;
    esac
}

ACTION="${1:-}"
case "${ACTION}" in
    ""|-h|--help|help) usage; exit 0 ;;
esac

[[ "${EUID}" -eq 0 ]] || die "Run as root: sudo ./tools.sh retrain <BDF>"
command -v nvidia-smi &>/dev/null || die "nvidia-smi not found"
command -v setpci &>/dev/null || die "setpci not found (install pciutils)"

gpu="$(normalize_bus_id "$1")"
[[ -e "/sys/bus/pci/devices/${gpu}" ]] || die "no such PCI device: ${gpu}"
check_is_cmp "${gpu}"
[[ -e "/sys/bus/pci/devices/${gpu}/resource0" ]] || die "${gpu}: no resource0 (BAR0) to map"

if [[ -n "${2:-}" ]]; then
    up="$(normalize_bus_id "$2")"
else
    up="$(basename "$(dirname "$(readlink -f "/sys/bus/pci/devices/${gpu}")")")"
fi
[[ "${up}" =~ ^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-9a-f]$ ]] \
    || die "could not determine the upstream bridge for ${gpu}; pass it explicitly"
[[ -e "/sys/bus/pci/devices/${up}" ]] || die "upstream bridge ${up} not present"

row="$(nvidia-smi --query-gpu=pci.bus_id,pcie.link.gen.current,pcie.link.gen.max --format=csv,noheader,nounits 2>/dev/null \
       | awk -F', ' -v b="${gpu}" 'tolower($1) ~ tolower(b) {print; exit}')"
[[ -n "${row}" ]] || die "${gpu}: nvidia-smi cannot see this GPU"
cur="$(echo "${row}" | cut -d, -f2 | tr -d ' ')"
max="$(echo "${row}" | cut -d, -f3 | tr -d ' ')"

if [[ "${cur}" == "2" ]]; then
    ok "${gpu}: already negotiated Gen2; nothing to do"
    exit 0
fi
case "${max}" in
    2|3|4) ;;
    *) die "${gpu}: max link gen is '${max}', not 2/3/4; refusing to retrain" ;;
esac

info "Retraining ${gpu} to Gen2 via upstream ${up} (currently Gen${cur})"
python3 "${SCRIPT_DIR}/retrain.py" "${gpu}" "${up}"