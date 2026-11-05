#!/usr/bin/env python3
"""pr-body-checks.yml runs the four description lints in one job, each on the events its own workflow had.

They were pr-capture-check.yml, pr-design-spec-check.yml, pr-perf-section-check.yml and
pr-cloud-backend-check.yml, each with a runner of its own. Each step keeps its old trigger: the capture
check also ran on media-tour label events, the perf check on perf label events, and the design spec and
cloud backend checks on no label event. The job keeps the pr-capture-check name first, which
cmuxterm-hq's next_autoland (`pr.?capture`) and base_red_watch ("pr-capture-check", before any " (")
read as the PR's own red. Only the capture step can turn the job red.

Run: python3 tests/test_pr_body_checks.py
"""
from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests"))

from test_ci_label_events_skip_full_ci import evaluate  # noqa: E402

WORKFLOW = yaml.safe_load((ROOT / ".github/workflows/pr-body-checks.yml").read_text())
JOB = WORKFLOW["jobs"]["body"]
STEPS = {s["name"]: s for s in JOB["steps"]}
CAPTURE = "Check the description for a real capture"
DESIGN = "Check the description cites each changed surface's spec"
PERF = "Check the description for a Performance table"
CLOUD = "Check where the cloud backend change belongs"

# event -> the checks that run on it
EVENTS = {
    ("synchronize", None): {CAPTURE, DESIGN, PERF, CLOUD},
    ("opened", None): {CAPTURE, DESIGN, PERF, CLOUD},
    ("edited", None): {CAPTURE, DESIGN, PERF, CLOUD},
    ("ready_for_review", None): {CAPTURE, DESIGN, PERF, CLOUD},
    ("labeled", "media-tour"): {CAPTURE},
    ("unlabeled", "media-tour-mac"): {CAPTURE},
    ("labeled", "perf"): {PERF},
    ("unlabeled", "performance"): {PERF},
    ("labeled", "risk:high"): set(),
}


def runs(expr: str, action: str, label: str | None, listed: bool = True) -> bool:
    text = expr.strip()
    if text.startswith("${{") and text.endswith("}}"):
        text = text[3:-2].strip()
    text = text.replace("!cancelled()", "true")
    text = re.sub(r"steps\.[a-z]+\.outputs\.listed == 'true'", "true" if listed else "false", text)
    text = text.replace("true", "(1 == 1)").replace("false", "(1 == 0)")
    return evaluate(text, {"event_name": "pull_request", "action": action, "label": label})


class BodyChecksTests(unittest.TestCase):
    def test_each_check_runs_on_the_events_its_workflow_had(self):
        for (action, label), want in EVENTS.items():
            with self.subTest(action=action, label=label):
                if not runs(JOB["if"], action, label):
                    self.assertEqual(want, set(), "the job skipped an event a check reads")
                    continue
                got = {name for name in (CAPTURE, DESIGN, PERF, CLOUD) if runs(STEPS[name]["if"], action, label)}
                self.assertEqual(got, want)

    def test_unlisted_paths_skip_the_checks_that_need_them(self):
        # Capture and perf fall back to the files API; design spec and cloud backend skip.
        self.assertTrue(runs(STEPS[CAPTURE]["if"], "synchronize", None, listed=False))
        self.assertTrue(runs(STEPS[PERF]["if"], "synchronize", None, listed=False))
        self.assertFalse(runs(STEPS[DESIGN]["if"], "synchronize", None, listed=False))
        self.assertFalse(runs(STEPS[CLOUD]["if"], "synchronize", None, listed=False))
        self.assertIn("gh api --paginate", STEPS[CAPTURE]["run"])
        self.assertIn("gh api --paginate", STEPS[PERF]["run"])

    def test_only_the_capture_check_can_fail_the_job(self):
        self.assertNotIn("continue-on-error", JOB)
        self.assertNotIn("continue-on-error", STEPS[CAPTURE])
        for name in (DESIGN, PERF, CLOUD):
            with self.subTest(step=name):
                self.assertIs(STEPS[name].get("continue-on-error"), True)
                self.assertIn("timeout-minutes", STEPS[name])
        for step in JOB["steps"]:
            if step.get("id") in {"paths", "tree", "renames"}:
                self.assertIs(step.get("continue-on-error"), True, step["name"])

    def test_the_design_spec_check_reads_paths_before_the_perf_fallback_can_rewrite_them(self):
        names = [s["name"] for s in JOB["steps"]]
        self.assertLess(names.index(DESIGN), names.index(PERF))

    def test_the_job_keeps_the_capture_check_name(self):
        name = JOB["name"]
        self.assertTrue(name.startswith("pr-capture-check"), name)
        self.assertIn("pr-capture-check", name.split(" (")[0])
        self.assertRegex(name, re.compile(r"pr.?capture", re.I))

    def test_the_checks_run_from_the_base_branch(self):
        checkout = JOB["steps"][0]["with"]
        self.assertEqual(checkout["ref"], "${{ github.event.pull_request.base.ref }}")
        self.assertFalse(checkout["persist-credentials"])
        wanted = {"scripts/ci/pr_capture_check.py", "scripts/cmux-next/media/path_map.py",
                  "scripts/ci/pr_design_spec_check.py", ".github/design-surfaces.json",
                  "scripts/ci/pr_perf_section_check.py", "scripts/ci/pr_cloud_backend_check.py",
                  ".github/cloud-backend-paths.json"}
        self.assertEqual(set(checkout["sparse-checkout"].split()), wanted)

    def test_it_runs_on_drafts_and_every_old_trigger(self):
        on = WORKFLOW.get(True, WORKFLOW.get("on"))["pull_request"]
        self.assertEqual(on["branches"], ["feat-cmux-next"])
        self.assertEqual(set(on["types"]), {"opened", "synchronize", "reopened", "edited", "labeled", "unlabeled",
                                             "ready_for_review"})
        self.assertNotIn("draft", str(JOB))


if __name__ == "__main__":
    unittest.main()
