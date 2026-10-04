#!/usr/bin/env python3
"""The cmux-next checks job runs every check, then fails once with the list of reds.

The job used to stop at its first failing step. The god-files step failed on
cmux-tui Rust files, so the Swift god-type, concurrency, crash-safety, module
resource and string-table checks never ran and their reds stayed hidden. Each
check step now continues on error, and a final `if: always()` step reads every
check's `outcome` (its `conclusion` is success under continue-on-error) and
fails the job naming each red step. The cmux-tui Rust ratchet is its own step,
so it can never mask the Swift god-type check.
"""
from __future__ import annotations

import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/cmux-next.yml"
GODFILES = ROOT / "scripts/cmux-next/check-no-godfiles.sh"
JOB = "checks"


def steps() -> list[dict]:
    return yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"][JOB]["steps"]


def is_setup(step: dict) -> bool:
    """Checkout and toolchain steps: an action, not a check script."""
    return "uses" in step


class ChecksJobStructure(unittest.TestCase):
    def split(self) -> tuple[list[dict], list[dict], dict]:
        all_steps = steps()
        aggregate = all_steps[-1]
        body = all_steps[:-1]
        return [s for s in body if is_setup(s)], [s for s in body if not is_setup(s)], aggregate

    def test_setup_steps_stop_the_job(self):
        setup, _, _ = self.split()
        self.assertTrue(setup, "the job checks out the repository")
        for step in setup:
            with self.subTest(step=step.get("name", step["uses"])):
                self.assertNotIn("continue-on-error", step)

    def test_every_check_step_has_an_id_and_continues_on_error(self):
        _, checks, _ = self.split()
        self.assertGreaterEqual(len(checks), 6)
        ids = [step.get("id") for step in checks]
        self.assertEqual(len(ids), len(set(ids)), ids)
        for step in checks:
            with self.subTest(step=step["name"]):
                self.assertTrue(step.get("id"), "a check step needs an id for the aggregate to read")
                self.assertIs(step.get("continue-on-error"), True)
                self.assertNotIn("if", step, "a check that may skip itself hides its result")

    def test_aggregate_reads_every_check_outcome(self):
        _, checks, aggregate = self.split()
        self.assertEqual(aggregate.get("if"), "always()")
        self.assertNotIn("continue-on-error", aggregate)
        text = yaml.safe_dump(aggregate)
        self.assertNotIn(".conclusion", text, "continue-on-error makes every conclusion success")
        read = re.findall(r"steps\.([A-Za-z0-9_-]+)\.outcome", text)
        self.assertEqual(sorted(read), sorted(step["id"] for step in checks))
        # Each outcome is listed with its step's name, so the summary names the red step.
        outcomes = aggregate["env"]["OUTCOMES"]
        for step in checks:
            with self.subTest(step=step["name"]):
                self.assertIn("${{ steps.%s.outcome }}|%s\n" % (step["id"], step["name"]), outcomes)
        self.assertIn("GITHUB_STEP_SUMMARY", aggregate["run"])
        self.assertIn("exit 1", aggregate["run"])

    def run_aggregate(self, outcomes: str) -> subprocess.CompletedProcess:
        _, _, aggregate = self.split()
        with tempfile.NamedTemporaryFile() as summary:
            return subprocess.run(
                ["bash", "-c", aggregate["run"]],
                env={**os.environ, "OUTCOMES": outcomes, "GITHUB_STEP_SUMMARY": summary.name},
                capture_output=True,
                text=True,
            )

    def test_aggregate_fails_closed_on_an_empty_outcome(self):
        # An id typo renders `${{ steps.x.outcome }}` as empty; that check never ran.
        for outcomes in ("|Lint\n", "|Crash safety\nsuccess|Lint\n"):
            with self.subTest(outcomes=outcomes):
                result = self.run_aggregate(outcomes)
                self.assertEqual(result.returncode, 1, result.stdout)
                name = outcomes.split("\n")[0].split("|")[1]
                self.assertIn("- %s (not run)" % name, result.stdout)

    def test_aggregate_passes_when_every_check_succeeds(self):
        result = self.run_aggregate("success|Lint\nsuccess|Crash safety\n")
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_rust_ratchet_is_its_own_step(self):
        _, checks, _ = self.split()
        godfile_runs = [step["run"] for step in checks if "check-no-godfiles.sh" in step["run"]]
        self.assertEqual(len(godfile_runs), 2, godfile_runs)
        self.assertEqual(sum("--only swift" in run for run in godfile_runs), 1, godfile_runs)
        self.assertEqual(sum("--only rust" in run for run in godfile_runs), 1, godfile_runs)


