#!/usr/bin/env python3
"""A cmux ios verify step still in the fleet queue is parked, not held on a Mac gateway runner.

On 2026-11-28 4 of 17 verify jobs in one hour were cancelled at their 150 min bound waiting on the simulator queue,
about 740 of the workflow's 888 runner minutes, with no record posted. ios_verify.py --queue-timeout now exits 75
with the steps in place, the workflow saves a parked cache key, and ios_verify_requeue.py dispatches the head again
once its steps ended.
"""
from __future__ import annotations

import datetime as dt
import json
import subprocess
import sys
import unittest
from pathlib import Path
from unittest import mock

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import ios_verify  # noqa: E402
import ios_verify_requeue as rq  # noqa: E402

WORKFLOW = ROOT / ".github" / "workflows" / "cmux-next-ios-verify-auto.yml"
SHA = "a" * 40


def done(code: int = 0, out: str = "", err: str = "") -> subprocess.CompletedProcess:
    return subprocess.CompletedProcess([], code, out, err)


class DispatchStepTest(unittest.TestCase):
    def step(self, mode: str = "flows") -> dict:
        return {"name": "shard-1", "mode": mode, "worker": None, "args": ["--x"]}

    def dispatch(self, step: dict, code: int, queue_timeout: int, signed: str | None = None):
        seen = {}

        def stream(cmd, name):
            seen["cmd"] = cmd
            return code, "step 0123456789abcdef01234567 queued"

        with mock.patch.object(ios_verify, "stream", stream), \
                mock.patch.object(ios_verify, "xcode_label", lambda: None), \
                mock.patch.object(ios_verify, "sign_in", lambda s: signed):
            run = ios_verify.dispatch_step(step, SHA, 1, False, "1", queue_timeout)
        return run, seen["cmd"]

    def test_queue_timeout_passed_and_exit_75_is_queued(self) -> None:
        run, cmd = self.dispatch(self.step(), ios_verify.QUEUED_EXIT, 600)
        self.assertEqual(cmd[cmd.index("--queue-timeout") + 1], "600")
        self.assertEqual(run["result"], "queued")

    def test_no_queue_timeout_keeps_75_a_failure(self) -> None:
        run, cmd = self.dispatch(self.step(), ios_verify.QUEUED_EXIT, 0)
        self.assertNotIn("--queue-timeout", cmd)
        self.assertEqual(run["result"], "fail")

    def test_signed_in_step_waits(self) -> None:
        _, cmd = self.dispatch(self.step("pair-e2e"), 0, 600, signed="agent")
        self.assertNotIn("--queue-timeout", cmd)


class RequeueDecideTest(unittest.TestCase):
    now = dt.datetime(2026, 11, 28, 23, 0, tzinfo=dt.timezone.utc)

    def entry(self, ids: str = "abc123def.0123abcd", hours: float = 1) -> dict:
        made = (self.now - dt.timedelta(hours=hours)).isoformat().replace("+00:00", "Z")
        return {"key": f"ios-verify-parked-65000-{SHA}-{ids}", "created_at": made}

    def gh(self, state: str = "open", head: str = SHA):
        return lambda *cmd, **kw: done(0, f"{state}\t{head}\n")

    def ci(self, state: str):
        return lambda *cmd, **kw: done(0, json.dumps({"state": state}))

    def test_parse(self) -> None:
        self.assertEqual(rq.parse(self.entry()["key"]), (65000, SHA, ["abc123def", "0123abcd"]))
        self.assertIsNone(rq.parse("ios-verify-parked-x"))

    def test_live_step_waits(self) -> None:
        self.assertEqual(rq.decide(self.entry(), "o/r", self.now, self.gh(), self.ci("queued"))[0], "wait")

    def test_ended_steps_dispatch(self) -> None:
        for state in ("done", "failed", "unread"):
            self.assertEqual(rq.decide(self.entry(), "o/r", self.now, self.gh(), self.ci(state))[0], "dispatch")

    def test_unreadable_status_dispatches(self) -> None:
        bad = lambda *cmd, **kw: done(1, "", "no")  # noqa: E731
        self.assertEqual(rq.decide(self.entry(), "o/r", self.now, self.gh(), bad)[0], "dispatch")

    def test_drops(self) -> None:
        self.assertEqual(rq.decide(self.entry(hours=13), "o/r", self.now, self.gh(), self.ci("queued"))[0], "drop")
        self.assertEqual(rq.decide(self.entry(), "o/r", self.now, self.gh("closed"), self.ci("queued"))[0], "drop")
        self.assertEqual(rq.decide(self.entry(), "o/r", self.now, self.gh(head="b" * 40), self.ci("queued"))[0],
                         "drop")

    def test_pr_not_read_waits(self) -> None:
        bad = lambda *cmd, **kw: done(1)  # noqa: E731
        self.assertEqual(rq.decide(self.entry(), "o/r", self.now, bad, self.ci("done"))[0], "wait")


class WorkflowTest(unittest.TestCase):
    def setUp(self) -> None:
        self.wf = yaml.safe_load(WORKFLOW.read_text())
        self.on = self.wf.get(True) or self.wf.get("on")

    def test_schedule_runs_only_requeue(self) -> None:
        self.assertTrue(self.on.get("schedule"))
        for name, job in self.wf["jobs"].items():
            self.assertEqual("'schedule'" in job["if"], name == "requeue", name)

    def test_verify_parks_on_75(self) -> None:
        steps = self.wf["jobs"]["verify-fleet"]["steps"]
        verify = next(s for s in steps if s.get("id") == "verify")
        self.assertIn("--queue-timeout", verify["run"])
        self.assertIn("--queued-out", verify["run"])
        self.assertIn('"$rc" == 75', verify["run"])
        park = next(s for s in steps if str(s.get("uses", "")).startswith("actions/cache/save@"))
        self.assertEqual(park["with"]["key"], "${{ steps.verify.outputs.parked }}")
        self.assertIn(rq.PARKED_PREFIX, verify["run"])

    def test_dispatch_input_matches_requeue(self) -> None:
        self.assertIn("queue_timeout", self.on["workflow_dispatch"]["inputs"])
        self.assertEqual(rq.WORKFLOW, WORKFLOW.name)


if __name__ == "__main__":
    unittest.main()
