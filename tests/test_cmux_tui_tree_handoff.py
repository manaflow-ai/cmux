#!/usr/bin/env python3
"""The tree hand-off re-runs a deferred run at most twice, and never after a quota-only failure.

2026-10-27: two runs that deferred the same tree re-ran each other through
notify-unpublished-tree's hand-off until they reached attempts 15 to 17, each
re-run spending the installation's API and attestation quota that was already
blocking every tree publish.
"""
from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/cmux_tui_tree_handoff.py"
WORKFLOW = ROOT / ".github/workflows/cmux-tui-artifacts.yml"
spec = importlib.util.spec_from_file_location("handoff", SCRIPT)
handoff = importlib.util.module_from_spec(spec)
sys.modules["handoff"] = handoff
spec.loader.exec_module(handoff)
KEY = "d65ec728a5e4d6e819e95e46cdd94bb8a7fe00fb"

# A fake gh: answers from $FAKE_STATE (a JSON file) and logs every call to $FAKE_LOG.
FAKE_GH = r"""#!/usr/bin/env python3
import json, os, sys
state = json.load(open(os.environ["FAKE_STATE"]))
args = sys.argv[1:]
open(os.environ["FAKE_LOG"], "a").write(json.dumps(args) + "\n")
if args[:2] == ["run", "rerun"]:
    sys.exit(0 if args[2] not in state.get("rerun_fails", []) else 1)
path = next(a for a in args[1:] if a.startswith("repos/"))
if "-X" in args:
    sys.exit(1 if state.get("delete_fails") else 0)
if path.endswith("/logs"):
    job = path.split("/")[-2]
    if job in state.get("log_errors", []):
        sys.exit(1)
    print(state.get("logs", {}).get(job, ""))
    sys.exit(0)
if "/jobs?" in path:
    if state.get("jobs_error"):
        print("HTTP 403", file=sys.stderr); sys.exit(1)
    assert "--paginate" not in args and "per_page=100" in path, args
    # Every job fits on the first page of 100; a later page is empty.
    jobs = [job for page in state["jobs_pages"] for job in page]
    print(json.dumps({"total_count": len(jobs), "jobs": jobs if path.endswith("page=1") else []}))
    sys.exit(0)
if "/artifacts?" in path:
    assert "--paginate" not in args and "per_page=100" in path, args
    artifacts = state.get("artifacts", [])
    print(json.dumps({"total_count": len(artifacts), "artifacts": artifacts if path.endswith("page=1") else []}))
    sys.exit(0)
run = path.rsplit("/", 1)[1]
if run not in state["runs"]:
    print("HTTP 404", file=sys.stderr); sys.exit(1)
print(json.dumps(state["runs"][run]))
"""


def job(job_id, name, conclusion, *failed_steps):
    steps = [{"name": "Set up job", "conclusion": "success"}]
    steps += [{"name": step, "conclusion": "failure"} for step in failed_steps]
    return {"id": job_id, "name": name, "conclusion": conclusion, "steps": steps}


def marker(artifact_id, run_id, branch="feat-cmux-next", expired=False):
    return {"id": artifact_id, "expired": expired, "workflow_run": {"id": run_id, "head_branch": branch}}


