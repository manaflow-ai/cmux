#!/usr/bin/env python3
"""Behavior tests for scripts/verify_app_libintl.py.

The fixtures are real (minimal) Mach-O files built here: a 64-bit Mach-O
header, one LC_SYMTAB load command, nlist_64 entries and a string table,
optionally wrapped in a fat (universal) container or an ar archive. They are
generated so the test runs on Linux CI without a macOS toolchain.
"""

from __future__ import annotations

import json
import os
import stat
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "verify_app_libintl.py"

GETTEXT_SHA = "c918503d593d70daf4844d175a13d816afacb667c06fba1ec9dcd5002c1518b7"
COPYING_SHA = "20e50fe7aae3e56378ebf0417d9de904f55a0e61e4df315333e632a4d3555d95"

N_SECT = 0x0E
N_EXT = 0x01
N_UNDF = 0x00


def macho(defined: list[str], undefined: list[str] = ()) -> bytes:
    """Minimal MH_MAGIC_64 object with defined (N_SECT) and undefined symbols."""
    strtab = b"\0"
    entries = []
    for name, ntype in [(n, N_SECT | N_EXT) for n in defined] + [(n, N_UNDF | N_EXT) for n in undefined]:
        entries.append((len(strtab), ntype))
        strtab += name.encode() + b"\0"
    header_size, symtab_cmd_size = 32, 24
    symoff = header_size + symtab_cmd_size
    stroff = symoff + 16 * len(entries)
    header = struct.pack("<IiiIIIII", 0xFEEDFACF, 0x0100000C, 0, 1, 1, symtab_cmd_size, 0, 0)
    symtab = struct.pack("<IIIIII", 0x2, symtab_cmd_size, symoff, len(entries), stroff, len(strtab))
    nlist = b"".join(struct.pack("<IBBHQ", strx, ntype, 1 if ntype & N_SECT else 0, 0, 0) for strx, ntype in entries)
    return header + symtab + nlist + strtab


def fat(*slices: bytes) -> bytes:
    header_end = (8 + 20 * len(slices) + 0xFFF) & ~0xFFF
    out = struct.pack(">II", 0xCAFEBABE, len(slices))
    bodies = b""
    for i, body in enumerate(slices):
        cputype = 0x0100000C if i else 0x01000007  # arm64, x86_64
        out += struct.pack(">iiIII", cputype, 0, header_end + len(bodies), len(body), 12)
        bodies += body
    return out.ljust(header_end, b"\0") + bodies


def ar(members: dict[str, bytes]) -> bytes:
    out = b"!<arch>\n"
    for name, body in members.items():
        payload = name.encode() + b"\0" * (-len(name) % 8)
        full = payload + body
        header = f"#1/{len(payload):<13}{0:<12}{0:<6}{0:<6}{'100644':<8}{len(full):<10}`\n".encode()
        out += header + full + (b"\n" if len(full) % 2 else b"")
    return out


class VerifyAppLibintlTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.app = self.root / "cmux.app"
        (self.app / "Contents" / "MacOS").mkdir(parents=True)
        (self.app / "Contents" / "Resources" / "bin").mkdir(parents=True)
        (self.app / "Contents" / "MacOS" / "cmux").write_bytes(fat(macho(["_main", "_ghostty_init"]), macho(["_main"])))
        (self.app / "Contents" / "Resources" / "LICENSE").write_text("not mach-o\n")
        self.bin = self.root / "bin"
        self.bin.mkdir()

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def fake_gh(self, assets: list[dict]) -> dict:
        gh = self.bin / "gh"
        payload = json.dumps({"tag_name": "v9.9.9", "assets": assets})
        gh.write_text(f"#!/bin/sh\ncat <<'JSON'\n{payload}\nJSON\n")
        gh.chmod(gh.stat().st_mode | stat.S_IEXEC)
        env = dict(os.environ)
        env["PATH"] = f"{self.bin}{os.pathsep}{env.get('PATH', '')}"
        return env

    def run_check(self, *extra: str, env: dict | None = None) -> subprocess.CompletedProcess:
        return subprocess.run(
            [sys.executable, str(SCRIPT), str(self.app), *extra],
            capture_output=True,
            text=True,
            env=env,
            check=False,
        )

    def test_clean_app_passes(self) -> None:
        # An undefined reference alone is not shipped libintl code.
        (self.app / "Contents" / "Resources" / "bin" / "ghostty").write_bytes(
            macho(["_main"], undefined=["_libintl_gettext"])
        )
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_universal_cli_with_libintl_fails(self) -> None:
        cli = self.app / "Contents" / "Resources" / "bin" / "ghostty"
        cli.write_bytes(fat(macho(["_main"]), macho(["_main", "__libintl_locale_name_canonicalize", "_libintl_dcigettext"])))
        result = self.run_check()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("Resources/bin/ghostty", result.stdout)
        self.assertIn("__libintl_locale_name_canonicalize", result.stdout)

    def test_static_archive_member_with_libintl_fails(self) -> None:
        lib = self.app / "Contents" / "Frameworks" / "libghostty.a"
        lib.parent.mkdir(parents=True)
        lib.write_bytes(ar({"foo.o": macho(["_foo"]), "dcigettext.o": macho(["_libintl_gettext"])}))
        result = self.run_check()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("(dcigettext.o)", result.stdout)

    def test_libintl_allowed_when_release_carries_source(self) -> None:
        (self.app / "Contents" / "Resources" / "bin" / "ghostty").write_bytes(macho(["_libintl_gettext"]))
        env = self.fake_gh([
            {"name": "cmux-macos.dmg", "digest": "sha256:" + "0" * 64},
            {"name": "gettext-0.24.tar.gz", "digest": f"sha256:{GETTEXT_SHA}"},
            {"name": "COPYING.LIB", "digest": f"sha256:{COPYING_SHA}"},
        ])
        result = self.run_check("--release-repo", "manaflow-ai/cmux", "--release-tag", "v9.9.9", env=env)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_libintl_rejected_when_release_source_missing_or_wrong(self) -> None:
        (self.app / "Contents" / "Resources" / "bin" / "ghostty").write_bytes(macho(["_libintl_gettext"]))
        for assets in (
            [{"name": "gettext-0.24.tar.gz", "digest": f"sha256:{GETTEXT_SHA}"}],
            [
                {"name": "gettext-0.24.tar.gz", "digest": "sha256:" + "1" * 64},
                {"name": "COPYING.LIB", "digest": f"sha256:{COPYING_SHA}"},
            ],
        ):
            env = self.fake_gh(assets)
            result = self.run_check("--release-repo", "manaflow-ai/cmux", "--release-tag", "v9.9.9", env=env)
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
