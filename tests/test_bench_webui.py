#!/usr/bin/env python3
"""bench-webui.py against a fake app (no app, no macOS): the rows each mode prints from the census and the process
counters it is handed, the session shapes it refuses, percentiles, and that it reuses the existing benches' process
counting instead of a copy. Run: python3 -I -m unittest tests/test_bench_webui.py"""
import argparse
import contextlib
import importlib.util
import io
import os
import re
import subprocess
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(ROOT, "scripts", "cmux-next", "bench-webui.py")
spec = importlib.util.spec_from_file_location("bench_webui", SCRIPT)
webui = importlib.util.module_from_spec(spec)
spec.loader.exec_module(webui)


class FakeClock:
    """A sleep advances the clock, so settles and bounded polls end at once."""

    def __init__(self):
        self.now = 0.0
        self.slept = 0.0

    def monotonic(self):
        return self.now

    def sleep(self, seconds):
        self.now += max(seconds, 0.01)
        self.slept += max(seconds, 0.01)


class FakeApp:
    """Enough of the control socket: pages open through their actions and land in the `debug.webui` census; a page
    hidden for 10 s freezes (the most recently hidden one stays hidden), one hidden for 300 s with no keep reason is
    discarded; `leak` makes publishing reach frozen pages; `census` False is a build without debug.webui."""

    def __init__(self, clock, census=True, windows=1, tabs=(), cef=None, leak=False, fork_api=29, keep=()):
        self.clock, self.has_census, self.leak, self.keep = clock, census, leak, set(keep)
        self.windows, self.tabs = windows, list(tabs)
        self.cef = cef if cef is not None else {"state": "ready", "fork_api": fork_api}
        self.pages = {}  # page id -> {"state", "hidden_at", "pid", "deliveries"}
        self.order = []
        self.calls = []
        self.next_pid = 500
        self.groups = {}
        self.hides = 0  # the order pages were hidden in: socket calls take no fake time, so several hide at once

    def page_for(self, action, args):
        for page_id, name, _ in webui.PAGES10:
            if name == action:
                return page_id
        return None

    def show(self, page_id):
        for other, page in self.pages.items():
            if other != page_id and page["state"] == "active":
                self.hides += 1
                page.update(state="hidden", hidden_at=self.clock.now, hide_order=self.hides)
        if page_id:
            self.pages[page_id].update(state="active", hidden_at=None)

    def refresh(self):
        hidden = [p for p, page in self.pages.items() if page["state"] in ("hidden", "frozen")]
        newest = max(hidden, key=lambda p: self.pages[p]["hide_order"], default=None)
        for page_id in hidden:
            page = self.pages[page_id]
            age = self.clock.now - page["hidden_at"]
            if age >= 300 and page_id not in self.keep:
                page["state"] = "discarded"
            elif age >= 10 and page_id != newest:
                page["state"] = "frozen"

    def rpc(self, method, params=None, timeout=60):
        params = params or {}
        self.calls.append((method, params))
        if method == "snapshot.get":
            panes = [{"id": "p1", "tabs": [{"id": f"t{i}", "kind": kind} for i, kind in enumerate(self.tabs)]}]
            return {"topology": {"windows": [{"id": f"w{i}"} for i in range(self.windows)],
                                 "workspaces": [{"id": "ws1", "screens": [{"panes": panes}]}]}}
        if method == "action.run":
            action = params["action"]
            page_id = self.page_for(action, params.get("args"))
            if page_id:
                self.pages.setdefault(page_id, {"pid": self.renderer(page_id), "deliveries": 0})
                self.order.append(page_id)
                self.show(page_id)
            elif action == "newSurface":
                self.show(None)
            return {}
        if method == "debug.page":
            page = self.pages.get(params.get("page"))
            if params.get("action") == "list":
                return {"pages": [{"page": params["page"], "parked": False}] if page and page["state"] != "discarded" else []}
            return {"painted": bool(page), "controls": 3} if page else {"error": "no live page"}
        if method == "debug.cef":
            return self.cef
        if method == "debug.webui":
            if not self.has_census:
                return {"error": {"code": "method_not_found"}}
            if params.get("action") == "publish":
                for page in self.pages.values():
                    if page["state"] == "frozen" and self.leak:
                        page["deliveries"] += 3
                return {"publishing": True}
            if params.get("action") == "pressure":
                for page in self.pages.values():
                    if page["state"] in ("hidden", "frozen"):
                        page["state"] = "discarded"
                return {"pressure": "critical"}
            self.refresh()
            return {"rows": [{"row": "page", "page": p, "state": page["state"], "group": "privileged",
                              "keep_reasons": ["audio"] if p in self.keep else [],
                              "renderer_pid": None if page["state"] == "discarded" else page["pid"],
                              "hidden_deliveries": page["deliveries"], "hidden_pushes": 0, "devtools": False}
                             for p, page in self.pages.items()]}
        if method == "debug.wakeups":
            return {"ledger": [{"owner": "terminal.cursor", "reason": "blink", "per_second": 2}]}
        return {}

    def renderer(self, page_id):
        """Privileged pages share one renderer; every other page gets its own (the base's one per page)."""
        group = "privileged" if page_id in {p for p, _, _ in webui.PRIVILEGED5} else page_id
        if group not in self.groups:
            self.groups[group] = self.next_pid
            self.next_pid += 1
        return self.groups[group]


