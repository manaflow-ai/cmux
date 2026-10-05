#!/usr/bin/env python3
# Copyright 2026 Manaflow, Inc.
# SPDX-License-Identifier: GPL-3.0-or-later
"""Tests for check_bundle_notices.py and bundle-map.json (stdlib unittest)."""

from __future__ import annotations

import json
from pathlib import Path
import re
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
sys.path.insert(0, str(HERE))
import check_bundle_notices as checker  # noqa: E402

THIN = b"\xcf\xfa\xed\xfe\x0c\x00\x00\x01" + b"\0" * 24
FAT = b"\xca\xfe\xba\xbe\x00\x00\x00\x02" + b"\0" * 24
JAVA_CLASS = b"\xca\xfe\xba\xbe\x00\x00\x00\x41" + b"\0" * 24

MAP = {
    "entries": [
        {"path": "Contents/MacOS/app", "notices": ["first-party", "section:manual-x"]},
        {"path": "Contents/Frameworks/Lib.framework/*", "notices": ["file:Contents/Frameworks/Lib.framework/Resources/CREDITS.html"]},
    ]
}


class CheckBundleNoticesTest(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.app = Path(self._tmp.name) / "x.app"
        (self.app / "Contents/MacOS").mkdir(parents=True)
        (self.app / "Contents/Resources").mkdir(parents=True)
        (self.app / "Contents/MacOS/app").write_bytes(THIN)
        (self.app / "Contents/Resources/LICENSE").write_text("GPL\n")
        (self.app / "Contents/Resources/THIRD_PARTY_LICENSES.md").write_text("<!-- notices-section: manual-x -->\n## X\n")

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def test_mapped_binary_with_its_notices_passes(self) -> None:
        self.assertEqual(checker.check(self.app, MAP), [])

    def test_unmapped_binary_fails(self) -> None:
        (self.app / "Contents/Resources/helper").write_bytes(FAT)
        self.assertEqual(checker.check(self.app, MAP), ["Contents/Resources/helper: Mach-O that no bundle-map entry covers"])

    def test_non_macho_files_and_java_classes_are_ignored(self) -> None:
        (self.app / "Contents/Resources/script.sh").write_text("#!/bin/sh\n")
        (self.app / "Contents/Resources/Thing.class").write_bytes(JAVA_CLASS)
        self.assertEqual(checker.check(self.app, MAP), [])

    def test_missing_section_license_and_file_fail(self) -> None:
        (self.app / "Contents/Resources/THIRD_PARTY_LICENSES.md").write_text("## X\n")
        (self.app / "Contents/Resources/LICENSE").write_text("")
        fw = self.app / "Contents/Frameworks/Lib.framework/Versions/A"
        fw.mkdir(parents=True)
        (fw / "Lib").write_bytes(THIN)
        errors = checker.check(self.app, MAP)
        self.assertIn("Contents/MacOS/app: missing notice first-party", errors)
        self.assertIn("Contents/MacOS/app: missing notice section:manual-x", errors)
        self.assertIn("Contents/Frameworks/Lib.framework/Versions/A/Lib: missing notice file:Contents/Frameworks/Lib.framework/Resources/CREDITS.html", errors)

    def test_symlinked_framework_paths_are_checked_once(self) -> None:
        fw = self.app / "Contents/Frameworks/Lib.framework"
        (fw / "Versions/A/Resources").mkdir(parents=True)
        (fw / "Versions/A/Lib").write_bytes(THIN)
        (fw / "Versions/A/Resources/CREDITS.html").write_text("credits\n")
        (fw / "Versions/Current").symlink_to("A")
        (fw / "Lib").symlink_to("Versions/Current/Lib")
        (fw / "Resources").symlink_to("Versions/Current/Resources")
        self.assertEqual(checker.macho_files(self.app), ["Contents/Frameworks/Lib.framework/Versions/A/Lib", "Contents/MacOS/app"])
        self.assertEqual(checker.check(self.app, MAP), [])

    def test_repository_notices_carry_every_section_that_the_map_names(self) -> None:
        bundle_map = json.loads((HERE / "bundle-map.json").read_text())
        needed = {n.split(":", 1)[1] for e in bundle_map["entries"] for n in e["notices"] if n.startswith("section:")}
        present = set(checker.MARKER.findall((ROOT / "THIRD_PARTY_LICENSES.md").read_text()))
        self.assertEqual(sorted(needed - present), [])

    def test_map_requirements_are_well_formed(self) -> None:
        bundle_map = json.loads((HERE / "bundle-map.json").read_text())
        for entry in bundle_map["entries"]:
            self.assertTrue(entry["notices"], entry["path"])
            for need in entry["notices"]:
                self.assertRegex(need, r"^(first-party|section:[A-Za-z0-9._-]+|file:Contents/.+)$")
            self.assertFalse(re.search(r"/Versions/[A-Z]/", entry["path"]), "match Versions with *, not a fixed letter")


if __name__ == "__main__":
    unittest.main()
