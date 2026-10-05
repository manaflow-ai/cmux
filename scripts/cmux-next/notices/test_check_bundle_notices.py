#!/usr/bin/env python3
# Copyright 2026 Manaflow, Inc.
# SPDX-License-Identifier: GPL-3.0-or-later
"""Tests for check_bundle_notices.py and bundle-map.json (stdlib unittest)."""

from __future__ import annotations

import hashlib
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

GHOSTTY_REVISION = "b" * 40
TREE = "Contents/Resources/ghostty-licenses"


def write_ghostty_license_tree(root: Path, revision: str = GHOSTTY_REVISION) -> None:
    """A minimal tree that verify-ghostty-license-bundle.py accepts."""
    entries = []
    for index in range(5):
        destination = f"pkg{index}/{index:012x}-LICENSE"
        content = f"license text {index}\n".encode()
        (root / destination).parent.mkdir(parents=True, exist_ok=True)
        (root / destination).write_bytes(content)
        entries.append({
            "bytes": len(content), "destination": destination, "package": f"pkg{index}",
            "sha256": hashlib.sha256(content).hexdigest(), "source": "LICENSE",
            "source_kind": "zig-cache",
        })
    manifest = {"schema": 1, "ghostty_revision": revision, "license_files": entries,
                "unresolved_packages": [], "zig_packages": {}}
    (root / "SOURCE-MANIFEST.json").write_text(json.dumps(manifest))


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

    def test_bundled_resources_need_their_notices(self) -> None:
        bundle_map = {**MAP, "resources": [{"path": "Contents/Resources/ghostty/themes", "notices": ["section:ghostty-themes"]}]}
        self.assertEqual(checker.check(self.app, bundle_map), [])
        themes = self.app / "Contents/Resources/ghostty/themes"
        themes.mkdir(parents=True)
        (themes / "Ubuntu").write_text("palette = 0=#2e3436\n")
        self.assertEqual(checker.check(self.app, bundle_map), ["Contents/Resources/ghostty/themes: missing notice section:ghostty-themes"])
        notices = self.app / "Contents/Resources/THIRD_PARTY_LICENSES.md"
        notices.write_text(notices.read_text() + "<!-- notices-section: ghostty-themes -->\n")
        self.assertEqual(checker.check(self.app, bundle_map), [])

    def tree_map(self) -> dict:
        return {**MAP, "resources": [{"path": TREE, "notices": [f"ghostty-license-tree:{TREE}"]}]}

    def test_bundled_ghostty_license_tree_must_verify(self) -> None:
        tree = self.app / TREE
        write_ghostty_license_tree(tree)
        self.assertEqual(checker.check(self.app, self.tree_map()), [])
        self.assertEqual(checker.check(self.app, self.tree_map(), ghostty_revision=GHOSTTY_REVISION), [])
        # The bundle must carry the tree of the Ghostty revision it was built from.
        errors = checker.check(self.app, self.tree_map(), ghostty_revision="c" * 40)
        self.assertEqual(len(errors), 1, errors)
        self.assertIn(f"{TREE}: missing notice ghostty-license-tree:{TREE}", errors[0])
        self.assertIn("revision differs", errors[0])
        # A changed text no longer matches the tree's manifest.
        (tree / "pkg0/000000000000-LICENSE").write_text("edited\n")
        errors = checker.check(self.app, self.tree_map())
        self.assertEqual(len(errors), 1, errors)
        self.assertIn("mismatch", errors[0])

    def test_bundled_ghostty_license_tree_needs_a_map_entry(self) -> None:
        write_ghostty_license_tree(self.app / TREE)
        self.assertEqual(
            checker.check(self.app, MAP),
            [f"{TREE}: bundled, but no bundle-map.json resources entry covers it"],
        )

    def test_the_map_covers_the_ghostty_license_tree(self) -> None:
        bundle_map = json.loads((HERE / "bundle-map.json").read_text())
        entries = [e for e in bundle_map.get("resources", []) if e["path"] == TREE]
        self.assertEqual(len(entries), 1)
        self.assertIn(f"ghostty-license-tree:{TREE}", entries[0]["notices"])
        self.assertIn("section:manual-ghostty", entries[0]["notices"])

    def test_bin_cmux_needs_the_ghostty_notice(self) -> None:
        # bin/cmux links libghostty-vt (Ghostty MIT, vendored simdutf); its
        # Zig packages are checked by check_ghostty_vt_notices.py.
        bundle_map = json.loads((HERE / "bundle-map.json").read_text())
        [entry] = [e for e in bundle_map["entries"] if e["path"] == "Contents/Resources/bin/cmux"]
        self.assertIn("section:manual-ghostty", entry["notices"])
        [ssh] = [e for e in bundle_map["entries"] if e["path"] == "Contents/Resources/bin/cmux-tui-ssh/cmux-tui-*"]
        self.assertIn("section:manual-ghostty", ssh["notices"])

    def test_the_map_covers_bundled_ghostty_themes(self) -> None:
        bundle_map = json.loads((HERE / "bundle-map.json").read_text())
        paths = {entry["path"] for entry in bundle_map.get("resources", [])}
        self.assertIn("Contents/Resources/ghostty/themes", paths)

    def test_repository_notices_carry_every_section_that_the_map_names(self) -> None:
        bundle_map = json.loads((HERE / "bundle-map.json").read_text())
        needed = {n.split(":", 1)[1] for e in bundle_map["entries"] + bundle_map.get("resources", []) for n in e["notices"] if n.startswith("section:")}
        present = set(checker.MARKER.findall((ROOT / "THIRD_PARTY_LICENSES.md").read_text()))
        self.assertEqual(sorted(needed - present), [])

    def test_map_requirements_are_well_formed(self) -> None:
        bundle_map = json.loads((HERE / "bundle-map.json").read_text())
        for entry in bundle_map["entries"] + bundle_map.get("resources", []):
            self.assertTrue(entry["notices"], entry["path"])
            for need in entry["notices"]:
                self.assertRegex(need, r"^(first-party|section:[A-Za-z0-9._-]+|(file|ghostty-license-tree):Contents/.+)$")
            self.assertFalse(re.search(r"/Versions/[A-Z]/", entry["path"]), "match Versions with *, not a fixed letter")


if __name__ == "__main__":
    unittest.main()
