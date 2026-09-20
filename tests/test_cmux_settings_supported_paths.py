#!/usr/bin/env python3
"""Exercise settings path validation in checkout and installed skill layouts."""

import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
SKILL_ROOT = REPO_ROOT / "skills" / "cmux-settings"


class SupportedPathsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="cmux-settings-paths-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.config = self.root / "cmux.json"

    def helper(self, layout, *, reference=True):
        root = self.root / layout
        skill = root / "skills" / "cmux-settings"
        script = skill / "scripts" / "cmux-settings"
        script.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(SKILL_ROOT / "scripts" / "cmux-settings", script)
        shutil.copyfile(SKILL_ROOT / "SKILL.md", skill / "SKILL.md")
        if reference:
            (skill / "references").mkdir(exist_ok=True)
            shutil.copyfile(
                SKILL_ROOT / "references" / "all-keys.md",
                skill / "references" / "all-keys.md",
            )
        if layout == "checkout":
            (root / "Sources").mkdir(exist_ok=True)
            shutil.copyfile(
                REPO_ROOT / "Sources" / "CmuxSettingsJSONPathSupport.swift",
                root / "Sources" / "CmuxSettingsJSONPathSupport.swift",
            )
        return script

    def run_helper(self, script, command):
        return subprocess.run(
            [sys.executable, str(script), "--file", str(self.config), command],
            cwd=self.root,
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )

    def test_validate_accepts_catalog_sidebar_paths_in_both_layouts(self):
        self.config.write_text(json.dumps({
            "sidebar": {"showPorts": True, "showPullRequests": False, "showLog": True},
        }))
        for layout in ("checkout", "installed"):
            with self.subTest(layout=layout):
                result = self.run_helper(self.helper(layout), "validate")
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("all settings keys are recognized", result.stdout)
                self.assertEqual(result.stderr, "")

    def test_validate_rejects_unknown_sidebar_path_in_both_layouts(self):
        self.config.write_text(json.dumps({"sidebar": {"notARealSetting": True}}))
        for layout in ("checkout", "installed"):
            with self.subTest(layout=layout):
                result = self.run_helper(self.helper(layout), "validate")
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn("unknown settings keys:", result.stdout)
                self.assertIn("sidebar.notARealSetting", result.stdout)

    def test_list_supported_is_identical_in_both_layouts(self):
        checkout = self.run_helper(self.helper("checkout"), "list-supported")
        installed = self.run_helper(self.helper("installed"), "list-supported")
        for result in (checkout, installed):
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("sidebar.showPorts", result.stdout.splitlines())
        self.assertEqual(checkout.stdout, installed.stdout)

    def test_missing_reference_falls_back_to_checkout_source(self):
        script = self.helper("checkout", reference=False)
        self.config.write_text(json.dumps({"app": {"workspaceInheritWorkingDirectory": True}}))
        valid = self.run_helper(script, "validate")
        self.assertEqual(valid.returncode, 0, valid.stdout + valid.stderr)
        self.assertIn("all settings keys are recognized", valid.stdout)
        paths = self.run_helper(script, "list-supported")
        self.assertEqual(paths.returncode, 0, paths.stdout + paths.stderr)
        self.assertIn("app.workspaceInheritWorkingDirectory", paths.stdout.splitlines())
        self.config.write_text(json.dumps({"app": {"notARealSetting": True}}))
        invalid = self.run_helper(script, "validate")
        self.assertEqual(invalid.returncode, 1, invalid.stdout + invalid.stderr)
        self.assertIn("app.notARealSetting", invalid.stdout)


if __name__ == "__main__":
    unittest.main()
