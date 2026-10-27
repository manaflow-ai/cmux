#!/usr/bin/env python3
"""bench_input.py, the typing benches' shared key input and summaries (p06-scheduler-230).

1. `--input` is in both benches' --help, with the debug and real choices.
2. A real key goes through hid_input.HidPoster (a down and an up of the key's ANSI code), sends no socket call, and
   launches the app frontmost; a debug key is the bench's `debug.key` call with an uptime timestamp and leaves the
   launch environment and the focus alone.
3. budget_summary reads today's per-class yields, the spec'd turn/unattributed/input-response fields,
   and leaves a field the app does not report as None, never 0.
4. mode_summary pools rounds and reports idle and storm p50/p95/p99/max (typing_report.distribution, the lab's
   perf_stats percentiles), storm minus idle p99, the storm's turn p99,
   unattributed share and yield counts.

    python3 -m unittest scripts/cmux-next/tests/test_bench_input.py
"""
from __future__ import annotations

import subprocess
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HERE))
import bench_input as bi  # noqa: E402
import bench_launch  # noqa: E402
import hid_input  # noqa: E402

TODAY = {"frames": 120, "classes": {"visible": {"tasks": 4, "yielded_to_input": 2},
                                    "automation": {"tasks": 9, "yielded_to_input": 5}}}
SPEC = {"frames": 120, "turn_ms": {"p50": 0.4, "p95": 2.1, "p99": 3.5, "max": 9.0}, "task_ms": {"p99": 1.2},
        "unattributed_share": 0.04,
        "classes": {"visible": {"yielded_to_input": 1, "yielded_to_input_response": 3},
                    "automation": {"yielded_to_input": 2, "yielded_to_input_response": 4}}}


class Help(unittest.TestCase):
    def test_both_benches_list_input(self):
        for script in ("automation-typing-bench.py", "sidebar-churn-typing.py"):
            done = subprocess.run([sys.executable, str(HERE / script), "--help"], capture_output=True, text=True, timeout=60)
            self.assertEqual(done.returncode, 0, done.stderr)
            self.assertIn("--input {debug,real}", done.stdout, script)


class Keys(unittest.TestCase):
    def test_real_key_posts_at_the_tap_and_sends_no_rpc(self):
        calls, fronted, backend = [], [], hid_input.RecordingBackend()
        sender = bi.KeySender("real", lambda *a: calls.append(a), poster=hid_input.HidPoster(backend),
                              front=fronted.append)
        self.assertIsNone(sender.send(bi.typed_key(0)))
        self.assertIsNone(sender.send(bi.typed_key(49)))
        a, ret = hid_input.KEYCODES["a"], hid_input.KEYCODES["return"]
        self.assertEqual([(e["code"], e["down"]) for e in backend.events], [(a, True), (a, False), (ret, True), (ret, False)])
        self.assertEqual(calls, [])
        env = sender.launch_env({"X": "1", "CMUX_NEXT_NO_ACTIVATE": "1"})
        self.assertIsNone(env["CMUX_NEXT_NO_ACTIVATE"])
        self.assertEqual(env[bench_launch.ISOLATED_LAUNCH_KEY], "1", "an activating launch stays isolated")
        sender.bring_front(42)
        self.assertEqual(fronted, [42])

    def test_debug_key_is_a_timestamped_debug_key(self):
        calls = []
        sender = bi.KeySender("debug", lambda key, timestamp: calls.append((key, timestamp)) or {"ok": 1},
                              clock=lambda: 12.5)
        self.assertEqual(sender.send("b"), {"ok": 1})
        self.assertEqual(calls, [("b", 12.5)])
        self.assertEqual(sender.launch_env({"X": "1"}), {"X": "1"})
        self.assertNotIn(bench_launch.ISOLATED_LAUNCH_KEY, sender.launch_env({"X": "1"}))
        fronted = []
        bi.KeySender("debug", None, front=fronted.append).bring_front(42)
        self.assertEqual(fronted, [], "an injected key needs no focus")

    def test_unknown_mode_is_refused(self):
        with self.assertRaises(ValueError):
            bi.KeySender("hid", None)

    def test_every_typed_key_has_a_code(self):
        for index in range(100):
            self.assertIn(bi.typed_key(index), hid_input.KEYCODES)


class Budget(unittest.TestCase):
    def test_todays_report_leaves_unreported_fields_none(self):
        got = bi.budget_summary(TODAY)
        self.assertEqual(got["yielded_to_input"], {"visible": 2, "automation": 5})
        self.assertEqual(got["yielded_to_input_total"], 7)
        for key in ("turn_p99_ms", "turn_max_ms", "task_p99_ms", "unattributed_share", "yielded_to_input_response",
                    "yielded_to_input_response_total"):
            self.assertIsNone(got[key], key)

    def test_spec_fields(self):
        got = bi.budget_summary(SPEC)
        self.assertEqual((got["turn_p99_ms"], got["turn_max_ms"], got["task_p99_ms"]), (3.5, 9.0, 1.2))
        self.assertEqual(got["unattributed_share"], 0.04)
        self.assertEqual(got["yielded_to_input_response_total"], 7)
        top = bi.budget_summary({"yielded_to_input_response": 6, "turn_ms": {"p99_ms": 2.0}})
        self.assertEqual((top["yielded_to_input_response_total"], top["turn_p99_ms"]), (6, 2.0))

    def test_error_reply(self):
        self.assertEqual(bi.budget_summary({"error": "no socket"}), {"error": "no socket"})
        self.assertIn("error", bi.budget_summary(None))


class Modes(unittest.TestCase):
    def test_idle_and_storm_per_mode(self):
        idle = [{"key_to_frame_samples_ms": [4.0, 5.0], "budget": bi.budget_summary(TODAY)},
                {"key_to_frame_samples_ms": [6.0], "budget": bi.budget_summary(TODAY)}]
        storm = [{"key_to_frame_samples_ms": [7.0, 9.0], "budget": bi.budget_summary(SPEC)},
                 {"key_to_frame_samples_ms": [8.0], "budget": bi.budget_summary(dict(SPEC, unattributed_share=0.08))}]
        got = bi.mode_summary("real", idle, storm)
        self.assertTrue(got["quotable"])
        self.assertEqual(got["idle"]["key_to_frame_ms"], {"n": 3, "p50": 5.0, "p95": 5.9, "p99": 5.98, "max": 6.0})
        self.assertEqual(got["storm"]["key_to_frame_ms"]["n"], 3)
        self.assertEqual(got["storm_minus_idle_p99_ms"], 3.0)
        self.assertEqual(got["storm"]["turn_p99_ms"], 3.5)
        self.assertEqual(got["storm"]["unattributed_share"], 0.08, "the worst round")
        self.assertEqual(got["storm"]["yielded_to_input"], 6)
        self.assertEqual(got["storm"]["yielded_to_input_response"], 14)
        self.assertIsNone(got["idle"]["turn_p99_ms"])
        self.assertFalse(bi.mode_summary("debug", [], [])["quotable"])
        self.assertIsNone(bi.mode_summary("debug", [], [])["storm_minus_idle_p99_ms"])


if __name__ == "__main__":
    unittest.main()
