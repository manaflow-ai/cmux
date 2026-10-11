#!/usr/bin/env python3
"""scripts/cmux-next/browser-host-release.py: what a cmux-browser-host release ships.

Every archive must carry, beside bin/cmux-browser-host, the GPL-3.0-or-later
LICENSE of the repository and the committed third-party notices of the Linux
binary; the release notes must link the exact source commit.
"""

from __future__ import annotations

import importlib.util
import io
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/cmux-next/browser-host-release.py"
NOTICES = ROOT / "cmux-tui/build-support/notices/browser-host/THIRD_PARTY_LICENSES.linux.md"
SHA = "0123456789abcdef0123456789abcdef01234567"


def load():
    spec = importlib.util.spec_from_file_location("browser_host_release", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class PackageTest(unittest.TestCase):
    def test_archive_holds_binary_license_and_notices(self):
        release = load()
        with tempfile.TemporaryDirectory() as tmp:
            binary = Path(tmp) / "cmux-browser-host"
            binary.write_bytes(b"\x7fELF fake")
            archive = release.package(str(binary), "0.1.0", "x86_64-unknown-linux-gnu", str(Path(tmp) / "dist"))
            with tarfile.open(archive, "r:gz") as tar:
                names = sorted(tar.getnames())
                self.assertEqual(names, ["LICENSE", "THIRD_PARTY_LICENSES.md", "bin", "bin/cmux-browser-host"])
                self.assertEqual(tar.extractfile("bin/cmux-browser-host").read(), b"\x7fELF fake")
                self.assertEqual(tar.extractfile("LICENSE").read(), (ROOT / "LICENSE").read_bytes())
                self.assertEqual(tar.extractfile("THIRD_PARTY_LICENSES.md").read(), NOTICES.read_bytes())
                self.assertEqual(tar.getmember("bin/cmux-browser-host").mode, 0o755)
                self.assertEqual(tar.getmember("LICENSE").mode, 0o644)

    def test_license_is_the_gpl_text(self):
        text = (ROOT / "LICENSE").read_text(encoding="utf-8")
        self.assertIn("GPL-3.0-or-later", text)
        self.assertIn("GNU GENERAL PUBLIC LICENSE\n                       Version 3, 29 June 2007", text)

    def test_notices_cover_the_linux_binary(self):
        text = NOTICES.read_text(encoding="utf-8")
        for needle in (
            "bin/cmux-browser-host",
            "x86_64-unknown-linux-gnu",
            "aarch64-unknown-linux-gnu",
            "Rust standard library",
            "compiler_rt",
            "playwright-core 1.57.0",
            "acorn 8.16.0",
            "rquickjs-sys",
        ):
            self.assertIn(needle, text)

    def test_same_binary_gives_same_archive(self):
        release = load()
        with tempfile.TemporaryDirectory() as tmp:
            binary = Path(tmp) / "cmux-browser-host"
            binary.write_bytes(b"same")
            a = Path(release.package(str(binary), "0.1.0", "aarch64-unknown-linux-gnu", str(Path(tmp) / "a"))).read_bytes()
            b = Path(release.package(str(binary), "0.1.0", "aarch64-unknown-linux-gnu", str(Path(tmp) / "b"))).read_bytes()
            self.assertEqual(a, b)


class NotesTest(unittest.TestCase):
    def test_notes_link_the_source_commit(self):
        release = load()
        notes = release.notes("0.1.0", SHA, "manaflow-ai/cmux", "2.31")
        self.assertIn(f"https://github.com/manaflow-ai/cmux/commit/{SHA}", notes)
        self.assertIn("glibc >= 2.31", notes)
        self.assertIn("LICENSE", notes)
        self.assertIn("THIRD_PARTY_LICENSES.md", notes)

    def test_notes_refuse_a_short_sha(self):
        release = load()
        with self.assertRaises(SystemExit):
            release.notes("0.1.0", SHA[:12], "manaflow-ai/cmux", "2.31")


if __name__ == "__main__":
    unittest.main()
