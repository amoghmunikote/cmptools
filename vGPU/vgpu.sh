#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common/lib.sh"
source "${SCRIPT_DIR}/helpers.sh"

usage() {
    cat <<'EOF'
Manage NVIDIA vGPU (SR-IOV host) on the CMP 170HX / GA100.

Usage: sudo ./tools.sh vGPU <command> [BDF]

  install <pkg.run>     install the vGPU manager userspace and services from an
                        NVIDIA-Linux-x86_64-<ver>-vgpu-kvm.run package
  enable  [BDF]         run in SR-IOV host mode from the next nvidia load
  unhide  [BDF]         expose SR-IOV, MSI-X and a 64 GB BAR1 (once per boot)
  start   [BDF] [VFs]   create VFs (default 4) and start the vGPU services
  stop    [BDF]         stop the services and remove the VFs; power off the VMs first

With no BDF a command applies to every CMP 170HX in the system; pass a BDF
(e.g. 0000:81:00.0) to restrict it to one card.

Typical first-time flow:
  sudo ./tools.sh vGPU install NVIDIA-Linux-x86_64-<ver>-vgpu-kvm.run
  sudo ./tools.sh vGPU enable     # then reboot
  sudo ./tools.sh vGPU unhide     # once per boot
  sudo ./tools.sh vGPU start
EOF
}

is_cmp() {
    local dev
    dev="$(cat "/sys/bus/pci/devices/$1/device" 2>/dev/null || true)"
    [[ "${dev}" == "0x20c2" || "${dev}" == "0x2082" ]]
}

resolve_targets() {
    local arg="${1:-}" bdf all
    if [[ -n "${arg}" ]]; then
        bdf="$(normalize_bus_id "${arg}")"
        [[ -e "/sys/bus/pci/devices/${bdf}" ]] || die "${bdf} not present"
        is_cmp "${bdf}" || die "${bdf} is not a CMP 170HX"
        echo "${bdf}"
    else
        all="$(cmp_gpus)"
        [[ -n "${all}" ]] || die "no CMP 170HX found"
        echo "${all}"
    fi
}

do_install() {
    local run="$1" ver dir tmp lib
    ver="$(basename "${run}" | sed -n 's/^NVIDIA-Linux-x86_64-\([0-9.]*\)-vgpu-kvm\.run$/\1/p')"
    [[ -f "${run}" && -n "${ver}" ]] || die "not an NVIDIA vGPU KVM host package: ${run}"
    tmp="$(mktemp -d)"
    trap 'rm -rf "${tmp}"' EXIT
    (cd "${tmp}" && sh "${run}" --extract-only >/dev/null)
    dir="${tmp}/NVIDIA-Linux-x86_64-${ver}-vgpu-kvm"

    mkdir -p "${LIB}"
    install -m 0755 "${dir}/nvidia-vgpud" "${dir}/nvidia-vgpu-mgr" "${LIB}/"
    for lib in libnvidia-vgpu libnvidia-vgxcfg libnvidia-ml; do
        install -m 0644 "${dir}/${lib}.so.${ver}" "${LIB}/"
        ln -sf "${lib}.so.${ver}" "${LIB}/${lib}.so.1"
    done
    ln -sf "${LIB}/libnvidia-vgpu.so.${ver}" "$(plugin_dir)/libnvidia-vgpu.so"
    ok "installed vGPU ${ver} userspace in ${LIB}"

    mkdir -p "$(dirname "${VGPU_XML}")"
    python3 "${SCRIPT_DIR}/profiles.py" "${dir}/vgpuConfig.xml" "${VGPU_XML}"

    cat > "${UNITS}/cmpunlocker-vgpud.service" <<EOF
[Unit]
Description=cmpunlocker: NVIDIA vGPU daemon

[Service]
Type=oneshot
Environment=LD_LIBRARY_PATH=${LIB}
ExecStart=${LIB}/nvidia-vgpud
EOF
    cat > "${UNITS}/cmpunlocker-vgpu-mgr.service" <<EOF
[Unit]
Description=cmpunlocker: NVIDIA vGPU manager
Requires=cmpunlocker-vgpud.service
After=cmpunlocker-vgpud.service

[Service]
Type=forking
KillMode=process
Environment=LD_LIBRARY_PATH=${LIB}
ExecStart=${LIB}/nvidia-vgpu-mgr
ExecStopPost=/bin/rm -rf /var/run/nvidia-vgpu-mgr
EOF
    systemctl daemon-reload
    [[ -f "${CONF}" ]] || printf 'options nvidia NVreg_RegistryDwords="RMSetSriovMode=0"\n' > "${CONF}"
    ok "wrote services and ${CONF}"
}