class FakeInstance:
    """procs.Instance: the counters a mode is handed (kinds as procs.window returns them)."""

    def __init__(self, clock, kinds=None, mb=200.0):
        self.clock, self.kinds, self.mb = clock, kinds or {}, mb
        self.windows = []

    def pids(self):
        return {}

    def memory(self, per_pid=False):
        return {"mb": self.mb, "processes": 3, "kinds": {}}

    def window(self, seconds, during=None, per_pid=False):
        self.windows.append(seconds)
        (during or self.clock.sleep)(seconds)
        return {"kinds": self.kinds, "seconds": seconds}


def options(**overrides):
    values = dict(engine="chromium", session="light", settle=60, measure=60, hide_settle=10, discard_settle=300,
                  open_timeout=20, priority_wait=1.0, runs=4, chat_turns=0, kills=4)
    values.update(overrides)
    return argparse.Namespace(**values)


def bench(app, clock, instance=None, alive=True, kill=None, priorities=None, **overrides):
    return webui.Bench(options(**overrides), app.rpc, instance or FakeInstance(clock), browser_renderers=set,
                       kind_of=lambda cmd: cmd, react_view=lambda run, page: ("react", ""), alive=lambda: alive,
                       kill=kill or (lambda pid, sig: None), priorities=priorities or (lambda pids: {}), clock=clock,
                       log=lambda text: None)


def rows(report):
    return {entry["name"]: entry for entry in report["rows"]}


class RowTests(unittest.TestCase):
    def test_series_prints_percentiles_and_counts_unfinished_samples(self):
        entry = webui.series("open_ms", [10, 20, 30, 40, None], ("p95", "<=", 50))
        self.assertEqual(entry["value"]["n"], 4)
        self.assertEqual(entry["value"]["p50"], 25)
        self.assertEqual(entry["value"]["missed"], 1)
        self.assertEqual(entry["status"], "met")
        text = webui.line("open", entry)
        for key in ("p50=25", "p95=", "p99=", "max=40", "missed=1", "status=met"):
            self.assertIn(key, text)

    def test_a_missed_target_is_marked_and_no_value_is_unscored(self):
        self.assertEqual(webui.row("renderers", 5, ("<=", 4))["status"], "missed")
        self.assertEqual(webui.row("renderers", None, ("<=", 4), note="no census")["status"], "unscored")
        self.assertEqual(webui.series("x", [None, None])["status"], "unscored")


class ShapeTests(unittest.TestCase):
    def test_refuses_two_windows(self):
        clock = FakeClock()
        with self.assertRaisesRegex(webui.ShapeError, "2 windows"):
            bench(FakeApp(clock, windows=2), clock).run("home")

    def test_refuses_a_restored_browser_tab(self):
        clock = FakeClock()
        with self.assertRaisesRegex(webui.ShapeError, "1 browser tabs"):
            bench(FakeApp(clock, tabs=("terminal", "browser")), clock).run("pages10")

    def test_refuses_webkit_fallback_when_chromium_is_asked(self):
        clock = FakeClock()
        app = FakeApp(clock, cef={"state": "ready", "fallback": {"count": 1}})
        with self.assertRaisesRegex(webui.ShapeError, "WebKit fallbacks"):
            bench(app, clock, discard_settle=0).run("pages10")

    def test_webkit_engine_skips_the_chromium_check(self):
        clock = FakeClock()
        app = FakeApp(clock, cef={"unavailable": "notBundled"})
        report = bench(app, clock, engine="webkit").run("home")
        self.assertEqual(rows(report)["cef_processes"]["target"], ["==", 0])

    def test_stress_shape_error_propagates(self):
        clock = FakeClock()

        class Refusing:
            def __init__(self, rpc, log=None):
                pass

            def build(self):
                raise webui.stress_session.StressShapeError("STRESS session has the wrong shape: 11 panes, not 14")

        real = webui.stress_session.Stress
        webui.stress_session.Stress = Refusing
        try:
            with self.assertRaises(webui.stress_session.StressShapeError):
                bench(FakeApp(clock), clock, session="stress").run("open")
        finally:
            webui.stress_session.Stress = real

    def test_a_page_that_never_opens_is_refused(self):
        clock = FakeClock()
        app = FakeApp(clock)
        app.page_for = lambda action, args: None
        with self.assertRaisesRegex(webui.ShapeError, "opened no cmux.settings page"):
            bench(app, clock).run("pages10")


