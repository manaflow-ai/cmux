#!/usr/bin/env python3
# Copyright 2026 Manaflow, Inc.
# SPDX-License-Identifier: GPL-3.0-or-later
"""Tests for vt_link_graph.py's attribution of DWARF source paths (no zig)."""

from __future__ import annotations

from pathlib import Path
import sys
import unittest

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import vt_link_graph as graph  # noqa: E402

SRC, CACHE, LIB = "/w/src", "/w/cache", "/zig/lib"
UUCODE = "uucode-0.2.0-ZZjBPuuFVgC8YZ8eld4fOKsZANLIhTFMzULQxhkLi1C7"
HWY = "N-V-__8AAGmZhABbsPJLfbqrh6JTHsXhY6qCaLAQyx25e0XE"


class AttributeTest(unittest.TestCase):
    def test_paths_are_sorted_into_their_owners(self) -> None:
        result = graph.attribute([
            f"{SRC}/zig-pkg/{UUCODE}/src/x.zig",
            f"{CACHE}/p/{HWY}/hwy/a.cc",
            f"{CACHE}/p/{HWY}/hwy/b.h",
            f"{SRC}/src/terminal/Parser.zig",
            f"{SRC}/pkg/highway/bridge.cpp",
            f"{SRC}/vendor/glad/src/gl.c",
            f"{SRC}/.zig-cache/o/abc/options.zig",
            f"{CACHE}/b/0b1ecd183bf230efed890ea5f252abf9/builtin.zig",
            f"{LIB}/std/math.zig",
            f"{LIB}/compiler_rt/udivmod.zig",
            f"{LIB}/libc/include/any-macos-any/stdio.h",
            "/usr/include/elsewhere.h",
            "",
        ], SRC, CACHE, LIB)
        self.assertEqual(result["packages"], sorted([HWY, UUCODE]))
        self.assertEqual(result["package_files"], {HWY: 2, UUCODE: 1})
        self.assertEqual(result["vendored"], {"pkg/highway": 1, "vendor/glad": 1})
        self.assertEqual(result["ghostty_files"], 1)
        self.assertEqual(result["generated_files"], 2)
        self.assertEqual(result["zig_lib"], {"compiler_rt": 1, "libc": 1, "std": 1})
        self.assertEqual(result["unattributed"], ["/usr/include/elsewhere.h"])

    def test_zig_env_is_read_as_json_or_zon(self) -> None:
        self.assertEqual(graph.zig_env_fields('{"lib_dir": "/a", "version": "0.15.2"}')["lib_dir"], "/a")
        self.assertEqual(graph.zig_env_fields('.{\n    .lib_dir = "/b",\n    .version = "0.16.0",\n}\n')["lib_dir"], "/b")

    def test_codeview_file_checksum_names_are_read(self) -> None:
        # llvm-readobj --codeview output of zig's x86_64-windows-gnu archive.
        lines = [
            "      Filename: /w/src/zig-pkg/N-V-wuffs/release/c/wuffs-v0.4.c (0x0)",
            "    FilenameSegment [",
            "      Filename: /usr/local/lib/zig/lib/std/log.zig (0x120)",
        ]
        names = [m.group(1) for m in map(graph.CODEVIEW_FILE.match, lines) if m]
        self.assertEqual(names, ["/w/src/zig-pkg/N-V-wuffs/release/c/wuffs-v0.4.c", "/usr/local/lib/zig/lib/std/log.zig"])
        self.assertIn("x86_64-windows-gnu", graph.DEFAULT_TARGETS)


if __name__ == "__main__":
    unittest.main()