class QuotaOnlyFailureTests(unittest.TestCase):
    def quota(self, jobs, logs=None):
        logs = logs or {}
        return handoff.quota_only_failure(jobs, lambda j: logs.get(j["id"], ""))

    def test_attestation_steps_only(self):
        jobs = [job(1, "build", "success"),
                job(2, "publish to R2", "failure", "Attest raw binary subjects", "Attest raw binary subjects (last try)")]
        self.assertTrue(self.quota(jobs))

    def test_retry_the_attestation_step(self):
        self.assertTrue(self.quota([job(2, "publish to R2", "failure", "Retry the attestation of raw binary subjects")]))

    def test_rate_limit_in_the_log(self):
        jobs = [job(2, "publish to R2", "failure", "Upload to R2")]
        for text in ("API rate limit exceeded for installation", "You have exceeded a secondary rate limit",
                     "HTTP 429: Too Many Requests"):
            self.assertTrue(self.quota(jobs, {2: text}), text)

    def test_mixed_failure_is_not_quota(self):
        # One rate-limited job does not hide another job's real failure.
        jobs = [job(1, "build / build aarch64-apple-darwin", "failure", "cargo build"),
                job(2, "publish to R2", "failure", "Upload to R2")]
        self.assertFalse(self.quota(jobs, {2: "API rate limit exceeded"}))

    def test_other_attest_named_steps_are_not_quota(self):
        self.assertFalse(self.quota([job(2, "publish to R2", "failure", "Verify attestation bundle")]))

    def test_unreadable_log_is_not_quota(self):
        jobs = [job(2, "publish to R2", "failure", "Upload to R2")]
        self.assertFalse(handoff.quota_only_failure(jobs, lambda j: None))

    def test_no_failed_job_is_not_quota(self):
        # A cancelled daemon test leaves no failed job: the hand-off still runs (and is capped).
        self.assertFalse(self.quota([job(3, "cmux_next_ daemon tests (macOS)", "cancelled")]))

    def test_the_reporting_job_is_ignored(self):
        jobs = [job(2, "publish to R2", "failure", "Attest raw binary subjects"),
                job(9, "report an unpublished cmux-tui tree to cmux-next", "failure", "Hand the key")]
        self.assertTrue(self.quota(jobs))


class CandidateTests(unittest.TestCase):
    def test_order_skips_self_and_expired(self):
        artifacts = [marker(1, 10, "lane/x"), marker(2, 11), marker(3, 12), marker(4, 13, expired=True), marker(5, 99)]
        self.assertEqual([row[1] for row in handoff.order_candidates(artifacts, 99)], [12, 11, 10])

    def test_cap_two_reruns(self):
        self.assertTrue(handoff.may_rerun({"status": "completed", "run_attempt": 1})[0])
        self.assertTrue(handoff.may_rerun({"status": "completed", "run_attempt": 2})[0])
        self.assertFalse(handoff.may_rerun({"status": "completed", "run_attempt": 3})[0])
        self.assertFalse(handoff.may_rerun({"status": "completed", "run_attempt": 17})[0])

    def test_live_run_is_not_rerun(self):
        self.assertFalse(handoff.may_rerun({"status": "in_progress", "run_attempt": 1})[0])


