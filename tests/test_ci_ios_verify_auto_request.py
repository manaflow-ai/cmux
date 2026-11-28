"""cmux ios verify (auto)'s request step, run against a fake `gh`: a spent installation rate limit
waits for its reset (bounded) and dispatches once more; a dispatch it cannot start fails the job, so
cmux/ios-fast never waits on a proof no run will post behind a green request (#65473 at f875e016)."""

import os
import stat
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

import yaml

WORKFLOW = Path(__file__).resolve().parents[1] / ".github/workflows/cmux-next-ios-verify-auto.yml"
JOB = yaml.safe_load(WORKFLOW.read_text())["jobs"]["request"]
STEP = next(step for step in JOB["steps"] if step.get("name") == "Dispatch the verify run on feat-cmux-next")

FAKE_GH = """#!/usr/bin/env bash
# `workflow run` reads its outcomes from $FAKE_DIR/dispatches (one per line: ok, ratelimit, other).
if [ "$1" = "workflow" ]; then
  n=$(cat "$FAKE_DIR/count" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$FAKE_DIR/count"
  case "$(sed -n "${n}p" "$FAKE_DIR/dispatches")" in
    ok) exit 0 ;;
    ratelimit) echo "HTTP 403: API rate limit exceeded for installation." >&2; exit 1 ;;
    *) echo "HTTP 422: Workflow does not have 'workflow_dispatch' trigger" >&2; exit 1 ;;
  esac
fi
if [ "$1" = "api" ]; then cat "$FAKE_DIR/reset"; exit 0; fi
exit 2
"""

FAKE_SLEEP = """#!/usr/bin/env bash
echo "$1" >> "$FAKE_DIR/slept"
"""


class IosVerifyAutoRequestTest(unittest.TestCase):
    def run_step(self, dispatches, reset_in=60):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            bin_dir = tmp / "bin"
            bin_dir.mkdir()
            for name, body in (("gh", FAKE_GH), ("sleep", FAKE_SLEEP)):
                path = bin_dir / name
                path.write_text(body)
                path.chmod(path.stat().st_mode | stat.S_IXUSR)
            (tmp / "dispatches").write_text("\n".join(dispatches) + "\n")
            (tmp / "reset").write_text(str(int(time.time()) + reset_in) if reset_in is not None else "")
            summary = tmp / "summary.md"
            summary.write_text("")
            env = dict(os.environ, PATH=f"{bin_dir}:{os.environ['PATH']}", FAKE_DIR=str(tmp),
                       GITHUB_STEP_SUMMARY=str(summary), REPO="manaflow-ai/cmux", PR="65473",
                       SHA="f875e01622cc290358bd7fd772af709e183f2ab2",
                       IOS_VERIFY_RESET_WAIT_S=STEP["env"]["IOS_VERIFY_RESET_WAIT_S"])
            proc = subprocess.run(["bash", "-e", "-c", STEP["run"]], env=env, capture_output=True, text=True)
            slept = (tmp / "slept").read_text().split() if (tmp / "slept").exists() else []
            count = int((tmp / "count").read_text())
            return proc, summary.read_text(), slept, count

    def test_requested_first_try(self):
        proc, summary, slept, count = self.run_step(["ok"])
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("requested for #65473 at f875e01622cc", summary)
        self.assertEqual((slept, count), ([], 1))

    def test_rate_limit_waits_for_reset_then_requests(self):
        proc, summary, slept, count = self.run_step(["ratelimit", "ok"], reset_in=60)
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("requested for #65473", summary)
        self.assertEqual(count, 2)
        self.assertTrue(55 <= int(slept[0]) <= 66, slept)

    def test_rate_limit_past_bound_fails_the_job(self):
        proc, summary, slept, count = self.run_step(["ratelimit"], reset_in=3000)
        self.assertEqual(proc.returncode, 1)
        self.assertIn("::error", proc.stdout)
        self.assertIn("past the 1500s bound", proc.stdout)
        self.assertEqual((slept, count, summary), ([], 1, ""))

    def test_rate_limit_still_refused_after_reset_fails_the_job(self):
        proc, _, slept, count = self.run_step(["ratelimit", "ratelimit"], reset_in=60)
        self.assertEqual(proc.returncode, 1)
        self.assertIn("still refused after waiting", proc.stdout)
        self.assertEqual((len(slept), count), (1, 2))

    def test_unreadable_reset_fails_the_job(self):
        proc, _, _, count = self.run_step(["ratelimit"], reset_in=None)
        self.assertEqual(proc.returncode, 1)
        self.assertIn("reset time unreadable", proc.stdout)
        self.assertEqual(count, 1)

    def test_other_refusal_retries_three_times_then_fails(self):
        proc, summary, slept, count = self.run_step(["other", "other", "other"])
        self.assertEqual(proc.returncode, 1)
        self.assertIn("dispatch refused 3 times", proc.stdout)
        self.assertEqual((slept, count, summary), (["10", "20", "30"], 3, ""))

    def test_job_timeout_covers_the_reset_wait(self):
        self.assertGreaterEqual(JOB["timeout-minutes"] * 60, int(STEP["env"]["IOS_VERIFY_RESET_WAIT_S"]) + 120)


if __name__ == "__main__":
    unittest.main()
