#!/usr/bin/env python3
"""The iOS app's Settings.bundle Acknowledgements pane and the Apple libintl rule (D1/D2)."""

from __future__ import annotations

import hashlib
import importlib.util
import json
import plistlib
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
SPEC = importlib.util.spec_from_file_location("ios_notices", HERE / "ios_notices.py")
assert SPEC and SPEC.loader
ios = importlib.util.module_from_spec(SPEC)
sys.modules["ios_notices"] = ios
SPEC.loader.exec_module(ios)

PIN = "134477ce13b2c34d408e3e0dffafa4e8b78140635aa7d9d794ad2818e64883aa"
MACHO = b"\xcf\xfa\xed\xfe" + b"\0" * 60


class RepositoryTests(unittest.TestCase):
    def test_pane_link_set_and_exceptions_match_the_ghosttykit_pin(self) -> None:
        self.assertEqual(ios.check_repo(), [])

    def test_settings_bundle_root_links_the_pane(self) -> None:
        root = plistlib.loads((ios.SETTINGS / "Root.plist").read_bytes())
        panes = [item for item in root["PreferenceSpecifiers"] if item.get("Type") == "PSChildPaneSpecifier"]
        self.assertEqual([pane["File"] for pane in panes], ["Acknowledgements"])


class LibintlRuleTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        self.exceptions = self.tmp / "exceptions.json"
        self.exceptions.write_text(json.dumps({"pins": {PIN: "D1 pending"}}))
        self.with_intl = self.tmp / "with.a"
        self.with_intl.write_bytes(b"x" * 10 + b"libintl_dcigettext" + b"y")
        self.without = self.tmp / "without.a"
        self.without.write_bytes(b"clean")

    def test_libintl_fails_for_any_pin_without_an_exception(self) -> None:
        self.assertTrue(ios.libintl_errors("0" * 64, [self.with_intl], self.exceptions))

    def test_the_excepted_pin_passes_while_it_still_has_libintl(self) -> None:
        self.assertEqual(ios.libintl_errors(PIN, [self.with_intl, self.without], self.exceptions), [])

    def test_an_exception_whose_xcframework_lost_libintl_must_be_removed(self) -> None:
        self.assertTrue(ios.libintl_errors(PIN, [self.without], self.exceptions, ratchet=True))

    def test_a_clean_app_under_an_excepted_pin_passes(self) -> None:
        # The linker drops unused libintl from the app even when the xcframework has it.
        self.assertEqual(ios.libintl_errors(PIN, [self.without], self.exceptions), [])

    def test_an_entry_for_a_pin_not_in_use_is_not_checked(self) -> None:
        # A second entry (a pin that may land next) never fails while another pin is current.
        self.exceptions.write_text(json.dumps({"pins": {PIN: "D1 pending", "2" * 64: "temporary until D1"}}))
        self.assertEqual(ios.libintl_errors("3" * 64, [self.without], self.exceptions, ratchet=True), [])
        self.assertEqual(ios.libintl_errors("2" * 64, [self.with_intl], self.exceptions, ratchet=True), [])

    def test_a_stripped_binary_is_still_found(self) -> None:
        # `strip` removes libintl's symbol names from a linked binary; its string literal stays.
        stripped = self.tmp / "stripped"
        stripped.write_bytes(MACHO + b"\0GETTEXT_LOG_UNTRANSLATED\0")
        self.assertTrue(ios.libintl_errors("0" * 64, [stripped], self.exceptions))

    def test_the_repository_lists_the_current_and_the_next_pre_d1_pins(self) -> None:
        pins = json.loads(ios.EXCEPTIONS.read_text())["pins"]
        self.assertIn(PIN, pins)
        self.assertIn("736e8f05256b6453ef2dd05c58eff3088cfc1eda7ae748c041e877c8a66741ba", pins)

    def test_clean_binaries_pass_for_a_new_pin(self) -> None:
        self.assertEqual(ios.libintl_errors("1" * 64, [self.without], self.exceptions), [])


