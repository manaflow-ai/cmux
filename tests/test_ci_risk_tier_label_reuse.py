#!/usr/bin/env python3
"""risk-tier.yml repeats a head's last passing grade on a label the grade does not read.

`risk evidence` is red only for an unowned takeback, which comes from the head's diff, the base and the
description. A label event (ready-to-land, full-ci and the rest) used to grade again from scratch: a checkout,
a 9-day base fetch and the reads, 2 to 4 runner-min each, about 3,800 runner-min per 4 h on 2026-11-25. The
first step now reads this head's earlier `risk evidence` check runs and, when the newest finished one passed,
passes without grading. Anything else (a red, none yet, a failed read, a sign-off label) grades as before, and
the run never ends skipped, so the newest check of that name is always a verdict.

Run: python3 tests/test_ci_risk_tier_label_reuse.py
"""

from __future__ import annotations

import json
import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "risk-tier.yml"
REUSE = "Reuse this head's verdict on a label the grade does not read"
GATE = "steps.reuse.outputs.verdict == ''"


def job() -> dict:
    return yaml.safe_load(WORKFLOW.read_text())["jobs"]["evidence"]


def check_run(conclusion: str, completed: str, run_id: int) -> dict:
    return {"status": "completed", "conclusion": conclusion, "completed_at": completed,
            "details_url": f"https://github.com/manaflow-ai/cmux/actions/runs/{run_id}/job/1"}


class LabelReuse(unittest.TestCase):
    def run_reuse(self, label: str, runs: list[dict] | None) -> tuple[subprocess.CompletedProcess, str]:
        step = next(s for s in job()["steps"] if s.get("name") == REUSE)
        with tempfile.TemporaryDirectory() as tmp:
            bin_dir = Path(tmp, "bin")
            bin_dir.mkdir()
            gh = bin_dir / "gh"
            if runs is None:
                gh.write_text("#!/bin/sh\necho 'HTTP 403' >&2\nexit 1\n")
            else:
                Path(tmp, "runs.json").write_text(json.dumps({"check_runs": runs}))
                # The real gh applies --jq; jq does the same here.
                gh.write_text(f'#!/bin/sh\nwhile [ "$1" != --jq ]; do shift; done\njq -r "$2" {tmp}/runs.json\n')
            gh.chmod(gh.stat().st_mode | stat.S_IEXEC)
            out = Path(tmp, "out")
            out.write_text("")
            env = {k: v for k, v in os.environ.items() if not k.startswith(("GITHUB_", "GH_"))}
            env.update(PATH=f"{bin_dir}:{env['PATH']}", GITHUB_OUTPUT=str(out), REPO="manaflow-ai/cmux",
                       HEAD_SHA="a" * 40, LABEL=label, RUN_ID="900")
            done = subprocess.run(["bash", "--noprofile", "--norc", "-eo", "pipefail", "-c", step["run"]],
                                  env=env, capture_output=True, text=True, timeout=60)
            return done, out.read_text()

    def test_an_unread_label_repeats_the_newest_pass(self) -> None:
        done, out = self.run_reuse("ready-to-land", [check_run("failure", "2026-11-25T10:00:00Z", 100),
                                                     check_run("success", "2026-11-25T11:00:00Z", 200)])
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(out, "verdict=pass\n")

    def test_a_newest_red_grades_again(self) -> None:
        done, out = self.run_reuse("full-ci", [check_run("success", "2026-11-25T10:00:00Z", 100),
                                               check_run("failure", "2026-11-25T11:00:00Z", 200)])
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(out, "")

    def test_this_run_and_cancelled_runs_are_not_a_verdict(self) -> None:
        done, out = self.run_reuse("full-ci", [check_run("success", "2026-11-25T12:00:00Z", 900),
                                               check_run("cancelled", "2026-11-25T11:00:00Z", 200)])
        self.assertEqual((done.returncode, out), (0, ""), done.stderr)

    def test_no_earlier_grade_or_a_failed_read_grades(self) -> None:
        for runs in ([], None):
            done, out = self.run_reuse("full-ci", runs)
            self.assertEqual((done.returncode, out), (0, ""), done.stderr)

    def test_a_sign_off_label_always_grades(self) -> None:
        for label in ("risk:human-ok", "risk:waived"):
            done, out = self.run_reuse(label, [check_run("success", "2026-11-25T11:00:00Z", 200)])
            self.assertEqual((done.returncode, out), (0, ""), done.stderr)

    def test_the_step_runs_first_only_on_label_events_and_never_fails_the_job(self) -> None:
        first = job()["steps"][0]
        self.assertEqual(first["name"], REUSE)
        self.assertEqual(first["if"], "github.event.action == 'labeled' || github.event.action == 'unlabeled'")
        self.assertIs(first["continue-on-error"], True)
        self.assertEqual(job()["permissions"]["checks"], "read")

    def test_every_grading_step_waits_on_the_reuse(self) -> None:
        for step in job()["steps"][1:]:
            if step["name"].startswith("Log the glaeda-route App budget after"):
                continue  # gated on the glaeda token, which a reused run never mints
            self.assertTrue(str(step.get("if", "")).startswith(GATE), step["name"])

    def test_the_job_has_no_job_level_if(self) -> None:
        self.assertNotIn("if", job())


if __name__ == "__main__":
    unittest.main()
