#!/usr/bin/env python3
"""ext_load: the load starts and stops by pid (none left), percentiles, the p95 condition and timeouts. No fleet, no app.

    python3 -I scripts/journeys/test_ext_load.py
"""
import os
import sys
import tempfile
import time
import types
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import ext_load as L  # noqa: E402


class FakeDriver:
    class StepError(Exception):
        pass

    @staticmethod
    def now():
        return time.monotonic()


L.install(FakeDriver)


def journey(home):
    return types.SimpleNamespace(app=types.SimpleNamespace(home=home), load_pids=[])


class LoadTests(unittest.TestCase):
    def test_the_load_starts_and_stops_every_pid(self):
        if not os.path.exists("/usr/bin/yes"):
            self.skipTest("no /usr/bin/yes")
        with tempfile.TemporaryDirectory() as home:
            j = journey(home)
            sysctl = L.subprocess.run
            L.subprocess.run = lambda *a, **k: types.SimpleNamespace(stdout="{ 1 1 1 }")  # no sysctl here
            try:
                started = L.step_start_load(j, {"cpus": 2, "io": True, "settle_s": 0.2})
            finally:
                L.subprocess.run = sysctl
            self.assertEqual(len(started["pids"]), 3)
            self.assertTrue(all(L._alive(p) for p in started["pids"]))
            stopped = L.step_stop_load(j, {})
            time.sleep(0.3)
            for pid in started["pids"]:
                try:
                    os.waitpid(pid, os.WNOHANG)
                except ChildProcessError:
                    pass
            self.assertEqual(sorted(stopped["stopped"]), sorted(started["pids"]))
            self.assertFalse(any(L._alive(p) for p in started["pids"]), "a load process is still alive")
            self.assertFalse(os.path.exists(L._scratch(j)), "the scratch folder is still there")
            self.assertEqual(j.load_pids, [])

    def test_percentiles_and_the_p95_condition(self):
        values = [100.0 + i for i in range(10)]
        self.assertEqual(L._pct(values, 0.5), 104.0)  # nearest rank: the 5th of 10
        self.assertEqual(L._pct(values, 0.95), 109.0)
        self.assertIsNone(L._pct([], 0.95))
        j = types.SimpleNamespace(load_results={"key_new_terminal": {"p50_ms": 105.0, "p95_ms": 109.0, "max_ms": 109.0,
                                                                       "timeouts": 0, "count": 10}})
        self.assertTrue(L.cond_first_prompt_p95(j, {"action": "key_new_terminal", "max_ms": 500}, {})[0])
        self.assertFalse(L.cond_first_prompt_p95(j, {"action": "key_new_terminal", "max_ms": 100}, {})[0])
        j.load_results["key_new_terminal"]["timeouts"] = 1
        self.assertFalse(L.cond_first_prompt_p95(j, {"action": "key_new_terminal", "max_ms": 500}, {})[0],
                         "a timeout fails the condition whatever the p95")
        self.assertFalse(L.cond_first_prompt_p95(j, {"action": "new_window", "max_ms": 500}, {})[0])


if __name__ == "__main__":
    unittest.main()
