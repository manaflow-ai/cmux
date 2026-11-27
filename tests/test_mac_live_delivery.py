#!/usr/bin/env python3
"""Run the shipped Mac publication step with failed delivery dependencies.

A missing live build must fail its job so retry/alerting can see it. Cloud channel
delivery is unrelated: a Linux failure must not prevent publishing Mac bytes.
"""
import os
import re
from pathlib import Path
import subprocess
import tempfile
import unittest

import workflow_jobs
from runs_on_labels import _Evaluator, _Parser

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/cmux-tui-artifacts.yml"


class Context(_Evaluator):
    def __init__(self, values):
        super().__init__("manaflow-ai", {})
        self.variables.update({key: {value} for key, value in values.items()})

    def __call__(self, node):
        if node[:2] == ("call", "cancelled"):
            return {False}
        return super().__call__(node)


class MacLiveDelivery(unittest.TestCase):
    def setUp(self):
        jobs = workflow_jobs.jobs(WORKFLOW)
        matches = [(job, step) for job in jobs.values() for step in job.get("steps", [])
                   if step.get("name") == "Sign the Mac live update file"]
        self.assertEqual(len(matches), 1)
        self.job, self.step = matches[0]

    def test_cloud_channel_failure_does_not_skip_mac_delivery(self):
        # GitHub skips a step after an earlier failed step, and waits for every
        # job in needs. Neither dependency belongs in Mac publication.
        earlier = self.job["steps"][:self.job["steps"].index(self.step)]
        self.assertNotIn("Sign and upload the channel", [s.get("name") for s in earlier])
        self.assertNotIn("point-machine-channel", self.job.get("needs", []))

    def test_push_and_manual_repair_publish_built_or_adopted_commits(self):
        condition = self.job["if"].strip().removeprefix("${{").removesuffix("}}")
        for event in ("push", "workflow_dispatch"):
            for published, adopted in (("success", ""), ("skipped", "present"),
                                       ("skipped", "adopted")):
                with self.subTest(event=event, published=published, adopted=adopted):
                    values = {"github.repository": "manaflow-ai/cmux",
                              "github.ref": "refs/heads/feat-cmux-next",
                              "github.event_name": event,
                              "needs.publish.result": published,
                              "needs.verify-publish.result": published,
                              "needs.adopt-commit-manifest.result": "success" if adopted else "skipped",
                              "needs.adopt-commit-manifest.outputs.state": adopted}
                    self.assertEqual(Context(values)(_Parser(condition).parse()), {True})
                    # A lane branch never runs this workflow on push (the trigger excludes it); a dispatch there
                    # is its PR head's on-request build and publishes the head's own per-commit file.
                    values["github.ref"] = "refs/heads/lane/some-pr"
                    self.assertEqual(Context(values)(_Parser(condition).parse()),
                                     {event == "workflow_dispatch"})
                    # Any other PR head publishes its own per-commit file on a push or a dispatch.
                    values["github.ref"] = "refs/heads/some-pr-head"
                    self.assertEqual(Context(values)(_Parser(condition).parse()), {True})
                    values["github.ref"] = "refs/heads/cmux-tui-pin-x"
                    self.assertEqual(Context(values)(_Parser(condition).parse()), {False})
                    values["github.ref"] = "refs/heads/main"
                    self.assertEqual(Context(values)(_Parser(condition).parse()), {False})

    def run_step(self, failure):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            bindir = root / "bin"
            bindir.mkdir()
            # Execute the actual workflow shell. Only external delivery commands
            # are faked; bash's error propagation and timeout wrapper are real.
            stub = '''#!/usr/bin/env bash
set -eu
name=$(basename "$0")
case "$name" in
  python3) case "$1" in
    *hot-apply.py) name=live-from ;;
    *cmux-machine-channel.py) name=payload ;;
  esac ;;
esac
echo "$name" >> "$CALLS"
[[ "$FAIL_AT" != "$name" ]] || exit 23
[[ "$name" != git ]] || echo 1700000000
'''
            for name in ("curl", "python3", "git"):
                path = bindir / name
                path.write_text(stub)
                path.chmod(0o755)
            point = root / "scripts/ci/cmux-machine-channel-point.sh"
            point.parent.mkdir(parents=True)
            point.write_text(stub)
            point.chmod(0o755)
            env = {**os.environ, "PATH": f"{bindir}:{os.environ['PATH']}",
                   "RUNNER_TEMP": tmp, "GITHUB_SHA": "a" * 40, "GITHUB_RUN_ID": "1",
                   "GITHUB_REF": "refs/heads/some-pr-head",
                   "CALLS": str(root / "calls"), "FAIL_AT": failure}
            result = subprocess.run(["bash", "-euo", "pipefail", "-c", self.step["run"]],
                                    cwd=root, env=env, capture_output=True, text=True, timeout=10)
            return result, (root / "calls").read_text().splitlines()

    def test_delivery_failures_are_visible_to_retry_and_alerting(self):
        for stage in ("curl", "live-from", "payload", "cmux-machine-channel-point.sh"):
            with self.subTest(stage=stage):
                result, calls = self.run_step(stage)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(calls[-1], stage)

    def test_the_job_outlasts_the_step_limits(self):
        # 2026-11-23: the job had 20 minutes and the helper wait alone could take 21, so GitHub cancelled the
        # job before the file was written and the channel stood still for 38 hours.
        limits = [int(n) for n in re.findall(r"\btimeout (\d+) ", self.step["run"])]
        self.assertGreaterEqual(len(limits), 3, limits)
        waits = [int(n) for n in re.findall(r"\bwait=(\d+)", self.step["run"])]
        self.assertLess(max(waits), limits[0], "the helper wait ends before its own timeout")
        self.assertLessEqual(sum(limits) + 300, int(self.job["timeout-minutes"]) * 60,
                             "the step's own limits, plus 5 minutes for checkout, fit in the job's")

    def test_success_reaches_signed_upload(self):
        result, calls = self.run_step("")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(calls[-1], "cmux-machine-channel-point.sh")


if __name__ == "__main__":
    unittest.main()
