#!/usr/bin/env python3
"""The perf budgets suite's table and gate (scripts/cmux-next/perf-budgets.py).

A row regresses when its p95 is more than 10 % over the stored baseline AND more than the row's
noise floor; a row the baseline lacks, or a row a bench could not measure, never fails the gate.
Each bench's report maps to rows with p50 and p95 whatever stat shape the bench keeps.
"""
import importlib.util
import json
import os
import re
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
spec = importlib.util.spec_from_file_location("perf_budgets", os.path.join(ROOT, "scripts/cmux-next/perf-budgets.py"))
pb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pb)


class ScrollPlanTests(unittest.TestCase):
    def test_scroll_parameters_reach_both_native_runners_without_running_them(self):
        for flags, rows, seconds, target in (
            ([], "5000", "3", None),
            (["--acp-rows", "3000", "--acp-fling-seconds", "15", "--scroll-target-hz", "120"],
             "3000", "15.0", "120.0"),
        ):
            with self.subTest(flags=flags), tempfile.TemporaryDirectory() as out:
                args = ["perf-budgets.py", "--tag", "test", "--app", "/unused.app", "--out", out,
                        "--only", "acp,sidebar", *flags]
                with patch.object(sys, "argv", args), patch.object(pb, "run_phase") as run, patch.object(pb, "finish"):
                    pb.main()
                plan = run.call_args.args[2]
                acp = plan["acp"][0]
                self.assertEqual(acp[acp.index("--rows") + 1], rows)
                self.assertEqual(acp[acp.index("--fling-seconds") + 1], seconds)
                for name in ("acp", "sidebar"):
                    command = plan[name][0]
                    if target is None:
                        self.assertNotIn("--target-hz", command)
                    else:
                        self.assertEqual(command[command.index("--target-hz") + 1], target)


class BenchAppTests(unittest.TestCase):
    def test_every_bench_measures_the_app_it_is_given(self):
        """home-perf.py took no --app and looked for a reload.sh build, so on the fleet (split-spring.sh builds
        into .build/DerivedData/cmux-measure) it exited in 0.2 s and every run's home rows were missing: an
        incomplete gate (stable-next run 42930043303)."""
        with tempfile.TemporaryDirectory() as out:
            args = ["perf-budgets.py", "--tag", "test", "--app", "/fleet/cmux DEV test.app", "--out", out]
            with patch.object(sys, "argv", args), patch.object(pb, "run_phase") as run, patch.object(pb, "finish"):
                pb.main()
        plan = run.call_args.args[2]
        for name in pb.BENCHES:
            command = plan[name][0]
            with self.subTest(bench=name):
                self.assertIn("--app", command)
                self.assertEqual(command[command.index("--app") + 1], "/fleet/cmux DEV test.app")

    def test_home_perf_takes_the_app_and_refuses_a_missing_one(self):
        import subprocess
        script = os.path.join(ROOT, "scripts/cmux-next/home-perf.py")
        with tempfile.TemporaryDirectory() as out:
            done = subprocess.run([sys.executable, script, "--tag", "t", "--out", os.path.join(out, "h.json"),
                                   "--app", os.path.join(out, "none.app")], capture_output=True, text=True, timeout=30)
        self.assertNotEqual(done.returncode, 0)
        self.assertIn("no app at", done.stderr + done.stdout)


