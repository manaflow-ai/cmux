"""The periodic main full-suite run: skip logic, suite choice, issue sync, wiring."""

import importlib.util
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import textwrap
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/main_full_suite.py"
WORKFLOW = ROOT / ".github/workflows/ci-main-full-suite.yml"
SPEC = importlib.util.spec_from_file_location("main_full_suite", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)

HEAD = "a" * 40
OTHER = "b" * 40


def run(**overrides):
    base = {
        "id": 1,
        "event": "workflow_dispatch",
        "head_branch": "main",
        "path": ".github/workflows/ci.yml",
        "head_sha": HEAD,
        "status": "completed",
        "conclusion": "success",
        "created_at": "2026-09-22T00:00:00Z",
    }
    base.update(overrides)
    return base


class DispatchDecisionTests(unittest.TestCase):
    def test_untested_head_dispatches(self):
        self.assertTrue(MODULE.dispatch_decision([], HEAD)[0])
        self.assertTrue(MODULE.dispatch_decision([run(head_sha=OTHER)], HEAD)[0])

    def test_green_or_red_run_at_head_skips(self):
        for conclusion in ("success", "failure"):
            with self.subTest(conclusion=conclusion):
                self.assertFalse(MODULE.dispatch_decision([run(conclusion=conclusion)], HEAD)[0])

    def test_cancelled_or_errored_run_does_not_count(self):
        for conclusion in ("cancelled", "startup_failure", "skipped", None):
            with self.subTest(conclusion=conclusion):
                self.assertTrue(MODULE.dispatch_decision([run(conclusion=conclusion)], HEAD)[0])

    def test_queued_or_running_run_at_head_skips(self):
        for status in ("queued", "in_progress", "waiting", "pending"):
            with self.subTest(status=status):
                self.assertFalse(
                    MODULE.dispatch_decision([run(status=status, conclusion=None)], HEAD)[0]
                )

    def test_only_full_suite_ci_runs_on_main_count(self):
        # PR and merge-group runs are not the full suite on main, and another
        # workflow or branch at the same SHA proves nothing about CI on main.
        for overrides in (
            {"event": "pull_request"},
            {"event": "merge_group"},
            {"event": "schedule"},
            {"head_branch": "feature"},
            {"path": ".github/workflows/nightly.yml"},
        ):
            with self.subTest(overrides=overrides):
                self.assertTrue(MODULE.dispatch_decision([run(**overrides)], HEAD)[0])


class ReportTests(unittest.TestCase):
    def test_latest_tested_run_ignores_cancelled_and_running(self):
        runs = [
            run(id=1, conclusion="failure", created_at="2026-09-22T00:00:00Z"),
            run(id=2, conclusion="success", created_at="2026-09-22T03:00:00Z"),
            run(id=3, conclusion="cancelled", created_at="2026-09-22T06:00:00Z"),
            run(id=4, status="in_progress", conclusion=None, created_at="2026-09-22T09:00:00Z"),
            run(id=5, event="pull_request", conclusion="failure", created_at="2026-09-22T10:00:00Z"),
        ]
        self.assertEqual(MODULE.latest_tested_run(runs)["id"], 2)
        self.assertIsNone(MODULE.latest_tested_run([run(conclusion="cancelled")]))

    def test_issue_plan(self):
        plan = MODULE.issue_plan
        self.assertEqual(plan("failure", False, False), "open")
        self.assertEqual(plan("failure", True, False), "comment")
        # workflow_run and the scheduled sweep can both see the same red run.
        self.assertEqual(plan("failure", True, True), "none")
        self.assertEqual(plan("success", True, False), "close")
        self.assertEqual(plan("success", False, False), "none")
        self.assertEqual(plan("cancelled", True, False), "none")

    def test_failure_body_lists_failing_jobs_and_run(self):
        jobs = MODULE.failing_jobs([
            {"name": "macos / app-host (1)", "conclusion": "failure", "html_url": "https://x/1"},
            {"name": "macos / app-host (2)", "conclusion": "success", "html_url": "https://x/2"},
            {"name": "macos / packages", "conclusion": "timed_out", "html_url": "https://x/3"},
        ])
        body = MODULE.failure_body(run(html_url="https://run/1"), jobs)
        self.assertIn("https://run/1", body)
        self.assertIn(HEAD, body)
        self.assertIn("macos / app-host (1)", body)
        self.assertIn("macos / packages", body)
        self.assertNotIn("app-host (2)", body)


class SuiteSelectionTests(unittest.TestCase):
    def test_dispatched_ci_runs_the_full_suite_under_compile_only_policy(self):
        sys.path.insert(0, str(ROOT / "scripts/ci"))
        from choose_ci_suite import wants_full_suite

        for event in ("workflow_dispatch", "schedule"):
            self.assertTrue(wants_full_suite(event, "compile-only", []))
            self.assertTrue(wants_full_suite(event, "compile-only", None))


class WorkflowWiringTests(unittest.TestCase):
    text = WORKFLOW.read_text(encoding="utf-8")

    def test_schedule_and_manual_triggers(self):
        self.assertRegex(self.text, r'(?m)^  schedule:\n    - cron: "23 \*/3 \* \* \*"$')
        self.assertIn("\n  workflow_dispatch:\n", self.text)
        self.assertIn("workflows: [CI]", self.text)

    def test_dispatches_ci_on_main(self):
        self.assertIn("gh workflow run ci.yml --repo \"$GITHUB_REPOSITORY\" --ref main", self.text)
        self.assertIn("steps.gate.outputs.dispatch == 'true'", self.text)

    def test_branch_lookup_failure_still_dispatches(self):
        gate = self.text.split("        id: gate\n", 1)[1].split("      - name: Dispatch CI", 1)[0]
        script = textwrap.dedent(gate.split("        run: |\n", 1)[1])
        for lookup_exit in (1, 0):
            with self.subTest(lookup_exit=lookup_exit), tempfile.TemporaryDirectory() as directory:
                output = pathlib.Path(directory) / "output"
                gh = pathlib.Path(directory) / "gh"
                gh.write_text(f"#!/bin/sh\necho {HEAD}\nexit {lookup_exit}\n")
                gh.chmod(0o755)
                result = subprocess.run(
                    ["bash", "-euo", "pipefail", "-c", script],
                    cwd=ROOT,
                    env={**os.environ, "PATH": directory + os.pathsep + os.environ["PATH"],
                         "GITHUB_OUTPUT": str(output), "GITHUB_REPOSITORY": "test/repo",
                         "FORCE": "true"},
                    capture_output=True, text=True, timeout=10,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(output.read_text().strip(), "dispatch=true")
                self.assertIn("Could not read" if lookup_exit else "forced by", result.stdout)

    def test_never_cancels_in_progress(self):
        self.assertNotRegex(self.text, r"cancel-in-progress:\s*(true|\$\{\{)")
        self.assertEqual(len(re.findall(r"cancel-in-progress: false", self.text)), 2)

    def test_actions_are_pinned_by_sha(self):
        for ref in re.findall(r"uses:\s*(\S+)", self.text):
            self.assertRegex(ref, r"@[0-9a-f]{40}$")

    def test_report_only_follows_dispatched_ci_on_main(self):
        self.assertIn("github.event.workflow_run.event == 'workflow_dispatch'", self.text)
        self.assertIn("github.event.workflow_run.head_branch == 'main'", self.text)


if __name__ == "__main__":
    unittest.main()
