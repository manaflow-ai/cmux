#!/usr/bin/env python3
"""scripts/cmux-next/bench_idle.py and bench_launch.py's launch order check: the parsers behind their JSON
(p06-scheduler-229, done checks 4, 6 and 7 of plans/cmux-next/chrome-parity/p06-scheduler.md).

1. `main_wakeups_per_s` is the `debug.hangs` `main_wakes` delta over the window, read last before and first after
   it; a missing or reset counter is None, never 0.
2. `owners` is the per-owner `debug.wakeups` ledger delta over the window, reasons summed, most first.
3. `hidden_workspace_layouts` and `hidden_workspace_applies` are `debug.layout_counters` deltas; None without the
   method (a Release build) or when the per-workspace sum went back (a workspace unmounted inside the window).
4. `mixed-hidden` expands to its window-visible and app-hidden phases; the criteria judge app + daemon and main
   wakeups there, and a hidden workspace layout in any scenario.
5. The mixed-hidden setup opens the tabs and terminals, then a new workspace, then hides the app; the app-hidden
   phase alone sets the workspace up first.
6. `launch.order_ok`: no background, idle or best-effort task before `launch.revealed`, from the app's signposts
   and its startup trace (an open trace without its closing `]` too); no reveal or no scheduled task fails closed.
7. `bench_launch.py order` writes `{"launch": {"order_ok": ...}}` from a stubbed app and signpost stream.

No app, no build, no macOS tool. Not on CI (Lawrence 2026-10-23: no new CI tests; lane = "manual"): run
python3 -I tests/test_bench_idle.py after changing bench_idle.py, bench_launch.py's order check or
DebugLayoutCounters' hidden counters.
"""
import argparse
import contextlib
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

SCRIPTS = Path(__file__).resolve().parents[1] / "scripts/cmux-next"
sys.path.insert(0, str(SCRIPTS))
import bench_idle as bi  # noqa: E402
import bench_launch as bl  # noqa: E402


def ledger(*entries):
    return [{"owner": owner, "reason": reason, "count": count, "per_second": 0} for owner, reason, count in entries]


class FakeControl:
    """A control socket whose replies come from `replies[method]`: a list (one per call, the last repeats) or a
    callable of (params)."""

    def __init__(self, replies):
        self.replies = replies
        self.calls = []

    def call(self, method, params=None, timeout=None):
        self.calls.append((method, params or {}))
        reply = self.replies.get(method)
        if reply is None:
            return {"error": {"code": "unknown_method"}}
        if callable(reply):
            return reply(params or {})
        index = sum(1 for name, _ in self.calls if name == method) - 1
        return reply[min(index, len(reply) - 1)]

    def action(self, name, timeout=None, **args):
        params = {"action": name}
        if args:
            params["args"] = args
        return self.call("action.run", params, timeout=timeout)


def args_for(**overrides):
    values = dict(max_cpu=0.5, max_wakeups=5, max_host_cpu=0.2, max_host_wakeups=2, max_helper_cpu=1.0,
                  max_mixed_wakeups=1.0, max_main_wakeups=0.5, hidden_tabs=10, hidden_terminals=5, url="http://x/p",
                  mixed_ready=False)
    values.update(overrides)
    namespace = argparse.Namespace(**values)
    namespace.next_url = lambda: namespace.url
    return namespace


def row(kind, wakeups, cpu=0.0, pid=1):
    return {"pid": pid, "kind": kind, "cpu_percent": cpu, "wakeups_per_s": wakeups, "footprint_mb": 1.0}