class CommandTests(unittest.TestCase):
    """Runs the script with a fake gh on PATH."""

    def run_handoff(self, state, token="t"):
        with tempfile.TemporaryDirectory() as tmp:
            gh = Path(tmp, "gh")
            gh.write_text(FAKE_GH)
            gh.chmod(gh.stat().st_mode | stat.S_IEXEC)
            Path(tmp, "state.json").write_text(json.dumps(state))
            env = {**os.environ, "PATH": f"{tmp}:{os.environ['PATH']}", "GH_TOKEN": token,
                   "FAKE_STATE": str(Path(tmp, "state.json")), "FAKE_LOG": str(Path(tmp, "log"))}
            if not token:
                env.pop("GH_TOKEN")
            result = subprocess.run([sys.executable, str(SCRIPT), "--repo", "o/r", "--run-id", "99", "--key", KEY],
                                    capture_output=True, text=True, env=env)
            log_path = Path(tmp, "log")
            calls = [json.loads(line) for line in log_path.read_text().splitlines()] if log_path.exists() else []
            return result, calls

    def test_reruns_the_newest_feat_run_under_the_cap_and_deletes_its_marker(self):
        state = {"jobs_pages": [[job(1, "build", "failure", "cargo build")], [job(3, "publish to R2", "skipped")]],
                 "artifacts": [marker(31, 12), marker(32, 13), marker(33, 10, "lane/x")],
                 "runs": {"13": {"status": "completed", "run_attempt": 3},
                          "12": {"status": "completed", "run_attempt": 2}}}
        result, calls = self.run_handoff(state)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Not re-running run 13", result.stdout)
        self.assertIn("Re-ran run 12", result.stdout)
        self.assertIn(["run", "rerun", "12", "--repo", "o/r"], calls)
        self.assertIn(["api", "-X", "DELETE", "repos/o/r/actions/artifacts/31"], calls)
        self.assertFalse(any(c[:3] == ["run", "rerun", "13"] for c in calls))
        lists = [c for c in calls if c[0] == "api" and c[-1].endswith("per_page=100&page=1")]
        self.assertEqual(len(lists), 2, "jobs and artifacts are read one bounded page per call")
        self.assertFalse(any("--paginate" in c for c in calls))

    def test_quota_only_owner_hands_nothing_off(self):
        state = {"jobs_pages": [[job(2, "publish to R2", "failure", "Upload to R2")]],
                 "logs": {"2": "Error: Failed to persist attestation: API rate limit exceeded for installation."},
                 "artifacts": [marker(31, 12)], "runs": {"12": {"status": "completed", "run_attempt": 1}}}
        result, calls = self.run_handoff(state)
        self.assertEqual(result.returncode, 0)
        self.assertIn("tree hand-off skipped", result.stdout)
        self.assertFalse(any(c[:2] == ["run", "rerun"] for c in calls))

    def test_every_candidate_capped_warns(self):
        state = {"jobs_pages": [[job(1, "build", "failure", "cargo build")]],
                 "artifacts": [marker(31, 12)], "runs": {"12": {"status": "completed", "run_attempt": 17}}}
        result, _ = self.run_handoff(state)
        self.assertIn("::warning::no run that deferred tree", result.stdout)

    def test_api_failure_warns_instead_of_failing_silently(self):
        result, _ = self.run_handoff({"jobs_error": True, "jobs_pages": []})
        self.assertEqual(result.returncode, 1)
        self.assertIn(f"::warning::tree {KEY} was not handed off", result.stdout)

    def test_delete_failure_warns_and_fails_the_step(self):
        state = {"jobs_pages": [[job(1, "build", "failure", "cargo build")]], "delete_fails": True,
                 "artifacts": [marker(31, 12)], "runs": {"12": {"status": "completed", "run_attempt": 1}}}
        result, _ = self.run_handoff(state)
        self.assertEqual(result.returncode, 1)
        self.assertIn("Re-ran run 12", result.stdout)
        self.assertIn("::warning::could not delete deferred marker 31", result.stdout)

    def test_unreadable_log_run_and_rerun_failures_warn(self):
        state = {"jobs_pages": [[job(2, "publish to R2", "failure", "Upload to R2")]], "log_errors": ["2"],
                 "rerun_fails": ["13"],
                 "artifacts": [marker(31, 14), marker(32, 13), marker(33, 12)],
                 "runs": {"13": {"status": "completed", "run_attempt": 1},
                          "12": {"status": "completed", "run_attempt": 1}}}
        result, _ = self.run_handoff(state)
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("::warning::could not read the log of job 2", result.stdout)
        self.assertIn("::warning::could not read run 14", result.stdout)
        self.assertIn("::warning::could not re-run run 13", result.stdout)
        self.assertIn("Re-ran run 12", result.stdout)

    def test_missing_token_warns(self):
        result, _ = self.run_handoff({"jobs_pages": []}, token="")
        self.assertEqual(result.returncode, 2)
        self.assertIn("::warning::", result.stderr)


class WorkflowTests(unittest.TestCase):
    def test_hand_off_step_runs_the_capped_script(self):
        workflow = yaml.safe_load(WORKFLOW.read_text())
        notify = workflow["jobs"]["notify-unpublished-tree"]
        step = next(s for s in notify["steps"] if s.get("name") == "Hand the key to a run that deferred to this one")
        self.assertIn("scripts/ci/cmux_tui_tree_handoff.py", step["run"])
        self.assertTrue(step.get("continue-on-error"))
        self.assertEqual(notify["permissions"].get("actions"), "write")
        checkout = next(s for s in notify["steps"] if "actions/checkout" in str(s.get("uses", "")))
        self.assertIn("scripts/ci", checkout["with"]["sparse-checkout"])
        # No step of the workflow re-runs a run around the cap.
        self.assertNotIn("gh run rerun", WORKFLOW.read_text())


if __name__ == "__main__":
    unittest.main()
