#!/usr/bin/env python3
"""Writes the app symbol map of a Mach-O executable before the release strip.

    scripts/write-app-symbol-map.py EXECUTABLE OUT

cmux NEXT's executable links with -no_exported_symbols, so the release strip
removes every function name from it. The map keeps them for in-app
symbolication (hang records, exception traces): per slice, the LC_UUID and
the __TEXT,__text symbols as offsets from the __TEXT segment, sorted, named
as dladdr names them (without the leading underscore), then one entry with
an empty name at the end of __TEXT,__text: addresses past it (__stubs,
__objc_stubs) name no function.

Format, little-endian: b"CMXSYM1\\0", u32 slice count, then per slice the
16-byte UUID, u32 payload size and the payload as raw DEFLATE (what
Foundation's `.zlib` decompression reads): u32 symbol count, one unsigned
LEB128 offset delta per symbol, then the names joined by NUL.

A second strip pass over the stripped executable leaves OUT as it is: OUT
already holds a map for every slice UUID (stripping keeps the UUID), and the
names left (such as __mh_execute_header) would replace it with almost none.
An executable with no such symbols also leaves OUT alone.
"""

from __future__ import annotations

import os
import struct
import sys
import tempfile
import zlib

MH_MAGIC_64 = 0xFEEDFACF
FAT_MAGICS = {0xCAFEBABE: 20, 0xCAFEBABF: 32}  # fat_arch, fat_arch_64 sizes
LC_SEGMENT_64, LC_SYMTAB, LC_UUID = 0x19, 0x2, 0x1B
N_STAB, N_TYPE, N_SECT = 0xE0, 0x0E, 0x0E


def slices(data: bytes) -> list[bytes]:
    """The thin 64-bit Mach-O images in data; none when it is not Mach-O."""
    if len(data) < 32:
        return []
    (magic,) = struct.unpack_from(">I", data, 0)
    if magic not in FAT_MAGICS:
        return [data] if struct.unpack_from("<I", data, 0)[0] == MH_MAGIC_64 else []
    (count,) = struct.unpack_from(">I", data, 4)
    out = []
    for i in range(count):
        at = 8 + i * FAT_MAGICS[magic]
        if magic == 0xCAFEBABE:
            _, _, offset, size, _ = struct.unpack_from(">iiIII", data, at)
        else:
            _, _, offset, size, _, _ = struct.unpack_from(">iiQQII", data, at)
        out.append(data[offset:offset + size])
    return out


def functions(image: bytes) -> tuple[bytes, list[tuple[int, str]]] | None:
    """(UUID, [(offset from __TEXT, name)]) of a thin 64-bit Mach-O."""
    magic, _, _, _, ncmds = struct.unpack_from("<IiiII", image, 0)
    if magic != MH_MAGIC_64:
        return None
    uuid = None
    text_vmaddr = None
    text_section = None
    text_end = None
    sections = 0
    symtab = None
    at = 32
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", image, at)
        if cmd == LC_UUID:
            uuid = image[at + 8:at + 24]
        elif cmd == LC_SEGMENT_64:
            segname = image[at + 8:at + 24].rstrip(b"\0")
            (vmaddr,) = struct.unpack_from("<Q", image, at + 24)
            (nsects,) = struct.unpack_from("<I", image, at + 64)
            if segname == b"__TEXT":
                text_vmaddr = vmaddr
            for s in range(nsects):
                sect = at + 72 + s * 80
                sections += 1
                if image[sect:sect + 16].rstrip(b"\0") == b"__text" and image[sect + 16:sect + 32].rstrip(b"\0") == b"__TEXT":
                    text_section = sections
                    sect_addr, sect_size = struct.unpack_from("<QQ", image, sect + 32)
                    text_end = sect_addr + sect_size
        elif cmd == LC_SYMTAB:
            symtab = struct.unpack_from("<IIII", image, at + 8)
        at += size
    if uuid is None or text_vmaddr is None or text_section is None or text_end is None or symtab is None:
        return None
    symoff, nsyms, stroff, strsize = symtab
    strings = image[stroff:stroff + strsize]
    found: dict[int, str] = {}
    for i in range(nsyms):
        strx, n_type, n_sect, _, value = struct.unpack_from("<IBBHQ", image, symoff + i * 16)
        if n_type & N_STAB or n_type & N_TYPE != N_SECT or n_sect != text_section:
            continue
        name = strings[strx:strings.index(b"\0", strx)].decode("utf-8", "replace")
        # Assembler temporaries name no function.
        if not name or name.startswith(("ltmp", "l_", "L")):
            continue
        # dladdr names drop the C prefix; so does the map.
        name = name[1:] if name.startswith("_") else name
        offset = value - text_vmaddr
        # Aliases at one address: the external (or first) name wins.
        if offset not in found or n_type & 0x01:
            found[offset] = name
    if found:
        # The end of __text: no function holds an address from here on.
        found[text_end - text_vmaddr] = ""
    return uuid, sorted(found.items())


def mapped_uuids(path: str) -> set[bytes]:
    """The slice UUIDs of an existing map file; empty when there is none."""
    try:
        with open(path, "rb") as f:
            blob = f.read()
    except OSError:
        return set()
    if blob[:8] != b"CMXSYM1\0" or len(blob) < 12:
        return set()
    (count,) = struct.unpack_from("<I", blob, 8)
    uuids, at = set(), 12
    for _ in range(count):
        if at + 20 > len(blob):
            return set()
        (size,) = struct.unpack_from("<I", blob, at + 16)
        uuids.add(blob[at:at + 16])
        at += 20 + size
    return uuids


def payload(symbols: list[tuple[int, str]]) -> bytes:
    body = bytearray(struct.pack("<I", len(symbols)))
    previous = 0
    for offset, _ in symbols:
        delta, previous = offset - previous, offset
        while True:
            byte = delta & 0x7F
            delta >>= 7
            body.append(byte | (0x80 if delta else 0))
            if not delta:
                break
    body += "\0".join(name for _, name in symbols).encode()
    compressor = zlib.compressobj(9, zlib.DEFLATED, -15)
    return compressor.compress(bytes(body)) + compressor.flush()


def main() -> int:
    executable, out = sys.argv[1], sys.argv[2]
    with open(executable, "rb") as f:
        data = f.read()
    found = [t for t in (functions(s) for s in slices(data)) if t]
    if found and {uuid for uuid, _ in found} <= mapped_uuids(out):
        print(f"app symbol map: {out} already maps {executable}; unchanged")
        return 0
    tables = [t for t in found if t[1]]
    if not tables:
        print(f"app symbol map: no function names in {executable}; {out} unchanged")
        return 0
    blob = bytearray(b"CMXSYM1\0" + struct.pack("<I", len(tables)))
    count = 0
    for uuid, symbols in tables:
        packed = payload(symbols)
        blob += uuid + struct.pack("<I", len(packed)) + packed
        count += len(symbols) - 1  # not the end-of-__text entry
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(out) or ".", prefix=".cmux-symbols-")
    with os.fdopen(fd, "wb") as f:
        f.write(blob)
    os.chmod(tmp, 0o644)
    os.replace(tmp, out)
    print(f"app symbol map: {count} functions in {len(tables)} slice(s), {len(blob) / 1048576:.2f} MiB -> {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
