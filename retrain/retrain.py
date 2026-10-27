#!/usr/bin/env python3
import mmap
import os
import struct
import subprocess
import sys
import time


def run(cmd):
    return subprocess.check_output(cmd, text=True).strip()


def bar0_open(path):
    fd = os.open(path, os.O_RDWR | os.O_SYNC)
    m = mmap.mmap(fd, os.path.getsize(path), access=mmap.ACCESS_WRITE)
    return fd, m


def r(m, off):
    return struct.unpack_from("<I", m, off)[0]


def w(m, off, val):
    struct.pack_into("<I", m, off, val & 0xFFFFFFFF)


def main(argv):
    if len(argv) != 2:
        sys.exit("usage: retrain.py <gpu-bdf> <upstream-bdf>")
    gpu, up = argv
    path = "/sys/bus/pci/devices/%s/resource0" % gpu

    fd, m = bar0_open(path)
    bar0 = r(m, 0)
    cya = r(m, 0x8C2C0)
    cap = r(m, 0x88084)
    link = r(m, 0x8C040)
    xve = r(m, 0x8872C)
    misc1 = r(m, 0x8841C)
    print("retrain: pre bar0=%08x CYA=%08x DIS_G2=%d MAX=%d CAP=%08x XVE=%08x MISC1=%08x"
          % (bar0, cya, (cya >> 2) & 1, (link >> 18) & 3, cap, xve, misc1))
    if bar0 == 0xFFFFFFFF or cya == 0xFFFFFFFF:
        print("retrain: BAR0 dead; skip")
        m.close(); os.close(fd)
        raise SystemExit(0)
    if ((cya >> 2) & 1) != 0:
        print("retrain: DIS_G2 still set; skip")
        m.close(); os.close(fd)
        raise SystemExit(0)
    if (cap & 0xF) < 2:
        print("retrain: Cap Gen%d; skip" % (cap & 0xF))
        m.close(); os.close(fd)
        raise SystemExit(0)
    m.close(); os.close(fd)

    for bdf in (up, gpu):
        cur = int(run(["setpci", "-s", bdf, "CAP_EXP+30.w"]), 16)
        subprocess.check_call(["setpci", "-s", bdf, "CAP_EXP+30.w=%04x" % ((cur & ~0xF) | 0x2)])
        print("retrain: TLS %s %04x -> %s" % (bdf, cur, run(["setpci", "-s", bdf, "CAP_EXP+30.w"])))

    time.sleep(0.2)
    fd, m = bar0_open(path)
    if r(m, 0) == 0xFFFFFFFF:
        print("retrain: BAR0 dead after TLS; skip")
        m.close(); os.close(fd)
        raise SystemExit(0)

    w(m, 0x8C2C0, r(m, 0x8C2C0) & ~(1 << 2))
    w(m, 0x8C040, (r(m, 0x8C040) & ~0xC0000) | (2 << 18))
    time.sleep(0.05)
    cya = r(m, 0x8C2C0)
    mx = (r(m, 0x8C040) >> 18) & 3
    alive = r(m, 0) != 0xFFFFFFFF
    print("retrain: post CYA=%08x DIS_G2=%d MAX=%d bar0=%08x" % (cya, (cya >> 2) & 1, mx, r(m, 0)))
    m.close(); os.close(fd)

    if not alive or ((cya >> 2) & 1) != 0 or mx != 2:
        print("retrain: preconditions failed; skip")
        raise SystemExit(0)

    cur = int(run(["setpci", "-s", up, "CAP_EXP+10.w"]), 16)
    subprocess.check_call(["setpci", "-s", up, "CAP_EXP+10.w=%04x" % (cur | 0x20)])
    time.sleep(2.0)
    sta = int(run(["setpci", "-s", gpu, "CAP_EXP+12.w"]), 16)
    print("retrain: speed_after=%d" % (sta & 0xF))


if __name__ == "__main__":
    main(sys.argv[1:])
