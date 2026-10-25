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

    CHECK = "scripts/cmux-next/check-settings-exports.sh"

    def step(self) -> str:
        """The one script every `settings` step of cmux-next.yml runs: the generated-files job's and
        the daemon-test job's folded copy (CMUX_NEXT_FOLD_GENERATED). Two inline copies would drift,
        and did: the fold's was still asking `defaults_guard.py check-stamp` (review of #23915)."""
        workflow = yaml.safe_load((ROOT / ".github/workflows/cmux-next.yml").read_text(encoding="utf-8"))
        steps = [step for job in workflow["jobs"].values() for step in job.get("steps", [])
                 if step.get("id") == "settings"]
        self.assertGreaterEqual(len(steps), 1)
        self.assertEqual({step["run"].strip() for step in steps}, {self.CHECK})
        return (ROOT / self.CHECK).read_text(encoding="utf-8")

    def test_the_check_runs_only_when_the_settings_sources_moved(self):
        script = self.step()
        self.assertIn('defaults_guard.py source-stamp --ref "$(git rev-parse HEAD^1)"', script)
        self.assertIn("defaults_guard.py source-stamp --ref HEAD", script)
        self.assertNotIn("generated_outputs.py caused", script)

    def test_the_check_exports_fresh_and_compares(self):
        script = self.step()
        self.assertIn("scripts/cmux-next/regenerate-settings-exports.sh", script)
        self.assertIn("s/^regenerated: //p", script)

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

    def run_step_on_merge(self, base_edit, pr_edit) -> subprocess.CompletedProcess:
        """The step on a merge commit: base_edit(repo) lands on the base without an export, then
        pr_edit(repo) is the pull request; the fake export writes the schema from A.swift's text."""
        tmp = tempfile.mkdtemp()
        self.addCleanup(subprocess.run, ["rm", "-rf", tmp])
        repo = Path(tmp) / "repo"
        repo.mkdir()
        run = lambda *args: subprocess.run(args, cwd=repo, capture_output=True, text=True, check=True)
        run("git", "init", "-q", "-b", "main")
        run("git", "config", "user.email", "t@t")
        run("git", "config", "user.name", "t")
        (repo / "scripts/ci").mkdir(parents=True)
        (repo / "scripts/ci/defaults_guard.py").write_text(
            (ROOT / "scripts/ci/defaults_guard.py").read_text(encoding="utf-8"))
        settings = repo / "Packages/macOS/CmuxNext/Sources/CmuxNextSettings"
        settings.mkdir(parents=True)
        (settings / "A.swift").write_text("v1\n")
        tests_dir = repo / "Packages/macOS/CmuxNext/Tests/CmuxNextSettingsTests"
        tests_dir.mkdir(parents=True)
        for name in ("ManagedPreferencesManifestTests.swift", "SettingsSchemaExportTests.swift"):
            (tests_dir / name).write_text("// t\n")
        (repo / "schemas/settings").mkdir(parents=True)
        (repo / "schemas/settings/settings-schema.json").write_text("v1\n")
        fake = repo / "scripts/cmux-next"
        fake.mkdir(parents=True)
        (fake / "regenerate-settings-exports.sh").write_text(
            "#!/bin/sh\nset -e\nf=schemas/settings/settings-schema.json\n"
            "cp Packages/macOS/CmuxNext/Sources/CmuxNextSettings/A.swift \"$f\"\n"
            "git diff --quiet -- \"$f\" || echo \"regenerated: $f\"\n")
        (fake / "regenerate-settings-exports.sh").chmod(0o755)
        run("git", "add", "-A")
        run("git", "commit", "-q", "-m", "base")
        base_edit(repo)
        run("git", "commit", "-q", "-am", "base change", "--allow-empty")
        run("git", "checkout", "-q", "-b", "pr", "HEAD~1")
        pr_edit(repo)
        run("git", "commit", "-q", "-am", "pr change")
        run("git", "checkout", "-q", "main")
        run("git", "merge", "-q", "--no-ff", "--no-edit", "pr")
        env = {"RUNNER_TEMP": tmp, "PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"}
        result = subprocess.run(["bash", "-c", self.step()], cwd=repo, env=env, capture_output=True, text=True)
        left = [line for line in run("git", "status", "--porcelain", "--untracked-files=no").stdout.splitlines()
                if not line.endswith("schemas/settings/settings-schema.json")]
        self.assertEqual(left, [], "the step leaves the settings sources as HEAD has them")
        return result

    @staticmethod
    def write(path: str, text: str):
        return lambda repo: (repo / path).write_text(text)

    def test_base_export_lag_is_a_warning_for_a_pr_that_touches_another_settings_source(self):
        result = self.run_step_on_merge(
            self.write("Packages/macOS/CmuxNext/Sources/CmuxNextSettings/A.swift", "v2\n"),
            self.write("Packages/macOS/CmuxNext/Tests/CmuxNextSettingsTests/SettingsSchemaExportTests.swift", "// t2\n"))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("::warning", result.stdout)

    def test_a_pr_settings_change_without_its_export_fails_over_base_lag(self):
        result = self.run_step_on_merge(
            lambda repo: None, self.write("Packages/macOS/CmuxNext/Sources/CmuxNextSettings/A.swift", "v3\n"))
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("settings-schema.json", result.stdout)

    def test_a_pr_that_edits_an_export_to_a_stale_value_fails(self):
        result = self.run_step_on_merge(
            self.write("Packages/macOS/CmuxNext/Sources/CmuxNextSettings/A.swift", "v2\n"),
            self.write("schemas/settings/settings-schema.json", "hand edit\n"))
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)

if __name__ == "__main__":
    unittest.main()