class MainWakeupsTests(unittest.TestCase):
    def test_rate_is_the_delta_per_second(self):
        self.assertEqual(bi.rate(100, 130, 60), 0.5)

    def test_a_missing_or_reset_counter_is_not_measured(self):
        self.assertIsNone(bi.rate(None, 10, 60))
        self.assertIsNone(bi.rate(10, None, 60))
        self.assertIsNone(bi.rate(50, 10, 60))
        self.assertIsNone(bi.rate(1, 2, 0))

    def test_main_wakes_reads_debug_hangs(self):
        control = FakeControl({"debug.hangs": [{"result": {"main_wakes": 42}}]})
        self.assertEqual(bi.main_wakes(control), 42)
        self.assertEqual(control.calls, [("debug.hangs", {"limit": 0})])

    def test_main_wakes_is_none_without_the_field(self):
        self.assertIsNone(bi.main_wakes(FakeControl({"debug.hangs": [{"result": {"count": 0}}]})))
        self.assertIsNone(bi.main_wakes(FakeControl({})))


class OwnerTests(unittest.TestCase):
    def test_owners_sum_reasons_and_sort_most_first(self):
        start = ledger(("terminal", "tick", 10), ("sidebar", "timer", 5))
        end = ledger(("terminal", "tick", 40), ("terminal", "blink", 6), ("sidebar", "timer", 5), ("cef", "pump", 15))
        owners = bi.owner_wakeups(start, end, 10)
        self.assertEqual([o["owner"] for o in owners], ["terminal", "cef"])  # sidebar did not wake
        self.assertEqual(owners[0], {"owner": "terminal", "wakeups": 36, "reasons": {"tick": 30, "blink": 6},
                                     "per_second": 3.6})
        self.assertEqual(owners[1]["per_second"], 1.5)

    def test_a_reset_ledger_counts_its_end(self):
        owners = bi.owner_wakeups(ledger(("a", "r", 100)), ledger(("a", "r", 4)), 2)
        self.assertEqual(owners[0]["wakeups"], 4)

    def test_no_ledger_is_no_owner(self):
        self.assertEqual(bi.owner_wakeups(None, None, 10), [])


class HiddenCounterTests(unittest.TestCase):
    def test_deltas(self):
        start = {"hidden_workspace_layouts": 3, "hidden_workspace_applies": 1, "workspace_applies": 9}
        end = {"hidden_workspace_layouts": 5, "hidden_workspace_applies": 1, "workspace_applies": 20}
        self.assertEqual(bi.hidden_counters(start, end), {"hidden_workspace_layouts": 2, "hidden_workspace_applies": 0})

    def test_a_sum_that_went_back_is_not_measured(self):
        # A hidden workspace that unmounted inside the window took its counts with it.
        start = {"hidden_workspace_layouts": 4, "hidden_workspace_applies": 9}
        end = {"hidden_workspace_layouts": 1, "hidden_workspace_applies": 9}
        self.assertEqual(bi.hidden_counters(start, end), {"hidden_workspace_layouts": None, "hidden_workspace_applies": 0})

    def test_none_without_the_method_or_the_field(self):
        self.assertEqual(bi.hidden_counters(None, None), {"hidden_workspace_layouts": None, "hidden_workspace_applies": None})
        self.assertEqual(bi.hidden_counters({"workspace_applies": 1}, {"workspace_applies": 2})["hidden_workspace_layouts"],
                         None)


