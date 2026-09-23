#!/usr/bin/env python3
"""Exercise path discovery in checkout and installed layouts.

Semantic validation belongs to config doctor; it must not use an ambient CLI
or be replaced by the path inventory. See test_cli_config_doctor.py.
"""

import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[1]
SKILL_ROOT = REPO_ROOT / "skills" / "cmux-settings"
# This helper covers settings only, not structural configuration such as actions
# or ui. Object-valued settings are listed at their root, as the CLI permits
# descendant paths beneath these roots (for example shortcuts.bindings).
SETTINGS_SECTIONS = (
    "app", "terminal", "notifications", "sidebar", "sidebarAppearance",
    "workspaceColors", "automation", "browser", "shortcuts",
)


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
        shutil.copytree(SKILL_ROOT / "scripts", script.parent, dirs_exist_ok=True)
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
            check=False,
        )

    def test_lists_catalog_sidebar_paths_in_both_layouts(self):
        for layout in ("checkout", "installed"):
            with self.subTest(layout=layout):
                result = self.run_helper(self.helper(layout), "list-supported")
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                for path in ("sidebar.showPorts", "sidebar.showPullRequests", "sidebar.showLog"):
                    self.assertIn(path, result.stdout.splitlines())
                self.assertEqual(result.stderr, "")

    def test_does_not_list_unknown_sidebar_path_in_both_layouts(self):
        for layout in ("checkout", "installed"):
            with self.subTest(layout=layout):
                result = self.run_helper(self.helper(layout), "list-supported")
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertNotIn("sidebar.notARealSetting", result.stdout.splitlines())

    def test_list_supported_is_identical_in_both_layouts(self):
        checkout = self.run_helper(self.helper("checkout"), "list-supported")
        installed = self.run_helper(self.helper("installed"), "list-supported")
        for result in (checkout, installed):
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("sidebar.showPorts", result.stdout.splitlines())
        self.assertEqual(checkout.stdout, installed.stdout)

    def test_missing_reference_falls_back_to_checkout_source(self):
        script = self.helper("checkout", reference=False)
        result = self.run_helper(script, "list-supported")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("app.workspaceInheritWorkingDirectory", result.stdout.splitlines())
        self.assertNotIn("app.notARealSetting", result.stdout.splitlines())

    def test_list_supported_matches_schema_settings_paths(self):
        schema = json.loads((REPO_ROOT / "web" / "data" / "cmux.schema.json").read_text())
        expected = {
            f"{section}.{key}"
            for section in SETTINGS_SECTIONS
            for key in schema["properties"][section]["properties"]
        }
        result = self.run_helper(self.helper("installed"), "list-supported")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        actual = set(result.stdout.splitlines())
        missing = sorted(expected - actual)
        extra = sorted(actual - expected)
        self.assertFalse(
            missing or extra,
            f"Refresh skills/cmux-settings/references/all-keys.md from the schema. "
            f"Missing paths: {missing}; extra paths: {extra}",
        )

    def test_lists_paths_previously_only_in_checkout_source(self):
        for layout in ("checkout", "installed"):
            with self.subTest(layout=layout):
                result = self.run_helper(self.helper(layout), "list-supported")
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("terminal.copyOnSelect", result.stdout.splitlines())
                self.assertIn("browser.urlAllowlist", result.stdout.splitlines())
                self.assertEqual(result.stderr, "")


class ShortcutActionReferenceTests(unittest.TestCase):
    """The shortcut reference must list exactly the schema's action ids.

    skills/cmux-keyboard-shortcuts/SKILL.md tells agents to validate action ids
    against this reference, so an id the schema accepts but the file omits reads
    as invented. Drift here silently blocks a real binding.
    """

    def test_reference_lists_every_schema_action(self):
        schema = json.loads(
            (REPO_ROOT / "web" / "data" / "cmux.schema.json").read_text()
        )
        enum = schema["properties"]["shortcuts"]["properties"]["bindings"][
            "propertyNames"
        ]["enum"]
        reference = (
            REPO_ROOT
            / "skills"
            / "cmux-settings"
            / "references"
            / "shortcut-actions.md"
        ).read_text()
        listed = set(
            re.findall(r"^-\s+`shortcuts\.bindings\.([A-Za-z0-9-]+)`", reference, re.M)
        )
        self.assertEqual(
            sorted(set(enum) - listed),
            [],
            "shortcut-actions.md is missing action ids the schema accepts",
        )
        self.assertEqual(
            sorted(listed - set(enum)),
            [],
            "shortcut-actions.md lists action ids the schema rejects",
        )


if __name__ == "__main__":
    unittest.main()
