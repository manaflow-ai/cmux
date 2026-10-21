#!/usr/bin/env python3
"""Capture-only control methods are compiled out of release builds, not just hidden at runtime.

debug.chief_workspaces opens workspaces on the local Chief machine for a capture (the Chief's
sidebar group). A release build must not contain it: its file is wrapped in `#if DEBUG` as a whole,
and its one registration sits inside AppControl's `#if DEBUG` block.
"""
from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "Packages/macOS/CmuxNext/Sources/CmuxNextApp"
# Each capture-only control: its file and the type AppControl registers.
DEBUG_ONLY = {"Server/ChiefCaptureControl.swift": "ChiefCaptureControl"}


def debug_ranges(lines: list[str]) -> list[tuple[int, int]]:
    """The line ranges inside `#if DEBUG` … `#endif` (nested #if blocks counted)."""
    ranges, stack = [], []
    for number, line in enumerate(lines):
        directive = line.strip()
        if directive.startswith("#if"):
            stack.append((number, directive == "#if DEBUG"))
        elif directive.startswith("#endif") and stack:
            start, is_debug = stack.pop()
            if is_debug:
                ranges.append((start, number))
    return ranges


class DebugOnlyControls(unittest.TestCase):
    def test_the_whole_file_is_compiled_out_of_release(self):
        for relative in DEBUG_ONLY:
            with self.subTest(file=relative):
                lines = (APP / relative).read_text().splitlines()
                code = [i for i, line in enumerate(lines) if line.strip() and not line.strip().startswith("//")]
                self.assertEqual(lines[code[0]].strip(), "#if DEBUG", "the file must open with #if DEBUG")
                self.assertEqual(lines[code[-1]].strip(), "#endif", "the file must close with #endif")
                self.assertIn((code[0], code[-1]), debug_ranges(lines), "one #if DEBUG block must span the file")

    def test_every_registration_is_inside_a_debug_block(self):
        sources = list(APP.rglob("*.swift"))
        for type_name in DEBUG_ONLY.values():
            uses = re.compile(rf"\b{type_name}\.methods\(")
            found = 0
            for path in sources:
                lines = path.read_text().splitlines()
                ranges = debug_ranges(lines)
                for number, line in enumerate(lines):
                    if uses.search(line):
                        found += 1
                        with self.subTest(type=type_name, at=f"{path.relative_to(ROOT)}:{number + 1}"):
                            self.assertTrue(any(a < number < b for a, b in ranges), "registered outside #if DEBUG")
            self.assertGreater(found, 0, f"{type_name} is never registered")


if __name__ == "__main__":
    unittest.main()
