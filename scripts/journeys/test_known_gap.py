#!/usr/bin/env python3
"""The driver's KNOWN GAP rule (journey step `known_gap`), with stub steps: no app.

    python3 scripts/journeys/test_known_gap.py

A check that fails on the gap's key path is recorded as the gap (ok None), the gap's fallback steps run, and the
journey goes on: no later failure -> "not run" naming the gap (never a pass); a later failure -> "fail" naming that
later step. On another key path, or when a fallback step fails, the failure is a real result.
"""
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "cmux-next"))
import driver as D  # noqa: E402


class FakeFrames:
    def __init__(self, *a):
        self.count, self.stopped = 0, type("E", (), {"set": lambda self: None})()

    def start(self):
        pass

    def join(self, timeout=None):
        pass


class Stub(D.Journey):
    """A Journey with scripted steps: `do` names a key of OUTCOMES (ok | fail | notrun), `key_path` is echoed."""
    def __init__(self, steps, out):
        self.spec = {"steps": steps, "continue_not_judged": True}
        self.id, self.out, self.app, self.deadline = "j", Path(out), None, D.now() + 60
        self.frame_interval, self.files, self.known_views = 1, [], set()
        self.steps, self.evidence, self.checks, self.marks, self.aliases = [], [], 0, {}, {}
        self.daemon_samples, self.nonce, self.term, self.pane, self.host_pid = [], "n", None, None, None
        self.calls = []

    def sample_daemons(self, at):
        self.daemon_samples.append({})

    def clip_frames(self):
        return 0

    def __getattr__(self, name):
        if not name.startswith("step_"):
            raise AttributeError(name)

        def run(step):
            self.calls.append(step.get("name", step["do"]))
            outcome = step.get("outcome", "ok")
            if outcome == "fail":
                self.evidence.append({"kind": "app", "pass": False, "check": "c"})
                raise D.StepError(f"{step.get('name')} failed")
            if outcome == "notrun":
                raise D.NotRun("cannot judge")
            for kind in ("app", "daemon", "frame"):
                self.evidence.append({"kind": kind, "pass": True, "check": kind})
            return {"key_path": step["key_path"]} if step.get("key_path") else {}
        return run


GAP = {"name": "New Column real key", "ref": "STATUS 1712/1724", "key_path": "real_hid",
       "fallback": [{"do": "x", "name": "escape", "outcome": "fail", "optional": True},
                    {"do": "x", "name": "action"}, {"do": "x", "name": "fallback-check"}]}


def journey(key_path="real_hid", later="ok", fallback_check="ok"):
    gap = dict(GAP, fallback=[dict(s, outcome=fallback_check) if s["name"] == "fallback-check" else s for s in GAP["fallback"]])
    return [{"do": "x", "name": "key", "key_path": key_path},
            {"do": "x", "name": "check", "outcome": "fail", "known_gap": gap},
            {"do": "x", "name": "later", "outcome": later}]


class KnownGap(unittest.TestCase):
    def run_steps(self, steps):
        D.Frames = FakeFrames
        D.daemon_verdict = lambda samples, bundle: None
        with tempfile.TemporaryDirectory() as tmp:
            j = Stub(steps, tmp)
            j.app = type("A", (), {"bundle": "b"})()
            return j, j.run()

    def test_only_the_gap_failed_is_not_run_naming_the_gap_and_later_steps_ran(self):
        j, result = self.run_steps(journey())
        self.assertEqual(result["status"], "not run")
        self.assertIn("step 2: KNOWN GAP: New Column real key (STATUS 1712/1724), not a result", result["reason"])
        self.assertIn("every later step passed", result["reason"])
        self.assertEqual(j.calls, ["key", "check", "escape", "action", "fallback-check", "later"])
        gap = next(s for s in result["steps"] if s.get("known_gap"))
        self.assertIsNone(gap["ok"])
        self.assertFalse([s for s in result["steps"] if s.get("ok") is False])

    def test_a_failure_after_the_gap_is_the_named_failure(self):
        j, result = self.run_steps(journey(later="fail"))
        self.assertEqual(result["status"], "fail")
        self.assertTrue(result["reason"].startswith("step 3 (x): later failed"), result["reason"])
        self.assertIn("after step 2: KNOWN GAP", result["reason"])

    def test_on_the_debug_key_path_the_check_is_a_real_failure(self):
        j, result = self.run_steps(journey(key_path="debug.key"))
        self.assertEqual(result["status"], "fail")
        self.assertNotIn("KNOWN GAP", result["reason"])
        self.assertEqual(j.calls, ["key", "check"])

    def test_a_failed_fallback_check_is_a_real_failure(self):
        j, result = self.run_steps(journey(fallback_check="fail"))
        self.assertEqual(result["status"], "fail")
        self.assertIn("the known gap's fallback step", result["reason"])
        self.assertNotIn("later", j.calls)


if __name__ == "__main__":
    unittest.main()
