#!/usr/bin/env python3
"""scripts/cmux-next/swift-exports-key.py: the source key of the Swift exports.

The exports (settings schema, MDM manifests, action surfaces, links, daemon
capabilities, the CI target graph) are written by Swift tests on a Mac. A cache
keyed by this source key lets a job that only needs them restore them instead of
building the package. So the key must move with every input and Xcode pin, and
must not move with the exports themselves.
"""
from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
SCRIPT = REPO / "scripts/cmux-next/swift-exports-key.py"

FILES = {
    "Packages/macOS/CmuxNext/Package.swift": "// package\n",
    "Packages/macOS/CmuxNext/Sources/CmuxNextSettings/Settings.swift": "struct Settings {}\n",
    "Packages/macOS/CmuxNext/Tests/CmuxNextSettingsTests/SettingsSchemaExportTests.swift": "// test\n",
    "Packages/macOS/CmuxNext/ci-target-graph.json": "{}\n",
    "Packages/Shared/CmuxTheme/Sources/Theme.swift": "struct Theme {}\n",
    "plans/cmux-next/actions.md": "# actions\n",
    "plans/cmux-next/action-surfaces.json": "{}\n",
    "plans/cmux-next/links.json": "{}\n",
    "plans/cmux-next/daemon-capabilities.json": "{}\n",
    "schemas/settings/settings-schema.json": "{}\n",
    "docs/mdm/com.manaflow.cmux.json": "{}\n",
    "docs/mdm/com.manaflow.cmux.plist": "<plist/>\n",
    "docs/mdm/com.manaflow.cmux.intune.plist": "<plist/>\n",
    "docs/mdm/managed-preferences.md": "# mdm\n",
    "scripts/ci/xcode-pins.txt": "26.0\n",
    "webviews/src/main.tsx": "export {}\n",
    "Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/Resources/agent-pane/index.js": "0\n",
}


def run(root: Path, mode: str) -> str:
    return subprocess.run(
        [sys.executable, str(SCRIPT), str(root), mode], check=True, capture_output=True, text=True
    ).stdout.strip()


class SwiftExportsKey(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        for rel, text in FILES.items():
            path = self.root / rel
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        subprocess.run(["git", "-C", str(self.root), "add", "-A"], check=True)

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def edit(self, rel: str, text: str = "changed\n") -> None:
        (self.root / rel).write_text(text)

    def test_a_package_source_moves_the_key(self) -> None:
        before = run(self.root, "--source")
        self.edit("Packages/macOS/CmuxNext/Sources/CmuxNextSettings/Settings.swift")
        self.assertNotEqual(before, run(self.root, "--source"))

    def test_a_local_package_the_package_uses_moves_the_key(self) -> None:
        before = run(self.root, "--source")
        self.edit("Packages/Shared/CmuxTheme/Sources/Theme.swift")
        self.assertNotEqual(before, run(self.root, "--source"))

    def test_the_xcode_pin_moves_the_key(self) -> None:
        before = run(self.root, "--source")
        self.edit("scripts/ci/xcode-pins.txt", "26.1\n")
        self.assertNotEqual(before, run(self.root, "--source"))

    def test_a_new_untracked_source_moves_the_key(self) -> None:
        before = run(self.root, "--source")
        self.edit("Packages/macOS/CmuxNext/Sources/CmuxNextSettings/New.swift")
        self.assertNotEqual(before, run(self.root, "--source"))

    def test_the_exports_do_not_move_the_key(self) -> None:
        before = run(self.root, "--source")
        for rel in (
            "plans/cmux-next/action-surfaces.json",
            "plans/cmux-next/links.json",
            "plans/cmux-next/daemon-capabilities.json",
            "schemas/settings/settings-schema.json",
            "docs/mdm/com.manaflow.cmux.json",
            "docs/mdm/managed-preferences.md",
            "Packages/macOS/CmuxNext/ci-target-graph.json",
        ):
            self.edit(rel)
        self.assertEqual(before, run(self.root, "--source"))

    def test_a_web_source_and_its_bundle_do_not_move_the_key(self) -> None:
        before = run(self.root, "--source")
        self.edit("webviews/src/main.tsx")
        self.edit("Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/Resources/agent-pane/index.js")
        self.assertEqual(before, run(self.root, "--source"))

    def test_the_output_digest_moves_with_each_export(self) -> None:
        before = run(self.root, "--outputs")
        self.edit("docs/mdm/com.manaflow.cmux.intune.plist")
        after = run(self.root, "--outputs")
        self.assertNotEqual(before, after)
        (self.root / "plans/cmux-next/links.json").unlink()
        self.assertNotEqual(after, run(self.root, "--outputs"))

    def test_the_stamp_is_the_source_key_then_the_output_digest(self) -> None:
        self.assertEqual(
            run(self.root, "--stamp"), f"{run(self.root, '--source')} {run(self.root, '--outputs')}"
        )

    def test_list_names_every_export(self) -> None:
        listed = run(self.root, "--list").splitlines()
        for rel in FILES:
            exported = rel.startswith(("plans/cmux-next/", "schemas/", "docs/mdm/")) or rel.endswith(
                "ci-target-graph.json"
            )
            self.assertEqual(rel in listed, exported, rel)


if __name__ == "__main__":
    unittest.main()
