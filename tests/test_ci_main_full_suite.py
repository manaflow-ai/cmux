"""The continuous main full-suite run: skip logic, suite choice, issue sync, wiring."""

import importlib.util
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import textwrap
import unittest
from datetime import datetime, timezone

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
                    MODULE.dispatch_decision([run(status=status, conclusion=None)], HEAD, now=NOW)[0]
                )

    def test_a_stale_queued_run_at_head_does_not_hold_the_schedule(self):
        now = datetime(2026, 9, 22, 7, 0, tzinfo=timezone.utc)
        stuck = run(status="queued", conclusion=None, created_at="2026-09-22T00:00:00Z")
        self.assertTrue(MODULE.dispatch_decision([stuck], HEAD, now=now)[0])
        self.assertFalse(MODULE.dispatch_decision([stuck], HEAD, now=datetime(2026, 9, 22, 5, 0, tzinfo=timezone.utc))[0])

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


NOW = datetime(2026, 9, 22, 1, 0, tzinfo=timezone.utc)


def fake_gh(directory, body):
    gh = pathlib.Path(directory) / "gh"
    gh.write_text("#!/bin/sh\n" + body)
    gh.chmod(0o755)


def gate(directory, *extra):
    output = pathlib.Path(directory) / "output"
    result = subprocess.run(
        [sys.executable, str(SCRIPT), "--repo", "test/repo", "gate", "--head-sha", HEAD,
         "--github-output", str(output), *extra],
        env={**os.environ, "PATH": directory + os.pathsep + os.environ["PATH"]},
        capture_output=True, text=True, timeout=10,
    )
    return result, output.read_text().strip()


class GateTests(unittest.TestCase):
    def test_a_run_in_flight_for_any_commit_holds_the_next_dispatch(self):
        for status in ("queued", "in_progress", "waiting", "pending"):
            with self.subTest(status=status):
                busy = MODULE.in_flight_run([run(head_sha=OTHER, status=status, conclusion=None)], now=NOW)
                self.assertIsNotNone(busy)
        self.assertIsNone(MODULE.in_flight_run([run(head_sha=OTHER)], now=NOW))
        self.assertIsNone(MODULE.in_flight_run([], now=NOW))
        # Only full-suite CI runs on main hold it.
        for overrides in ({"event": "pull_request"}, {"head_branch": "feature"}, {"path": ".github/workflows/nightly.yml"}):
            with self.subTest(overrides=overrides):
                self.assertIsNone(MODULE.in_flight_run([run(status="in_progress", conclusion=None, **overrides)], now=NOW))

    def test_a_stale_in_flight_run_does_not_hold_forever(self):
        # A run GitHub never starts and cannot cancel must not stop every later
        # dispatch, the schedule backstop included.
        stuck = run(status="queued", conclusion=None, created_at="2026-09-21T18:59:59Z")
        fresh = run(status="queued", conclusion=None, created_at="2026-09-21T19:00:01Z")
        self.assertIsNone(MODULE.in_flight_run([stuck], now=NOW))
        self.assertIsNone(MODULE.in_flight_reason([stuck], now=NOW))
        self.assertIsNotNone(MODULE.in_flight_run([fresh], now=NOW))
        self.assertIn("still queued", MODULE.in_flight_reason([fresh], now=NOW))
        # An unreadable timestamp still holds: better one late run than a duplicate.
        self.assertIsNotNone(MODULE.in_flight_run([run(status="queued", conclusion=None, created_at=None)], now=NOW))

    def test_a_busy_main_holds_the_gate(self):
        busy = {**run(status="in_progress", conclusion=None, head_sha=OTHER), "created_at": "2999-01-01T00:00:00Z"}
        with tempfile.TemporaryDirectory() as directory:
            fake_gh(directory, f"cat <<'JSON'\n{json.dumps(busy)}\nJSON\n")
            result, output = gate(directory)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output, "dispatch=false")
        self.assertIn("still in_progress", result.stdout)

    def test_the_completed_run_at_head_does_not_redispatch_itself(self):
        # A run that ends cancelled on an idle main would otherwise loop,
        # and it must hold even when the run lookup fails.
        with tempfile.TemporaryDirectory() as directory:
            fake_gh(directory, "exit 1\n")
            result, output = gate(directory, "--completed-sha", HEAD)
            self.assertEqual(output, "dispatch=false")
            self.assertIn("has not moved", result.stdout)
            (pathlib.Path(directory) / "output").unlink()
            result, output = gate(directory, "--completed-sha", OTHER)
            self.assertEqual(output, "dispatch=true")
            self.assertIn("could not read earlier runs", result.stdout)


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

    def test_failure_body_carries_the_attribution_section(self):
        body = MODULE.failure_body(run(), [], "### New since `abc`\n\nrow\n")
        self.assertIn("### New since `abc`", body)
        self.assertIn("closes itself on the next green run", body.split("### New since", 1)[1])
        self.assertEqual(MODULE.read_extra_section(None), "")
        self.assertEqual(MODULE.read_extra_section("/nonexistent/new-failures.md"), "")


class SuiteSelectionTests(unittest.TestCase):
    def test_dispatched_ci_runs_the_full_suite_under_compile_only_policy(self):
        sys.path.insert(0, str(ROOT / "scripts/ci"))
        from choose_ci_suite import wants_full_suite

        for event in ("workflow_dispatch", "schedule"):
            self.assertTrue(wants_full_suite(event, "compile-only", []))
            self.assertTrue(wants_full_suite(event, "compile-only", None))


