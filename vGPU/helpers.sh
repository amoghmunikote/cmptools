#!/bin/bash
HELPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LIB="/usr/local/lib/cmpunlocker/vgpu"
CONF="/etc/modprobe.d/cmpunlocker-vgpu.conf"
UNITS="/etc/systemd/system"
VGPU_XML="/usr/share/nvidia/vgpu/vgpuConfig.xml"

ecam() { python3 "${HELPER_DIR}/ecam.py" "$@"; }

plugin_dir() {
    local ml
    ml="$(ldconfig -p | awk '/libnvidia-ml\.so\.1 .*x86-64/ {print $NF; exit}')"
    [[ -n "${ml}" ]] || die "libnvidia-ml.so.1 not found; install nvidia-open first"
    dirname "${ml}"
}

set_numvfs() {
    local pf="$1" count="$2" dev="/sys/bus/pci/devices/$1"
    nvidia-smi -pm 0 >/dev/null
    echo 1 > "/proc/driver/nvidia/gpus/${pf}/unbindLock"
    echo "${pf}" > /sys/bus/pci/drivers/nvidia/unbind
    modprobe pci-pf-stub
    echo pci-pf-stub > "${dev}/driver_override"
    echo "${pf}" > /sys/bus/pci/drivers/pci-pf-stub/bind
    echo 0 > "${dev}/sriov_drivers_autoprobe"
    echo "${count}" > "${dev}/sriov_numvfs"
    echo "${pf}" > /sys/bus/pci/drivers/pci-pf-stub/unbind
    echo > "${dev}/driver_override"
    echo "${pf}" > /sys/bus/pci/drivers/nvidia/bind
    nvidia-smi -pm 1 >/dev/null
}