class GateTests(unittest.TestCase):
    def test_regression_needs_ten_percent_and_the_floor(self):
        rows = [{"name": "a", "p95": 11.5, "floor": 1.0},   # +15 %, +1.5 ms: regressed
                {"name": "b", "p95": 10.9, "floor": 1.0},   # +9 %: within 10 %
                {"name": "c", "p95": 1.5, "floor": 1.0},    # +50 % but +0.5 ms: noise
                {"name": "d", "p95": None, "floor": 1.0},   # not measured
                {"name": "e", "p95": 99.0, "floor": 1.0}]   # no baseline
        base = {"a": 10.0, "b": 10.0, "c": 1.0, "d": 5.0}
        self.assertEqual([r["name"] for r in pb.compare(rows, base)], ["a"])
        self.assertEqual(pb.compare(rows, base)[0]["worse_pct"], 15.0)

    def test_over_budget_is_listed_separately(self):
        rows = [{"name": "a", "p95": 9.0, "budget": 8.33}, {"name": "b", "p95": 8.0, "budget": 8.33},
                {"name": "c", "p95": None, "budget": 8.33}]
        self.assertEqual(pb.over_budget(rows), ["a"])

    def test_incomplete_rows_fails_for_missing_current_and_manifest_families(self):
        rows = [{"name": "panes.split.4x2.frame", "p95": None},
                {"name": "home.scroll.frame", "p95": 8.0}]
        baseline = {"panes.split.4x2.frame": 8.0}
        manifest = {"panes": [r"panes\..*\.frame"], "home": [r"home\.typing\.key_dispatch", r"home\.scroll\.frame"]}
        missing = pb.incomplete_rows(rows, baseline, manifest, ["panes", "home"])
        self.assertEqual([item["name"] for item in missing], ["panes.split.4x2.frame", r"home\.typing\.key_dispatch"])

    def test_incomplete_rows_is_empty_for_measured_manifest(self):
        rows = [{"name": "panes.split.4x2.frame", "p95": 8.0}]
        self.assertEqual(pb.incomplete_rows(rows, {"panes.split.4x2.frame": 8.0},
                                             {"panes": [r"panes\..*\.frame"]}, ["panes"]), [])