class MeasureTests(unittest.TestCase):
    def test_measure_records_main_wakeups_owners_and_hidden_counters(self):
        control = FakeControl({
            "debug.wakeups": [{"result": {"ledger": ledger(("terminal", "tick", 10))}},
                              {"result": {"ledger": ledger(("terminal", "tick", 70)), "active_frame_clients": [],
                                          "display_links": 0}}],
            "debug.layout_counters": [{"result": {"hidden_workspace_layouts": 0, "hidden_workspace_applies": 0}},
                                      {"result": {"hidden_workspace_layouts": 2, "hidden_workspace_applies": 1}}],
            "debug.hangs": [{"result": {"main_wakes": 1000}}, {"result": {"main_wakes": 1030}},
                            {"result": {"busy_count": 0, "count": 0}}],
        })
        samples = iter([(0, 0, 1 << 20), (0, 60, 1 << 20)])
        clock = iter([100.0, 160.0])
        with mock.patch.object(bi, "classify", return_value={7: "app"}), \
                mock.patch.object(bi, "usage", side_effect=lambda pid: next(samples)), \
                mock.patch.object(bi.time, "sleep"), mock.patch.object(bi.time, "monotonic", side_effect=lambda: next(clock)):
            result = bi.measure(7, "/b.app", 60, control)
        self.assertEqual(result["main_wakeups_per_s"], 0.5)
        self.assertEqual(result["owners"], [{"owner": "terminal", "wakeups": 60, "reasons": {"tick": 60}, "per_second": 1.0}])
        self.assertEqual(result["hidden_workspace_layouts"], 2)
        self.assertEqual(result["hidden_workspace_applies"], 1)
        self.assertEqual(result["processes"][0]["wakeups_per_s"], 1.0)
        # The main-thread requests come before the first main_wakes read and after the second.
        methods = [name for name, _ in control.calls]
        first_hang, second_hang = [i for i, name in enumerate(methods) if name == "debug.hangs"][:2]
        self.assertEqual(methods[:first_hang], ["debug.wakeups", "debug.layout_counters"])
        self.assertTrue(all(name != "debug.wakeups" for name in methods[first_hang:second_hang]))
        json.dumps(result)


class ScenarioTests(unittest.TestCase):
    def test_mixed_hidden_expands_to_both_phases_once(self):
        self.assertEqual(bi.scenario_list("terminals,mixed-hidden"),
                         ["terminals", "mixed-hidden-visible", "mixed-hidden-app-hidden"])
        self.assertEqual(bi.scenario_list("mixed-hidden-app-hidden,mixed-hidden"),
                         ["mixed-hidden-app-hidden", "mixed-hidden-visible"])

    def test_mixed_hidden_criteria(self):
        result = {"processes": [row("app", 0.6), row("daemon", 0.6, pid=2), row("terminal-host", 0.1, pid=3)],
                  "main_wakeups_per_s": 0.8, "hidden_workspace_layouts": 0}
        failures = bi.criteria("mixed-hidden-visible", result, args_for())
        self.assertEqual(failures, ["mixed-hidden-visible: app + daemon 1.2 wakeups/s > 1.0",
                                    "mixed-hidden-visible: main thread 0.8 wakeups/s > 0.5"])
        # Other scenarios keep their per-process limits only.
        self.assertEqual(bi.criteria("terminals", result, args_for()), [])

    def test_a_hidden_workspace_layout_fails_any_scenario(self):
        result = {"processes": [], "hidden_workspace_layouts": 3}
        self.assertEqual(bi.criteria("chromium-hidden", result, args_for()), ["chromium-hidden: 3 hidden workspace layouts > 0"])
        # Not measured (a Release build) is not a failure.
        self.assertEqual(bi.criteria("chromium-hidden", {"processes": [], "hidden_workspace_layouts": None}, args_for()), [])

    def test_mixed_hidden_setup_then_app_hidden(self):
        control = FakeControl({"action.run": [{"result": {}}]})
        args = args_for(hidden_tabs=3, hidden_terminals=2)
        with mock.patch.object(bi, "classify", return_value={7: "app", 8: "cef-renderer"}):
            self.assertIsNone(bi.prepare("mixed-hidden-visible", control, args, 7, "/b.app"))
            actions = [params["action"] for _, params in control.calls]
            self.assertEqual(actions, ["openBrowser.chromium"] * 3 + ["newSurface"] * 2 + ["newTab"])
            control.calls.clear()
            self.assertIsNone(bi.prepare("mixed-hidden-app-hidden", control, args, 7, "/b.app"))
        self.assertEqual(control.calls, [("action.run", {"action": "showHideAllWindows", "args": {"hidden": True},
                                                         "focus": False, "origin": "script"})])

    def test_app_hidden_phase_alone_sets_the_workspace_up_first(self):
        control = FakeControl({"action.run": [{"result": {}}]})
        with mock.patch.object(bi, "classify", return_value={8: "cef-renderer"}):
            self.assertIsNone(bi.prepare("mixed-hidden-app-hidden", control, args_for(hidden_tabs=1, hidden_terminals=1),
                                         7, "/b.app"))
        actions = [params["action"] for _, params in control.calls]
        self.assertEqual(actions, ["openBrowser.chromium", "newSurface", "newTab", "showHideAllWindows"])

    def test_a_refused_terminal_skips_the_scenario(self):
        def reply(params):
            return {"ok": False, "error": {"code": "no_pane"}} if params["action"] == "newSurface" else {"result": {}}
        with mock.patch.object(bi, "classify", return_value={8: "cef-renderer"}):
            skipped = bi.prepare("mixed-hidden-visible", FakeControl({"action.run": reply}), args_for(hidden_tabs=1), 7, "/b")
        self.assertEqual(skipped, "terminal 1: {'code': 'no_pane'}")


