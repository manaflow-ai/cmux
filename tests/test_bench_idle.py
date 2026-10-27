#!/usr/bin/env python3
"""scripts/cmux-next/bench_idle.py and bench_launch.py's launch order check: the parsers behind their JSON
(p06-scheduler-229, done checks 4, 6 and 7 of plans/cmux-next/chrome-parity/p06-scheduler.md).

1. `main_wakeups_per_s` is the `debug.hangs` `main_wakes` delta over the window, read last before and first after
   it; a missing or reset counter is None, never 0.
2. `owners` is the per-owner `debug.wakeups` ledger delta over the window, reasons summed, most first.
3. `hidden_workspace_layouts` and `hidden_workspace_applies` are `debug.layout_counters` deltas of app-wide
   monotonic counters; None without the method (a Release build) or when a counter went back (a reset).
   The end usage samples come before every request after the window.
4. `mixed-hidden` expands to its window-visible and app-hidden phases; the criteria judge app + daemon and main
   wakeups there, fail when main wakeups, hidden layouts (with the method) or window visibility was not measured,
   and judge a hidden workspace layout in any scenario.
5. The mixed-hidden setup opens the tabs and terminals, then a new workspace, then hides the app; it runs once,
   for whichever phase runs first, and a minimized window is restored first.
6. `launch.order_ok`: no background, idle or best-effort task before `launch.revealed`, from the app's signposts
   and its startup trace (an open trace without its closing `]` too); no reveal, no scheduled task, a signpost
   loss event or a missing trace file fails closed.
7. `bench_launch.py order` writes `{"launch": {"order_ok": ...}}` from a stubbed app and signpost stream.
8. app-hidden and covered-window (p03-rendering-097): app-hidden only hides the app; covered-window puts a new
   window at the shown one's exact frame, and skips while windowOcclusionFamily is off; both judge main wakeups
   (not measured fails) and covered-window fails unless the covered window's family was occluded. Their launch
   turns the feature on as a Labs local choice (bench_launch.write_local_features keeps the file's other choices)
   with the user's draw of occluded windows.
9. hidden-printing (p03-rendering-088) opens --printing-terminals terminals with focus, sends PRINT_LOOP to each
   new daemon tab by its own `tab:<id>` target (never the selected tab), then a new workspace with focus hides
   them; a refused step, a tab that never appears or a printing workspace that still shows skips it; it runs
   last, and its result is reported, never judged.

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


class FakeSession:
    """An app session for hidden-printing: snapshot.get's topology changes as the actions run. newSurface adds a
    terminal tab to the shown workspace (first a provisional one with no `terminal` id when `provisional_first`),
    newTab adds a workspace and shows it unless `new_workspace_shows` is False; `refuse` names an action that
    fails."""

    def __init__(self, creates_tabs=True, provisional_first=False, new_workspace_shows=True, refuse=None):
        self.creates_tabs, self.provisional_first = creates_tabs, provisional_first
        self.new_workspace_shows, self.refuse = new_workspace_shows, refuse
        self.workspaces = {"ws_1": [{"id": "tab_launch", "kind": "terminal", "terminal": "term_launch",
                                     "selected": True}]}
        self.shown = "ws_1"
        self.made = []

    def control(self):
        return FakeControl({"action.run": self.run, "snapshot.get": lambda _params: {"result": {"topology": self.topology()}}})

    def run(self, params):
        name = params["action"]
        if name == self.refuse:
            return {"ok": False, "error": {"code": "no_terminal"}}
        if name == "newSurface" and self.creates_tabs:
            tabs = self.workspaces[self.shown]
            if self.provisional_first:
                tabs.append({"id": "tab_provisional", "kind": "terminal", "terminal": None})
                self.provisional_first = False
            tab = f"tab_{len(self.made) + 1}"
            tabs.append({"id": tab, "kind": "terminal", "terminal": f"term_{len(self.made) + 1}"})
            self.made.append(tab)
        elif name == "newTab":
            workspace = f"ws_{len(self.workspaces) + 1}"
            self.workspaces[workspace] = []
            if self.new_workspace_shows:
                self.shown = workspace
        return {"result": {}}

    def topology(self):
        return {"windows": [{"id": "win_1", "workspace": self.shown}],
                "workspaces": [{"id": workspace, "screens": [{"panes": [{"id": f"pane_{workspace}", "tabs": tabs}]}]}
                               for workspace, tabs in self.workspaces.items()]}


def args_for(**overrides):
    values = dict(max_cpu=0.5, max_wakeups=5, max_host_cpu=0.2, max_host_wakeups=2, max_helper_cpu=1.0,
                  max_mixed_wakeups=1.0, max_main_wakeups=0.5, hidden_tabs=10, hidden_terminals=5, url="http://x/p",
                  mixed_ready=False, has_layout_counters=True, printing_terminals=10)
    values.update(overrides)
    namespace = argparse.Namespace(**values)
    namespace.next_url = lambda: namespace.url
    return namespace


def main_window(visible, miniaturized):
    return {"result": {"windows": [{"kind": "main", "visible": visible, "miniaturized": miniaturized},
                                   {"kind": "popover", "visible": False, "miniaturized": False}]}}


SHOWN, MINIMIZED = main_window(True, False), main_window(False, True)


def actions_of(control):
    return [params["action"] for method, params in control.calls if method == "action.run"]


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

    def test_a_counter_that_went_back_is_not_measured(self):
        # A `reset` inside the window.
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
        samples = iter([bi.procs.Usage(footprint=1 << 20), bi.procs.Usage(interrupt_wakeups=60, footprint=1 << 20)])
        clock = iter([100.0, 160.0])
        with mock.patch.object(bi, "classify", return_value={7: "app"}), \
                mock.patch.object(bi.procs, "usage", side_effect=lambda pid: next(samples)), \
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

    def test_end_usage_comes_before_any_request_after_the_window(self):
        order = []

        def hangs(params):
            order.append(("debug.hangs", params))
            return {"result": {"main_wakes": 1}}

        def sample(pid):
            order.append(("usage", pid))
            return bi.procs.Usage()

        control = FakeControl({"debug.hangs": hangs})
        clock = iter([0.0, 10.0])
        with mock.patch.object(bi, "classify", return_value={7: "app"}), mock.patch.object(bi.procs, "usage", side_effect=sample), \
                mock.patch.object(bi.time, "sleep", side_effect=lambda _: order.append(("sleep",))), \
                mock.patch.object(bi.time, "monotonic", side_effect=lambda: next(clock)):
            bi.measure(7, "/b.app", 10, control)
        sleep = order.index(("sleep",))
        self.assertEqual(order[sleep - 2:sleep + 3], [("debug.hangs", {"limit": 0}), ("usage", 7), ("sleep",),
                                                       ("usage", 7), ("debug.hangs", {"limit": 0})])


class ScenarioTests(unittest.TestCase):
    def test_mixed_hidden_expands_to_both_phases_once(self):
        self.assertEqual(bi.scenario_list("terminals,mixed-hidden"),
                         ["terminals", "mixed-hidden-visible", "mixed-hidden-app-hidden"])
        self.assertEqual(bi.scenario_list("mixed-hidden-app-hidden,mixed-hidden"),
                         ["mixed-hidden-app-hidden", "mixed-hidden-visible"])

    def test_mixed_hidden_criteria(self):
        result = {"processes": [row("app", 0.6), row("daemon", 0.6, pid=2), row("terminal-host", 0.1, pid=3)],
                  "main_wakeups_per_s": 0.8, "hidden_workspace_layouts": 0, "window_visible": True}
        failures = bi.criteria("mixed-hidden-visible", result, args_for())
        self.assertEqual(failures, ["mixed-hidden-visible: app + daemon 1.2 wakeups/s > 1.0",
                                    "mixed-hidden-visible: main thread 0.8 wakeups/s > 0.5"])
        # Other scenarios keep their per-process limits only.
        self.assertEqual(bi.criteria("terminals", result, args_for()), [])

    def test_a_hidden_workspace_layout_fails_any_scenario(self):
        result = {"processes": [], "hidden_workspace_layouts": 3}
        self.assertEqual(bi.criteria("chromium-hidden", result, args_for()), ["chromium-hidden: 3 hidden workspace layouts > 0"])
        # Not measured is not a failure in the older scenarios.
        self.assertEqual(bi.criteria("chromium-hidden", {"processes": [], "hidden_workspace_layouts": None}, args_for()), [])

    def test_mixed_hidden_fails_closed_on_numbers_not_measured(self):
        result = {"processes": [row("app", 0.1)], "main_wakeups_per_s": None, "hidden_workspace_layouts": None,
                  "window_visible": None}
        self.assertEqual(bi.criteria("mixed-hidden-visible", result, args_for()), [
            "mixed-hidden-visible: main thread wakeups not measured",
            "mixed-hidden-visible: hidden workspace layouts not measured",
            "mixed-hidden-visible: the window was not visible (window_visible=None)"])
        # A build without debug.layout_counters cannot measure hidden layouts; the app-hidden phase has no window check.
        self.assertEqual(bi.criteria("mixed-hidden-app-hidden", result, args_for(has_layout_counters=False)),
                         ["mixed-hidden-app-hidden: main thread wakeups not measured"])
        minimized = {"processes": [], "main_wakeups_per_s": 0.1, "hidden_workspace_layouts": 0, "window_visible": False}
        self.assertEqual(bi.criteria("mixed-hidden-visible", minimized, args_for()),
                         ["mixed-hidden-visible: the window was not visible (window_visible=False)"])

    def test_mixed_hidden_setup_then_app_hidden(self):
        control = FakeControl({"action.run": [{"result": {}}], "debug.window_list": [SHOWN]})
        args = args_for(hidden_tabs=3, hidden_terminals=2)
        with mock.patch.object(bi, "classify", return_value={7: "app", 8: "cef-renderer"}):
            self.assertIsNone(bi.prepare("mixed-hidden-visible", control, args, 7, "/b.app"))
            self.assertEqual(actions_of(control), ["openBrowser.chromium"] * 3 + ["newSurface"] * 2 + ["newTab"])
            control.calls.clear()
            self.assertIsNone(bi.prepare("mixed-hidden-app-hidden", control, args, 7, "/b.app"))
        self.assertEqual([call for call in control.calls if call[0] == "action.run"],
                         [("action.run", {"action": "showHideAllWindows", "args": {"hidden": True},
                                          "focus": False, "origin": "script"})])

    def test_app_hidden_then_visible_sets_up_once(self):
        control = FakeControl({"action.run": [{"result": {}}], "debug.window_list": [SHOWN]})
        args = args_for(hidden_tabs=2, hidden_terminals=1)
        with mock.patch.object(bi, "classify", return_value={8: "cef-renderer"}):
            for scenario in bi.scenario_list("mixed-hidden-app-hidden,mixed-hidden"):
                self.assertIsNone(bi.prepare(scenario, control, args, 7, "/b.app"))
        self.assertEqual(actions_of(control),
                         ["openBrowser.chromium"] * 2 + ["newSurface", "newTab", "showHideAllWindows"])

    def test_a_minimized_window_is_restored_before_mixed_hidden(self):
        # `minimized` ran before: the window is in the Dock until showMainWindow restores it.
        control = FakeControl({"action.run": [{"result": {}}], "debug.window_list": [MINIMIZED, MINIMIZED, SHOWN]})
        with mock.patch.object(bi, "classify", return_value={8: "cef-renderer"}), mock.patch.object(bi.time, "sleep"):
            self.assertIsNone(bi.prepare("mixed-hidden-visible", control, args_for(hidden_tabs=1, hidden_terminals=0),
                                         7, "/b.app"))
        self.assertEqual(actions_of(control), ["showMainWindow", "openBrowser.chromium", "newTab"])

    def test_a_window_that_stays_minimized_skips_the_phase(self):
        control = FakeControl({"action.run": [{"result": {}}], "debug.window_list": [MINIMIZED]})
        clock = iter(float(t) for t in range(100))
        with mock.patch.object(bi.time, "sleep"), mock.patch.object(bi.time, "monotonic", side_effect=lambda: next(clock)):
            skipped = bi.prepare("mixed-hidden-visible", control, args_for(hidden_tabs=1), 7, "/b.app")
        self.assertEqual(skipped, "the main window is still minimized or hidden 15 s after showMainWindow")
        self.assertEqual(actions_of(control), ["showMainWindow"])

    def test_hidden_printing_prints_in_each_new_tab_by_its_own_target(self):
        session = FakeSession()
        control = session.control()
        self.assertIsNone(bi.prepare("hidden-printing", control, args_for(printing_terminals=3), 7, "/b.app"))
        self.assertEqual(actions_of(control), ["newSurface", "terminal.sendText"] * 3 + ["newTab"])
        sends = [params for _, params in control.calls if params.get("action") == "terminal.sendText"]
        self.assertEqual([params["args"]["text"] for params in sends], [bi.PRINT_LOOP] * 3)
        targets = [params.get("target") for params in sends]
        # Each loop goes to a distinct tab the bench made, never the launch tab that was selected before.
        self.assertEqual(targets, [f"tab:{tab}" for tab in session.made])
        self.assertEqual(len(set(targets)), 3)
        self.assertNotIn("tab:tab_launch", targets)
        self.assertTrue(all(params.get("focus") is False for params in sends))
        creates = [params for _, params in control.calls if params.get("action") in ("newSurface", "newTab")]
        self.assertTrue(all(params.get("focus") is True for params in creates))
        self.assertEqual(session.shown, "ws_2")

    def test_a_provisional_tab_is_not_a_print_target(self):
        session = FakeSession(provisional_first=True)
        control = session.control()
        self.assertIsNone(bi.prepare("hidden-printing", control, args_for(printing_terminals=1), 7, "/b.app"))
        targets = [params.get("target") for _, params in control.calls if params.get("action") == "terminal.sendText"]
        self.assertEqual(targets, [f"tab:{session.made[0]}"])

    def test_a_terminal_that_never_appears_skips_hidden_printing(self):
        session = FakeSession(creates_tabs=False)
        with mock.patch.object(bi, "wait_for", side_effect=lambda condition, _limit: condition()):
            skipped = bi.prepare("hidden-printing", session.control(), args_for(), 7, "/b.app")
        self.assertEqual(skipped, "printing terminal 1: no new terminal tab in 15 s")

    def test_a_printing_workspace_that_still_shows_skips_hidden_printing(self):
        session = FakeSession(new_workspace_shows=False)
        with mock.patch.object(bi, "wait_for", side_effect=lambda condition, _limit: condition()):
            skipped = bi.prepare("hidden-printing", session.control(), args_for(printing_terminals=1), 7, "/b.app")
        self.assertEqual(skipped, "the printing workspace still shows 15 s after newTab")

    def test_a_refused_print_skips_hidden_printing(self):
        session = FakeSession(refuse="terminal.sendText")
        skipped = bi.prepare("hidden-printing", session.control(), args_for(), 7, "/b.app")
        self.assertEqual(skipped, "printing terminal 1: terminal.sendText: {'code': 'no_terminal'}")

    def test_hidden_printing_runs_last(self):
        self.assertIsNone(bi.scenario_order_error(["terminals", "minimized", "hidden-printing"]))
        self.assertEqual(bi.scenario_order_error(["hidden-printing", "minimized"]),
                         "hidden-printing runs last (its terminals keep printing)")
        self.assertEqual(bi.scenario_order_error(["tabs-10", "terminals"]), "tabs-10 runs alone (--scenarios tabs-10)")
        self.assertIsNone(bi.scenario_order_error(["tabs-10"]))

    def test_hidden_printing_is_reported_not_judged(self):
        busy = {"processes": [row("app", 400.0, cpu=30.0), row("daemon", 90.0, cpu=5.0, pid=2)]}
        self.assertEqual(bi.criteria("hidden-printing", busy, args_for()), [])

    def test_main_window_shown(self):
        self.assertTrue(bi.main_window_shown(FakeControl({"debug.window_list": [SHOWN]})))
        self.assertFalse(bi.main_window_shown(FakeControl({"debug.window_list": [MINIMIZED]})))
        self.assertIsNone(bi.main_window_shown(FakeControl({})))
        panel_only = {"result": {"windows": [{"kind": "panel", "visible": True, "miniaturized": False}]}}
        self.assertIsNone(bi.main_window_shown(FakeControl({"debug.window_list": [panel_only]})))

    def test_app_hidden_phase_alone_sets_the_workspace_up_first(self):
        control = FakeControl({"action.run": [{"result": {}}], "debug.window_list": [SHOWN]})
        with mock.patch.object(bi, "classify", return_value={8: "cef-renderer"}):
            self.assertIsNone(bi.prepare("mixed-hidden-app-hidden", control, args_for(hidden_tabs=1, hidden_terminals=1),
                                         7, "/b.app"))
        self.assertEqual(actions_of(control), ["openBrowser.chromium", "newSurface", "newTab", "showHideAllWindows"])

    def test_a_refused_terminal_skips_the_scenario(self):
        def reply(params):
            return {"ok": False, "error": {"code": "no_pane"}} if params["action"] == "newSurface" else {"result": {}}
        with mock.patch.object(bi, "classify", return_value={8: "cef-renderer"}):
            skipped = bi.prepare("mixed-hidden-visible", FakeControl({"action.run": reply, "debug.window_list": [SHOWN]}),
                                 args_for(hidden_tabs=1), 7, "/b")
        self.assertEqual(skipped, "terminal 1: {'code': 'no_pane'}")


FRAME = [0, 0, 1200, 800]
FAMILY_ON = {"result": {"features": [{"name": "windowOcclusionFamily", "state": "on", "source": "local"}]}}
FAMILY_OFF = {"result": {"features": [{"name": "windowOcclusionFamily", "state": "off", "source": "default"}]}}


def windows(*entries):
    return {"result": {"windows": [{"id": wid, "visible": True, "family_occluded": occluded} for wid, occluded in entries]}}


class OcclusionScenarioTests(unittest.TestCase):
    def setUp(self):
        bi.COVERED.clear()

    def covering_control(self, features=FAMILY_ON):
        def frame(params):
            return {"result": {"frame": params.get("frame", FRAME)}}
        return FakeControl({"action.run": [{"result": {}}], "debug.window_list": [SHOWN], "features.list": [features],
                            "debug.windows": [windows(("w1", False)), windows(("w1", False)),
                                              windows(("w1", False), ("w2", False))],
                            "debug.window_frame": frame})

    def test_the_occlusion_scenarios_are_scenarios_of_their_own(self):
        self.assertEqual(bi.scenario_list("app-hidden,covered-window"), ["app-hidden", "covered-window"])

    def test_app_hidden_only_hides_the_app(self):
        control = FakeControl({"action.run": [{"result": {}}]})
        self.assertIsNone(bi.prepare("app-hidden", control, args_for(), 7, "/b.app"))
        self.assertEqual(actions_of(control), ["showHideAllWindows"])

    def test_covered_window_puts_a_new_window_at_the_shown_ones_frame(self):
        control = self.covering_control()
        with mock.patch.object(bi.time, "sleep"):
            self.assertIsNone(bi.prepare("covered-window", control, args_for(), 7, "/b.app"))
        self.assertEqual(actions_of(control), ["newWindow"])
        frames = [params for method, params in control.calls if method == "debug.window_frame"]
        self.assertEqual(frames, [{"window": "w1"}, {"window": "w2", "frame": FRAME}])
        self.assertEqual(bi.COVERED, {"window": "w1"})

    def test_covered_window_skips_while_the_feature_is_off(self):
        control = self.covering_control(FAMILY_OFF)
        self.assertEqual(bi.prepare("covered-window", control, args_for(), 7, "/b.app"),
                         "the feature windowOcclusionFamily is off")
        self.assertEqual(actions_of(control), [])

    def test_covered_window_skips_when_the_cover_does_not_take_the_frame(self):
        control = self.covering_control()
        control.replies["debug.window_frame"] = lambda params: {"result": {"frame": [10, 10, 600, 400] if "frame" in params else FRAME}}
        with mock.patch.object(bi.time, "sleep"):
            skipped = bi.prepare("covered-window", control, args_for(), 7, "/b.app")
        self.assertIn("the cover window took [10, 10, 600, 400]", skipped)
        self.assertEqual(bi.COVERED, {})

    def test_the_covered_family_is_read_from_debug_windows(self):
        bi.COVERED["window"] = "w1"
        control = FakeControl({"debug.windows": [windows(("w1", True), ("w2", False))]})
        self.assertIs(bi.covered_family_occluded(control), True)
        self.assertIsNone(bi.covered_family_occluded(FakeControl({})))

    def test_criteria_judge_main_wakeups_and_the_covered_family(self):
        quiet = {"processes": [row("app", 0.2)], "main_wakeups_per_s": 0.3, "covered_family_occluded": True}
        self.assertEqual(bi.criteria("covered-window", quiet, args_for()), [])
        self.assertEqual(bi.criteria("app-hidden", {"processes": [], "main_wakeups_per_s": 0.9}, args_for()),
                         ["app-hidden: main thread 0.9 wakeups/s > 0.5"])
        self.assertEqual(bi.criteria("covered-window", {"processes": [], "main_wakeups_per_s": None,
                                                        "covered_family_occluded": False}, args_for()),
                         ["covered-window: main thread wakeups not measured",
                          "covered-window: the covered window's family was not occluded (family_occluded=False)"])

    def test_the_occlusion_launch(self):
        self.assertEqual(bi.occlusion_launch(["terminals"]), ({}, None))
        self.assertEqual(bi.occlusion_launch(["terminals", "covered-window"]),
                         ({"CMUX_NEXT_BENCH_SHIPPING_DRAW": "1"}, {"windowOcclusionFamily": True}))

    def test_local_features_keep_the_files_other_choices(self):
        with tempfile.TemporaryDirectory() as root:
            os.makedirs(os.path.join(root, "features"))
            with open(os.path.join(root, "features", "local-overrides.json"), "w") as handle:
                json.dump({"energySaver": False, "windowOcclusionFamily": False, "junk": 3}, handle)
            path = bl.write_local_features(root, {"windowOcclusionFamily": True})
            with open(path) as handle:
                self.assertEqual(json.load(handle), {"energySaver": False, "windowOcclusionFamily": True})
        with tempfile.TemporaryDirectory() as root:
            path = bl.write_local_features(os.path.join(root, "fresh"), {"windowOcclusionFamily": True})
            with open(path) as handle:
                self.assertEqual(json.load(handle), {"windowOcclusionFamily": True})


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
                "not json"]

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

    def test_a_loss_event_fails_closed(self):
        # A dropped begin could have been a background task's before the reveal; a loss event of any process counts.
        loss = json.dumps({"eventType": "lossEvent", "processID": 0})
        result = bl.launch_order(bl.launch_signposts(self.lines(loss) + [loss], pid=10))
        self.assertFalse(result["order_ok"])
        self.assertEqual(result["signpost_loss_events"], 2)
        self.assertEqual(result["reason"], "2 signpost loss events: the stream cannot prove the order")

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
                if write_trace:
                    with open(self.env["CMUX_TRACE_STARTUP_FILE"], "w") as f:
                        f.write('[\n{"name":"launch.revealed","cat":"launch","ph":"i","s":"p","ts":100.0,"pid":1,"tid":1}\n')

            def rpc(self, method, params=None, timeout=60):
                if method == "debug.timings":
                    return {"launch_ms_since_process_start": {"launch.revealed": 120.5}}
                return {"enabled": True}

            def stop(self):
                self.stopped = True

        apps = []
        write_trace = True

        def make_app(env):
            apps.append(App(env))
            return apps[-1]

        def check(name):
            opts = argparse.Namespace(app="/x.app", out=out, runs=2, timeout=5, after=0, trace_seconds=30,
                                      json=os.path.join(out, name))
            with contextlib.redirect_stdout(io.StringIO()) as printed, contextlib.redirect_stderr(io.StringIO()):
                code = bl.launch_order_check(opts, make_app=make_app, start_stream=Stream)
            with open(opts.json) as f:
                return code, json.load(f), printed.getvalue()

        code, written, printed = check("order.json")
        self.assertEqual(code, 0, written)
        self.assertTrue(written["launch"]["order_ok"])
        self.assertEqual(written["launch"]["runs"], 2)
        self.assertIn("BENCH-LAUNCH ", printed)
        self.assertTrue(all(app.stopped for app in apps))
        self.assertEqual(apps[0].env["CMUX_TRACE_STARTUP"], "30")
        self.assertTrue(apps[0].env["CMUX_TRACE_STARTUP_FILE"].endswith("startup-1.json"))

        # No startup trace file (the env not honored, or its write failed) is no evidence: the run fails closed.
        for index in (1, 2):
            os.remove(os.path.join(out, f"startup-{index}.json"))
        write_trace = False
        code, written, _ = check("order-no-trace.json")
        self.assertEqual(code, 1)
        run = written["launch"]["per_run"][0]
        self.assertEqual((run["order_ok"], run["trace_missing"]), (False, True))
        self.assertIn("no launch.revealed mark in the startup trace", run["reason"])

    def test_order_is_a_subcommand(self):
        with contextlib.redirect_stdout(io.StringIO()) as printed, self.assertRaises(SystemExit):
            bl.main(["order", "--help"])
        self.assertIn("--trace-seconds", printed.getvalue())


if __name__ == "__main__":
    unittest.main()