class MappingTests(unittest.TestCase):
    def test_stat_shapes(self):
        self.assertEqual(pb.p50_p95({"p50": 3, "p95": 7}), (3, 7))
        self.assertEqual(pb.p50_p95({"p50_ms": 3, "p95_ms": 7, "p99_ms": 9}), (3, 7))
        self.assertEqual(pb.p50_p95({"p50": 3, "p90": 6, "max": 9}), (3, 6))
        self.assertEqual(pb.p50_p95([1, 2, 3, 4, 5]), (3, 4.8))
        self.assertEqual(pb.p50_p95(None), (None, None))

    def test_bench_reports_map_to_rows(self):
        self.assertEqual(pb.rows_new_surfaces({"summary": {"idle/new_workspace": {"visible_p50": 9, "visible_p95": 14},
                                                           "load/split_right": {"visible_p50": 12, "visible_p95": 30}}}),
                         {"cmd_n.idle.key_to_visible": (9, 14), "cmd_d.load.key_to_visible": (12, 30)})
        self.assertEqual(pb.rows_panes({"summary": [{"layout": "4x2", "action": "split", "frames_p50_ms": 8.3,
                                                     "frames_p95_ms": 16.6}]}),
                         {"panes.split.4x2.frame": (8.3, 16.6)})
        self.assertEqual(pb.rows_tab_switch({"scenarios": [{"kind": "terminal", "count": 10, "ctrl_tab": {
            "table": {"ctrl_tab": {"e2e": {"p50": 5, "p95": 9}}}}}]}), {"tab_switch.terminal.10.e2e": (5, 9)})
        self.assertEqual(pb.rows_palette({"surfaces": {"terminal Cmd-Shift-P": {"table": {"key": {"p50": 7, "p90": 12}}}}}),
                         {"palette.terminal_cmd_shift_p.key_to_frame": (7, 12)})
        self.assertEqual(pb.rows_idle({"scenarios": {"terminals": {"processes": [{"kind": "app", "cpu_percent": 0.4},
                                                                                 {"kind": "daemon", "cpu_percent": 2}]}}}),
                         {"idle.terminals.app_cpu_pct": (0.4, 0.4)})
        sidebar = {"sizes": {"400": {"ticks": {"ticking": {"cpu_pct": 12.5}, "main_ms_per_s": 80.0,
                                               "frames_while_ticking": {"p50_ms": 8.3, "p95_ms": 9.1}},
                                     "switch_matrix": {"tickers": 15, "terminal.click": {
                                         "input_to_idle_ms": {"p50": 20, "p95": 41}, "longest_frame_ms": {"p50": 17, "p95": 33}}}}}}
        rows = pb.rows_sidebar(sidebar, 400)
        self.assertEqual(rows["workspace_switch.terminal.click.input_to_idle"], (20, 41))
        self.assertEqual(rows["workspace_switch.terminal.click.longest_frame"], (17, 33))
        self.assertEqual(rows["sidebar.400.ticking.cpu_pct"], (12.5, 12.5))
        self.assertEqual(rows["sidebar.400.ticking.main_ms_per_s"], (80.0, 80.0))
        self.assertEqual(rows["sidebar.400.ticking.frame"], (8.3, 9.1))
        # An older build's report with another shape (or none) leaves the rows empty, never raises.
        self.assertEqual(pb.rows_panes(None), {})
        self.assertEqual(pb.rows_sidebar(None, 400)["sidebar.400.scroll.frame"], (None, None))

    def test_a_page_slower_than_the_display_refuses_its_key_to_frame_rows(self):
        """CMUX-571 typing-latency (interim-coord, 2026-11-16: "fail any run whose page draws slower than the display"):
        the page's own cadence is a row, key to frame is also counted in its frames, the render-rate arms are rows, and a
        page drawing at 60 Hz on the 120 Hz virtual display keeps its to_work row but not its to_frame or to_paint."""
        stat = lambda p50, p95: {"p50_ms": p50, "p95_ms": p95, "max_ms": p95 + 1}  # noqa: E731
        rep = {"modes": {
            "own": {"summary": {"typing_to_frame": stat(10, 17), "typing_to_paint": stat(11, 18),
                                "typing_to_work": stat(4.5, 9), "frame_interval": stat(17, 18),
                                "rate_arms": {"capped": {"frame_interval": stat(17, 18), "typing_to_frame": stat(10, 17),
                                                         "typing_to_work": stat(4, 8)},
                                              "full": {"frame_interval": stat(8.33, 9), "typing_to_frame": stat(7, 9),
                                                       "typing_to_work": stat(4, 8)}}}},
            "chromium": {"summary": {"typing_to_frame": stat(5, 8), "typing_to_paint": stat(6, 9),
                                     "frame_interval": stat(8.33, 8.5)}}}}
        rows = pb.rows_acp(rep)
        self.assertEqual(rows["acp.own.frame_interval"], (17, 18))
        self.assertEqual(rows["acp.own.typing.to_frame_frames"], (0.59, 1.0))
        self.assertEqual(rows["acp.own-full.frame_interval"], (8.33, 9))
        self.assertEqual(rows["acp.own-capped.typing.to_frame"], (10, 17))
        for name in ("acp.own.frame_interval", "acp.own.typing.to_frame_frames", "acp.own-full.typing.to_frame",
                     "acp.chromium-nolimit.typing.to_frame"):
            self.assertTrue(pb.STAGE_ROW_RE.match(name), name)
        self.assertFalse(pb.STAGE_ROW_RE.match("acp.own.typing.to_frame"))
        with tempfile.TemporaryDirectory() as out:
            self.assertIsNone(pb.display_refresh_ms(out))
            with open(os.path.join(out, "display.txt"), "w") as f:
                f.write("ready 89 8.33 main=89 size=1920x1200 visible=1920x1092\n")
            refresh = pb.display_refresh_ms(out)
        self.assertEqual(refresh, 8.33)
        values = dict(rows)
        refused = pb.refresh_mismatches(values, refresh)
        self.assertEqual({r["name"] for r in refused}, {"acp.own.typing.to_frame", "acp.own.typing.to_paint"})
        self.assertIn("REFRESH-MISMATCH", refused[0]["reason"])
        for gone in ("acp.own.typing.to_frame", "acp.own.typing.to_paint", "acp.own.typing.to_frame_frames"):
            self.assertNotIn(gone, values)
        self.assertEqual(values["acp.own.typing.to_work"], (4.5, 9))  # independent of the refresh: kept
        self.assertEqual(values["acp.chromium.typing.to_frame"], (5, 8))  # drew at the display's refresh: kept
        self.assertEqual(values["acp.own-capped.typing.to_frame"], (10, 17))  # an arm is the experiment: kept
        self.assertEqual(pb.refresh_mismatches(dict(rows), None), [])  # the real display: no check

    def test_typing_stages_become_rows_that_are_never_judged(self):
        """CMUX-571 typing-latency: the chat composer's typing stages (key to page, key to edit and render done) are
        stored beside to_frame and to_paint, with no budget, no regression check and no baseline entry."""
        stat = lambda p50, p95: {"p50_ms": p50, "p95_ms": p95, "max_ms": p95 + 1}  # noqa: E731
        rep = {"modes": {"chromium": {"summary": {"typing_to_frame": stat(10.5, 12.8), "typing_to_paint": stat(11, 13),
                                                  "typing_to_listener": stat(1.2, 2.5), "typing_to_work": stat(3.1, 6.0)}},
                         "own": {"summary": {"typing_to_frame": stat(13, 15),
                                             "typing_to_listener": {"p50_ms": 0, "p95_ms": 0, "max_ms": 0}}}}}
        rows = pb.rows_acp(rep)
        self.assertEqual(rows["acp.chromium.typing.to_listener"], (1.2, 2.5))
        self.assertEqual(rows["acp.chromium.typing.to_work"], (3.1, 6.0))
        # A build without the stage marks: typingSummary's zeros (or no key) make no row, never a 0 ms one.
        self.assertNotIn("acp.own.typing.to_listener", rows)
        self.assertNotIn("acp.own.typing.to_work", rows)
        self.assertEqual(rows["acp.own.typing.to_frame"], (13, 15))
        self.assertTrue(pb.STAGE_ROW_RE.match("acp.chromium.typing.to_work@cmux20-bench"))
        self.assertFalse(pb.STAGE_ROW_RE.match("acp.chromium.typing.to_frame"))
        with tempfile.TemporaryDirectory() as out:
            base = os.path.join(out, "base.json")
            json.dump({"p95": {"acp.chromium.typing.to_frame": 12.8, "acp.chromium.typing.to_work": 1.0}}, open(base, "w"))
            opts = type("Opts", (), {"out": out, "profile": False, "baseline": base, "json": os.path.join(out, "r.json"),
                                     "tag": "t", "raw": "", "write_baseline": os.path.join(out, "new.json"), "gate": True})()
            with self.assertRaises(SystemExit) as done:
                pb.finish(opts, json.load(open(pb.BUDGETS_FILE)), ["acp"], {}, rows)
            self.assertEqual(done.exception.code, 0, "a stage over its (stale) baseline value never fails the gate")
            report = json.load(open(opts.json))
            by_name = {r["name"]: r for r in report["rows"]}
            self.assertIsNone(by_name["acp.chromium.typing.to_work"]["budget"])
            self.assertEqual(by_name["acp.chromium.typing.to_frame"]["budget"], 8.33)
            self.assertNotIn("acp.chromium.typing.to_work", report["over_budget"])
            written = json.load(open(opts.write_baseline))["p95"]
            self.assertIn("acp.chromium.typing.to_frame", written)
            self.assertNotIn("acp.chromium.typing.to_work", written)

    def test_tab_churn_report_maps_to_budgeted_rows(self):
        """ask-8a0837950b: tab-churn-bench.py's summary becomes terminal_burst.* rows, each with a budget and an expected family."""
        churn_spec = importlib.util.spec_from_file_location("tab_churn", os.path.join(ROOT, "scripts/cmux-next/tab-churn-bench.py"))
        churn = importlib.util.module_from_spec(churn_spec)
        churn_spec.loader.exec_module(churn)  # main() runs only as a script: importing launches nothing
        burst = [{"visible_ms": v} for v in (8, 9, 10, 9, 11, 12, 16, 18, 20)]
        summary = churn.summarize({"open@1": [{"visible_ms": 7, "key_ms": 1}, {"visible_ms": 9, "key_ms": 2}],
                                   "close@1": [{"visible_ms": 8}, {"visible_ms": None, "error": "no new tab page"}],
                                   "new_terminal": burst, "open@31": [{"visible_ms": 12}],
                                   "close@31": [{"visible_ms": 13}], "close_terminal": [{"visible_ms": 21.5}]})
        self.assertEqual(summary["close@1"]["visible_ms"]["missed"], 1)
        self.assertEqual(summary["close@1"]["errors"], ["no new tab page"])
        self.assertEqual((summary["new_terminal"]["first"]["p50"], summary["new_terminal"]["last"]["p50"]), (9, 18))
        self.assertEqual(summary["new_terminal"]["growth"], 2.0)  # the last ten open twice as slow as the first
        rows = pb.rows_terminal_burst({"summary": summary})
        self.assertEqual(rows, {"terminal_burst.open.1.key_to_visible": (7, 9), "terminal_burst.close.1.key_to_visible": (8, 8),
                                "terminal_burst.new_terminal.first.key_to_visible": (9, 10),
                                "terminal_burst.new_terminal.last.key_to_visible": (18, 20), "terminal_burst.new_terminal.growth": (2.0, 2.0),
                                "terminal_burst.open.31.key_to_visible": (12, 12), "terminal_burst.close.31.key_to_visible": (13, 13),
                                "terminal_burst.close_terminal.key_to_state": (21.5, 21.5)})
        budgets = json.load(open(pb.BUDGETS_FILE))
        for name in rows:
            self.assertTrue(pb.budget_for(name, budgets).get("p95"), name)
            self.assertTrue(any(re.fullmatch(p, name) for p in budgets["expected"]["terminal_burst"]), name)
        self.assertEqual(pb.budget_for("terminal_burst.new_terminal.growth", budgets)["unit"], "x")
        # Opt-in: the default suite is what stable-next's --gate step runs, and this group must not become a gate row.
        self.assertNotIn("terminal_burst", pb.BENCHES)
        self.assertIn("terminal_burst", pb.OPT_IN_BENCHES)
        self.assertEqual(pb.rows_terminal_burst(None), {})

    def test_animation_rows_take_their_budgets_from_the_perf_bench_file(self):
        rows = pb.rows_anim({"summary": [{"anim": "tab-new", "p50_ms": 8.3, "p95_ms": 9.0, "dropped": 2, "main_ms_max": 12.5}]})
        self.assertEqual(rows["anim.tab-new.frame"], (8.3, 9.0))
        self.assertEqual(rows["anim.tab-new.dropped"], (2, 2))
        budgets = {"rows": {}, "_animations": {"anim.tab-new.dropped": {"p95": 0, "unit": "frames"}}}
        self.assertEqual(pb.budget_for("anim.tab-new.dropped", budgets)["p95"], 0)
        self.assertEqual(pb.over_budget([{"name": "anim.tab-new.dropped", "p95": 2, "budget": 0}]), ["anim.tab-new.dropped"])

    def test_every_row_the_benches_make_has_a_budget(self):
        budgets = json.load(open(pb.BUDGETS_FILE))
        names = ["panes.split.4x2.frame", "sidebar.400.scroll.frame", "sidebar.400.scroll_while_ticking.frame",
                 "sidebar.400.workspace_switch.click_to_idle", "sidebar.400.ticking.cpu_pct", "home.scroll.frame",
                 "home.typing.key_dispatch", "acp.chromium.typing.to_frame", "cmd_n.idle.key_to_visible",
                 "cmd_t.load.key_to_visible", "ctrl_backtick.idle.key_to_visible", "cmd_d.idle.key_to_visible",
                 "cmd_shift_d.idle.key_to_visible", "tab_switch.chromium.10.e2e",
                 "palette.home_cmd_p.key_to_frame", "idle.terminals.app_cpu_pct",
                 "workspace_switch.chromium.cmd_digit.input_to_idle", "workspace_switch.terminal.next_prev.longest_frame",
                 "sidebar.400.ticking.frame", "sidebar.400.ticking.main_ms_per_s", "sidebar.400.drag.frame"]
        for name in names:
            self.assertTrue(pb.budget_for(name, budgets).get("p95"), name)
        for pattern in budgets["rows"]:
            re.compile(pattern)