class BuiltAppTests(unittest.TestCase):
    def app(self) -> Path:
        app = Path(tempfile.mkdtemp()) / "cmux.app"
        shutil.copytree(ios.SETTINGS, app / "Settings.bundle")
        (app / "cmux").write_bytes(MACHO + b"libintl_dcigettext")  # today's pin still links libintl
        return app

    def test_accepts_the_committed_pane(self) -> None:
        self.assertEqual(ios.check_app(self.app()), [])

    def test_accepts_a_binary_plist_copy(self) -> None:
        app = self.app()
        pane = app / "Settings.bundle/Acknowledgements.plist"
        pane.write_bytes(plistlib.dumps(plistlib.loads(pane.read_bytes()), fmt=plistlib.FMT_BINARY))
        self.assertEqual(ios.check_app(app), [])

    def test_refuses_a_missing_pane(self) -> None:
        app = self.app()
        (app / "Settings.bundle/Acknowledgements.plist").unlink()
        self.assertTrue(ios.check_app(app))

    def test_refuses_an_old_pane(self) -> None:
        app = self.app()
        pane = app / "Settings.bundle/Acknowledgements.plist"
        data = plistlib.loads(pane.read_bytes())
        data["PreferenceSpecifiers"].pop(1)
        pane.write_bytes(plistlib.dumps(data))
        self.assertTrue(any("old pane" in error for error in ios.check_app(app)))

    def test_accepts_an_app_whose_linker_dropped_libintl(self) -> None:
        app = self.app()
        (app / "cmux").write_bytes(MACHO)
        self.assertEqual(ios.check_app(app), [])

    def test_refuses_missing_japanese_strings(self) -> None:
        app = self.app()
        shutil.rmtree(app / "Settings.bundle/ja.lproj")
        self.assertTrue(any("ja.lproj" in error for error in ios.check_app(app)))


class PaneTests(unittest.TestCase):
    def tree(self, revision: str) -> Path:
        tree = Path(tempfile.mkdtemp())
        files = {"zig-pkg/HZ/LICENSE": b"z2d MPL text\n", "zig-pkg/HF/LICENSE.TXT": b"FreeType text\n", "src/font/res/OFL.txt": b"OFL text\n"}
        entries = []
        for index, (source, data) in enumerate(files.items()):
            destination = f"ghostty-source/{index}"
            (tree / "ghostty-source").mkdir(exist_ok=True)
            (tree / destination).write_bytes(data)
            entries.append({"source": source, "package": "ghostty-next", "destination": destination, "sha256": hashlib.sha256(data).hexdigest()})
        manifest = {
            "ghostty_revision": revision,
            "unresolved_packages": 0,
            "zig_packages": {"HZ": {"dependency": "z2d", "url": "https://example.test/z2d.tar.gz"}, "HF": {"dependency": "freetype", "url": "u"}},
            "license_files": entries,
        }
        (tree / "SOURCE-MANIFEST.json").write_text(json.dumps(manifest))
        return tree

    def test_pane_has_the_linked_texts_and_the_z2d_source_offer(self) -> None:
        pin = {"url": "u", "sha256": PIN, "ghostty_revision": "a" * 40}
        links = {"dwarf_owners": ["zig-package:freetype", "zig-lib:std"], "zig_source_packages": ["z2d"], "zig_version": "0.16.0"}
        pane = ios.build_pane(self.tree("a" * 40), links, pin)
        titles = [group["Title"] for group in pane["PreferenceSpecifiers"]]
        self.assertIn("freetype (in Ghostty)", titles)
        self.assertIn("Ghostty (license, embedded fonts)", titles)
        z2d = next(group for group in pane["PreferenceSpecifiers"] if group["Title"] == "z2d (in Ghostty)")
        self.assertIn("z2d MPL text", z2d["FooterText"])
        self.assertIn("https://example.test/z2d.tar.gz", z2d["FooterText"])
        self.assertIn("Source Code Form", z2d["FooterText"])

    def test_refuses_a_tree_for_another_ghostty_revision(self) -> None:
        pin = {"url": "u", "sha256": PIN, "ghostty_revision": "a" * 40}
        with self.assertRaises(ios.NoticeError):
            ios.build_pane(self.tree("b" * 40), {"dwarf_owners": [], "zig_source_packages": [], "zig_version": "0.16.0"}, pin)

    def test_refuses_a_linked_package_without_a_collected_license(self) -> None:
        pin = {"url": "u", "sha256": PIN, "ghostty_revision": "a" * 40}
        links = {"dwarf_owners": ["zig-package:harfbuzz"], "zig_source_packages": [], "zig_version": "0.16.0"}
        with self.assertRaises(ios.NoticeError):
            ios.build_pane(self.tree("a" * 40), links, pin)


if __name__ == "__main__":
    unittest.main()
