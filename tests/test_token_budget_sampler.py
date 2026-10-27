import csv
import importlib.util
import os
import pathlib
import tempfile
import unittest
import urllib.error

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/token_budget_sampler.py"
WORKFLOW = ROOT / ".github/workflows/ci-token-budget-sampler.yml"
SPEC = importlib.util.spec_from_file_location("token_budget_sampler", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class Clock:
    def __init__(self):
        self.t = 1_800_000_000.0
        self.slept = []

    def now(self):
        return self.t

    def sleep(self, seconds):
        self.slept.append(seconds)
        self.t += seconds


class SampleTests(unittest.TestCase):
    def run_sample(self, read, minutes=1):
        clock = Clock()
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "s.csv")
            code = MODULE.sample("t", minutes, out, read=read, now=clock.now, wall=clock.now, sleep=clock.sleep)
            with open(out, encoding="utf-8") as handle:
                rows = list(csv.DictReader(handle))
        return code, rows, clock

    def test_reads_every_interval_until_the_deadline(self):
        left = iter(range(5000, 0, -7))
        code, rows, clock = self.run_sample(
            lambda token: {"remaining": next(left), "used": 0, "limit": 5000, "reset": 1_800_000_720})
        self.assertEqual(code, 0)
        self.assertEqual(len(rows), 60 // MODULE.SAMPLE_SECONDS)
        self.assertEqual(rows[0]["remaining"], "5000")
        self.assertEqual(rows[1]["remaining"], "4993")
        self.assertTrue(all(s == MODULE.SAMPLE_SECONDS for s in clock.slept))

    def test_the_last_sleep_ends_at_the_deadline(self):
        left = iter(range(5000, 0, -1))
        code, rows, clock = self.run_sample(
            lambda token: {"remaining": next(left), "used": 0, "limit": 5000, "reset": 1}, minutes=0.1)
        self.assertEqual(code, 0)
        self.assertEqual(len(rows), 2)
        self.assertEqual(clock.slept, [MODULE.SAMPLE_SECONDS, 1])

    def test_stops_after_repeated_failures(self):
        def fail(token):
            raise urllib.error.URLError("down")
        code, rows, clock = self.run_sample(fail, minutes=60)
        self.assertEqual(code, 1)
        self.assertEqual(rows, [])
        self.assertEqual(len(clock.slept), MODULE.MAX_FAILURES - 1)

    def test_rejects_unbounded_windows(self):
        os.environ["GH_TOKEN"] = "t"
        try:
            self.assertEqual(MODULE.main(["sample", "--minutes", "0", "--out", "x"]), 2)
            self.assertEqual(MODULE.main(["sample", "--minutes", str(MODULE.MAX_MINUTES + 1), "--out", "x"]), 2)
        finally:
            del os.environ["GH_TOKEN"]


class WorkflowTests(unittest.TestCase):
    def test_dispatch_only_and_bounded(self):
        text = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn("on:\n  workflow_dispatch:", text)
        for trigger in ("schedule:", "push:", "pull_request", "workflow_run:"):
            self.assertNotIn(trigger, text)
        self.assertIn("timeout-minutes: 130", text)
        self.assertIn("cancel-in-progress: false", text)
        self.assertIn("permissions:\n      contents: read", text)


if __name__ == "__main__":
    unittest.main()
