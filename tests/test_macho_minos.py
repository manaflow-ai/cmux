#!/usr/bin/env python3
"""Dry run of nightly-next-macos15-launch's "Check every bundled Mach-O loads on macOS 14".

The nightly runs `scripts/ci/macho_minos.py scan "$APP" --floor 14.0` on the
published DMG's app. The scanner is pure Python, so this runs that same command
on Linux against a fixture bundle of synthetic Mach-O files: a pull request
that breaks the scanner fails here, not after publication.
"""

from __future__ import annotations

import plistlib
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
SCANNER = ROOT / "scripts" / "ci" / "macho_minos.py"
NIGHTLY = ROOT / ".github" / "workflows" / "nightly.yml"
STEP = ("nightly-next-macos15-launch", "Check every bundled Mach-O loads on macOS 14")

ARM64, X86_64 = 0x0100000C, 0x01000007
EXECUTE, DYLIB = 2, 6
LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_BUILD_VERSION = 0x0C, 0x80000018, 0x32
SWIFTUI_CORE = "/System/Library/Frameworks/SwiftUICore.framework/Versions/A/SwiftUICore"
LIBSYSTEM = "/usr/lib/libSystem.B.dylib"


def version(text: str) -> int:
    major, minor = (int(part) for part in text.split("."))
    return major << 16 | minor << 8


def dylib_command(cmd: int, name: str) -> bytes:
    raw = name.encode() + b"\0"
    raw += b"\0" * (-(24 + len(raw)) % 8)
    return struct.pack("<IIIIII", cmd, 24 + len(raw), 24, 0, 0, 0) + raw


def thin(cpu: int = ARM64, minos: str | None = "14.0", strong=(LIBSYSTEM,), weak=(), filetype=EXECUTE) -> bytes:
    commands = []
    if minos is not None:
        commands.append(struct.pack("<IIIIII", LC_BUILD_VERSION, 24, 1, version(minos), version("26.0"), 0))
    commands += [dylib_command(LC_LOAD_DYLIB, name) for name in strong]
    commands += [dylib_command(LC_LOAD_WEAK_DYLIB, name) for name in weak]
    body = b"".join(commands)
    header = struct.pack("<IiiIIIII", 0xFEEDFACF, cpu, 0, filetype, len(commands), len(body), 0, 0)
    return header + body


def fat(*slices: bytes) -> bytes:
    offset, table, payload = 4096, b"", b""
    for item in slices:
        table += struct.pack(">iiIII", 0, 0, offset + len(payload), len(item), 12)
        payload += item + b"\0" * (-len(item) % 4096)
    head = struct.pack(">II", 0xCAFEBABE, len(slices)) + table
    return head + b"\0" * (offset - len(head)) + payload


class MachOMinosTests(unittest.TestCase):
    def setUp(self) -> None:
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.app = Path(temp.name) / "cmux NEXT.app"
        self.write("Contents/Info.plist", plistlib.dumps({"LSMinimumSystemVersion": "14.0"}))
        self.write("Contents/MacOS/cmux", fat(thin(ARM64), thin(X86_64)))
        self.write("Contents/Resources/bin/cmux", thin(weak=(SWIFTUI_CORE,)))
        self.write("Contents/Frameworks/Helper.dylib", thin(filetype=DYLIB))
        self.write("Contents/Resources/readme.txt", b"not a Mach-O")

    def write(self, relative: str, data: bytes) -> None:
        path = self.app / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)

    def scan(self) -> subprocess.CompletedProcess:
        # The nightly step's own command (test_nightly_step_runs_this_command pins it).
        return subprocess.run([sys.executable, str(SCANNER), "scan", str(self.app), "--floor", "14.0"],
                              capture_output=True, text=True, timeout=60)

    def assert_offender(self, needle: str) -> None:
        result = self.scan()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn(needle, result.stdout)

    def test_nightly_step_runs_this_command(self) -> None:
        workflow = yaml.safe_load(NIGHTLY.read_text(encoding="utf-8"))
        runs = [step.get("run", "") for step in workflow["jobs"][STEP[0]]["steps"] if step.get("name") == STEP[1]]
        self.assertEqual(runs, ['python3 scripts/ci/macho_minos.py scan "$APP" --floor 14.0'])

    def test_a_bundle_that_loads_on_14_passes(self) -> None:
        result = self.scan()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("3 Mach-O files", result.stdout)
        self.assertIn("every Mach-O loads on the floor", result.stdout)

    def test_a_slice_built_for_15_fails(self) -> None:
        self.write("Contents/MacOS/cmux", fat(thin(ARM64), thin(X86_64, minos="15.0")))
        self.assert_offender("Contents/MacOS/cmux [x86_64]: minos 15.0 > 14.0")

    def test_a_binary_without_a_deployment_target_fails(self) -> None:
        self.write("Contents/Resources/bin/optchat-chief", thin(minos=None))
        self.assert_offender("no deployment target")

    def test_a_strong_load_of_a_library_macos_14_lacks_fails(self) -> None:
        self.write("Contents/Resources/bin/cmux", thin(strong=(LIBSYSTEM, SWIFTUI_CORE)))
        self.assert_offender(f"strong load of {SWIFTUI_CORE} (macOS 15.0+)")

    def test_a_nested_bundle_that_asks_for_15_fails(self) -> None:
        nested = "Contents/Library/cmux Computer Use.app/Contents/Info.plist"
        self.write(nested, plistlib.dumps({"LSMinimumSystemVersion": "15.0"}))
        self.assert_offender(f"{nested}: LSMinimumSystemVersion 15.0 > 14.0")


if __name__ == "__main__":
    unittest.main()
