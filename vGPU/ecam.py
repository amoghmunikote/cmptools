#!/usr/bin/env python3
import mmap
import os
import struct
import sys


def ecam_base():
    with open("/sys/firmware/acpi/tables/MCFG", "rb") as f:
        return struct.unpack_from("<Q", f.read(), 44)[0]


def addr_for(bdf, off):
    bus, rest = bdf.split(":")[-2:]
    dev, fn = rest.split(".")
    return (ecam_base()
            + (int(bus, 16) << 20)
            + (int(dev, 16) << 15)
            + (int(fn, 16) << 12)
            + off)


def access(op, bdf, off, val=None):
    addr = addr_for(bdf, off)
    write = op == "write"
    fd = os.open("/dev/mem", (os.O_RDWR | os.O_SYNC) if write else os.O_RDONLY)
    try:
        mem = mmap.mmap(fd, mmap.PAGESIZE, mmap.MAP_SHARED,
                        mmap.PROT_READ | (mmap.PROT_WRITE if write else 0),
                        offset=addr & ~0xfff)
    finally:
        os.close(fd)
    pos = addr & 0xfff
    if write:
        mem[pos:pos + 4] = (val & 0xffffffff).to_bytes(4, "little")
    return int.from_bytes(mem[pos:pos + 4], "little")


def main(argv):
    if len(argv) not in (3, 4) or argv[0] not in ("read", "write"):
        sys.exit("usage: ecam.py read <bdf> <off> | write <bdf> <off> <val>")
    op, bdf, off = argv[0], argv[1], int(argv[2], 16)
    val = int(argv[3], 16) if op == "write" else None
    print("0x%08x" % access(op, bdf, off, val))


if __name__ == "__main__":
    main(sys.argv[1:])
