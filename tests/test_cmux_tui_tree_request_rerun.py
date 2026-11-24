#!/usr/bin/env python3
"""A tree request re-runs only what it must: a coalesced run in full, a failed run's failed jobs, and stops at 3.

efficiency-scout, 2026-11-21 22:37Z: "Make re-runs go through the coalescing too, or cap automatic re-runs of these
legs." On 2026-11-21 cmux-tui-tree-request.yml re-ran failed runs in full, rebuilding legs that had passed, up to
attempt 4. 2026-11-23 and 11-24, while feat-cmux-next did not compile, attempts 2 and 3 rebuilt every leg and failed
on the same rustc error: a run whose build leg failed to compile is not re-run (compile-error).

Run: python3 tests/test_cmux_tui_tree_request_rerun.py
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "ci" / "cmux_tui_tree_request_rerun.py"
WORKFLOW = ROOT / ".github" / "workflows" / "cmux-tui-tree-request.yml"
sys.path.insert(0, str(SCRIPT.parent))
import cmux_tui_tree_request_rerun as rerun  # noqa: E402


class DecideTest(unittest.TestCase):
    def test_a_coalesced_run_reruns_in_full(self) -> None:
        # Its builds skipped and it succeeded: only a full re-run (attempt > 1 runs past the coalescing) builds it.
        for attempt in (1, 2, 5):
            self.assertEqual(rerun.decide(attempt, "success"), "full")

    def test_a_failed_run_reruns_only_its_failed_jobs(self) -> None:
        for conclusion in ("failure", "cancelled", "timed_out", "startup_failure"):
            for attempt in (1, 2):
                with self.subTest(conclusion=conclusion, attempt=attempt):
                    self.assertEqual(rerun.decide(attempt, conclusion), "failed-jobs")

    def test_three_failed_attempts_stop(self) -> None:
        for attempt in (3, 4, 17):
            self.assertEqual(rerun.decide(attempt, "failure"), "cap")
        self.assertEqual(rerun.MAX_ATTEMPTS, 3)

    def test_cli(self) -> None:
        out = subprocess.run([sys.executable, str(SCRIPT), "--attempt", "2", "--conclusion", "FAILURE"],
                             capture_output=True, text=True, check=True).stdout.strip()
        self.assertEqual(out, "failed-jobs")


LEG = "build-linux / build x86_64-unknown-linux-musl"
E0599 = ("2026-11-23T20:45:31.0255786Z error[E0599]: no method named `lock_or_recover` found for struct `ChatLocks`\n"
         "2026-11-23T20:45:31.0263638Z error: could not compile `acpmux` (lib) due to 1 previous error\n")


def fake_api(jobs, logs):
    calls = []

    def api(path):
        calls.append(path)
        if path.endswith("/jobs?filter=latest&per_page=100"):
            return json.dumps({"jobs": jobs})
        return logs.get(path.rsplit("/", 2)[-2])
    return api, calls


class CompileErrorTest(unittest.TestCase):
    def test_a_leg_that_did_not_compile(self):
        api, calls = fake_api([{"id": 7, "name": LEG, "conclusion": "failure", "steps": []}], {"7": E0599})
        self.assertTrue(rerun.failed_on_compile_error("o/r", "5", api))
        self.assertEqual(calls, ["repos/o/r/actions/runs/5/jobs?filter=latest&per_page=100", "repos/o/r/actions/jobs/7/logs"])

    def test_no_evidence_reruns_as_before(self):
        api, _ = fake_api([{"id": 7, "name": LEG, "conclusion": "failure", "steps": []}], {"7": "runner lost"})
        self.assertFalse(rerun.failed_on_compile_error("o/r", "5", api))
        self.assertFalse(rerun.failed_on_compile_error("o/r", "5", lambda path: None))
        self.assertFalse(rerun.failed_on_compile_error("o/r", "5", lambda path: "not json"))

    def test_without_the_run_in_the_environment_nothing_is_read(self):
        # An older request workflow sets no RUN_ID: the decision is the attempt and conclusion alone.
        env = {k: v for k, v in os.environ.items() if k not in ("RUN_ID", "REPOSITORY")}
        out = subprocess.run([sys.executable, str(SCRIPT), "--attempt", "1", "--conclusion", "failure"],
                             capture_output=True, text=True, check=True, env=env).stdout.strip()
        self.assertEqual(out, "failed-jobs")

    def test_cli_reads_the_run_from_the_environment(self):
        with tempfile.TemporaryDirectory() as tmp:
            gh = Path(tmp, "gh")
            gh.write_text("#!/bin/sh\ncase \"$2\" in\n  */jobs\\?*) printf '%s' '"
                          + json.dumps({"jobs": [{"id": 7, "name": LEG, "conclusion": "failure"}]})
                          + "' ;;\n  */logs) printf '%s' 'error[E0062]: x\nerror: could not compile `acpmux`' ;;\n"
                          "  *) exit 1 ;;\nesac\n")
            gh.chmod(0o755)
            env = {**os.environ, "PATH": f"{tmp}:{os.environ['PATH']}", "REPOSITORY": "o/r", "RUN_ID": "5"}
            for attempt, conclusion, want in ((1, "failure", "compile-error"), (2, "cancelled", "compile-error"),
                                              (1, "success", "full"), (3, "failure", "cap")):
                out = subprocess.run([sys.executable, str(SCRIPT), "--attempt", str(attempt), "--conclusion", conclusion],
                                     capture_output=True, text=True, check=True, env=env).stdout.strip()
                self.assertEqual(out, want, (attempt, conclusion))


class WiringTest(unittest.TestCase):
    def setUp(self) -> None:
        job = yaml.safe_load(WORKFLOW.read_text())["jobs"]["request"]
        self.step = next(s for s in job["steps"] if s.get("id") == "request")["run"]
        self.sparse = job["steps"][0]["with"]["sparse-checkout"]

    def test_the_request_asks_the_script_with_the_runs_attempt_and_conclusion(self) -> None:
        self.assertIn('\\(.run_attempt)\\t\\(.conclusion // "")', self.step)
        self.assertIn("read -r run_id run_status run_url run_attempt run_conclusion", self.step)
        self.assertIn("scripts/ci/cmux_tui_tree_request_rerun.py", self.step)
        self.assertIn("scripts/ci", self.sparse)

    def test_each_decision_takes_its_own_endpoint(self) -> None:
        self.assertIn('actions/runs/$run_id/rerun-failed-jobs"', self.step.split("failed-jobs)", 1)[1].split(";;")[0])
        self.assertIn('actions/runs/$run_id/rerun"', self.step.split("full)", 1)[1].split(";;")[0])
        cap = self.step.split("cap)", 1)[1].split(";;")[0]
        self.assertIn("exit 1", cap)
        self.assertNotIn("gh api", cap)
        compile_error = self.step.split("compile-error)", 1)[1].split(";;")[0]
        self.assertIn('report failed "$run_url"', compile_error)
        self.assertIn("exit 1", compile_error)
        self.assertNotIn("gh api", compile_error)

    def test_the_request_names_the_run_by_environment(self):
        # The script runs from the requested commit's checkout; an older one ignores the environment.
        self.assertIn('RUN_ID="$run_id" python3 scripts/ci/cmux_tui_tree_request_rerun.py', self.step)
        self.assertIn("REPOSITORY", yaml.safe_load(WORKFLOW.read_text())["jobs"]["request"]["steps"][
            next(i for i, st in enumerate(yaml.safe_load(WORKFLOW.read_text())["jobs"]["request"]["steps"])
                 if st.get("id") == "request")]["env"])


if __name__ == "__main__":
    unittest.main()
