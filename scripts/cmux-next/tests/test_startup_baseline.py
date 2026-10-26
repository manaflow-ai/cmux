#!/usr/bin/env python3
"""startup-baseline.py's numbers and rows, with no app: mark spreads leave interrupted runs out, a mark the build never
sent gets its own row, every row names host, macOS, refresh, display, sha and config, a failed part says why, and the
App Launch life-cycle table is read through xctrace's refs.
Run: python3 -I scripts/cmux-next/tests/test_startup_baseline.py"""
import importlib.util, os, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("startup_baseline", os.path.join(HERE, "..", "startup-baseline.py"))
baseline = importlib.util.module_from_spec(spec)
spec.loader.exec_module(baseline)
summary = baseline.perf_stats().summary

ENV = {"host": "cmux22-perf", "macos": "27.0 (27A100)", "display": baseline.display_from("ready 5 8.33 main=5"),
       "size": "1920x1155", "sha": "772cdfc45ac399e8557215eb68e720bb3c51a66b", "config": "bench"}


def bench(runs):
    return {"split-spring": {"warm": runs}}


class MarkRows(unittest.TestCase):
    def test_interrupted_runs_are_left_out(self):
        runs = [{"first_window_frame_committed": 200 + i, "window_display": 150.0} for i in range(4)]
        runs.append({"first_window_frame_committed": 9000, baseline.INTERRUPTED: 1})
        numbers = baseline.mark_rows(bench(runs), summary)
        self.assertEqual((numbers["runs"], numbers["kept"]), (5, 4))
        self.assertEqual(numbers["marks"]["first_window_frame_committed"]["max"], 203)
        self.assertEqual(numbers["marks"]["startup_complete"]["n"], 0)

    def test_a_false_interrupted_mark_keeps_the_run(self):
        numbers = baseline.mark_rows(bench([{"window_display": 1, baseline.INTERRUPTED: False}]), summary)
        self.assertEqual(numbers["kept"], 1)

    def test_temperatures_are_counted(self):
        runs = [{baseline.TEMPERATURE: "cold"}, {baseline.TEMPERATURE: "cold"}, {baseline.TEMPERATURE: "warm"}, {}]
        self.assertEqual(baseline.mark_rows(bench(runs), summary)["temperatures"], {"cold": 2, "warm": 1})


class Display(unittest.TestCase):
    def test_virtual_display_gives_its_rate(self):
        self.assertEqual(baseline.display_from("ready 7 8.33 main=7 visible=1920x1155")["hz"], 120)

    def test_a_fallback_names_the_real_display(self):
        display = baseline.display_from("error: no main display")
        self.assertIsNone(display["hz"])
        self.assertIn("real main display", display["kind"])

    def test_a_virtual_display_that_is_not_main_is_not_virtual(self):
        self.assertIsNone(baseline.display_from("ready 7 8.33 main=1")["hz"])


class Rows(unittest.TestCase):
    def report(self, parts):
        args = {"warm": 20, "cold": 10, "stress": 10, "traces": 5, "app_launches": 5,
                "workstream": "p08-startup-069 baseline"}
        return {"args": args, "env": ENV, "parts": parts}

    def test_every_row_names_the_conditions(self):
        warm = {"numbers": baseline.mark_rows(bench([{"first_window_frame_committed": 270.6}]), summary)}
        rows = baseline.render_rows(self.report({"warm": warm}), date="2026-10-26")
        self.assertEqual(len(rows), 1 + len(baseline.ROW_MARKS))
        for row in rows:
            for needle in ("host cmux22-perf", "macOS 27.0", "120 Hz", "display virtual", "sha 772cdfc45ac",
                           "config bench"):
                self.assertIn(needle, row)
            self.assertTrue(row.startswith("| 2026-10-26 | p08-startup-069 baseline | 772cdfc45ac |"))
        self.assertIn("first_window_frame_committed | p50 270.6", "".join(rows))
        self.assertIn("startup_complete | not sent by this build", "".join(rows))

    def test_a_failed_part_says_why(self):
        cold = {"exit": 2, "tail": "launch...\n--require-optimized: tag x is a Debug build\n", "numbers": None}
        rows = baseline.render_rows(self.report({"cold": cold}))
        self.assertEqual(len(rows), 1)
        self.assertIn("not measured: exit 2: --require-optimized: tag x is a Debug build", rows[0])

    def test_queue_rows_list_hits_or_the_refusal(self):
        hits = [{"summary": f"split-spring warm: a -> b p50 {i} ms"} for i in range(7)]
        queues = {"blocking": {"exit": 2, "tail": "startup-queue: debug.blocking: no detector", "numbers": None},
                  "mainjobs": {"numbers": {"queue": "Q11", "runs": 1, "hits": []}}}
        gaps = {"gaps warm": {"numbers": {"queue": "Q7", "runs": 20, "hits": hits}}}
        rows = baseline.render_rows(self.report({"queues": queues, "gaps": gaps}))
        text = "\n".join(rows)
        self.assertIn("queue blocking | no report: exit 2: startup-queue: debug.blocking: no detector", text)
        self.assertIn("queue Q11 mainjobs | 0 hits over 1 runs; top: no hit", text)
        self.assertIn("queue Q7 gaps warm | 7 hits over 20 runs", text)
        self.assertNotIn("p50 5 ms", text)  # top 5 only

    def test_a_bar_in_a_hit_does_not_split_the_row(self):
        gaps = {"gaps warm": {"numbers": {"queue": "Q7", "runs": 1, "hits": [{"summary": "a|b -> c p50 9 ms"}]}}}
        row = baseline.render_rows(self.report({"gaps": gaps}))[0]
        self.assertEqual(row.replace("\\|", "").count("|"), 7)

    def test_app_launch_periods_spread_over_the_traces(self):
        launches = [{"periods": [("Process Creation", 10.0 + i), ("Initial Frame Rendering", 100.0)]} for i in range(5)]
        rows = baseline.render_rows(self.report({"applaunch": {"numbers": launches}}))
        self.assertEqual(len(rows), 2)
        self.assertIn("App Launch: Process Creation x5 | p50 12.0", rows[0])


class LifeCycle(unittest.TestCase):
    def test_refs_are_resolved(self):
        xml = ('<trace-query-result><node><schema name="life-cycle-period"/>'
               '<row><start-time id="1" fmt="00:00.000">0</start-time><duration id="2" fmt="12 ms">12000000</duration>'
               '<string id="3" fmt="Process Creation">Process Creation</string></row>'
               '<row><start-time fmt="00:00.012">12000000</start-time><duration ref="2"/><string ref="3"/></row>'
               '<row><sentinel/></row></node></trace-query-result>')
        self.assertEqual(baseline.life_cycle_rows(xml), [("Process Creation", 12.0), ("Process Creation", 12.0)])

    def test_unparseable_export_reads_as_no_rows(self):
        self.assertEqual(baseline.life_cycle_rows("<oops"), [])


if __name__ == "__main__":
    unittest.main()
