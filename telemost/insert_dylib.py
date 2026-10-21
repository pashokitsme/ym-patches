#!/usr/bin/env python3
"""Add an LC_LOAD_DYLIB command to every slice of a (fat) Mach-O, in place.

Uses the zero padding between the load commands and the first section.
Idempotent: a slice that already loads the dylib is left alone.
Usage: insert_dylib.py <binary> <install-name>
"""
import struct
import sys

FAT_MAGIC, FAT_MAGIC_64 = 0xCAFEBABE, 0xCAFEBABF
MH_MAGIC_64 = 0xFEEDFACF
LC_LOAD_DYLIB, LC_SEGMENT_64, LC_CODE_SIGNATURE = 0xC, 0x19, 0x1D


def patch_slice(buf, off, name):
    magic, _, _, _, ncmds, sizeofcmds, _ = struct.unpack_from("<7I", buf, off)
    if magic != MH_MAGIC_64:
        raise SystemExit(f"slice @{off:#x}: unsupported magic {magic:#x}")
    hdr = 32
    p = off + hdr
    first_sect = None
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<2I", buf, p)
        if cmd == LC_LOAD_DYLIB:
            str_off = struct.unpack_from("<I", buf, p + 8)[0]
            existing = bytes(buf[p + str_off : p + size]).split(b"\0", 1)[0].decode()
            if existing == name:
                return "already present"
        if cmd == LC_SEGMENT_64:
            nsects = struct.unpack_from("<I", buf, p + 64)[0]
            for i in range(nsects):
                s = p + 72 + i * 80
                sect_off = struct.unpack_from("<I", buf, s + 48)[0]
                if sect_off and (first_sect is None or sect_off < first_sect):
                    first_sect = sect_off
        p += size
    raw = name.encode() + b"\0"
    cmd_size = (24 + len(raw) + 7) & ~7
    end = off + hdr + sizeofcmds
    if first_sect is None or end + cmd_size > off + first_sect:
        raise SystemExit("not enough header padding for a new load command")
    if any(buf[end : end + cmd_size]):
        raise SystemExit("header padding is not zeroed, refusing to overwrite")
    # dylib_command: cmd, cmdsize, name.offset, timestamp, current_version, compat_version
    lc = struct.pack("<6I", LC_LOAD_DYLIB, cmd_size, 24, 2, 0x10000, 0x10000) + raw
    buf[end : end + cmd_size] = lc.ljust(cmd_size, b"\0")
    struct.pack_into("<2I", buf, off + 16, ncmds + 1, sizeofcmds + cmd_size)
    return "inserted"


def main():
    path, name = sys.argv[1], sys.argv[2]
    buf = bytearray(open(path, "rb").read())
    magic = struct.unpack_from(">I", buf, 0)[0]
    if magic in (FAT_MAGIC, FAT_MAGIC_64):
        n = struct.unpack_from(">I", buf, 4)[0]
        step = 20 if magic == FAT_MAGIC else 32
        offs = []
        for i in range(n):
            e = 8 + i * step
            offs.append(struct.unpack_from(">I" if magic == FAT_MAGIC else ">Q", buf, e + 8)[0])
    else:
        offs = [0]
    for o in offs:
        print(f"slice @{o:#x}: {patch_slice(buf, o, name)}")
    open(path, "wb").write(buf)


if __name__ == "__main__":
    main()
