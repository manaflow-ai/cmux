#!/usr/bin/env python3
"""The release strip keeps cmux's function names in an app symbol map.

The cmux NEXT executable links with -no_exported_symbols, and the release
strip then removes every name from it. Before stripping,
scripts/strip-release-bundle.sh writes Contents/Resources/cmux-symbols.bin:
per slice, the LC_UUID and the __TEXT,__text functions as offsets from the
image's __TEXT segment, so hang records and exception traces still name app
frames. The map ends with an unnamed entry at the end of __text, so an
address past the last function (__stubs, __objc_stubs) names no function.
A second strip pass over the stripped executable keeps the map.
"""

from __future__ import annotations

import os
import struct
import subprocess
import tempfile
import unittest
import uuid
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
STRIP = ROOT / "scripts/strip-release-bundle.sh"
TEXT_VMADDR = 0x1_0000_0000
SLICE_UUID = uuid.UUID("0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0")


def macho(symbols: list[tuple[str, int, int, int]]) -> bytes:
    """A thin arm64 MH_EXECUTE: __TEXT (one __text section), LC_UUID, LC_SYMTAB.
    symbols: (name, n_type, n_sect, n_value)."""
    strtab = b"\x00"
    nlist = b""
    for name, n_type, n_sect, n_value in symbols:
        nlist += struct.pack("<IBBHQ", len(strtab), n_type, n_sect, 0, n_value)
        strtab += name.encode() + b"\x00"
    section = struct.pack("<16s16sQQIIIIIIII", b"__text", b"__TEXT", TEXT_VMADDR + 0x1000, 0x1000,
                          0x1000, 4, 0, 0, 0x80000400, 0, 0, 0)
    segment = struct.pack("<II16sQQQQiiII", 0x19, 72 + len(section), b"__TEXT", TEXT_VMADDR, 0x2000,
                          0, 0x2000, 5, 5, 1, 0) + section
    uuid_cmd = struct.pack("<II16s", 0x1B, 24, SLICE_UUID.bytes)
    commands = segment + uuid_cmd
    header_size = 32 + len(commands) + 24
    symoff = header_size
    stroff = symoff + len(nlist)
    symtab = struct.pack("<IIIIII", 0x2, 24, symoff, len(symbols), stroff, len(strtab))
    commands += symtab
    header = struct.pack("<IiiIIIII", 0xFEEDFACF, 0x0100000C, 0, 2, 3, len(commands), 0x200085, 0)
    return header + commands + nlist + strtab


def read_map(path: Path) -> dict[uuid.UUID, list[tuple[int, str]]]:
    data = path.read_bytes()
    assert data[:8] == b"CMXSYM1\x00", data[:8]
    (count,) = struct.unpack_from("<I", data, 8)
    pos = 12
    slices = {}
    for _ in range(count):
        key = uuid.UUID(bytes=data[pos:pos + 16])
        (size,) = struct.unpack_from("<I", data, pos + 16)
        payload = zlib.decompress(data[pos + 20:pos + 20 + size], -15)
        pos += 20 + size
        (n,) = struct.unpack_from("<I", payload, 0)
        cursor, offsets, offset = 4, [], 0
        for _ in range(n):
            shift = delta = 0
            while True:
                byte = payload[cursor]
                cursor += 1
                delta |= (byte & 0x7F) << shift
                shift += 7
                if byte < 0x80:
                    break
            offset += delta
            offsets.append(offset)
        names = payload[cursor:].decode().split("\x00")
        slices[key] = list(zip(offsets, names))
    return slices


def function_at(symbols: list[tuple[int, str]], offset: int) -> tuple[str, int] | None:
    """What AppSymbolMap.function(at:) answers: the last entry starting at or
    before offset, nil before the first or on an unnamed entry."""
    held = [(start, name) for start, name in symbols if start <= offset]
    if not held or not held[-1][1]:
        return None
    start, name = held[-1]
    return name, offset - start


class AppSymbolMapTest(unittest.TestCase):
    def strip(self, app: Path) -> None:
        tools = app.parent / "tools"
        tools.mkdir(exist_ok=True)
        (tools / "strip").write_text("#!/bin/sh\nexit 0\n")
        (tools / "file").write_text('#!/bin/sh\nprintf "%s: Mach-O 64-bit executable arm64\\n" "$1"\n')
        for tool in tools.iterdir():
            tool.chmod(0o755)
        env = dict(os.environ, CMUX_STRIP_TOOL=str(tools / "strip"), CMUX_FILE_TOOL=str(tools / "file"))
        subprocess.run(["bash", str(STRIP), str(app)], check=True, env=env, capture_output=True)

    def test_release_strip_writes_the_main_executable_symbol_map(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = Path(tmp) / "cmux.app"
            (app / "Contents/MacOS").mkdir(parents=True)
            (app / "Contents/Resources").mkdir()
            exe = app / "Contents/MacOS/cmux"
            exe.write_bytes(macho([
                ("_$s4cmux3AppV3runyyF", 0x0E, 1, TEXT_VMADDR + 0x1000),  # local, as -no_exported_symbols leaves it
                ("_main", 0x0F, 1, TEXT_VMADDR + 0x1400),                 # external
                ("ltmp0", 0x0E, 1, TEXT_VMADDR + 0x1000),                 # assembler temporary
                ("_OBJC_CLASS_$_Data", 0x0E, 2, TEXT_VMADDR + 0x1800),    # not in __TEXT,__text
                ("/src/App.swift", 0x64, 0, 0),                           # debug stab
            ]))
            exe.chmod(0o755)
            self.strip(app)
            symbols = read_map(app / "Contents/Resources/cmux-symbols.bin")
            # __text spans 0x1000..0x2000; the unnamed entry marks its end.
            self.assertEqual(symbols, {SLICE_UUID: [(0x1000, "$s4cmux3AppV3runyyF"), (0x1400, "main"), (0x2000, "")]})
            table = symbols[SLICE_UUID]
            self.assertEqual(function_at(table, 0x1fff), ("main", 0xbff))
            self.assertIsNone(function_at(table, 0x2000))  # a stub after __text
            self.assertIsNone(function_at(table, 0x2400))
            self.assertIsNone(function_at(table, 0xfff))

            # The second strip pass (nightly nn-strip-again) sees the stripped
            # executable, same UUID, where only __mh_execute_header is left in
            # __TEXT,__text. It keeps the map.
            before = (app / "Contents/Resources/cmux-symbols.bin").read_bytes()
            exe.write_bytes(macho([("__mh_execute_header", 0x0F, 1, TEXT_VMADDR)]))
            self.strip(app)
            self.assertEqual((app / "Contents/Resources/cmux-symbols.bin").read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
