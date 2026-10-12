#!/usr/bin/env python3
"""Mark every global definition of a 64-bit Mach-O object file weak (N_WEAK_DEF).

  macho_weaken.py <object.o>    patch in place, print the count

Zig's compiler_rt exports its routines with weak linkage (lib/compiler_rt.zig:
"we prefer weak linkage because some of the routines we implement here may also
be provided by system/dynamic libc"), but the compiler_rt.o that a Linux-hosted
`zig build` bundles into a macOS static library carries them as strong
definitions. libghostty-vt then holds two strong memset definitions (compiler_rt
and ghostty-next src/quirks_memset.zig, which relies on compiler_rt's being
weak). scripts/ci/macos-cross.sh restores the intended weak linkage on that one
object; scripts/ci/macho_parity.py then compares the linked daemon with the
Mac-built one.
"""
from __future__ import annotations

import struct
import sys

MH_MAGIC_64 = 0xFEEDFACF
MH_OBJECT = 0x1
LC_SYMTAB = 0x2
N_EXT, N_TYPE, N_SECT, N_WEAK_DEF = 0x01, 0x0E, 0x0E, 0x0080


def weaken(data: bytearray) -> int:
    magic, _cpu, _sub, filetype, ncmds, _size, _flags, _reserved = struct.unpack_from("<8I", data, 0)
    if magic != MH_MAGIC_64 or filetype != MH_OBJECT:
        raise SystemExit("not a little-endian 64-bit Mach-O object file")
    offset, changed = 32, 0
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<2I", data, offset)
        if cmd == LC_SYMTAB:
            symoff, nsyms, _stroff, _strsize = struct.unpack_from("<4I", data, offset + 8)
            for index in range(nsyms):
                entry = symoff + 16 * index
                n_type = data[entry + 4]
                n_desc = struct.unpack_from("<H", data, entry + 6)[0]
                if n_type & N_EXT and (n_type & N_TYPE) == N_SECT and not n_desc & N_WEAK_DEF:
                    struct.pack_into("<H", data, entry + 6, n_desc | N_WEAK_DEF)
                    changed += 1
        offset += cmdsize
    return changed


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    with open(argv[1], "rb") as handle:
        data = bytearray(handle.read())
    changed = weaken(data)
    with open(argv[1], "wb") as handle:
        handle.write(data)
    print(f"macho_weaken: {argv[1]}: {changed} global definitions marked weak")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