class HomeTests(unittest.TestCase):
    KINDS = {"main": {"n": 1, "cpu_pct": 0.2, "wakeups_per_s": 3.0},
             "renderer": {"n": 3, "cpu_pct": 1.8, "wakeups_per_s": 12.0},
             "gpu": {"n": 1, "cpu_pct": 0.1, "wakeups_per_s": 1.0},
             "utility:NetworkService": {"n": 1, "cpu_pct": 0.05, "wakeups_per_s": 0.5},
             "webkit-webcontent": {"n": 1, "cpu_pct": 0.1, "wakeups_per_s": 11.0}}

    def test_counts_come_from_the_procs_window_it_is_handed(self):
        clock = FakeClock()
        instance = FakeInstance(clock, self.KINDS, mb=793.0)
        report = bench(FakeApp(clock, census=False), clock, instance).run("home")
        got = rows(report)
        self.assertEqual(got["chromium_renderers"]["value"], 3)
        self.assertEqual(got["chromium_renderers"]["status"], "missed")
        self.assertEqual(got["webcontent_processes"]["value"], 1)
        self.assertEqual(got["cef_processes"]["value"], 5)
        self.assertEqual(got["web_helper_cpu_pct"]["value"], 2.05)
        self.assertEqual(got["footprint_mb"]["value"], 793.0)
        self.assertEqual(got["extension_renderers"]["status"], "unscored")
        self.assertEqual(instance.windows, [60])
        self.assertGreaterEqual(clock.slept, 60 + 60)  # --settle, then --measure

    def test_page_wakeup_owners_are_summed(self):
        clock = FakeClock()
        app = FakeApp(clock)
        real = app.rpc

        def rpc(method, params=None, timeout=60):
            if method == "debug.wakeups":
                return {"ledger": [{"owner": "page.history", "reason": "timer", "per_second": 1.5},
                                   {"owner": "newTab.preload", "reason": "raf", "per_second": 0.5},
                                   {"owner": "terminal", "reason": "blink", "per_second": 2}]}
            return real(method, params, timeout)

        app.rpc = rpc
        self.assertEqual(rows(bench(app, clock).run("home"))["page_preload_spare_wakeups_per_s"]["value"], 2.0)


class PagesTests(unittest.TestCase):
    def test_pages10_freezes_eight_and_keeps_the_last_hidden(self):
        clock = FakeClock()
        got = rows(bench(FakeApp(clock), clock).run("pages10"))
        self.assertEqual(got["frozen_pages"]["value"], 8)
        self.assertEqual(got["last_hidden_not_frozen"]["value"], 1)
        self.assertEqual(got["frozen_hidden_traffic"]["value"], 0)
        self.assertEqual(got["page_renderers"]["value"], 6)  # 5 privileged in one, 5 others alone
        self.assertEqual(got["page_renderers"]["status"], "missed")
        self.assertEqual(got["discarded_pages"]["value"], 9)
        self.assertEqual(got["devtools_on_page_renderers"]["value"], 0)

    def test_delivery_to_frozen_pages_is_counted(self):
        clock = FakeClock()
        got = rows(bench(FakeApp(clock, leak=True), clock).run("delivery"))
        self.assertEqual(got["frozen_hidden_traffic"]["value"], 24)
        self.assertEqual(got["frozen_hidden_traffic"]["status"], "missed")

    def test_a_page_with_a_keep_reason_is_not_expected_to_discard(self):
        clock = FakeClock()
        got = rows(bench(FakeApp(clock, keep=("cmux.history",)), clock).run("pages10"))
        self.assertEqual(got["discarded_pages"]["value"], 8)
        self.assertEqual(got["discarded_pages"]["target"], ["==", 8])

    def test_devtools_row_is_unscored_before_fork_29(self):
        clock = FakeClock()
        got = rows(bench(FakeApp(clock, fork_api=28), clock, discard_settle=0).run("pages10"))
        self.assertEqual(got["devtools_on_page_renderers"]["status"], "unscored")
        self.assertIn("< 29", got["devtools_on_page_renderers"]["note"])

    def test_without_census_census_rows_are_unscored(self):
        clock = FakeClock()
        got = rows(bench(FakeApp(clock, census=False), clock, discard_settle=0).run("pages10"))
        self.assertEqual(got["frozen_pages"]["status"], "unscored")
        self.assertEqual(got["frozen_hidden_traffic"]["status"], "unscored")
        self.assertEqual(got["page_renderers"]["value"], 0)  # procs found no renderer without a browser tab