class GodfileScopes(unittest.TestCase):
    """`--only swift` and `--only rust` each check their half, at unchanged budgets."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        repo = Path(cls.tmp.name)
        package = repo / "Packages/macOS/CmuxNext"
        (package / "Sources/Fixture").mkdir(parents=True)
        (package / "Tests").mkdir()
        # A 401-line Swift file (limit 400) and a 1001-line Swift type (limit 1000).
        (package / "Sources/Fixture/Wide.swift").write_text("let wide = 0\n" * 401)
        body = "".join(f"    let field{i} = {i}\n" for i in range(997))
        (package / "Sources/Fixture/Huge.swift").write_text("struct Huge {\n" + body + "}\n")
        (package / "Sources/Fixture/HugeMore.swift").write_text("extension Huge {\n}\n")
        rust = repo / "cmux-tui/crates/fixture/src"
        rust.mkdir(parents=True)
        # Rust budgets: 1000 lines, 60 fns; tests 1500 lines, 120 fns.
        (rust / "long.rs").write_text("// x\n" * 1001)
        (rust / "at_budget.rs").write_text("// x\n" * 1000)
        (rust / "many_fns.rs").write_text("fn f() {}\n" * 61)
        (rust / "tests.rs").write_text("fn t() {}\n" * 120 + "// x\n" * 1380)
        git = ["git", "-C", str(repo), "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"]
        subprocess.run([*git, "init", "-q"], check=True)
        subprocess.run([*git, "add", "."], check=True)
        subprocess.run([*git, "commit", "-qm", "fixture"], check=True)
        cls.package = package

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def run_check(self, *args: str) -> subprocess.CompletedProcess:
        env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
        return subprocess.run(["bash", str(GODFILES), *args, str(self.package)],
                              capture_output=True, text=True, env=env, timeout=120)

    def test_swift_scope_reports_only_swift(self):
        result = self.run_check("--only", "swift")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("Wide.swift has 401 lines (limit 400)", result.stdout)
        self.assertIn("type Fixture/Huge spans 1001 lines", result.stdout)
        self.assertNotIn("cmux-tui/", result.stdout)

    def test_rust_scope_reports_only_rust_at_unchanged_budgets(self):
        result = self.run_check("--only", "rust")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertNotIn(".swift", result.stdout)
        self.assertNotIn("god type", result.stdout)
        self.assertIn("long.rs has 1001 lines, 0 fns (limit 1000 lines, 60 fns", result.stdout)
        self.assertIn("many_fns.rs has 61 lines, 61 fns (limit 1000 lines, 60 fns", result.stdout)
        self.assertNotIn("at_budget.rs", result.stdout)
        self.assertNotIn("fixture/src/tests.rs", result.stdout)
        # Baseline entries of the other half are not reported as gone.
        self.assertNotIn("swift-type", result.stdout)

    def test_unscoped_run_still_checks_both(self):
        result = self.run_check()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("Wide.swift", result.stdout)
        self.assertIn("long.rs", result.stdout)

    def test_scope_cannot_rewrite_the_baseline(self):
        # A scoped baseline rewrite would drop the other half's entries.
        result = self.run_check("--update-baseline", "--only", "rust")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--only", result.stdout + result.stderr)

    def test_unknown_scope_is_rejected(self):
        result = self.run_check("--only", "go")
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)


class PathRoutingStructure(unittest.TestCase):
    def test_path_route_gates_mac_jobs_and_keeps_webviews_on_one_compile(self):
        jobs = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]
        route = jobs["path_route"]
        self.assertIn("native", route["outputs"])
        self.assertIn("macos", route["outputs"])
        self.assertIn("needs.path_route.outputs.macos", jobs["macos-placement"]["if"])
        self.assertIn("needs.path_route.outputs.native", jobs["swift-test"]["if"])
        self.assertIn("needs.path_route.outputs.native", jobs["release-compile"]["if"])
        self.assertIn("needs.path_route.outputs.macos", jobs["cmux-scheme-compile"]["if"])
        route_script = route["steps"][-1]["run"]
        self.assertIn("webviews/*", route_script)
        self.assertIn("web/*", route_script)
        self.assertIn("Packages/macOS/CmuxNext/*", route_script)
        self.assertIn("Packages/*", route_script)


RESET_STALE_SUBMODULES = "scripts/ci/reset-stale-submodules.sh"


def can_run_on_owned_runner(job: dict) -> bool:
    """A runs-on that reads a repository variable can resolve to a mini (glaeda-*)."""
    return "vars." in str(job.get("runs-on", ""))


class ReusedWorkspaceSubmodules(unittest.TestCase):
    """A reused mini workspace keeps the previous job's submodule checkouts.

    actions/checkout with `submodules: false` moves the superproject but leaves
    ghostty at the last branch's commit, so pin-cmux-tui.sh fetch saw ` M ghostty`
    and refused the checkout (run 37198483749). Every such checkout on a job
    that can run on a mini is followed at once by the reset step.
    """

    def test_every_submodule_free_checkout_on_an_owned_runner_resets_submodules(self):
        jobs = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]
        checked = []
        for job_id, job in jobs.items():
            if not can_run_on_owned_runner(job):
                continue
            job_steps = job.get("steps", [])
            for index, step in enumerate(job_steps):
                if not str(step.get("uses", "")).startswith("actions/checkout@"):
                    continue
                if str(step.get("with", {}).get("submodules", False)).lower() in ("true", "recursive"):
                    continue
                checked.append(job_id)
                with self.subTest(job=job_id):
                    following = job_steps[index + 1] if index + 1 < len(job_steps) else {}
                    self.assertIn(RESET_STALE_SUBMODULES, following.get("run", ""),
                                  "the step after checkout must drop stale submodule checkouts")
        self.assertEqual(sorted(checked), ["cmux-scheme-compile", "release-compile", "swift-test"])


if __name__ == "__main__":
    unittest.main()
