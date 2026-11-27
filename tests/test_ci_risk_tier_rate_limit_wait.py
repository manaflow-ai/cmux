#!/usr/bin/env python3
"""risk-tier.yml waits out a refused budget once, bounded, instead of handing the red to a rerun.

risk_tier.py (feat-cmux-next) ends a grade that GitHub's API budget refused red, ungraded, with the marker
`risk-evidence.rate-limited {"endpoint": ..., "graded": false, "reset": EPOCH, "status": 403}`. The grade step
on main tries the App's token and then GITHUB_TOKEN. When both were refused, it sleeps to the sooner of the two
resets (at most RATE_LIMIT_WAIT_S) and grades once more on that token. A reset further off, a second refusal or a
real verdict stays red: an ungraded pull request never passes as graded.

cmux#61052 run 45967298587 job 140401581683 (2026-11-27 08:45:29Z): both tokens refused, resets 08:51:11Z and
08:54:41Z; it was red on two attempts and GitHub refused a third rerun.

Run: python3 tests/test_ci_risk_tier_rate_limit_wait.py
"""

from __future__ import annotations

import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "risk-tier.yml"
STEP = "Grade the pull request"

# Stands in for the base's scripts/ci/risk_tier.py. Each call takes the next outcome from $PLAN (comma separated):
# `graded`, `unread` (high, its sign-off read refused), `red` (a real held verdict, exit 1) or `limited:SECONDS` (refused, reset SECONDS from now).
FAKE_RISK_TIER = """import json, os, sys, time
args = sys.argv[1:]
log = os.environ["GRADE_LOG"]
calls = open(log).read().split() if os.path.exists(log) else []
open(log, "a").write(os.environ["GH_TOKEN"] + "\\n")
outcome = os.environ["PLAN"].split(",")[len(calls)]
out = open(args[args.index("--github-output") + 1], "a")
if outcome == "graded":
    out.write("tier=low\\nlabel=risk:low\\nready=true\\nsignoff_unread=false\\n")
    sys.exit(0)
if outcome == "unread":
    out.write("tier=high\\nlabel=risk:high\\nready=false\\nsignoff_unread=true\\n")
    sys.exit(0)
if outcome == "red":
    out.write("tier=normal\\nlabel=risk:normal\\nready=false\\nsignoff_unread=false\\n")
    sys.exit(1)
reset = int(time.time()) + int(outcome.split(":")[1])
print("risk-evidence.rate-limited " + json.dumps(dict(endpoint="repos/o/r/pulls/7/files", graded=False,
                                                      reset=reset, status=403), sort_keys=True))
out.write("tier=ungraded\\nlabel=\\nready=false\\nsignoff_unread=true\\n")
sys.exit(1)
"""


def grade_step() -> dict:
    steps = yaml.safe_load(WORKFLOW.read_text())["jobs"]["evidence"]["steps"]
    return next(s for s in steps if s.get("name") == STEP)