class CrashPressurePriorityTests(unittest.TestCase):
    def test_crash_kills_the_shown_renderer_and_checks_the_cap(self):
        clock = FakeClock()
        app = FakeApp(clock)
        killed = []

        got = rows(bench(app, clock, kill=self.crasher(app, killed, reload_hidden=False)).run("crash"))
        self.assertEqual(len(killed), 4)
        self.assertEqual(got["app_survived"]["value"], 1)
        self.assertEqual(got["pages_in_killed_renderer"]["value"], 5)
        self.assertEqual(got["reload_past_group_cap"]["value"], 0)
        self.assertEqual(got["shown_page_back_ms"]["value"]["n"], 3)
        self.assertEqual(got["hidden_pages_reloaded"]["value"], 0)

    def test_crash_counts_hidden_pages_that_reload_at_once(self):
        clock = FakeClock()
        app = FakeApp(clock)
        got = rows(bench(app, clock, kills=1, kill=self.crasher(app, [], reload_hidden=True)).run("crash"))
        self.assertEqual(got["hidden_pages_reloaded"]["value"], 4)
        self.assertEqual(got["hidden_pages_reloaded"]["status"], "missed")

    @staticmethod
    def crasher(app, killed, reload_hidden):
        """kill -9 of a renderer: the app reloads the shown page in a new renderer until the group cap; hidden pages
        of that renderer reload at once (`reload_hidden`, the base's behavior) or wait, crashed, until shown."""

        def kill(pid, sig):
            killed.append(pid)
            fresh = pid + 1000 * len(killed)
            for page in app.pages.values():
                if page["pid"] != pid:
                    continue
                if page["state"] == "active" and len(killed) <= webui.GROUP_CAP:
                    page["pid"] = fresh
                elif page["state"] in ("hidden", "frozen") and reload_hidden:
                    page["pid"] = fresh
                elif page["state"] in ("hidden", "frozen"):
                    page.update(state="crashed", pid=None)

        return kill

    def test_pressure_reads_the_preload_and_renderers(self):
        clock = FakeClock()
        got = rows(bench(FakeApp(clock), clock).run("pressure"))
        self.assertEqual(got["preload_after_pressure"]["value"], 0)
        self.assertEqual(got["pages_left_undiscarded"]["value"], 0)
        self.assertEqual(got["renderers_after_discard"]["value"], 1)

    def test_priority_times_each_renderer_backgrounding(self):
        clock = FakeClock()
        app = FakeApp(clock)
        hidden_since = []

        def priorities(pids):
            if not any(p["state"] == "active" for p in app.pages.values()) and not hidden_since:
                hidden_since.append(clock.now)
            late = hidden_since and clock.now - hidden_since[0] >= 0.3
            return {pid: 4 if late else 31 for pid in pids}

        got = rows(bench(app, clock, priorities=priorities).run("priority"))
        self.assertEqual(got["page_renderers"]["value"], 1)
        self.assertEqual(got["backgrounded_renderers"]["status"], "met")
        self.assertGreaterEqual(got["background_ms"]["value"]["max"], 300)

    def test_a_dead_app_is_a_row(self):
        clock = FakeClock()
        got = rows(bench(FakeApp(clock), clock, alive=False).run("home"))
        self.assertEqual(got["app_alive_at_end"]["status"], "missed")


class ThinDriverTests(unittest.TestCase):
    SOURCE = open(SCRIPT).read()

    def test_no_copy_of_process_counting(self):
        for copied in ("proc_pid_rusage", "libproc", "ps\", \"-axo", "pgrep", "def process_table", "def counters"):
            self.assertNotIn(copied, self.SOURCE, copied)
        for reused in ("procs.py", "bench_launch.py", "bench_renderer_sharing.py", "bench-pages.py", "perf_stats.py"):
            self.assertIn(reused, self.SOURCE, reused)

    def test_only_settle_and_bounded_polls_sleep(self):
        self.assertNotIn("time.sleep", self.SOURCE)
        self.assertEqual(len(re.findall(r"self\.clock\.sleep\(", self.SOURCE)), 2)

    def test_no_budget_files_or_ci(self):
        for name in ("budgets.json", "perf-budgets", ".github"):
            self.assertNotIn(name, self.SOURCE)

    def test_fleet_entry_parses(self):
        result = subprocess.run(["bash", "-n", os.path.join(ROOT, "scripts", "measure", "webui-bench.sh")],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_bad_options_are_refused(self):
        for argv in (["home", "--app", "x", "--settle", "-1"], ["warp", "--app", "x"], ["home", "--app", "x", "--runs", "0"]):
            with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
                webui.parse(argv)


if __name__ == "__main__":
    unittest.main()
