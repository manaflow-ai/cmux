#!/usr/bin/env python3
"""risk-tier.yml grades a held pull request a second time on GITHUB_TOKEN only when the sign-off read was refused.

GitHub runs pull_request_target workflows from main's copy, so this file is the one that grades every pull request
into feat-cmux-next. Its job runs on cmux-gcp-pr-control-jit-x64, and a self-hosted job's GITHUB_TOKEN draws on the
repository's self-hosted token hour: the one that ran dry about every hour on 2026-11-21 (15:49, 16:12, 17:28,
18:46, 19:48Z) and that the production promote gates read their staging runs from.

The step grades on the glaeda-route App's read first. It used to grade again on GITHUB_TOKEN whenever the verdict
was held (ready=false): a FIX on the head, read fine, cost about ten more GITHUB_TOKEN calls (the files pages,
comments, reviews and label events), about 220 an hour. Only a refused sign-off read can come out differently on
another token, and risk_tier.py now says so (signoff_unread=true, feat-cmux-next tests/test_risk_tier.py). A base
whose risk_tier.py predates that line keeps the old second grade.

Run: python3 tests/test_ci_risk_tier_grades_once.py
"""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "risk-tier.yml"
STEP = "Grade the pull request"

# Stands in for the base's scripts/ci/risk_tier.py: logs the token it graded with, then writes the outputs in
# $OUT_APP (App token) or $OUT_GITHUB (GITHUB_TOKEN); FAIL_APP=1 makes the App's grade fail like a refused read.
FAKE_RISK_TIER = """import os, sys
args = sys.argv[1:]
token = os.environ["GH_TOKEN"]
open(os.environ["GRADE_LOG"], "a").write(token + "\\n")
if token == "app-token" and os.environ.get("FAIL_APP") == "1":
    sys.exit(1)
out = os.environ["OUT_APP" if token == "app-token" else "OUT_GITHUB"].replace("|", "\\n")
open(args[args.index("--github-output") + 1], "a").write(out + "\\n")
open(args[args.index("--summary") + 1], "a").write("graded\\n")
"""


def grade_step() -> dict:
    steps = yaml.safe_load(WORKFLOW.read_text())["jobs"]["evidence"]["steps"]
    return next(s for s in steps if s.get("name") == STEP)


class GradesOnce(unittest.TestCase):
    def run_step(self, out_app: str, *, fail_app: bool = False, app_token: str = "app-token") -> tuple[list[str], str]:
        root = Path(tempfile.mkdtemp(prefix="risk-tier-grade-"))
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        (root / "scripts" / "ci").mkdir(parents=True)
        (root / "scripts" / "ci" / "risk_tier.py").write_text(FAKE_RISK_TIER)
        temp = root / "runner-temp"
        temp.mkdir()
        log, output, summary = root / "grades.log", root / "github-output", root / "summary"
        env = {k: v for k, v in os.environ.items() if not k.startswith(("GITHUB_", "GH_"))}
        env.update(READ_TOKEN=app_token, GH_TOKEN="github-token", REPO="manaflow-ai/cmux", NUMBER="7",
                   RUNNER_TEMP=str(temp), GITHUB_OUTPUT=str(output), GITHUB_STEP_SUMMARY=str(summary),
                   GRADE_LOG=str(log), OUT_APP=out_app, OUT_GITHUB="tier=high|ready=false|signoff_unread=false",
                   FAIL_APP="1" if fail_app else "0")
        done = subprocess.run(["bash", "--noprofile", "--norc", "-eo", "pipefail", "-c", grade_step()["run"]],
                              cwd=root, env=env, capture_output=True, text=True, timeout=60)
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        return log.read_text().split(), output.read_text()

    def test_a_held_verdict_read_in_full_is_graded_once(self) -> None:
        grades, output = self.run_step("tier=high|ready=false|signoff_unread=false")
        self.assertEqual(grades, ["app-token"])
        self.assertIn("ready=false", output.splitlines())

    def test_a_refused_sign_off_read_is_graded_again_on_github_token(self) -> None:
        grades, output = self.run_step("tier=high|ready=false|signoff_unread=true")
        self.assertEqual(grades, ["app-token", "github-token"])
        self.assertIn("signoff_unread=false", output.splitlines())

    def test_a_base_that_predates_the_line_keeps_the_second_grade(self) -> None:
        grades, _ = self.run_step("tier=high|ready=false")
        self.assertEqual(grades, ["app-token", "github-token"])

    def test_a_ready_verdict_is_graded_once(self) -> None:
        grades, _ = self.run_step("tier=low|ready=true|signoff_unread=false")
        self.assertEqual(grades, ["app-token"])

    def test_a_failed_app_grade_falls_back_to_github_token(self) -> None:
        grades, output = self.run_step("", fail_app=True)
        self.assertEqual(grades, ["app-token", "github-token"])
        self.assertIn("tier=high", output.splitlines())

    def test_no_app_token_grades_once_on_github_token(self) -> None:
        grades, _ = self.run_step("", app_token="")
        self.assertEqual(grades, ["github-token"])


if __name__ == "__main__":
    unittest.main()
