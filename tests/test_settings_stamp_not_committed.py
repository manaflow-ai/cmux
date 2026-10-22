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
    """The generated files job exports the settings fresh only when the event changed the settings
    sources (their derived stamps at HEAD^1 and HEAD differ), and fails when the committed copies
    differ. Any other event leaves exports the base left stale to the base autofix: a PR that only
    touched other Swift must not go red for the base's staleness (review of #23915)."""

    def step(self) -> str:
        workflow = yaml.safe_load((ROOT / ".github/workflows/cmux-next.yml").read_text(encoding="utf-8"))
        steps = [step for job in workflow["jobs"].values() for step in job.get("steps", [])
                 if step.get("id") == "settings"]
        self.assertEqual(len(steps), 1)
        return steps[0]["run"]

    def test_the_check_runs_only_when_the_settings_sources_moved(self):
        script = self.step()
        self.assertIn('defaults_guard.py source-stamp --ref "$(git rev-parse HEAD^1)"', script)
        self.assertIn("defaults_guard.py source-stamp --ref HEAD", script)
        self.assertNotIn("generated_outputs.py caused", script)

    def test_the_check_exports_fresh_and_compares(self):
        script = self.step()
        self.assertIn("scripts/cmux-next/regenerate-settings-exports.sh", script)
        self.assertIn("grep -q '^regenerated: '", script)

    def test_an_unchanged_source_stamp_exports_nothing(self):
        """Run the step's own gate in a repository where HEAD changed only non-settings Swift."""
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            run = lambda *args: subprocess.run(args, cwd=repo, capture_output=True, text=True, check=True)
            run("git", "init", "-q", "-b", "main")
            run("git", "config", "user.email", "t@t")
            run("git", "config", "user.name", "t")
            (repo / "scripts/ci").mkdir(parents=True)
            (repo / "scripts/ci/defaults_guard.py").write_text(
                (ROOT / "scripts/ci/defaults_guard.py").read_text(encoding="utf-8"))
            settings = repo / "Packages/macOS/CmuxNext/Sources/CmuxNextSettings"
            settings.mkdir(parents=True)
            (settings / "A.swift").write_text("// a\n")
            tests_dir = repo / "Packages/macOS/CmuxNext/Tests/CmuxNextSettingsTests"
            tests_dir.mkdir(parents=True)
            for name in ("ManagedPreferencesManifestTests.swift", "SettingsSchemaExportTests.swift"):
                (tests_dir / name).write_text("// t\n")
            other = repo / "Packages/macOS/CmuxNext/Sources/CmuxNextApp"
            other.mkdir(parents=True)
            (other / "B.swift").write_text("// b\n")
            run("git", "add", "-A")
            run("git", "commit", "-q", "-m", "base")
            (other / "B.swift").write_text("// b, edited\n")
            run("git", "commit", "-q", "-am", "other swift")
            fake = repo / "scripts/cmux-next"
            fake.mkdir(parents=True)
            (fake / "regenerate-settings-exports.sh").write_text("#!/bin/sh\necho EXPORTED\n")
            (fake / "regenerate-settings-exports.sh").chmod(0o755)
            env = {"RUNNER_TEMP": tmp, "PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"}
            result = subprocess.run(["bash", "-c", self.step()], cwd=repo, env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertNotIn("EXPORTED", result.stdout)
            (settings / "A.swift").write_text("// a, edited\n")
            run("git", "commit", "-q", "-am", "settings swift")
            result = subprocess.run(["bash", "-c", self.step()], cwd=repo, env=env, capture_output=True, text=True)
            self.assertIn("EXPORTED", result.stdout)
            # An event that changes an export with the sources unchanged (a merge that kept older exports
            # while taking the base's sources) is checked too: the stamp alone would let it through.
            schema = repo / "schemas/settings"
            schema.mkdir(parents=True)
            (schema / "settings-schema.json").write_text("{}\n")
            run("git", "add", "-A")
            run("git", "commit", "-q", "-m", "an older export")
            result = subprocess.run(["bash", "-c", self.step()], cwd=repo, env=env, capture_output=True, text=True)
            self.assertIn("EXPORTED", result.stdout)

if __name__ == "__main__":
    unittest.main()
