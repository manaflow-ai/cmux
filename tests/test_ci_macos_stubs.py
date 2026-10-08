#!/usr/bin/env python3
"""The tools that let the macOS cross build on Linux link without an Apple SDK.

scripts/ci/macos_stubs.py writes framework link stubs from the imports of our
own Mac-built binaries and checks that the committed stubs still cover them.
scripts/ci/macho_weaken.py restores the weak linkage of Zig's compiler_rt
definitions in a Mach-O object. These tests run the tools on canned llvm
output and on a hand-built Mach-O object.
"""
from __future__ import annotations

import importlib.util
import struct
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def load(name: str, path: str):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


stubs = load("macos_stubs", "scripts/ci/macos_stubs.py")
weaken = load("macho_weaken", "scripts/ci/macho_weaken.py")

CF = "/System/Library/Frameworks/CoreFoundation.framework/Versions/A/CoreFoundation"
SEC = "/System/Library/Frameworks/Security.framework/Versions/A/Security"
DYLIBS = f"""bin:
\t{CF} (compatibility version 150.0.0, current version 5026.5.4)
\t{SEC} (compatibility version 1.0.0, current version 61901.120.67)
\t/usr/lib/libiconv.2.dylib (compatibility version 7.0.0, current version 7.0.0)
\t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1356.0.0)
"""
NM = """                 (undefined) external _CFRelease (from CoreFoundation)
                 (undefined) external _kCFAllocatorDefault (from CoreFoundation)
                 (undefined) external _SecTrustEvaluateWithError (from Security)
                 (undefined) weak external _OBJC_CLASS_$_NSObject (from CoreFoundation)
                 (undefined) external _write (from libSystem)
"""


class FakeTools:
    """Replace llvm-objdump and llvm-nm with canned output per binary."""

    def __init__(self, outputs: dict[str, tuple[str, str]]):
        self.outputs = outputs

    def __call__(self, tool: str, *args: str) -> str:
        dylibs, nm = self.outputs[args[-1]]
        return dylibs if tool.endswith("llvm-objdump") else nm


class StubTests(unittest.TestCase):
    def setUp(self) -> None:
        self.original_run = stubs._run
        stubs._run = FakeTools({"a": (DYLIBS, NM), "b": (DYLIBS, "                 (undefined) external _CFRetain (from CoreFoundation)\n")})
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)

    def tearDown(self) -> None:
        stubs._run = self.original_run
        self.tmp.cleanup()

    def test_imports_are_grouped_by_install_name_with_versions(self) -> None:
        libs = stubs.imports("a")
        self.assertEqual(libs[CF]["current"], "5026.5.4")
        self.assertEqual(libs[CF]["compat"], "150.0.0")
        self.assertEqual(libs[CF]["symbols"], {"_CFRelease", "_kCFAllocatorDefault", "_OBJC_CLASS_$_NSObject"})
        self.assertEqual(libs[SEC]["symbols"], {"_SecTrustEvaluateWithError"})
        self.assertEqual(libs["/usr/lib/libSystem.B.dylib"]["symbols"], {"_write"})

    def test_generate_writes_one_stub_per_framework_from_every_binary(self) -> None:
        self.assertEqual(stubs.cmd_generate(self.dir, ["a", "b"]), 0)
        self.assertEqual(sorted(p.name for p in self.dir.iterdir()), ["CoreFoundation.tbd", "Security.tbd"])
        text = (self.dir / "CoreFoundation.tbd").read_text()
        self.assertIn(f"install-name:    '{CF}'", text)
        self.assertIn("current-version: 5026.5.4", text)
        self.assertIn("compatibility-version: 150.0.0", text)
        symbols = [line.strip().strip("',") for line in text.splitlines() if line.strip().startswith("'_")]
        self.assertEqual(symbols, ["_CFRelease", "_CFRetain", "_OBJC_CLASS_$_NSObject", "_kCFAllocatorDefault"])

    def test_check_names_a_stub_that_lost_an_import(self) -> None:
        stubs.cmd_generate(self.dir, ["a"])
        self.assertEqual(stubs.cmd_check(self.dir, ["a"]), 0)
        self.assertEqual(stubs.cmd_check(self.dir, ["a", "b"]), 1)
        (self.dir / "Security.tbd").unlink()
        self.assertEqual(stubs.cmd_check(self.dir, ["a"]), 1)

    def test_install_puts_framework_stubs_where_the_linker_looks(self) -> None:
        stubs.cmd_generate(self.dir, ["a"])
        sysroot = self.dir / "sysroot"
        stubs.cmd_install(self.dir, sysroot)
        installed = sysroot / "System/Library/Frameworks/CoreFoundation.framework/CoreFoundation.tbd"
        self.assertEqual(installed.read_text(), (self.dir / "CoreFoundation.tbd").read_text())
        self.assertTrue((sysroot / "System/Library/Frameworks/Security.framework/Security.tbd").exists())

    def test_two_versions_of_one_framework_are_refused(self) -> None:
        stubs._run = FakeTools({"a": (DYLIBS, NM), "c": (DYLIBS.replace("5026.5.4", "4000.0.0"), NM)})
        with self.assertRaises(SystemExit):
            stubs.cmd_generate(self.dir, ["a", "c"])


def macho_object(symbols: list[tuple[int, int]]) -> bytearray:
    """A 64-bit Mach-O object with one LC_SYMTAB: (n_type, n_desc) per symbol."""
    header = struct.pack("<8I", 0xFEEDFACF, 0x0100000C, 0, 0x1, 1, 24, 0, 0)
    symoff = 32 + 24
    symtab_cmd = struct.pack("<6I", 0x2, 24, symoff, len(symbols), symoff + 16 * len(symbols), 1)
    table = b"".join(struct.pack("<IBBHQ", 0, n_type, 1, n_desc, 0) for n_type, n_desc in symbols)
    return bytearray(header + symtab_cmd + table + b"\0")


def descs(data: bytearray, count: int) -> list[int]:
    return [struct.unpack_from("<H", data, 56 + 16 * i + 6)[0] for i in range(count)]


class WeakenTests(unittest.TestCase):
    GLOBAL, LOCAL, UNDEFINED = 0x0F, 0x0E, 0x01  # N_SECT|N_EXT, N_SECT, N_UNDF|N_EXT

    def test_only_global_definitions_become_weak(self) -> None:
        data = macho_object([(self.GLOBAL, 0), (self.LOCAL, 0), (self.UNDEFINED, 0), (self.GLOBAL, 0x0080)])
        self.assertEqual(weaken.weaken(data), 1)
        self.assertEqual(descs(data, 4), [0x0080, 0, 0, 0x0080])
        self.assertEqual(weaken.weaken(data), 0)

    def test_a_linked_image_is_refused(self) -> None:
        data = macho_object([(self.GLOBAL, 0)])
        struct.pack_into("<I", data, 12, 0x2)  # MH_EXECUTE
        with self.assertRaises(SystemExit):
            weaken.weaken(data)


if __name__ == "__main__":
    unittest.main()
