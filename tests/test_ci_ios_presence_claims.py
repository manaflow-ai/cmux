#!/usr/bin/env python3
"""scripts/ci/check-ios-presence-claims.py fails iPhone copy that says a Mac is asleep
(cmux#57792: the phone can't know that) and passes hedged lines and other subjects."""

from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/check-ios-presence-claims.py"
VIEW = "cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileWorkspaces/Thing.swift"


class PresenceClaimCheck(unittest.TestCase):
    def run_on(self, body: str, path: str = VIEW) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as tmp:
            f = Path(tmp) / path
            f.parent.mkdir(parents=True)
            f.write_text(body, encoding="utf-8")
            return subprocess.run(
                [sys.executable, str(SCRIPT), "cmux-next-ios/"], cwd=tmp, capture_output=True, text=True
            )

    def assertFails(self, body: str) -> None:
        r = self.run_on(body)
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("ASLEEP", r.stdout)

    def assertPasses(self, body: str, path: str = VIEW) -> None:
        r = self.run_on(body, path)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_the_regressed_title_fails(self) -> None:
        self.assertFails('EmptyState(title: "Your Macs are asleep", message: "Wake a Mac.")\n')

    def test_one_mac_and_a_named_mac_fail(self) -> None:
        self.assertFails('Text("Your Mac is asleep")\n')
        self.assertFails('Text("\\(displayName(mac)) is asleep")\n')
        self.assertFails('Text("Mac’s asleep")\n')

    def test_offline_copy_passes(self) -> None:
        self.assertPasses('EmptyState(title: "Your Macs are offline", message: "Open cmux on a Mac.")\n')

    def test_hedged_and_other_subjects_pass(self) -> None:
        self.assertPasses('Text("The Mac may be asleep, or cmux on it may have quit.")\n')
        self.assertPasses('Text("Mac\'s display is asleep")\n')
        self.assertPasses('Text(String(localized: "Computer is asleep"))\n')
        self.assertPasses('.accessibilityIdentifier("workspaces.empty.asleep")\n')

    def test_string_catalogs_and_rust_copy_fail(self) -> None:
        # Every screen: a word that lives in a catalog or in the phone's Rust core is copy too.
        catalog = "cmux-next-ios/App/Localizable.xcstrings"
        self.assertEqual(self.run_on('    "Your Macs are asleep" : {\n', catalog).returncode, 1)
        strings = "cmux-next-ios/App/en.lproj/Localizable.strings"
        self.assertEqual(self.run_on('"empty.title" = "Your Mac is asleep";\n', strings).returncode, 1)
        self.assertPasses('    "Your Macs are offline" : {\n', catalog)

    def test_rust_copy_fails_and_rust_tests_pass(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            core = Path(tmp) / "cmux-tui/crates/cmux-mobile-core/src/presence.rs"
            core.parent.mkdir(parents=True)
            core.write_text('pub const TITLE: &str = "Your Mac is asleep";\n', encoding="utf-8")
            test = Path(tmp) / "cmux-tui/crates/cmux-mobile-core/tests/presence.rs"
            test.parent.mkdir(parents=True)
            test.write_text('assert_eq!(t, "Your Mac is asleep");\n', encoding="utf-8")
            r = subprocess.run([sys.executable, str(SCRIPT)], cwd=tmp, capture_output=True, text=True)
            self.assertEqual(r.returncode, 1, r.stdout)
            self.assertIn("src/presence.rs", r.stdout)
            self.assertNotIn("tests/presence.rs", r.stdout)

    def test_comments_marks_and_tests_pass(self) -> None:
        self.assertPasses('// was "Your Macs are asleep"\n')
        self.assertPasses('// presence-ok: the Mac reported it sleeps\nText("Your Mac is asleep")\n')
        self.assertPasses(
            'Text("Your Mac is asleep")\n', "cmux-next-ios/CmuxMobileKit/Tests/XTests/ThingTests.swift"
        )


if __name__ == "__main__":
    unittest.main()
