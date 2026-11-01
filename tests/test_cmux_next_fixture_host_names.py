#!/usr/bin/env python3
"""scripts/cmux-next/check-fixture-host-names.py: fleet host names stay out of gallery fixtures."""

from __future__ import annotations

import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
SCRIPT = os.path.join(ROOT, "scripts/cmux-next/check-fixture-host-names.py")
SPEC = importlib.util.spec_from_file_location("check_fixture_host_names", SCRIPT)
check = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(check)


class FixtureHostNamesTest(unittest.TestCase):
    def hits(self, line: str) -> list[str]:
        return check.scan_file("webviews/src/x.gallery.ts", line)

    def test_each_host_name_shape_is_a_hit(self):
        for line in ('text: "air-blue"', 'label: "Huge Blue lease"', "built on cmux22", "cmux10s | 42%",
                     "http://someones-mac-mini:31415/v1", "ssh cmux-lawrence", "aws-m4pro-3", "glaeda wait"):
            with self.subTest(line=line):
                self.assertEqual(len(self.hits(line)), 1)

    def test_neutral_names_and_product_words_pass(self):
        for line in ('text: "studio-mac"', 'peers: ["lab-box", "Office Mac"]', "cmux #22231", "cmux-next",
                     "cmux-tui", "http://mini.tail1234.ts.net:7320", "a blue-green ring", "Mac mini (M4)"):
            with self.subTest(line=line):
                self.assertEqual(self.hits(line), [])

    def test_only_gallery_fixture_files_are_scanned(self):
        for rel in ("Packages/macOS/CmuxNext/Sources/CmuxNextSidebar/Views/WorkspaceHoverCardGallery.swift",
                    "Packages/macOS/CmuxNext/Sources/CmuxNextApp/HomeShowcase.swift",
                    "Packages/macOS/CmuxNext/Sources/CmuxNextSidebar/Model/SidebarNestedFixture.swift",
                    "webviews/src/a/b.gallery.tsx", "webviews/src/a/b.gallery.ts",
                    "webviews/src/gallery/fixtures/cases.md", "webviews/src/a/runBoardFixture.ts"):
            with self.subTest(rel=rel):
                self.assertTrue(check.is_fixture(rel))
        for rel in ("Packages/macOS/CmuxNext/Sources/CmuxNextApp/AgentTabs.swift", "webviews/src/a/b.tsx",
                    "Packages/macOS/CmuxNext/Tests/CmuxNextAppTests/AgentChatActionFixture.swift",
                    "Packages/Shared/CmuxMessagesLab/Sources/MessagesLabHome/Vendor/catalyst/Fixture.swift",
                    "webviews/test/fixtures/palette-eval/overlay.json", "scripts/gallery-compare.sh"):
            with self.subTest(rel=rel):
                self.assertFalse(check.is_fixture(rel))

    def test_the_script_names_the_line_and_fails(self):
        with tempfile.TemporaryDirectory() as root:
            path = os.path.join(root, "Packages/macOS/CmuxNext/Sources/Views/CardGallery.swift")
            os.makedirs(os.path.dirname(path))
            with open(path, "w", encoding="utf-8") as stream:
                stream.write('let ok = "studio-mac"\nlet machine = "cosmic-gray"\n')
            done = subprocess.run([sys.executable, "-I", SCRIPT, root], capture_output=True, text=True)
            self.assertEqual(done.returncode, 1)
            self.assertIn("Packages/macOS/CmuxNext/Sources/Views/CardGallery.swift:2: fleet host name", done.stdout)
            with open(path, "w", encoding="utf-8") as stream:
                stream.write('let machine = "build-box"\n')
            done = subprocess.run([sys.executable, "-I", SCRIPT, root], capture_output=True, text=True)
            self.assertEqual(done.returncode, 0, done.stdout + done.stderr)


if __name__ == "__main__":
    unittest.main()