split_spec = importlib.util.spec_from_file_location("perf_profile_split",
                                                    os.path.join(ROOT, "scripts/cmux-next/perf-profile-split.py"))
ps = importlib.util.module_from_spec(split_spec)
split_spec.loader.exec_module(ps)


class ProfileSplitTests(unittest.TestCase):
    """Main-thread samples split into framework diff/layout/draw and our own work (immediate-mode question)."""
    APP = "cmux DEV.debug.dylib"

    def test_first_owner_from_the_leaf_decides(self):
        run = [("-[NSApplication run]", "AppKit"), ("main", self.APP), ("start", "dyld")]
        self.assertEqual(ps.classify([("malloc", "libsystem_malloc.dylib"), ("SidebarLayout.make(rows:)", self.APP)] + run),
                         "ours.model_rebuild")
        self.assertEqual(ps.classify([("AG::Graph::update", "AttributeGraph"), ("SidebarHost.body", self.APP)] + run),
                         "framework.swiftui_diff")
        self.assertEqual(ps.classify([("-[NSView layoutSubtreeIfNeeded]", "AppKit")] + run), "framework.appkit_layout")
        self.assertEqual(ps.classify([("CA::Layer::commit_if_needed", "QuartzCore"), ("CA::Transaction::commit()", "QuartzCore")] + run),
                         "framework.ca_commit")
        self.assertEqual(ps.classify([("WorkspaceHoverCard.rebuild()", self.APP), ("WorkspaceRowView.configure(_:)", self.APP)] + run),
                         "ours.hover_card")
        self.assertEqual(ps.classify([("mach_msg2_trap", "libsystem_kernel.dylib")] + run), "idle")

    def test_sample_report_self_time(self):
        text = """Call graph:
    100 Thread_1   DispatchQueue_1: com.apple.main-thread  (serial)
    + 100 start  (in dyld) + 1  [0x1]
    +   100 main  (in cmux DEV) + 2  [0x2]
    +     100 -[NSApplication run]  (in AppKit) + 3  [0x3]
    +       40 mach_msg2_trap  (in libsystem_kernel.dylib) + 8  [0x4]
    +       30 -[NSView layoutSubtreeIfNeeded]  (in AppKit) + 1  [0x5]
    +       ! 20 SidebarLayout.make(rows:)  (in cmux DEV.debug.dylib) + 1  [0x6]
    +       ! 10 AG::Graph::update  (in AttributeGraph) + 1  [0x8]
    +       30 CA::Transaction::commit()  (in QuartzCore) + 1  [0x9]
    50 Thread_2
"""
        buckets = {}
        for count, stack in ps.stacks_from_sample(text):
            b = ps.classify(stack)
            buckets[b] = buckets.get(b, 0) + count
        self.assertEqual(buckets, {"idle": 40, "ours.model_rebuild": 20, "framework.swiftui_diff": 10, "framework.ca_commit": 30})
        summary = ps.summarize(buckets)
        self.assertEqual((summary["framework_pct"], summary["ours_pct"]), (66.7, 33.3))


if __name__ == "__main__":
    unittest.main()
