"""The motion frames dispatcher's step, run against a fake `gh`: a dispatch refused for a spent
installation rate limit waits for its reset (bounded) and tries once more; any refusal it cannot
retry passes with a "Not measured" step summary (fail open, Leo 2026-11-27 clause 23)."""

import os
import stat
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

import yaml

WORKFLOW = Path(__file__).resolve().parents[1] / ".github/workflows/cmux-next-motion-frames.yml"
ROUTER = WORKFLOW.parent / "pr-router.yml"
DOC = yaml.safe_load(WORKFLOW.read_text())
STEPS = DOC["jobs"]["dispatch"]["steps"]
STEP = next(step for step in STEPS if step.get("name") == "Start the motion frame checks on this branch")

FAKE_GH = """#!/usr/bin/env bash
# Fake gh: `workflow run` reads its outcomes from $FAKE_DIR/dispatches (one per line: ok, ratelimit, other).
if [ "$1" = "workflow" ]; then
  n=$(cat "$FAKE_DIR/count" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$FAKE_DIR/count"
  outcome=$(sed -n "${n}p" "$FAKE_DIR/dispatches")
  case "$outcome" in
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


class MotionFramesDispatchTest(unittest.TestCase):
    def run_step(self, dispatches, reset_in=60, bound="900"):
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
            env = dict(os.environ, PATH=f"{bin_dir}:{os.environ['PATH']}", FAKE_DIR=str(tmp),
                       GITHUB_STEP_SUMMARY=str(summary), GITHUB_REPOSITORY="manaflow-ai/cmux",
                       GITHUB_SERVER_URL="https://github.com", BRANCH="lane/x",
                       MOTION_FRAMES_RESET_WAIT_S=bound)
            proc = subprocess.run(["bash", "-e", "-c", STEP["run"]], env=env, capture_output=True, text=True)
            slept = (tmp / "slept").read_text().split() if (tmp / "slept").exists() else []
            count = int((tmp / "count").read_text())
            return proc, summary.read_text(), slept, count

    def test_started_first_try(self):
        proc, summary, slept, count = self.run_step(["ok"])
        self.assertEqual(proc.returncode, 0)
        self.assertIn("Started a `frames` run", summary)
        self.assertEqual((slept, count), ([], 1))

    def test_rate_limit_waits_for_reset_then_starts(self):
        proc, summary, slept, count = self.run_step(["ratelimit", "ok"], reset_in=60)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("Started a `frames` run", summary)
        self.assertEqual(count, 2)
        self.assertTrue(55 <= int(slept[0]) <= 66, slept)

    def test_rate_limit_past_bound_is_not_measured_and_passes(self):
        proc, summary, slept, count = self.run_step(["ratelimit"], reset_in=3000)
        self.assertEqual(proc.returncode, 0)
        self.assertIn("**Not measured**", summary)
        self.assertIn("past the 900s bound", summary)
        self.assertEqual((slept, count), ([], 1))

    def test_rate_limit_still_refused_after_wait_passes(self):
        proc, summary, _, count = self.run_step(["ratelimit", "ratelimit"], reset_in=30)
        self.assertEqual(proc.returncode, 0)
        self.assertIn("still refused after waiting", summary)
        self.assertEqual(count, 2)

    def test_other_refusal_is_not_measured_without_waiting(self):
        proc, summary, slept, count = self.run_step(["other"])
        self.assertEqual(proc.returncode, 0)
        self.assertIn("**Not measured**", summary)
        self.assertIn("HTTP 422", summary)
        self.assertEqual((slept, count), ([], 1))

    def test_job_timeout_covers_the_wait(self):
        job = DOC["jobs"]["dispatch"]
        self.assertGreater(job["timeout-minutes"] * 60, int(STEP["env"]["MOTION_FRAMES_RESET_WAIT_S"]) + 60)

    def test_dispatch_uses_the_app_token_not_the_shared_budget(self):
        mint = next(step for step in STEPS if step.get("id") == "dispatch-token")
        self.assertIn("create-github-app-token", mint["uses"])
        self.assertEqual(mint["with"]["permission-actions"], "write")
        self.assertTrue(mint["continue-on-error"])
        self.assertLess(STEPS.index(mint), STEPS.index(STEP))
        self.assertEqual(STEP["env"]["GH_TOKEN"], "${{ steps.dispatch-token.outputs.token || github.token }}")
        # on: parses as True in PyYAML.
        call = (DOC.get("on") or DOC[True])["workflow_call"]
        self.assertIn(mint["with"]["private-key"].split("secrets.")[1].rstrip(" }"), call["secrets"])
        caller = yaml.safe_load(ROUTER.read_text())["jobs"]["motion-frames"]
        self.assertEqual(caller["secrets"]["CMUX_BOT_APP_KEY"], "${{ secrets.CMUX_BOT_APP_KEY }}")

    def test_step_runs_with_the_token_it_is_given(self):
        proc, _, _, _ = self.run_step(["ok"])
        self.assertEqual(proc.returncode, 0)


if __name__ == "__main__":
    unittest.main()