class RateLimitWait(unittest.TestCase):
    def run_step(self, plan: str, *, app_token: str = "app-token") -> tuple[int, list[str], list[str], str]:
        root = Path(tempfile.mkdtemp(prefix="risk-tier-wait-"))
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        (root / "scripts" / "ci").mkdir(parents=True)
        (root / "scripts" / "ci" / "risk_tier.py").write_text(FAKE_RISK_TIER)
        bin_dir = root / "bin"
        bin_dir.mkdir()
        slept = root / "slept"
        fake_sleep = bin_dir / "sleep"
        fake_sleep.write_text(f'#!/bin/sh\necho "$1" >> "{slept}"\n')
        fake_sleep.chmod(fake_sleep.stat().st_mode | stat.S_IXUSR)
        temp = root / "runner-temp"
        temp.mkdir()
        log, output, summary = root / "grades.log", root / "github-output", root / "summary"
        env = {k: v for k, v in os.environ.items() if not k.startswith(("GITHUB_", "GH_"))}
        step_env = grade_step()["env"]
        env.update(READ_TOKEN=app_token, GH_TOKEN="github-token", REPO="manaflow-ai/cmux", NUMBER="7",
                   RATE_LIMIT_WAIT_S=str(step_env["RATE_LIMIT_WAIT_S"]), RUNNER_TEMP=str(temp),
                   GITHUB_OUTPUT=str(output), GITHUB_STEP_SUMMARY=str(summary), GRADE_LOG=str(log), PLAN=plan,
                   PATH=f"{bin_dir}:{env.get('PATH', '/usr/bin:/bin')}")
        done = subprocess.run(["bash", "--noprofile", "--norc", "-e", "-c", grade_step()["run"]],
                              cwd=root, env=env, capture_output=True, text=True, timeout=60)
        sleeps = slept.read_text().split() if slept.exists() else []
        return done.returncode, log.read_text().split(), sleeps, output.read_text() if output.exists() else ""

    def test_the_wait_is_bounded_and_the_job_timeout_holds_it(self) -> None:
        wait = int(grade_step()["env"]["RATE_LIMIT_WAIT_S"])
        timeout = yaml.safe_load(WORKFLOW.read_text())["jobs"]["evidence"]["timeout-minutes"]
        # The App's reset in cmux#61052 was 342 s after the refusal; the job stays a trivial check (cron_concurrency).
        self.assertGreaterEqual(wait, 342)
        self.assertLessEqual(timeout, 10)
        self.assertGreaterEqual(timeout * 60 - wait, 150)

    def test_both_refused_waits_for_the_sooner_reset_and_grades_on_that_token(self) -> None:
        rc, grades, sleeps, output = self.run_step("limited:340,limited:400,graded")
        self.assertEqual(rc, 0)
        self.assertEqual(grades, ["app-token", "github-token", "app-token"])
        self.assertEqual(len(sleeps), 1)
        self.assertTrue(340 <= int(sleeps[0]) <= 350, sleeps)
        self.assertIn("ready=true", output.splitlines())

    def test_the_job_token_resetting_first_is_the_one_graded_again(self) -> None:
        rc, grades, _, _ = self.run_step("limited:410,limited:60,graded")
        self.assertEqual(rc, 0)
        self.assertEqual(grades, ["app-token", "github-token", "github-token"])

    def test_a_reset_past_the_bound_stays_red_without_waiting(self) -> None:
        rc, grades, sleeps, output = self.run_step("limited:2000,limited:3000")
        self.assertEqual(rc, 1)
        self.assertEqual(grades, ["app-token", "github-token"])
        self.assertEqual(sleeps, [])
        self.assertNotIn("ready=true", output.splitlines())

    def test_a_second_refusal_stays_red(self) -> None:
        rc, grades, sleeps, output = self.run_step("limited:30,limited:60,limited:3000")
        self.assertEqual(rc, 1)
        self.assertEqual(len(grades), 3)
        self.assertEqual(len(sleeps), 1)
        self.assertNotIn("ready=true", output.splitlines())

    def test_a_real_red_on_the_app_is_not_waited_on(self) -> None:
        rc, grades, sleeps, _ = self.run_step("red,limited:30")
        self.assertEqual(rc, 1)
        self.assertEqual(grades, ["app-token", "github-token"])
        self.assertEqual(sleeps, [])

    def test_a_real_red_on_the_job_token_is_not_waited_on(self) -> None:
        rc, _, sleeps, _ = self.run_step("limited:30,red")
        self.assertEqual(rc, 1)
        self.assertEqual(sleeps, [])

    def test_no_app_token_waits_on_the_job_token(self) -> None:
        rc, grades, sleeps, _ = self.run_step("limited:30,graded", app_token="")
        self.assertEqual(rc, 0)
        self.assertEqual(grades, ["github-token", "github-token"])
        self.assertEqual(len(sleeps), 1)

    def test_a_refused_second_sign_off_read_keeps_the_apps_grade(self) -> None:
        # The App graded with the sign-off unread (ready=false, signoff_unread=true); GITHUB_TOKEN's regrade is refused.
        rc, grades, sleeps, output = self.run_step("unread,limited:30")
        self.assertEqual(rc, 0)
        self.assertEqual(grades, ["app-token", "github-token"])
        self.assertEqual(sleeps, [])
        self.assertIn("tier=high", output.splitlines())
        self.assertNotIn("tier=ungraded", output.splitlines())

    def test_a_real_red_on_the_second_sign_off_read_stays_red(self) -> None:
        rc, _, _, _ = self.run_step("unread,red")
        self.assertEqual(rc, 1)

    def test_a_first_grade_is_untouched(self) -> None:
        rc, grades, sleeps, _ = self.run_step("graded")
        self.assertEqual((rc, grades, sleeps), (0, ["app-token"], []))


class RealMarker(unittest.TestCase):
    """The step's `sed` reads the reset from the marker line risk_tier.py really prints (cmux#61052 job 140401581683)."""

    LINE = ('risk-evidence.rate-limited {"endpoint": "repos/manaflow-ai/cmux/issues/61052/comments?per_page=100", '
            '"graded": false, "reset": 1795769471, "status": 403}')

    def test_sed_reads_the_real_markers_reset(self) -> None:
        script = grade_step()["run"]
        sed = next(line.strip() for line in script.splitlines() if line.strip().startswith("sed -n"))
        expr = sed.split("'")[1]
        root = Path(tempfile.mkdtemp(prefix="risk-tier-marker-"))
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        log = root / "grade.log"
        log.write_text("risk-tier: reading\n" + self.LINE + "\n")
        done = subprocess.run(["sed", "-n", expr, str(log)], capture_output=True, text=True, check=True)
        self.assertEqual(done.stdout.strip(), "1795769471")


if __name__ == "__main__":
    unittest.main()