def signpost(name, kind, message, at, pid=10):
    return json.dumps({"eventType": "signpostEvent", "signpostName": name, "signpostType": kind,
                       "eventMessage": message, "machTimestamp": at, "processID": pid})


class LaunchOrderTests(unittest.TestCase):
    def lines(self, *extra):
        return ["Filtering the log data using ...",
                signpost("launch.mark", "event", "main_start ms=1.0", 10),
                signpost("stall.main_task", "begin", "class=visible owner=daemon.store", 20),
                signpost("stall.main_task", "end", "", 21),
                *extra,
                signpost("launch.mark", "event", "launch.revealed ms=120.5", 100),
                signpost("stall.main_task", "begin", "class=background owner=feed", 110),
                json.dumps({"eventType": "lossEvent"}), "not json"]

    def test_deferred_work_after_the_reveal_holds(self):
        events = bl.launch_signposts(self.lines(), pid=10)
        result = bl.launch_order(events)
        self.assertTrue(result["order_ok"], result)
        self.assertEqual((result["main_tasks_seen"], result["main_tasks_before_reveal"], result["early_main_tasks"]),
                         (2, 1, 0))

    def test_a_background_task_before_the_reveal_fails(self):
        lines = self.lines(signpost("stall.main_task", "begin", "class=background owner=updates", 50),
                           signpost("stall.main_task", "begin", "class=automation owner=cli", 60))
        result = bl.launch_order(bl.launch_signposts(lines, pid=10))
        self.assertFalse(result["order_ok"])
        self.assertEqual(result["early_main_owners"], [{"class": "background", "owner": "updates"}])
        self.assertIn("1 background/idle/bestEffort main tasks before launch.revealed", result["reason"])

    def test_another_process_is_ignored(self):
        lines = self.lines(signpost("stall.main_task", "begin", "class=background owner=x", 50, pid=99))
        self.assertTrue(bl.launch_order(bl.launch_signposts(lines, pid=10))["order_ok"])

    def test_no_reveal_or_no_task_fails_closed(self):
        no_reveal = [signpost("stall.main_task", "begin", "class=visible owner=a", 1)]
        self.assertEqual(bl.launch_order(bl.launch_signposts(no_reveal))["reason"], "no launch.revealed signpost")
        no_task = [signpost("launch.mark", "event", "launch.revealed ms=1", 1)]
        result = bl.launch_order(bl.launch_signposts(no_task))
        self.assertFalse(result["order_ok"])
        self.assertIn("no stall.main_task signposts", result["reason"])

    def test_startup_trace_lane_jobs(self):
        # StartupTraceEncoder's form: an open trace has no closing bracket yet.
        trace = ('[\n{"name":"process_name","ph":"M","pid":1,"tid":0,"args":{"name":"cmux"}}\n'
                 ',\n{"name":"lane.files","cat":"lane","ph":"X","ts":50.000,"dur":1.0,"pid":1,"tid":2,"args":{"priority":"userVisible"}}'
                 ',\n{"name":"lane.cpu","cat":"lane","ph":"X","ts":60.000,"dur":1.0,"pid":1,"tid":2,"args":{"priority":"bestEffort"}}'
                 ',\n{"name":"launch.revealed","cat":"launch","ph":"i","s":"p","ts":100.000,"pid":1,"tid":1}'
                 ',\n{"name":"lane.system","cat":"lane","ph":"X","ts":150.000,"dur":1.0,"pid":1,"tid":2,"args":{"priority":"idle"}}\n')
        events = bl.startup_trace_events(trace)
        self.assertEqual(len(events), 5)
        self.assertEqual(bl.startup_trace_events(trace + "]\n"), events)
        result = bl.launch_order(bl.launch_signposts(self.lines(), pid=10), events)
        self.assertFalse(result["order_ok"])
        self.assertEqual(result["early_lane_job_names"], [{"lane": "lane.cpu", "priority": "bestEffort"}])
        self.assertEqual(result["lane_jobs_seen"], 3)
        self.assertEqual(bl.startup_trace_events(""), [])
        self.assertEqual(bl.startup_trace_events("[\n{broken"), [])

    def test_summary_needs_every_run(self):
        self.assertTrue(bl.launch_order_summary([{"run": 1, "order_ok": True}])["order_ok"])
        summary = bl.launch_order_summary([{"run": 1, "order_ok": True}, {"run": 2, "order_ok": False}])
        self.assertEqual((summary["order_ok"], summary["failed_runs"]), (False, [2]))
        self.assertFalse(bl.launch_order_summary([])["order_ok"])


