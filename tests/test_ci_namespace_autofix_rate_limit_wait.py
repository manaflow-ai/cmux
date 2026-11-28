#!/usr/bin/env python3
"""namespace-autofix.yml waits out a refused file listing once, bounded, before its git fallback.

The fix step lists the PR's files through the API on the job token, and on a failure falls back to git's merge-base
diff. When the job token's budget was spent and the merge base was more than 8500 commits back, both sources
failed and the job was red until a rerun after the reset: runs 45924331840 (2026-11-27 01:45:47Z) and 45965901335
(08:28:43Z), "API rate limit exceeded for installation", then "Both sources of the PR's files failed ... no merge
base". Now a quota refusal (403/429 with core remaining 0, read from the free rate_limit endpoint) is listed again
once after the reset when that is at most RATE_LIMIT_WAIT_S away. A reset further off or a second refusal goes to
the git fallback as before, and when that fails too the job stays red and names the time to rerun after. Nothing
is skipped: an unlisted PR never reads as clean.

Run: python3 tests/test_ci_namespace_autofix_rate_limit_wait.py
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
WORKFLOW = ROOT / ".github" / "workflows" / "namespace-autofix.yml"
STEP = "Fix safe namespace violations"
START = 'listed="$RUNNER_TEMP/namespace-listed.txt"'
END = "awk '/^(Packages|ios\\/cmux)\\/.*\\.swift$/"

# Stands in for gh. `gh api rate_limit` prints the reset from $RESET_IN (seconds from now) when the budget is
# spent. Every other call takes the next outcome from $PLAN (comma separated): `ok` (lists one Swift file),
# `limited` (a quota refusal) or `broken` (a 502).
FAKE_GH = """#!/usr/bin/env python3
import os, sys, time
args = sys.argv[1:]
if args[:2] == ["api", "rate_limit"]:
    spent = os.environ.get("SPENT", "1") == "1"
    if spent:
        print(int(time.time()) + int(os.environ["RESET_IN"]))
    sys.exit(0)
log = os.environ["CALL_LOG"]
calls = open(log).read().split() if os.path.exists(log) else []
open(log, "a").write(os.environ["GH_TOKEN"] + "\\n")
outcome = os.environ["PLAN"].split(",")[len(calls)]
if outcome == "ok":
    print("Packages/A/Sources/A.swift")
    sys.exit(0)
if outcome == "limited":
    sys.stderr.write("gh: API rate limit exceeded for installation. If you reach out to GitHub Support...\\n")
    sys.exit(1)
sys.stderr.write("gh: HTTP 502: Bad Gateway\\n")
sys.exit(1)
"""

# Stands in for git: merge-base answers $MERGE_BASE (empty: none found), fetches succeed, diff lists one file.
FAKE_GIT = """#!/bin/sh
case "$1" in
  merge-base) [ -n "$MERGE_BASE" ] && echo "$MERGE_BASE"; exit 0 ;;
  fetch) exit 0 ;;
