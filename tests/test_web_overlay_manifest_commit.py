#!/usr/bin/env python3
"""web-overlay.sh install records the commit of the bundles it installs, never this checkout's HEAD.

An output root built elsewhere (another checkout, a PR's head, a fleet job) carries no record of
its commit, so `install DIR` used to stamp manifest.json with the HEAD of the checkout running the
script: the overlay then claimed a commit its files did not come from.
"""

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/cmux-next/web-overlay.sh"
PANE = "Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/Resources/agent-pane"


class WebOverlayManifestCommitTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="web-overlay-manifest-"))
        self.overlay = self.tmp / "overlay"
        self.env = {
            **os.environ,
            "HOME": str(self.tmp / "home"),
            "CMUX_NEXT_CONFIG_FILE": str(self.tmp / "config/cmux-next.json"),
            "CMUX_WEB_OVERLAY_DIR": str(self.overlay),
            "CMUX_WEB_SLOT_STATE_DIR": str(self.tmp / "state"),
        }

    def out_root(self, name: str) -> Path:
        root = self.tmp / name
        (root / PANE).mkdir(parents=True)
        (root / PANE / "index.html").write_text("<!doctype html>\n")
        return root

    def install(self, *args: str) -> dict:
        subprocess.run(["bash", str(SCRIPT), "install", *args], env=self.env, check=True, capture_output=True, text=True)
        return json.loads((self.overlay / "manifest.json").read_text())

    def test_an_unrecorded_output_root_is_unknown_not_this_checkout(self):
        head = subprocess.run(["git", "-C", str(ROOT), "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
        manifest = self.install(str(self.out_root("built-elsewhere")))
        self.assertEqual(manifest["commit"], "unknown")
        self.assertNotEqual(manifest["commit"], head)

    def test_commit_flag_names_the_source(self):
        sha = "0123456789abcdef0123456789abcdef01234567"
        manifest = self.install(str(self.out_root("flagged")), "--commit", sha)
        self.assertEqual(manifest["commit"], sha)

    def test_a_recorded_output_root_keeps_its_commit(self):
        root = self.out_root("recorded")
        (root / ".web-overlay-source").write_text("fedcba9876543210fedcba9876543210fedcba98-dirty\n")
        manifest = self.install(str(root))
        self.assertEqual(manifest["commit"], "fedcba9876543210fedcba9876543210fedcba98-dirty")


if __name__ == "__main__":
    unittest.main()