do_enable() {
    local bdf="$1" devs
    [[ -e "/sys/bus/pci/devices/${bdf}" ]] || die "${bdf} not present"
    devs="$(sed -n 's/.*NVreg_RegistryDwordsPerDevice="\(.*\)"/\1/p' "${CONF}" 2>/dev/null || true)"
    [[ "${devs}" == *"pci=${bdf};"* ]] || devs="${devs}pci=${bdf};RMSetSriovMode=1;"
    printf 'options nvidia NVreg_RegistryDwords="RMSetSriovMode=0" NVreg_RegistryDwordsPerDevice="%s"\n' \
        "${devs}" > "${CONF}"
    ok "${bdf} runs in SR-IOV host mode from the next nvidia load (${CONF})"
}

do_unhide() {
    local gpu="$1" port nic v
    [[ -e "/sys/bus/pci/devices/${gpu}" ]] || die "${gpu} not present"
    grep -qw "iomem=relaxed" /proc/cmdline || die "iomem=relaxed missing from the kernel command line"
    grep -qE "pci=[^ ]*realloc" /proc/cmdline || die "pci=realloc=on missing from the kernel command line"
    v="$(setpci -s "${gpu}" 71c.l)"
    if (( (0x${v} & 1) == 0 )); then
        ok "${gpu} already exposes SR-IOV"
        return 0
    fi
    port="$(readlink -f "/sys/bus/pci/devices/${gpu}" | cut -d/ -f5)"
    nic="$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'dev \K\S+' || true)"
    if [[ -n "${nic}" && "$(readlink -f "/sys/class/net/${nic}")" == *"/${port}/"* ]]; then
        die "the default-route NIC sits behind ${port}"
    fi
    systemctl stop nvidia-persistenced 2>/dev/null || true
    modprobe -r nvidia_drm nvidia_modeset nvidia_uvm nvidia_vgpu_vfio nvidia 2>/dev/null || true
    grep -q '^nvidia ' /proc/modules && die "could not unload nvidia"
    find "$(readlink -f "/sys/bus/pci/devices/${port}")" \
        -regex '.*/[0-9a-f]\{4\}:[0-9a-f]\{2\}:[0-9a-f]\{2\}\.[0-7]/power/control' \
        -exec sh -c 'echo on > "$1"' _ {} \;
    sleep 1
    echo 0 > /sys/bus/pci/drivers_autoprobe
    echo 1 > "/sys/bus/pci/devices/${port}/remove"
    sleep 3
    v="$(ecam read "${gpu}" 71c)"
    if [[ "${v}" == 0xffffffff ]]; then
        echo 1 > /sys/bus/pci/rescan
        echo 1 > /sys/bus/pci/drivers_autoprobe
        die "${gpu} unreachable over ECAM"
    fi
    ecam write "${gpu}" 71c "$(printf %08x $(( v & ~1 )))" >/dev/null
    v="$(ecam read "${gpu}" 41c)"
    ecam write "${gpu}" 41c "$(printf %08x $(( (v & ~(1 << 29)) | (1 << 17) )))" >/dev/null
    ecam write "${gpu}" 724 00000030 >/dev/null
    ecam write "${gpu}" dcc 8000000a >/dev/null
    v="$(ecam read "${gpu}" bc0)"
    ecam write "${gpu}" bc0 "$(printf %08x $(( (v & ~0x3f00) | (16 << 8) )))" >/dev/null
    echo 1 > /sys/bus/pci/rescan
    sleep 8
    echo 1 > /sys/bus/pci/drivers_autoprobe
    for v in /sys/bus/pci/devices/*; do
        [[ "$(readlink -f "${v}")" == *"/${port}/"* && -e "${v}/vendor" ]] || continue
        basename "${v}" > /sys/bus/pci/drivers_probe 2>/dev/null || true
    done
    [[ -e "/sys/bus/pci/devices/${gpu}/sriov_totalvfs" ]] || die "${gpu} did not expose SR-IOV"
    ok "${gpu}: $(cat "/sys/bus/pci/devices/${gpu}/sriov_totalvfs") VFs, BAR1 $(( ($(sed -n 2p "/sys/bus/pci/devices/${gpu}/resource" | awk '{print $2 " - " $1}') + 1) >> 20 )) MB"
}

do_start() {
    local pf="$1" count="${2:-4}" vf dev="/sys/bus/pci/devices/$1"
    [[ -e "${dev}/sriov_totalvfs" ]] || die "${pf} has no SR-IOV capability; run './tools.sh vGPU unhide ${pf}' first"
    [[ "$(cat "${dev}/sriov_numvfs")" -eq 0 ]] || die "${pf} already has VFs"
    modprobe nvidia-vgpu-vfio
    set_numvfs "${pf}" "${count}"
    for vf in "${dev}"/virtfn*; do
        vf="$(basename "$(readlink -f "${vf}")")"
        echo | tee "/sys/bus/pci/devices/${vf}/reset_method" >/dev/null
        echo nvidia > "/sys/bus/pci/devices/${vf}/driver_override"
        echo "${vf}" > /sys/bus/pci/drivers/nvidia/bind
    done
    systemctl start cmpunlocker-vgpud.service cmpunlocker-vgpu-mgr.service
    vf="$(basename "$(readlink -f "${dev}/virtfn0")")"
    ok "${count} VFs on ${pf}; creatable on ${vf}:"
    cat "/sys/bus/pci/devices/${vf}/nvidia/creatable_vgpu_types" 2>/dev/null || warn "no creatable vGPU types"
}

do_stop() {
    local pf="$1" vf dev="/sys/bus/pci/devices/$1"
    pgrep -x qemu-system-x86 >/dev/null && die "QEMU is running; power the VMs off first"
    systemctl stop cmpunlocker-vgpu-mgr.service cmpunlocker-vgpud.service
    for vf in "${dev}"/virtfn*; do
        [[ -e "${vf}" ]] || continue
        vf="$(basename "$(readlink -f "${vf}")")"
        echo 0 > "/sys/bus/pci/devices/${vf}/nvidia/current_vgpu_type" 2>/dev/null || true
        [[ -e "/sys/bus/pci/drivers/nvidia/${vf}" ]] && echo "${vf}" > /sys/bus/pci/drivers/nvidia/unbind
    done
    set_numvfs "${pf}" 0
    echo 1 > "${dev}/sriov_drivers_autoprobe"
    ok "vGPU stopped on ${pf}"
}

cmd="${1:-}"
shift 2>/dev/null || true
case "${cmd}" in
    ""|-h|--help|help) usage; exit 0 ;;
esac
[[ "${EUID}" -eq 0 ]] || die "run as root"
case "${cmd}" in
    install)
        [[ $# -eq 1 ]] || { usage; exit 1; }
        do_install "$1"
        ;;
    enable|unhide|stop)
        [[ $# -le 1 ]] || { usage; exit 1; }
        targets="$(resolve_targets "${1:-}")" || exit 1
        while read -r bdf; do
            [[ -n "${bdf}" ]] || continue
            "do_${cmd}" "${bdf}"
        done <<< "${targets}"
        ;;
    start)
        start_bdf=""
        start_count=4
        for arg in "$@"; do
            if [[ "${arg}" == *:* ]]; then
                start_bdf="${arg}"
            elif [[ "${arg}" =~ ^[0-9]+$ ]]; then
                start_count="${arg}"
            else
                usage; exit 1
            fi
        done
        targets="$(resolve_targets "${start_bdf}")" || exit 1
        while read -r bdf; do
            [[ -n "${bdf}" ]] || continue
            do_start "${bdf}" "${start_count}"
        done <<< "${targets}"
        ;;
    *) usage; exit 1 ;;
esac