class LaunchOrderCommandTests(unittest.TestCase):
    def test_order_writes_launch_order_ok(self):
        out = tempfile.mkdtemp(prefix="bench-idle-test-")
        lines = LaunchOrderTests.lines(LaunchOrderTests())

        class Process:
            pid = 10

        class Stream:
            def __init__(self, path):
                with open(path, "w") as f:
                    f.write("\n".join(lines) + "\n")

            def send_signal(self, _):
                pass

            def wait(self, timeout=None):
                return 0

        class App:
            def __init__(self, env):
                self.env, self.process, self.stopped = env, Process(), False

            def launch(self, timeout):
                pass

            def rpc(self, method, params=None, timeout=60):
                if method == "debug.timings":
                    return {"launch_ms_since_process_start": {"launch.revealed": 120.5}}
                return {"enabled": True}

            def stop(self):
                self.stopped = True

        apps = []

        def make_app(env):
            apps.append(App(env))
            return apps[-1]

        opts = argparse.Namespace(app="/x.app", out=out, runs=2, timeout=5, after=0, trace_seconds=30,
                                  json=os.path.join(out, "order.json"))
        with contextlib.redirect_stdout(io.StringIO()) as printed, contextlib.redirect_stderr(io.StringIO()):
            code = bl.launch_order_check(opts, make_app=make_app, start_stream=Stream)
        self.assertEqual(code, 0)
        with open(opts.json) as f:
            written = json.load(f)
        self.assertTrue(written["launch"]["order_ok"])
        self.assertEqual(written["launch"]["runs"], 2)
        self.assertIn("BENCH-LAUNCH ", printed.getvalue())
        self.assertTrue(all(app.stopped for app in apps))
        self.assertEqual(apps[0].env["CMUX_TRACE_STARTUP"], "30")
        self.assertTrue(apps[0].env["CMUX_TRACE_STARTUP_FILE"].endswith("startup-1.json"))

    def test_order_is_a_subcommand(self):
        with contextlib.redirect_stdout(io.StringIO()) as printed, self.assertRaises(SystemExit):
            bl.main(["order", "--help"])
        self.assertIn("--trace-seconds", printed.getvalue())


if __name__ == "__main__":
    unittest.main()