esac
for a in "$@"; do [ "$a" = diff ] && { echo "Packages/B/Sources/B.swift"; exit 0; }; done
exit 0
"""


def step() -> dict:
    steps = yaml.safe_load(WORKFLOW.read_text())["jobs"]["autofix"]["steps"]
    return next(s for s in steps if s.get("name") == STEP)


def listing_block() -> str:
    script = step()["run"]
    start = script.index(START)
    end = script.index(END)
    return script[start:end].replace("${{ github.event.pull_request.number }}", "7")


class RateLimitWait(unittest.TestCase):
    def run_block(self, plan: str, *, reset_in: int = 120, spent: bool = True,
                  merge_base: str = "") -> tuple[int, list[str], list[str], str, str]:
        root = Path(tempfile.mkdtemp(prefix="namespace-autofix-wait-"))
        self.addCleanup(shutil.rmtree, root, ignore_errors=True)
        bin_dir = root / "bin"
        bin_dir.mkdir()
        slept = root / "slept"
        for name, body in (("gh", FAKE_GH), ("git", FAKE_GIT), ("sleep", f'#!/bin/sh\necho "$1" >> "{slept}"\n')):
            path = bin_dir / name
            path.write_text(body)
            path.chmod(path.stat().st_mode | stat.S_IXUSR)
        temp = root / "runner-temp"
        temp.mkdir()
        log = root / "calls.log"
        env = {k: v for k, v in os.environ.items() if not k.startswith(("GITHUB_", "GH_"))}
        env.update(READ_TOKEN="job-token", GITHUB_REPOSITORY="manaflow-ai/cmux", BASE_SHA="b" * 40,
                   HEAD_SHA="h" * 40, RATE_LIMIT_WAIT_S=str(step()["env"]["RATE_LIMIT_WAIT_S"]),
                   RUNNER_TEMP=str(temp), CALL_LOG=str(log), PLAN=plan, RESET_IN=str(reset_in),
                   SPENT="1" if spent else "0", MERGE_BASE=merge_base,
                   PATH=f"{bin_dir}:{env.get('PATH', '/usr/bin:/bin')}")
        script = ('set -euo pipefail\ngit_retry() { "$@"; }\n' + listing_block()
                  + 'cat "$RUNNER_TEMP/namespace-listed.txt"\n')
        done = subprocess.run(["bash", "--noprofile", "--norc", "-c", script], cwd=root, env=env,
                              capture_output=True, text=True, timeout=60)
        calls = log.read_text().split() if log.exists() else []
        sleeps = slept.read_text().split() if slept.exists() else []
        return done.returncode, calls, sleeps, done.stdout, done.stderr

    def test_the_wait_is_bounded_and_the_job_timeout_holds_it(self) -> None:
        wait = int(step()["env"]["RATE_LIMIT_WAIT_S"])
        timeout = yaml.safe_load(WORKFLOW.read_text())["jobs"]["autofix"]["timeout-minutes"]
        # The job stays a trivial check (cron_concurrency's TRIVIAL_TIMEOUT_MINUTES); the lint takes about 3 min on
        # a large PR (run 45981165492), so the wait leaves at least 4 min for checkout, lint and push.
        self.assertLessEqual(timeout, 10)
        self.assertGreaterEqual(wait, 120)
        self.assertGreaterEqual(timeout * 60 - wait, 240)

    def test_a_first_listing_is_untouched(self) -> None:
        rc, calls, sleeps, out, _ = self.run_block("ok")
        self.assertEqual((rc, calls, sleeps), (0, ["job-token"], []))
        self.assertIn("Packages/A/Sources/A.swift", out)

    def test_a_refusal_waits_for_the_reset_and_lists_again(self) -> None:
        rc, calls, sleeps, out, err = self.run_block("limited,ok", reset_in=120)
        self.assertEqual(rc, 0, err)
        self.assertEqual(calls, ["job-token", "job-token"])
        self.assertEqual(len(sleeps), 1)
        self.assertTrue(120 <= int(sleeps[0]) <= 130, sleeps)
        self.assertIn("Packages/A/Sources/A.swift", out)

    def test_a_reset_past_the_bound_goes_to_git_without_waiting(self) -> None:
        rc, calls, sleeps, out, _ = self.run_block("limited", reset_in=2000, merge_base="m" * 40)
        self.assertEqual(rc, 0)
        self.assertEqual(calls, ["job-token"])
        self.assertEqual(sleeps, [])
        self.assertIn("Packages/B/Sources/B.swift", out)

    def test_a_second_refusal_goes_to_git(self) -> None:
        rc, calls, sleeps, out, _ = self.run_block("limited,limited", reset_in=60, merge_base="m" * 40)
        self.assertEqual(rc, 0)
        self.assertEqual(len(calls), 2)
        self.assertEqual(len(sleeps), 1)
        self.assertIn("Packages/B/Sources/B.swift", out)

    def test_both_sources_failing_stays_red_and_names_the_rerun_time(self) -> None:
        rc, _, sleeps, out, _ = self.run_block("limited", reset_in=2000)
        self.assertEqual(rc, 1)
        self.assertEqual(sleeps, [])
        self.assertRegex(out, r"::error::Both sources .* Rerun after \d\d:\d\d:\d\dZ")

    def test_a_failure_that_is_not_a_quota_refusal_is_not_waited_on(self) -> None:
        rc, calls, sleeps, out, _ = self.run_block("broken", merge_base="m" * 40)
        self.assertEqual(rc, 0)
        self.assertEqual((calls, sleeps), (["job-token"], []))
        self.assertIn("Packages/B/Sources/B.swift", out)

    def test_a_rate_limit_message_with_budget_left_is_not_waited_on(self) -> None:
        # A secondary limit leaves core remaining above 0: the free rate_limit read names no reset.
        rc, calls, sleeps, _, _ = self.run_block("limited", spent=False, merge_base="m" * 40)
        self.assertEqual(rc, 0)
        self.assertEqual((calls, sleeps), (["job-token"], []))


if __name__ == "__main__":
    unittest.main()
