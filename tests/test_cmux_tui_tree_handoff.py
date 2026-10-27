#!/usr/bin/env python3
"""The tree hand-off re-runs a deferred run at most twice, and never after a quota-only failure.

2026-10-27: two runs that deferred the same tree re-ran each other through
notify-unpublished-tree's hand-off until they reached attempts 15 to 17, each
re-run spending the installation's API and attestation quota that was already
blocking every tree publish.
"""
from __future__ import annotations

import importlib.util
from pathlib import Path
import sys
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/cmux_tui_tree_handoff.py"
WORKFLOW = ROOT / ".github/workflows/cmux-tui-artifacts.yml"
spec = importlib.util.spec_from_file_location("handoff", SCRIPT)
handoff = importlib.util.module_from_spec(spec)
sys.modules["handoff"] = handoff
spec.loader.exec_module(handoff)


def job(name, conclusion, *failed_steps):
    steps = [{"name": "Set up job", "conclusion": "success"}]
    steps += [{"name": step, "conclusion": "failure"} for step in failed_steps]
    return {"id": hash(name) & 0xFFFF, "name": name, "conclusion": conclusion, "steps": steps}


class QuotaOnlyFailureTests(unittest.TestCase):
    def test_attestation_steps_only(self):
        jobs = [job("build", "success"),
                job("publish to R2", "failure", "Attest raw binary subjects", "Attest raw binary subjects (last try)")]
        self.assertTrue(handoff.quota_only_failure(jobs))

    def test_retry_the_attestation_step(self):
        self.assertTrue(handoff.quota_only_failure([job("publish to R2", "failure", "Retry the attestation of raw binary subjects")]))

    def test_rate_limit_text(self):
        jobs = [job("publish to R2", "failure", "Upload to R2")]
        self.assertTrue(handoff.quota_only_failure(jobs, "Failed to persist attestation: API rate limit exceeded for installation."))

    def test_a_build_failure_is_not_quota(self):
        jobs = [job("build / build aarch64-apple-darwin", "failure", "cargo build"),
                job("publish to R2", "failure", "Attest raw binary subjects")]
        self.assertFalse(handoff.quota_only_failure(jobs))

    def test_no_failed_step_is_not_quota(self):
        # A cancelled daemon test leaves no failed step: the hand-off still runs (and is capped below).
        self.assertFalse(handoff.quota_only_failure([job("cmux_next_ daemon tests (macOS)", "cancelled")]))

    def test_the_reporting_job_is_ignored(self):
        jobs = [job("publish to R2", "failure", "Attest raw binary subjects"),
                job("report an unpublished cmux-tui tree to cmux-next", "failure", "Hand the key")]
        self.assertTrue(handoff.quota_only_failure(jobs))


class CandidateTests(unittest.TestCase):
    def test_order_skips_self_and_expired(self):
        artifacts = [
            {"id": 1, "expired": False, "workflow_run": {"id": 10, "head_branch": "lane/x"}},
            {"id": 2, "expired": False, "workflow_run": {"id": 11, "head_branch": "feat-cmux-next"}},
            {"id": 3, "expired": False, "workflow_run": {"id": 12, "head_branch": "feat-cmux-next"}},
            {"id": 4, "expired": True, "workflow_run": {"id": 13, "head_branch": "feat-cmux-next"}},
            {"id": 5, "expired": False, "workflow_run": {"id": 99, "head_branch": "feat-cmux-next"}},
        ]
        self.assertEqual([row[1] for row in handoff.order_candidates(artifacts, 99)], [12, 11, 10])

    def test_cap_two_reruns(self):
        self.assertTrue(handoff.may_rerun({"status": "completed", "run_attempt": 1})[0])
        self.assertTrue(handoff.may_rerun({"status": "completed", "run_attempt": 2})[0])
        self.assertFalse(handoff.may_rerun({"status": "completed", "run_attempt": 3})[0])
        self.assertFalse(handoff.may_rerun({"status": "completed", "run_attempt": 17})[0])

    def test_live_run_is_not_rerun(self):
        self.assertFalse(handoff.may_rerun({"status": "in_progress", "run_attempt": 1})[0])


class WorkflowTests(unittest.TestCase):
    def test_hand_off_step_runs_the_capped_script(self):
        workflow = yaml.safe_load(WORKFLOW.read_text())
        steps = workflow["jobs"]["notify-unpublished-tree"]["steps"]
        step = next(s for s in steps if s.get("name") == "Hand the key to a run that deferred to this one")
        self.assertIn("scripts/ci/cmux_tui_tree_handoff.py", step["run"])
        self.assertNotIn("gh run rerun", step["run"])
        # No other step of the workflow re-runs a run around the cap.
        text = WORKFLOW.read_text()
        self.assertNotIn("gh run rerun", text)


if __name__ == "__main__":
    unittest.main()
