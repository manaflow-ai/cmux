#!/usr/bin/env python3
"""The settings export stamp is derived, never committed (Leo 2026-10-21: "just generate and
don't commit"). It was one `sha256  path` line per CmuxNextSettings source, so every pull request
that touched a settings source changed it, it conflicted on nearly every base move, and the
red it caused needed a 30-minute Mac export to clear (#22674). `defaults_guard.py source-stamp
--ref REF` derives it for any commit; the committed schema is checked against a fresh export
(SettingsSchemaExportTests) instead.
"""

from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
STAMP = "schemas/settings-export/settings-schema.sources.sha256"


def git(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(["git", "-C", str(ROOT), *args], capture_output=True, text=True, check=False)


class SettingsStampIsNotCommitted(unittest.TestCase):
    def test_the_stamp_is_not_tracked(self):
        self.assertEqual(git("ls-files", "--", STAMP).stdout, "")

    def test_the_stamp_is_ignored(self):
        self.assertEqual(git("check-ignore", "-q", "--no-index", STAMP).returncode, 0)

    def test_no_script_workflow_or_test_reads_a_committed_stamp(self):
        # ci-target-graph.json is generated (base autofix rewrites it from the test sources).
        found = git("grep", "-l", "-F", STAMP, "--", ".github", "scripts", "tests", "Packages", ".gitattributes",
                    ":!Packages/macOS/CmuxNext/ci-target-graph.json",
                    ":!tests/test_settings_stamp_not_committed.py").stdout.split()
        self.assertEqual(found, [])

    def test_no_gate_asks_whether_a_committed_stamp_is_fresh(self):
        found = git("grep", "-l", "-e", "check-stamp", "--", ".github", "scripts",
                    ":!scripts/ci/cmux-tui-rust-check.sh").stdout.split()
        self.assertEqual(found, [])


class ExportsAreComparedWithAFreshExport(unittest.TestCase):
    """The generated files job exports the settings fresh when the event changed an export input,
    and fails when the committed copies differ; staleness the base left is the base autofix's."""

    def caused(self, *changed: str) -> int:
        with tempfile.NamedTemporaryFile("w", suffix=".txt") as handle:
            handle.write("\n".join(changed) + "\n")
            handle.flush()
            return subprocess.run([sys.executable, str(ROOT / "scripts/cmux-next/generated_outputs.py"), "caused",
                                   "schemas/settings/settings-schema.json", "--changed", handle.name],
                                  capture_output=True, text=True, check=False).returncode

    def test_a_settings_source_change_owns_the_export(self):
        self.assertEqual(self.caused("Packages/macOS/CmuxNext/Sources/CmuxNextSettings/TabsSetting.swift"), 0)

    def test_an_unrelated_change_leaves_the_export_to_the_base(self):
        self.assertEqual(self.caused("README.md", "schemas/settings/settings-schema.json"), 1)

    def test_the_generated_files_job_exports_fresh_and_compares(self):
        workflow = yaml.safe_load((ROOT / ".github/workflows/cmux-next.yml").read_text(encoding="utf-8"))
        steps = [step for job in workflow["jobs"].values() for step in job.get("steps", [])
                 if step.get("id") == "settings"]
        self.assertEqual(len(steps), 1)
        script = steps[0]["run"]
        self.assertIn("generated_outputs.py caused schemas/settings/settings-schema.json", script)
        self.assertIn("scripts/cmux-next/regenerate-settings-exports.sh", script)
        self.assertIn("grep -q '^regenerated: '", script)


if __name__ == "__main__":
    unittest.main()