class WorkflowWiringTests(unittest.TestCase):
    text = WORKFLOW.read_text(encoding="utf-8")

    def test_push_completion_schedule_and_manual_triggers(self):
        self.assertRegex(self.text, r'(?m)^  push:\n    branches: \[main\]$')
        self.assertRegex(self.text, r'(?m)^  schedule:\n    - cron: "23 \*/3 \* \* \*"$')
        self.assertIn("\n  workflow_dispatch:\n", self.text)
        self.assertIn("workflows: [CI]", self.text)

    def test_dispatches_ci_on_main(self):
        self.assertIn("gh workflow run ci.yml --repo \"$GITHUB_REPOSITORY\" --ref main", self.text)
        self.assertIn("steps.gate.outputs.dispatch == 'true'", self.text)

    def test_a_completed_full_suite_run_dispatches_the_next(self):
        dispatch = self.text.split("  dispatch:\n", 1)[1].split("\n  report:\n", 1)[0]
        condition = dispatch.split("    if: ", 1)[1].splitlines()[0]
        self.assertIn("github.event_name != 'workflow_run'", condition)
        self.assertIn("github.event.workflow_run.event == 'workflow_dispatch'", condition)
        self.assertIn("github.event.workflow_run.path == '.github/workflows/ci.yml'", condition)
        self.assertIn("COMPLETED_SHA: ${{ github.event.workflow_run.head_sha }}", dispatch)
        self.assertIn('--completed-sha "$COMPLETED_SHA"', dispatch)

    def dispatch_step(self, newest):
        step = self.text.split("      - name: Dispatch CI on main\n", 1)[1].split("\n  report:\n", 1)[0]
        script = textwrap.dedent(step.split("        run: |\n", 1)[1])
        with tempfile.TemporaryDirectory() as directory:
            listing = f'echo "{newest}"' if newest else "exit 1"
            fake_gh(directory, f'[ "$1" = workflow ] && exit 0\n{listing}\n')
            sleep = pathlib.Path(directory) / "sleep"
            sleep.write_text("#!/bin/sh\n")
            sleep.chmod(0o755)
            return subprocess.run(
                ["bash", "-euo", "pipefail", "-c", script],
                env={**os.environ, "PATH": directory + os.pathsep + os.environ["PATH"],
                     "GITHUB_REPOSITORY": "test/repo", "GITHUB_STEP_SUMMARY": os.devnull},
                capture_output=True, text=True, timeout=10,
            )

    def test_the_dispatch_step_waits_until_its_run_is_listed(self):
        self.assertEqual(self.dispatch_step("2999-01-01T00:00:00Z").returncode, 0)
        # An older run, or a lookup that keeps failing, never passes for the new one.
        for newest in ("2020-01-01T00:00:00Z", None):
            with self.subTest(newest=newest):
                result = self.dispatch_step(newest)
                self.assertEqual(result.returncode, 1)
                self.assertIn("was not listed", result.stdout)

    def test_branch_lookup_failure_still_dispatches(self):
        gate = self.text.split("        id: gate\n", 1)[1].split("      - name: Dispatch CI", 1)[0]
        script = textwrap.dedent(gate.split("        run: |\n", 1)[1])
        for lookup_exit in (1, 0):
            with self.subTest(lookup_exit=lookup_exit), tempfile.TemporaryDirectory() as directory:
                output, result = self.gate_step(script, directory, lookup_exit, FORCE="true")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(output.read_text().strip(), "dispatch=true")
                self.assertIn("Could not read" if lookup_exit else "forced by", result.stdout)
        # After a completed run, a failed lookup must not re-run that commit.
        with tempfile.TemporaryDirectory() as directory:
            output, result = self.gate_step(script, directory, 1, FORCE="false", COMPLETED_SHA=HEAD)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(output.read_text().strip(), "dispatch=false")

    @staticmethod
    def gate_step(script, directory, lookup_exit, **env):
        output = pathlib.Path(directory) / "output"
        gh = pathlib.Path(directory) / "gh"
        gh.write_text(f"#!/bin/sh\necho {HEAD}\nexit {lookup_exit}\n")
        gh.chmod(0o755)
        result = subprocess.run(
            ["bash", "-euo", "pipefail", "-c", script],
            cwd=ROOT,
            env={**os.environ, "PATH": directory + os.pathsep + os.environ["PATH"],
                 "GITHUB_OUTPUT": str(output), "GITHUB_REPOSITORY": "test/repo", **env},
            capture_output=True, text=True, timeout=10,
        )
        return output, result

    def test_never_cancels_in_progress(self):
        self.assertNotRegex(self.text, r"cancel-in-progress:\s*(true|\$\{\{)")
        self.assertEqual(len(re.findall(r"cancel-in-progress: false", self.text)), 2)

    def test_actions_are_pinned_by_sha(self):
        for ref in re.findall(r"uses:\s*(\S+)", self.text):
            self.assertRegex(ref, r"@[0-9a-f]{40}$")

    def test_report_only_follows_dispatched_ci_on_main(self):
        report = self.text.split("\n  report:\n", 1)[1]
        condition = report.split("    if: ", 1)[1].splitlines()[0]
        self.assertIn("github.event.workflow_run.event == 'workflow_dispatch'", condition)
        self.assertIn("github.event.workflow_run.head_branch == 'main'", condition)
        self.assertIn("github.event_name != 'push'", condition)


if __name__ == "__main__":
    unittest.main()
