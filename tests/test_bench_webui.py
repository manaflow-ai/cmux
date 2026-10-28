#!/usr/bin/env python3
"""bench-webui.py against a fake app (no app, no macOS): the rows each mode prints from the census and the process
counters it is handed, the session shapes it refuses, percentiles, and that it reuses the existing benches' process
counting instead of a copy. Run from the repo root: python3 -I tests/test_bench_webui.py (not `python3 -I -m unittest
tests/test_bench_webui.py`: -I puts no current folder on sys.path, so unittest cannot import `tests`)."""
import argparse
import contextlib
import importlib.util
import io
import json
import os
import re
import signal
import subprocess
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(ROOT, "scripts", "cmux-next", "bench-webui.py")
spec = importlib.util.spec_from_file_location("bench_webui", SCRIPT)
webui = importlib.util.module_from_spec(spec)
spec.loader.exec_module(webui)


class FakeClock:
    """A sleep advances the clock, so settles and bounded polls end at once. `uptime` is the app's clock too."""

    def __init__(self):
        self.now = 0.0
        self.slept = 0.0

    def monotonic(self):
        return self.now

    def uptime(self):
        return self.now

    def sleep(self, seconds):
        self.now += max(seconds, 0.01)
        self.slept += max(seconds, 0.01)


class FakeApp:
    """Enough of the control socket: pages open through their actions and land in the `debug.webui` census; a page
    hidden for 10 s freezes (the most recently hidden one stays hidden), one hidden for 300 s with no keep reason is
    discarded; `leak` makes publishing reach frozen pages; `census` False is a build without debug.webui. `verbs` is
    how `debug.webui publish` and `debug.hibernation.pressure` answer: ok, error (a release build has no pressure
    override), or ignored (a reply that confirms nothing, as a build without the verb).
    `other_pane` holds the tabs of a second pane; a new chat opens in the first. Cmd-, opens Settings, painted
    `open_delay` s after the key (`cold_delay` when its renderer is new); Cmd-W closes it. `freeze_after` None is
    `browser.freezeHiddenTabs` "off" (pages stay hidden and still discard on time). `engine_close` is when a Cmd-W
    ends Settings' engine page, stamped in `debug.webui` `retire`: "deferred" at the retirer's deadline (0.5 s
    later), "in_turn" in the key's turn; None is a build with no `retire`. `preload` is the New Tab preload's census
    row fields (none without it); `live` the `live_ms` values Cmd-T into it reports."""

    def __init__(self, clock, census=True, windows=1, tabs=("terminal",), cef=None, leak=False, fork_api=29, keep=(),
                 verbs="ok", other_pane=(), open_delay=0.012, cold_delay=0.09, freeze_after=10, engine_close=None,
                 preload=None, live=None):
        self.preload, self.live = preload, iter(live * 50) if live else None
        self.clock, self.has_census, self.leak, self.keep = clock, census, leak, set(keep)
        self.windows, self.tabs, self.other_pane = windows, list(tabs), list(other_pane)
        self.verbs, self.open_delay, self.cold_delay = verbs, open_delay, cold_delay
        self.freeze_after = freeze_after
        self.cef = cef if cef is not None else {"state": "ready", "fork_api": fork_api}
        self.pages = {}  # page id -> {"state", "hidden_at", "pid", "deliveries", "painted_uptime"?}
        self.order = []
        self.calls = []
        self.override = None  # the memory coordinator's pressure override (`debug.hibernation.pressure`)
        self.next_pid = 500
        self.groups = {}
        self.hides = 0  # the order pages were hidden in: socket calls take no fake time, so several hide at once
        self.budget, self.shown_tab, self.seeded = [], None, {}
        self.visible = iter([4.0, 6.0, 7.5, 9.0] * 50)
        self.engine_close, self.engine_close_uptimes = engine_close, []

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
            elif self.freeze_after is not None and age >= self.freeze_after and page_id != newest:
                page["state"] = "frozen"

    def tab_kind(self, tab_id):
        tabs = self.tabs if tab_id.startswith("t") else self.other_pane
        return tabs[int(tab_id[1:])]

    def record(self, action):
        sequence = len(self.budget) + 1
        self.budget.append({"sequence": sequence, "id": action, "commit_ms": 2.0 + sequence % 3,
                            "start_uptime_ns": self.clock.now * 1e9})

    def rpc(self, method, params=None, timeout=60):
        params = params or {}
        self.calls.append((method, params))
        if method == "snapshot.get":
            panes = [{"id": "p1", "tabs": [{"id": f"t{i}", "kind": kind} for i, kind in enumerate(self.tabs)]},
                     {"id": "p2", "tabs": [{"id": f"u{i}", "kind": kind} for i, kind in enumerate(self.other_pane)]}]
            return {"topology": {"windows": [{"id": f"w{i}"} for i in range(self.windows)],
                                 "workspaces": [{"id": "ws1", "screens": [{"panes": panes}]}]}}
        if method == "action.run":
            action = params["action"]
            page_id = self.page_for(action, params.get("args"))
            if page_id:
                self.pages.setdefault(page_id, {"pid": self.renderer(page_id), "deliveries": 0})
                if self.pages[page_id].get("state") == "discarded":
                    # Shown again: the snapshot in this turn, the restored document's frame later.
                    now = self.clock.now
                    self.pages[page_id]["restore"] = {"started": now, "covered": now + 0.004, "painted": now + 0.09}
                    self.record(action)
                self.order.append(page_id)
                self.show(page_id)
            elif action == "newSurface":
                self.show(None)
                self.shown_tab = None
            elif action.startswith("openBrowser."):
                self.tabs.append("browser")
            elif action == "palette.newAgentChat":
                self.tabs.append("conversation")
                self.shown_tab = f"t{len(self.tabs) - 1}"
            elif action == "tab.focus":
                self.shown_tab = params["target"].split(":", 1)[1]
            return {}
        if method == "debug.key":
            if params["key"] == ",":
                fresh = "privileged" not in self.groups
                self.pages["cmux.settings"] = {"pid": self.renderer("cmux.settings"), "deliveries": 0,
                                               "painted_uptime": self.clock.now + (self.cold_delay if fresh else self.open_delay)}
                self.show("cmux.settings")
                self.record("openSettings")
            elif params["key"] == "w":
                self.pages.pop("cmux.settings", None)
                self.record("closeTab")
                if self.engine_close:
                    self.engine_close_uptimes.append(self.clock.now + (0.5 if self.engine_close == "deferred" else 0.001))
            return {}
        if method == "debug.action_budget":
            return {"recent": self.budget[-params.get("limit", 64):]}
        if method == "debug.new_tab":
            if params["action"] == "state":
                return {"spares": [{"ready": True}]}
            if params["action"] == "bench_open":
                return {"key_ms": 1.5, "visible_ms": next(self.visible), "frames": {"first_tick_ms": 8.3, "refresh_ms": 8.333},
                        "opening": {"spare": True}, **({"live_ms": next(self.live)} if self.live else {})}
            return {"key_ms": 0.8}
        if method == "debug.agent_pane":
            pane = params.get("pane", "p1")
            if params["action"] == "seed_rows":
                self.seeded[pane] = params["count"]
                return {"seeded": params["count"], "pane": pane}
            chat = self.shown_tab is not None and self.tab_kind(self.shown_tab) == "conversation"
            return {"pane": pane, "composer_visible": True, "transcript_rows": self.seeded.get(pane, 0) if chat else 0}
        if method == "debug.page":
            page = self.pages.get(params.get("page"))
            if params.get("action") == "list":
                return {"pages": [{"page": params["page"], "parked": False}] if page and page["state"] != "discarded" else []}
            if not page:
                return {"error": "no live page"}
            return {"painted": True, "controls": 3, **({"painted_uptime": page["painted_uptime"]} if "painted_uptime" in page else {}),
                    **({"restore": page["restore"]} if "restore" in page else {})}
        if method == "debug.cef":
            return self.cef
        if method == "debug.hibernation.pressure":
            if self.verbs == "error":
                return {"error": {"code": "method_not_found"}}
            if self.verbs != "ok":
                return {}
            level = params.get("level")
            self.override = None if level == "none" else level
            if level == "critical":
                for page in self.pages.values():
                    if page["state"] in ("hidden", "frozen"):
                        page["state"] = "discarded"
            return {"level": self.override or "normal", "override": self.override, "pressure": self.override or "normal"}
        if method == "debug.webui":
            if not self.has_census:
                return {"error": {"code": "method_not_found"}}
            verb = params.get("action")
            if verb == "publish" and self.verbs == "error":
                return {"error": {"code": "invalid_params", "message": f"unknown action {verb}"}}
            if verb == "publish" and self.verbs == "ok":
                for page in self.pages.values():
                    if page["state"] == "frozen" and self.leak:
                        page["deliveries"] += 3
                return {"publishing": True}
            self.refresh()
            return {"rows": [{"row": "page", "page": p, "state": page["state"], "group": "privileged",
                              "keep_reasons": ["audio"] if p in self.keep else [],
                              "renderer_pid": None if page["state"] == "discarded" else page["pid"],
                              "hidden_deliveries": page["deliveries"], "hidden_pushes": 0, "devtools": False}
                             for p, page in self.pages.items()]
                    + ([{"row": "spare", "spare_kind": "preload", "renderer_pid": 700, **self.preload}] if self.preload else []),
                    **({"retire": {"engine_closes": len(self.engine_close_uptimes),
                                   "engine_close_uptimes": self.engine_close_uptimes[-32:]}} if self.engine_close else {})}
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
    """procs.Instance: the counters a mode is handed (kinds as procs.window returns them), its command lines and, for
    a per-pid window, `per_pid` ({pid: wakeups/s}, as procs.window's `pids` rows) or `pids` (window number -> those
    rows, spike 090)."""

    def __init__(self, clock, kinds=None, mb=200.0, commands=(), per_pid=None, pids=None):
        self.clock, self.kinds, self.mb = clock, kinds or {}, mb
        self.pid_rows = pids  # spike 090: window number -> procs.window's `pids` rows (wins over per_pid)
        self.commands = dict(enumerate(commands, start=900))
        self.per_pid = per_pid or {}
        self.windows = []

    def pids(self):
        return self.commands

    def memory(self, per_pid=False):
        return {"mb": self.mb, "processes": 3, "kinds": {}}

    def window(self, seconds, during=None, per_pid=False):
        self.windows.append(seconds)
        (during or self.clock.sleep)(seconds)
        result = {"kinds": self.kinds, "seconds": seconds}
        if per_pid and self.pid_rows is not None:
            result["pids"] = self.pid_rows(len(self.windows))
        elif per_pid:
            result["pids"] = [{"pid": pid, "kind": "renderer", "wakeups_per_s": rate} for pid, rate in self.per_pid.items()]
        return result


def options(**overrides):
    values = dict(engine="chromium", session="light", settle=60, measure=60, hide_settle=10, discard_settle=300,
                  open_timeout=20, priority_wait=1.0, runs=4, cold_runs=2, chat_turns=0, kills=4, every_page_hidden=False,
                  page_code_cache=False, mode="pages10", enable_feature=[], push_hz=10, park=None)
    values.update(overrides)
    return argparse.Namespace(**values)


def type_kind(cmd):
    """tab_pages.process_type_kind for the fake command lines."""
    if "--type=renderer" not in cmd:
        return None
    return "cef-extension" if "--extension-process" in cmd else "cef-renderer"


def bench(app, clock, instance=None, alive=True, kill=None, priorities=None, **overrides):
    return webui.Bench(options(**overrides), app.rpc, instance or FakeInstance(clock), browser_renderers=set,
                       kind_of=lambda cmd: cmd, type_kind=type_kind, react_view=lambda run, page: ("react", ""),
                       alive=lambda: alive, kill=kill or (lambda pid, sig: None), priorities=priorities or (lambda pids: {}),
                       clock=clock, log=lambda text: None)


def rows(report):
    return {entry["name"]: entry for entry in report["rows"]}


def replying(app, method, reply):
    """`app.rpc` with `method` answering `reply`."""
    real = app.rpc

    def rpc(name, params=None, timeout=60):
        return reply if name == method else real(name, params, timeout)

    app.rpc = rpc
    return app


class RowTests(unittest.TestCase):
    def test_series_prints_percentiles_and_counts_unfinished_samples(self):
        entry = webui.series("open_ms", [10, 20, 30, 40, None], ("p95", "<=", 50))
        self.assertEqual(entry["value"]["n"], 4)
        self.assertEqual(entry["value"]["p50"], 25)
        self.assertEqual(entry["value"]["missed"], 1)
        self.assertEqual(entry["status"], "missed")  # a sample that timed out never prints met
        self.assertEqual(webui.series("open_ms", [10, 20, 30, 40], ("p95", "<=", 50))["status"], "met")
        text = webui.line("open", webui.series("open_ms", [10, 20, 30, 40, None], ("p95", "<=", 50), tier="train"))
        for key in ("p50=25", "p95=", "p99=", "max=40", "missed=1", "tier=train", "status=missed"):
            self.assertIn(key, text)

    def test_nineteen_timeouts_and_one_fast_open_is_missed(self):
        entry = webui.series("settings.open_ms", [20] + [None] * 19, ("p95", "<=", 50))
        self.assertEqual(entry["value"]["p95"], 20)
        self.assertEqual(entry["status"], "missed")

    def test_a_missed_target_is_marked_and_no_value_is_unscored(self):
        self.assertEqual(webui.row("renderers", 5, ("<=", 4))["status"], "missed")
        self.assertEqual(webui.row("renderers", None, ("<=", 4), note="no census")["status"], "unscored")
        self.assertEqual(webui.series("x", [None, None])["status"], "unscored")
        self.assertEqual(webui.series("x", [], ("p95", "<=", 1))["status"], "unscored")
        timed_out = webui.series("x", [None, None], ("p95", "<=", 1))
        self.assertEqual(timed_out["status"], "missed")  # every sample timed out
        self.assertEqual(timed_out["value"]["missed"], 2)
        self.assertIn("missed=2", webui.line("open", timed_out))


class CensusTests(unittest.TestCase):
    def test_task_001_report_reads_as_rows(self):
        census = webui.Census.from_report({
            "pages": [{"page": "cmux.settings", "state": "visible", "keep_reasons": ["visible", "focused"], "spare": None,
                       "renderer_pids": [41], "webkit_pid": None, "deliveries_while_hidden": 0, "pushes_while_hidden": 0},
                      {"page": "cmux.history", "state": "hidden", "keep_reasons": [], "spare": None, "renderer_pids": [41],
                       "deliveries_while_hidden": 2, "pushes_while_hidden": 1},
                      {"page": "cmux.newtab", "state": "hidden", "spare": "new_tab", "renderer_pids": [], "webkit_pid": 77}],
            "spares": [{"spare": "cef_window", "state": "live", "renderer_pids": [52]}],
            "processes": [{"pid": 41, "kind": "renderer"}, {"pid": 60, "kind": "extension_renderer"}]})
        census = webui.Census(census)
        self.assertEqual([p["page"] for p in census.pages("active")], ["cmux.settings"])
        self.assertEqual(census.page("cmux.settings")["keep_reasons"], ["focused"])
        self.assertEqual(census.renderers(), {41: ["cmux.settings", "cmux.history"]})
        self.assertEqual([s["spare_kind"] for s in census.spares()], ["preload", "cef_window"])
        self.assertEqual(len(census.processes("extension")), 1)


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
             "webkit-webcontent": {"n": 1, "cpu_pct": 0.1, "wakeups_per_s": 11.0},
             "webkit-networking": {"n": 1, "cpu_pct": 0.1, "wakeups_per_s": 4.0}}
    COMMANDS = ("Helper (Renderer) --type=renderer", "Helper (Renderer) --type=renderer",
                "Helper (Renderer) --type=renderer --extension-process", "Helper (GPU) --type=gpu-process")

    def test_counts_come_from_the_procs_window_it_is_handed(self):
        clock = FakeClock()
        instance = FakeInstance(clock, self.KINDS, mb=793.0, commands=self.COMMANDS)
        report = bench(FakeApp(clock, census=False), clock, instance).run("home")
        got = rows(report)
        self.assertEqual(got["chromium_renderers"]["value"], 2)  # the extension renderer is counted apart
        self.assertEqual(got["chromium_renderers"]["status"], "missed")
        self.assertEqual(got["chromium_renderers"]["tier"], "train")
        self.assertEqual(got["extension_renderers"]["value"], 1)
        self.assertEqual(got["extension_renderers"]["status"], "missed")
        self.assertEqual(got["extension_renderers"]["tier"], "pinned")
        self.assertEqual(got["webcontent_processes"]["value"], 1)
        self.assertEqual(got["cef_processes"]["value"], 5)
        self.assertEqual(got["web_helper_cpu_pct"]["value"], 2.15)
        self.assertEqual(got["web_helper_cpu_pct"]["tier"], "pinned")
        self.assertEqual(got["web_helper_cpu_pct_train"]["target"], ["<=", 0.05])
        self.assertEqual(got["footprint_mb"]["value"], 793.0)
        self.assertEqual(got["preload_frozen"]["status"], "unscored")
        self.assertEqual(instance.windows, [60])
        self.assertGreaterEqual(clock.slept, 60 + 60)  # --settle, then --measure

    def test_webkit_wakeups_row_counts_webcontent_only(self):
        clock = FakeClock()
        instance = FakeInstance(clock, self.KINDS)
        got = rows(bench(FakeApp(clock, cef={"unavailable": "notBundled"}), clock, instance, engine="webkit").run("home"))
        self.assertEqual(got["webcontent_wakeups_per_s"]["value"], 11.0)
        self.assertEqual(got["webcontent_wakeups_per_s"]["target"], ["<=", 0.2])
        self.assertEqual(got["web_helper_wakeups_per_s"]["value"], 28.5)
        self.assertIsNone(got["web_helper_wakeups_per_s"]["target"])

    def test_page_wakeup_owners_are_summed(self):
        clock = FakeClock()
        app = replying(FakeApp(clock), "debug.wakeups", {"ledger": [
            {"owner": "page.history", "reason": "timer", "per_second": 1.5},
            {"owner": "newTab.preload", "reason": "raf", "per_second": 0.5},
            {"owner": "terminal", "reason": "blink", "per_second": 2}]})
        self.assertEqual(rows(bench(app, clock).run("home"))["page_preload_spare_wakeups_per_s"]["value"], 2.0)

    def test_a_failed_wakeups_read_is_unscored_not_zero(self):
        for reply in ({"error": {"code": "timeout"}}, None, {"owners": []}):
            clock = FakeClock()
            entry = rows(bench(replying(FakeApp(clock), "debug.wakeups", reply), clock).run("home"))["page_preload_spare_wakeups_per_s"]
            self.assertEqual(entry["status"], "unscored", reply)
            self.assertIn("no ledger", entry["note"])


class PagesTests(unittest.TestCase):
    def test_pages10_freezes_eight_and_keeps_the_last_hidden(self):
        clock = FakeClock()
        got = rows(bench(FakeApp(clock), clock).run("pages10"))
        self.assertEqual(got["frozen_pages"]["value"], 8)
        self.assertEqual(got["last_hidden_not_frozen"]["value"], 1)
        self.assertEqual(got["frozen_hidden_traffic"]["value"], 0)
        self.assertEqual(got["frozen_hidden_traffic"]["status"], "met")
        self.assertEqual(got["page_renderers"]["value"], 6)  # 5 privileged in one, 5 others alone
        self.assertEqual(got["page_renderers"]["status"], "missed")
        self.assertEqual(got["discarded_pages"]["value"], 9)
        self.assertEqual(got["devtools_on_page_renderers"]["value"], 0)

    def test_discarded_pages_shown_again_are_timed_from_the_key(self):
        clock = FakeClock()
        got = rows(bench(FakeApp(clock), clock, runs=3).run("pages10"))
        snapshot, live = got["discarded_page.snapshot_frame_ms"], got["discarded_page.live_ms"]
        self.assertEqual(snapshot["value"]["n"], 3)
        self.assertEqual(snapshot["value"]["max"], 4.0)  # restore.covered - the action's start_uptime_ns
        self.assertEqual(snapshot["status"], "met")
        self.assertEqual(live["value"]["max"], 90.0)
        self.assertEqual(live["status"], "met")

    def test_no_discarded_page_leaves_the_discarded_rows_unscored(self):
        clock = FakeClock()
        got = rows(bench(FakeApp(clock, census=False), clock, discard_settle=0).run("pages10"))
        self.assertEqual(got["discarded_page.live_ms"]["status"], "unscored")

    def test_delivery_to_frozen_pages_is_counted(self):
        clock = FakeClock()
        got = rows(bench(FakeApp(clock, leak=True), clock).run("delivery"))
        self.assertEqual(got["frozen_hidden_traffic"]["value"], 24)
        self.assertEqual(got["frozen_hidden_traffic"]["status"], "missed")

    def test_a_publish_that_fails_or_is_ignored_is_unscored(self):
        for verbs in ("error", "ignored"):
            clock = FakeClock()
            entry = rows(bench(FakeApp(clock, leak=True, verbs=verbs), clock).run("delivery"))["frozen_hidden_traffic"]
            self.assertEqual(entry["status"], "unscored", verbs)
            self.assertIn("publish", entry["note"])

    def test_no_frozen_page_before_the_window_is_unscored(self):
        clock = FakeClock()
        entry = rows(bench(FakeApp(clock), clock, hide_settle=0).run("delivery"))["frozen_hidden_traffic"]
        self.assertEqual(entry["status"], "unscored")
        self.assertIn("no frozen page", entry["note"])

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


class HiddenWakeupsTests(unittest.TestCase):
    """pages10 --every-page-hidden (task 037, MQ5). FakeApp gives the privileged pages pid 500 and the other five
    pids 501-505. The run's app has `browser.freezeHiddenTabs` "off" (FakeApp freeze_after=None) unless a test
    shows a build where pages still freeze."""

    QUIET = {500: 0.05, 501: 0.0, 502: 0.1, 503: 0.0, 504: 0.2, 505: 0.0}
    GPU = {"gpu": {"n": 1, "wakeups_per_s": 0.1}}
    SHARED = "hidden_renderer_wakeups_per_s:" + "+".join(p for p, _, _ in webui.PRIVILEGED5)

    def run_hidden(self, per_pid, kinds=None, freeze_after=None, census=True, commands=(), **overrides):
        clock = FakeClock()
        app = FakeApp(clock, freeze_after=freeze_after, census=census)
        instance = FakeInstance(clock, kinds=self.GPU if kinds is None else kinds, per_pid=per_pid, commands=commands)
        report = bench(app, clock, instance, every_page_hidden=True, **overrides).run("pages10")
        return app, instance, rows(report)

    def test_the_run_turns_page_freezing_off(self):
        self.assertEqual(webui.launch_config(options(every_page_hidden=True))["browser"]["freezeHiddenTabs"], "off")
        self.assertNotIn("freezeHiddenTabs", webui.launch_config(options())["browser"])

    def test_quiet_hidden_running_renderers_name_no_loop(self):
        app, instance, got = self.run_hidden(self.QUIET)
        self.assertEqual({page["state"] for page in app.pages.values()}, {"hidden"})
        self.assertIn(("action.run", {"action": "newSurface", "args": {}, "focus": True, "origin": "script"}), app.calls)
        self.assertEqual(instance.windows, [60])
        self.assertEqual(got["hidden_page_renderers"]["value"], 6)
        verdict = got["hidden_page_renderer_wakeups_max_per_s"]
        self.assertEqual((verdict["value"], verdict["status"]), (0.2, "met"))
        self.assertIn("no rAF loop moves", verdict["note"])
        self.assertEqual(got[self.SHARED]["value"], 0.05)
        self.assertIn("cmux.settings=hidden>hidden", got[self.SHARED]["note"])
        self.assertEqual((got["hidden_frozen_pages"]["value"], got["hidden_frozen_pages"]["status"]), (0, "met"))
        self.assertNotIn("frozen_pages", got)  # D3's rows need one page shown: not this run's shape

    def test_pages_that_freeze_during_the_window_leave_the_verdict_open(self):
        # A build where pages still freeze at 10 s: the frozen renderers read 0, which proves nothing.
        _, _, got = self.run_hidden({pid: 0.0 for pid in self.QUIET}, freeze_after=10)
        self.assertEqual(got[self.SHARED]["status"], "unscored")
        self.assertIn("cmux.settings=frozen>frozen", got[self.SHARED]["note"])
        verdict = got["hidden_page_renderer_wakeups_max_per_s"]
        self.assertEqual(verdict["status"], "unscored")
        self.assertNotIn("no rAF loop moves", verdict["note"])
        self.assertEqual(got["hidden_frozen_pages"]["status"], "missed")
        # Hidden and running at the start, frozen by the end of the window: unscored too.
        _, _, got = self.run_hidden(self.QUIET, freeze_after=30, hide_settle=10)
        self.assertEqual(got[self.SHARED]["status"], "unscored")
        self.assertIn("cmux.settings=hidden>frozen", got[self.SHARED]["note"])
        self.assertEqual(got["hidden_page_renderer_wakeups_max_per_s"]["status"], "unscored")

    def test_a_waking_renderer_names_its_pages(self):
        _, _, got = self.run_hidden({**self.QUIET, 503: 1.5})
        entry = got["hidden_page_renderer_wakeups_max_per_s"]
        self.assertEqual(entry["status"], "missed")
        self.assertIn("cmux.markdown (1.5/s)", entry["note"])
        self.assertEqual(got["hidden_renderer_wakeups_per_s:cmux.markdown"]["status"], "missed")

    def test_a_renderer_with_no_counters_leaves_the_verdict_open(self):
        quiet = dict(self.QUIET)
        del quiet[505]
        _, _, got = self.run_hidden(quiet)
        self.assertEqual(got["hidden_renderer_wakeups_per_s:cmux.chief-usage"]["status"], "unscored")
        verdict = got["hidden_page_renderer_wakeups_max_per_s"]
        self.assertEqual(verdict["status"], "unscored")
        self.assertIn("not measured: cmux.chief-usage", verdict["note"])
        self.assertNotIn("no rAF loop moves", verdict["note"])
        _, _, got = self.run_hidden({**quiet, 503: 1.5})  # a measured loop is still a finding
        self.assertEqual(got["hidden_page_renderer_wakeups_max_per_s"]["status"], "missed")
        _, _, got = self.run_hidden({})
        self.assertEqual(got["hidden_page_renderer_wakeups_max_per_s"]["status"], "unscored")

    def test_without_a_census_rows_name_the_pid_and_stay_unscored(self):
        _, _, got = self.run_hidden({900: 0.0, 901: 0.0}, census=False, commands=("renderer", "renderer"))
        self.assertEqual(got["hidden_page_renderers"]["value"], 2)
        for pid in (900, 901):
            self.assertEqual(got[f"hidden_renderer_wakeups_per_s:pid-{pid}"]["status"], "unscored")
        self.assertEqual(got["hidden_page_renderer_wakeups_max_per_s"]["status"], "unscored")
        self.assertEqual(got["hidden_frozen_pages"]["status"], "unscored")

    def test_gpu_wakeups_sum_both_engines_gpu_processes(self):
        kinds = {"gpu": {"n": 1, "wakeups_per_s": 0.3}, "webkit-gpu": {"n": 1, "wakeups_per_s": 0.1},
                 "renderer": {"n": 6, "wakeups_per_s": 9.0}}
        _, _, got = self.run_hidden(self.QUIET, kinds=kinds)
        self.assertEqual(got["hidden_gpu_wakeups_per_s"]["value"], 0.4)
        self.assertEqual(got["hidden_gpu_wakeups_per_s"]["status"], "missed")

    def test_no_gpu_process_counted_is_unscored_not_zero(self):
        _, _, got = self.run_hidden(self.QUIET, kinds={"renderer": {"n": 6, "wakeups_per_s": 0.1}})
        self.assertEqual(got["hidden_gpu_wakeups_per_s"]["status"], "unscored")
        self.assertIn("no GPU process", got["hidden_gpu_wakeups_per_s"]["note"])

    def test_the_option_belongs_to_pages10(self):
        self.assertTrue(webui.parse(["pages10", "--app", "x", "--every-page-hidden"]).every_page_hidden)
        with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
            webui.parse(["home", "--app", "x", "--every-page-hidden"])


class OpenTests(unittest.TestCase):
    def run_open(self, app, clock, kill=None, **overrides):
        return rows(bench(app, clock, kill=kill, **overrides).run("open"))

    @staticmethod
    def killer(app, dead):
        """kill -9 drops the renderer (the next Settings open starts a fresh one); signal 0 tests it."""

        def kill(pid, sig):
            if sig == 0:
                if pid in dead:
                    raise ProcessLookupError(pid)
                return
            dead.add(pid)
            app.groups = {group: p for group, p in app.groups.items() if p != pid}

        return kill

    def test_new_tab_cover_frame_is_visible_ms(self):
        clock = FakeClock()
        got = self.run_open(FakeApp(clock), clock)
        cover = got["new_tab.cover_frame_ms"]
        self.assertEqual(cover["target"], ["p50", "<=", 8.3])
        self.assertEqual(cover["value"]["n"], 4)
        self.assertEqual(cover["value"]["max"], 9.0)
        self.assertEqual(cover["status"], "met")  # p50 6.75
        self.assertEqual(got["new_tab.cover_frame_p99_ms"]["target"], ["p99", "<=", 16.7])
        self.assertIsNone(got["new_tab.first_tick_ms"]["target"])
        self.assertEqual(got["new_tab.first_tick_ms"]["status"], "info")
        self.assertEqual(got["new_tab.live_ms"]["status"], "unscored")
        self.assertEqual(got["new_tab.from_spare"]["value"], 4)
        self.assertEqual(got["new_tab.key_turn_ms"]["value"]["p99"], 1.5)
        self.assertEqual(got["new_tab.cmd_w_key_turn_ms"]["value"]["n"], 4)

    def test_a_slow_cover_frame_misses(self):
        clock = FakeClock()
        app = FakeApp(clock)
        app.visible = iter([30.0] * 10)
        self.assertEqual(self.run_open(app, clock)["new_tab.cover_frame_ms"]["status"], "missed")

    def test_settings_open_is_timed_on_the_app_clock(self):
        clock = FakeClock()
        app = FakeApp(clock)
        got = self.run_open(app, clock, kill=self.killer(app, set()))
        warm = got["settings.open_ms"]
        self.assertEqual(warm["value"]["n"], 4)
        self.assertEqual(warm["value"]["max"], 12.0)  # painted_uptime - the key's start_uptime_ns, no poll in it
        self.assertEqual(warm["status"], "met")
        cold = got["settings.cold_open_ms"]
        self.assertEqual(cold["value"]["n"], 3)  # the first open and --cold-runs 2 after the renderer was killed
        self.assertEqual(cold["value"]["max"], 90.0)
        self.assertEqual(cold["target"], ["p95", "<=", 150])
        self.assertEqual(got["settings.key_turn_ms"]["value"]["n"], 7)
        self.assertEqual(got["settings.cmd_w_key_turn_ms"]["value"]["n"], 7)
        for name in ("cef.window_built_on_key_turn", "second_page_same_pane_windows",
                     "settings.cmd_w_engine_close_calls", "settings.cover_frame_ms"):
            self.assertEqual(got[name]["status"], "unscored", name)

    def test_settings_cmd_w_counts_the_engine_closes_in_the_keys_turn(self):
        clock = FakeClock()
        app = FakeApp(clock, engine_close="deferred")
        deferred = self.run_open(app, clock, kill=self.killer(app, set()))["settings.cmd_w_engine_close_calls"]
        self.assertEqual(deferred["value"], 0)  # each close's engine page ended at the retirer's deadline
        self.assertEqual(deferred["status"], "met")
        clock = FakeClock()
        app = FakeApp(clock, engine_close="in_turn")
        in_turn = self.run_open(app, clock, kill=self.killer(app, set()))["settings.cmd_w_engine_close_calls"]
        self.assertEqual(in_turn["value"], 7)  # one per Cmd-W: the first, --runs 4 and --cold-runs 2
        self.assertEqual(in_turn["status"], "missed")

    def test_a_renderer_that_is_not_killed_gives_no_cold_sample(self):
        clock = FakeClock()
        got = self.run_open(FakeApp(clock), clock, kill=lambda pid, sig: None)  # signal 0 says it still runs
        self.assertEqual(got["settings.cold_open_ms"]["value"]["n"], 1)

    def test_a_settings_page_that_never_answers_is_missed(self):
        clock = FakeClock()
        app = FakeApp(clock)
        real = app.rpc

        def rpc(method, params=None, timeout=60):
            if method == "debug.page" and params.get("action") != "list":
                return {"error": "no live page"}
            return real(method, params, timeout)

        app.rpc = rpc
        got = self.run_open(app, clock, open_timeout=0.1, cold_runs=0)
        self.assertEqual(got["settings.open_ms"]["status"], "missed")
        self.assertEqual(got["settings.open_ms"]["value"]["missed"], 4)
        self.assertEqual(got["settings.cold_open_ms"]["status"], "missed")

    def test_frozen_chat_measures_the_new_chat_not_the_last_one(self):
        clock = FakeClock()
        app = FakeApp(clock, other_pane=("conversation",))
        b = bench(app, clock, chat_turns=2000)
        b.frozen_chat()
        got = rows({"rows": b.rows})
        self.assertEqual(got["frozen_chat.live_ms"]["value"]["n"], 4)
        self.assertEqual(got["frozen_chat.live_ms"]["value"]["missed"], 0)
        self.assertEqual(got["frozen_chat.first_frame_ms"]["status"], "unscored")
        focused = [p["target"] for m, p in app.calls if m == "action.run" and p["action"] == "tab.focus"]
        self.assertEqual(set(focused), {"tab:t1"})  # the new chat in p1, not u0 (the last conversation tab)
        panes = {p.get("pane") for m, p in app.calls if m == "debug.agent_pane"}
        self.assertEqual(panes, {"p1"})
        self.assertEqual(app.seeded, {"p1": 2000})

    def test_open_runs_the_chat_with_chat_turns(self):
        clock = FakeClock()
        got = self.run_open(FakeApp(clock), clock, chat_turns=50)
        self.assertEqual(got["frozen_chat.live_ms"]["note"].split(";")[0], "50 seeded turns")


class PageCodeCacheTests(unittest.TestCase):
    """Task 052's A/B arm: the switches reach the app only with --page-code-cache, and a run whose renderers do not
    carry them is refused: before the mode, at the first Settings open and at the end."""

    RENDERER = "Chromium Helper (Renderer) --type=renderer --lang=en"
    SWITCHED = RENDERER + " " + webui.CODE_CACHE_MARK + " --enable-features=WebUICodeCache"
    EXTENSION = RENDERER + " --extension-process"

    def run_open(self, commands, **overrides):
        clock = FakeClock()
        app = FakeApp(clock)
        return bench(app, clock, instance=FakeInstance(clock, commands=commands), cold_runs=0, **overrides).run("open")

    def test_the_switches_reach_the_app_only_with_the_option(self):
        on = webui.launch_env(webui.parse(["open", "--app", "x", "--page-code-cache"]), "/t.json")
        self.assertEqual(on["CMUX_NEXT_CEF_EXTRA_SWITCHES"],
                         "cmux-code-cache-schemes=cmux-page:enable-features=WebUICodeCache")
        self.assertEqual(on["CMUX_NEXT_DEBUG_TUNABLES_FILE"], "/t.json")
        off = webui.launch_env(webui.parse(["open", "--app", "x"]), "/t.json")
        self.assertEqual(off, {"CMUX_NEXT_DEBUG_TUNABLES_FILE": "/t.json"})

    def test_enable_feature_turns_features_on_for_the_run(self):
        """p13-webui-055: the home bench's arm with an off feature on (chromiumAdBlockerAtFirstTab)."""
        opts = webui.parse(["home", "--app", "x", "--enable-feature", "chromiumAdBlockerAtFirstTab", "--enable-feature", "other"])
        self.assertEqual(webui.launch_env(opts, "/t.json")["CMUX_ENABLE_FEATURES"], "chromiumAdBlockerAtFirstTab,other")
        self.assertNotIn("CMUX_ENABLE_FEATURES", webui.launch_env(webui.parse(["home", "--app", "x"]), "/t.json"))

    def test_switched_renderers_measure_and_are_counted(self):
        report = self.run_open([self.SWITCHED, self.SWITCHED, self.EXTENSION], page_code_cache=True)
        got = rows(report)
        self.assertTrue(report["facts"]["page_code_cache"])
        self.assertEqual(got["page_code_cache.renderers_with_switch"]["value"], 2)  # extension renderers are not pages
        self.assertEqual(got["page_code_cache.renderers_with_switch"]["status"], "met")
        self.assertIn("settings.open_ms", got)

    def test_a_renderer_without_the_switch_refuses_the_run(self):
        with self.assertRaisesRegex(webui.ShapeError, "1 of 2 Chromium renderers lack"):
            self.run_open([self.SWITCHED, self.RENDERER], page_code_cache=True)

    def run_late(self, commands_after):
        """No renderer before the mode; `commands_after(opens)` lists the command lines once Cmd-, opened Settings
        `opens` times."""
        clock = FakeClock()
        app = FakeApp(clock)
        instance = FakeInstance(clock)
        opens = lambda: sum(entry["id"] == "openSettings" for entry in app.budget)
        instance.pids = lambda: dict(enumerate(commands_after(opens()), start=900)) if opens() else {}
        return bench(app, clock, instance=instance, cold_runs=0, page_code_cache=True).run("open")

    def test_a_late_renderer_without_the_switch_refuses_the_run(self):
        with self.assertRaisesRegex(webui.ShapeError, "1 of 1 Chromium renderers lack .* while Settings shows"):
            self.run_late(lambda opens: [self.RENDERER])

    def test_a_late_switched_renderer_measures(self):
        got = rows(self.run_late(lambda opens: [self.SWITCHED]))
        self.assertEqual(got["page_code_cache.renderers_with_switch"]["status"], "met")
        self.assertIn("settings.cold_open_ms", got)

    def test_a_renderer_without_the_switch_after_the_first_open_refuses_the_run(self):
        with self.assertRaisesRegex(webui.ShapeError, "1 of 2 Chromium renderers lack .* at the end of the run"):
            self.run_late(lambda opens: [self.SWITCHED] + ([self.RENDERER] if opens > 1 else []))

    def test_no_renderer_while_settings_shows_refuses_the_run(self):
        with self.assertRaisesRegex(webui.ShapeError, "no Chromium renderer while Settings shows"):
            self.run_open([], page_code_cache=True)

    def test_the_off_arm_adds_no_row(self):
        report = self.run_open([self.RENDERER])
        self.assertFalse(report["facts"]["page_code_cache"])
        self.assertNotIn("page_code_cache.renderers_with_switch", rows(report))

    def test_webkit_has_no_code_cache_arm(self):
        with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
            webui.parse(["open", "--app", "x", "--engine", "webkit", "--page-code-cache"])


class PushApp(FakeApp):
    """FakeApp with `debug.page ping` (task 079): each ping is a host call into the page and the page's answer,
    `ms` after the send, as `form` ("data" on the push channel, else "script"), which the census counts per page
    (the call and the page's reply). `ping` None is a build without the verb, `counts` False a census without the delivery counts."""

    def __init__(self, clock, form="script", ping=1.5, counts=True, **kwargs):
        super().__init__(clock, freeze_after=None, **kwargs)
        self.form, self.ping, self.counts = form, ping, counts

    def rpc(self, method, params=None, timeout=60):
        params = params or {}
        if method == "debug.page" and params.get("action") == "ping":
            self.calls.append((method, params))
            page = self.pages.get(params.get("page"))
            if self.ping is None or not page:
                return {"error": "unknown action"}
            page[f"{self.form}_deliveries"] = page.get(f"{self.form}_deliveries", 0) + 2
            return {"ms": self.ping}
        reply = super().rpc(method, params, timeout)
        if method == "debug.webui" and isinstance(reply, dict) and self.counts:
            for entry in reply.get("rows") or []:
                page = self.pages.get(entry.get("page")) or {}
                entry.update(script_deliveries=page.get("script_deliveries", 0), data_deliveries=page.get("data_deliveries", 0))
        return reply


class PushTests(unittest.TestCase):
    """push (task 079): the page push channel's A/B over the ten pages, by `debug.page ping`."""

    def run_push(self, app, clock, features=(), per_pid=None, **overrides):
        instance = FakeInstance(clock, per_pid=per_pid or {})
        report = bench(app, clock, instance, enable_feature=list(features), push_hz=10, measure=2, **overrides).run("push")
        return instance, rows(report)

    def test_the_on_arm_counts_data_deliveries_and_no_scripts(self):
        clock = FakeClock()
        app = PushApp(clock, form="data", fork_api=webui.PUSH_FORK_API)
        _, got = self.run_push(app, clock, features=("pagePushChannel",))
        pings = sum(1 for method, params in app.calls if method == "debug.page" and params.get("action") == "ping")
        self.assertEqual(pings, 2 * 10 * 10)  # 2 s at 10 Hz to ten pages
        self.assertEqual(got["push.script_deliveries.on"]["value"], 0)
        self.assertEqual(got["push.script_deliveries.on"]["status"], "met")
        self.assertEqual(got["push.data_deliveries.on"]["value"], 2 * pings)
        self.assertEqual(got["push.round_trip_ms.on"]["value"]["n"], pings)
        self.assertEqual(got["push.round_trip_ms.on"]["value"]["p99"], 1.5)

    def test_the_off_arm_scores_no_script_bound(self):
        clock = FakeClock()
        _, got = self.run_push(PushApp(clock, form="script", fork_api=webui.PUSH_FORK_API), clock)
        self.assertEqual(got["push.script_deliveries.off"]["status"], "info")
        self.assertGreater(got["push.script_deliveries.off"]["value"], 0)
        self.assertEqual(got["push.data_deliveries.off"]["value"], 0)

    def test_renderer_cpu_is_per_thousand_deliveries_of_page_renderers_only(self):
        clock = FakeClock()
        app = PushApp(clock, form="data", fork_api=webui.PUSH_FORK_API)
        instance = FakeInstance(clock)
        renderer_pids = []

        def window(seconds, during=None, per_pid=False):
            during(seconds)
            renderer_pids.extend(sorted({page["pid"] for page in app.pages.values()}))
            # 10 % of a core per page renderer over 2 s; pid 1 is not a page renderer.
            return {"kinds": {}, "seconds": seconds,
                    "pids": [{"pid": pid, "cpu_pct": 10.0} for pid in renderer_pids] + [{"pid": 1, "cpu_pct": 90.0}]}

        instance.window = window
        report = bench(app, clock, instance, enable_feature=["pagePushChannel"], push_hz=10, measure=2).run("push")
        entry = rows(report)["push.renderer_cpu_ms_per_1000.on"]
        cpu_ms = 0.1 * 2 * 1000 * len(renderer_pids)
        self.assertAlmostEqual(entry["value"], round(cpu_ms * 1000 / 400, 3))

    def test_a_build_without_ping_leaves_the_round_trip_unscored(self):
        clock = FakeClock()
        _, got = self.run_push(PushApp(clock, ping=None), clock)
        self.assertEqual(got["push.round_trip_ms.off"]["status"], "unscored")

    def test_a_census_without_counts_leaves_the_delivery_rows_unscored(self):
        clock = FakeClock()
        _, got = self.run_push(PushApp(clock, counts=False, form="data", fork_api=webui.PUSH_FORK_API), clock, features=("pagePushChannel",))
        self.assertEqual(got["push.script_deliveries.on"]["status"], "unscored")

    def test_the_run_turns_page_freezing_off(self):
        self.assertEqual(webui.launch_config(options(mode="push"))["browser"]["freezeHiddenTabs"], "off")

    def test_a_pace_of_zero_is_refused(self):
        with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
            webui.parse(["push", "--app", "x", "--push-hz", "0"])


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
        self.assertEqual(got["shown_page_back_ms"]["status"], "met")
        self.assertEqual(got["hidden_pages_reloaded"]["value"], 0)
        self.assertEqual(got["shown_page_notice"]["status"], "unscored")
        self.assertEqual(got["shown_page_reloads"]["status"], "unscored")

    def test_crash_counts_hidden_pages_that_reload_at_once(self):
        clock = FakeClock()
        app = FakeApp(clock)
        got = rows(bench(app, clock, kills=1, kill=self.crasher(app, [], reload_hidden=True)).run("crash"))
        self.assertEqual(got["hidden_pages_reloaded"]["value"], 4)
        self.assertEqual(got["hidden_pages_reloaded"]["status"], "missed")

    def test_no_renderer_pid_is_not_a_dead_app(self):
        clock = FakeClock()
        app = FakeApp(clock)
        app.renderer = lambda page_id: None
        got = rows(bench(app, clock).run("crash"))
        self.assertEqual(got["app_survived"]["value"], 1)
        self.assertEqual(got["shown_page_renderer"]["status"], "unscored")
        self.assertIn("no renderer pid", got["shown_page_renderer"]["note"])
        self.assertEqual(got["shown_page_back_ms"]["status"], "unscored")  # no kill, no sample
        self.assertEqual(got["hidden_pages_reloaded"]["status"], "unscored")

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
        app = FakeApp(clock)
        got = rows(bench(app, clock).run("pressure"))
        self.assertEqual(got["preload_after_pressure"]["value"], 0)
        self.assertEqual(got["pages_left_undiscarded"]["value"], 0)
        self.assertEqual(got["renderers_after_discard"]["value"], 1)
        self.assertEqual(got["discards_in_importance_order"]["status"], "unscored")
        self.assertIn("browser", app.tabs)  # the ranked pass has a browser tab and a chat to rank
        self.assertIn("conversation", app.tabs)
        # The pressure goes through the memory coordinator's override, cleared at the end.
        levels = [params["level"] for method, params in app.calls if method == "debug.hibernation.pressure"]
        self.assertEqual(levels, ["critical", "none"])
        self.assertIsNone(app.override)

    def test_a_pressure_that_fails_or_is_ignored_is_unscored(self):
        for verbs in ("error", "ignored"):
            clock = FakeClock()
            got = rows(bench(FakeApp(clock, verbs=verbs), clock).run("pressure"))
            for name in ("preload_after_pressure", "renderers_after_discard", "pages_left_undiscarded"):
                self.assertEqual(got[name]["status"], "unscored", (verbs, name))
            self.assertIn("pressure", got["preload_after_pressure"]["note"])

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

    def test_priority_with_no_renderer_is_not_a_pass(self):
        clock = FakeClock()
        app = FakeApp(clock)
        app.renderer = lambda page_id: None
        got = rows(bench(app, clock, priorities=lambda pids: {}).run("priority"))
        self.assertEqual(got["page_renderers"]["status"], "missed")
        self.assertEqual(got["backgrounded_renderers"]["status"], "unscored")

    def test_a_renderer_that_never_backgrounds_misses(self):
        clock = FakeClock()
        got = rows(bench(FakeApp(clock), clock, priorities=lambda pids: {pid: 31 for pid in pids}).run("priority"))
        self.assertEqual(got["backgrounded_renderers"]["status"], "missed")
        self.assertEqual(got["background_ms"]["status"], "missed")

    def test_a_dead_app_is_a_row(self):
        clock = FakeClock()
        got = rows(bench(FakeApp(clock), clock, alive=False).run("home"))
        self.assertEqual(got["app_alive_at_end"]["status"], "missed")


def park_report(park, engine, session="light", live=(10, 12, 14, 16), wakeups=(0.0, 0.5, 0.2), asked=True, job_sha="abc"):
    """A park run's report as main writes it, built through the bench against the fake app."""
    clock = FakeClock()
    preload = {"state": "frozen"} if park == "frozen" else {"state": "hidden", "engine_visible": False}
    if not asked:
        preload = {"state": "hidden", "engine_visible": True}
    app = FakeApp(clock, preload=preload, live=list(live))
    instance = FakeInstance(clock, pids=lambda n: [{"pid": 700, "wakeups_per_s": wakeups[n % len(wakeups)]}])
    report = bench(app, clock, instance, engine=engine, session="light", park=park, measure=3).run("park")
    report.update(session=session, host="cmux15", sha=job_sha * 14)
    return report


class ParkTests(unittest.TestCase):
    def test_park_state_reads_frozen_rendered_and_visible(self):
        self.assertEqual(webui.park_state({"state": "frozen"}), "frozen")
        self.assertEqual(webui.park_state({"state": "hidden", "engine_visible": False}), "rendered")
        self.assertEqual(webui.park_state({"state": "hidden", "engine_visible": True}), "visible")  # the base's spare
        self.assertIsNone(webui.park_state({"state": "hidden"}))
        rows_ = webui.Census.from_report({"pages": [{"page": "cmux.newtab", "state": "hidden", "spare": "new_tab",
                                                     "engine_visible": False, "renderer_pids": [7]}]})
        self.assertEqual(webui.park_state(rows_[0]), "rendered")

    def test_park_measures_wakeups_and_opens_of_the_variant_asked(self):
        clock = FakeClock()
        app = FakeApp(clock, preload={"state": "frozen"}, live=[20.0, 24.0, 30.0, 26.0])
        instance = FakeInstance(clock, pids=lambda n: [{"pid": 700, "wakeups_per_s": 0.5}, {"pid": 1, "wakeups_per_s": 9}])
        report = bench(app, clock, instance, park="frozen", measure=5).run("park")
        got = rows(report)
        self.assertEqual(report["park"], "frozen")
        self.assertEqual(got["park.state_as_asked"]["status"], "met")
        self.assertEqual(got["park.renderer_wakeups_per_s"]["value"]["n"], 5)  # one sample per 1 s window
        self.assertEqual(got["park.renderer_wakeups_per_s"]["value"]["p50"], 0.5)  # the preload's pid only
        self.assertEqual(instance.windows, [1] * 5)
        self.assertEqual(got["park.live_frame_ms"]["value"]["max"], 30.0)
        self.assertEqual(got["park.live_frame_ms"]["target"], ["p95", "<=", 50])
        self.assertEqual(got["park.cover_frame_ms"]["value"]["n"], 4)
        self.assertEqual(got["park.refresh_hz"]["value"], 120.0)
        self.assertEqual(got["park.refresh_hz"]["status"], "met")
        self.assertEqual(sum(1 for method, params in app.calls if method == "debug.new_tab" and params["action"] == "bench_open"), 4)

    def test_a_build_that_parks_otherwise_is_unscored_not_measured(self):
        clock = FakeClock()
        app = FakeApp(clock, preload={"state": "hidden", "engine_visible": True})
        instance = FakeInstance(clock, pids=lambda n: [{"pid": 700, "wakeups_per_s": 0.0}])
        got = rows(bench(app, clock, instance, park="rendered").run("park"))
        self.assertEqual(got["park.state_as_asked"]["status"], "unscored")
        self.assertIn("parked as visible, not rendered", got["park.state_as_asked"]["note"])
        for name in webui.Bench.PARK_ROWS:
            self.assertEqual(got[name]["status"], "unscored", name)
        self.assertEqual(instance.windows, [])
        self.assertFalse(any(m == "debug.new_tab" and p.get("action") == "bench_open" for m, p in app.calls))

    def test_without_census_park_is_unscored(self):
        clock = FakeClock()
        got = rows(bench(FakeApp(clock, census=False), clock, park="frozen").run("park"))
        self.assertEqual(got["park.state_as_asked"]["note"], "no debug.webui in this build")

    def test_a_window_whose_process_was_not_read_is_missed(self):
        clock = FakeClock()
        app = FakeApp(clock, preload={"state": "frozen"}, live=[20.0])
        instance = FakeInstance(clock, pids=lambda n: [{"pid": 700, "wakeups_per_s": 0.1}] if n % 2 else [])
        got = rows(bench(app, clock, instance, park="frozen", measure=4).run("park"))
        self.assertEqual(got["park.renderer_wakeups_per_s"]["value"]["missed"], 2)

    def test_no_live_frame_signal_is_unscored(self):
        clock = FakeClock()
        app = FakeApp(clock, preload={"state": "frozen"})
        instance = FakeInstance(clock, pids=lambda n: [{"pid": 700, "wakeups_per_s": 0.1}])
        got = rows(bench(app, clock, instance, park="frozen", measure=1).run("park"))
        self.assertEqual(got["park.live_frame_ms"]["status"], "unscored")
        self.assertIn("no live_ms", got["park.live_frame_ms"]["note"])

    def test_open_scores_the_new_tab_live_frame_when_the_app_reports_it(self):
        clock = FakeClock()
        got = rows(bench(FakeApp(clock, live=[30.0, 60.0]), clock).run("open"))
        self.assertEqual(got["new_tab.live_ms"]["value"]["max"], 60.0)
        self.assertEqual(got["new_tab.live_ms"]["status"], "missed")

    def test_home_checks_the_park_state_asked(self):
        clock = FakeClock()
        got = rows(bench(FakeApp(clock, preload={"state": "hidden", "engine_visible": False}), clock, park="rendered").run("home"))
        self.assertEqual(got["preload_rendered"]["value"], 1)
        clock = FakeClock()
        got = rows(bench(FakeApp(clock, preload={"state": "hidden", "engine_visible": True}), clock).run("home"))
        self.assertEqual(got["preload_frozen"]["value"], 0)

    def test_park_needs_a_variant(self):
        with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
            webui.parse(["park", "--app", "x"])
        self.assertEqual(webui.parse(["park", "--app", "x", "--park", "rendered"]).park, "rendered")


class ParkDecisionTests(unittest.TestCase):
    def reports(self, frozen_live, rendered_live, frozen_wakeups, rendered_wakeups, sessions=("light",)):
        return [park_report(park, engine, session, live=live, wakeups=wakeups)
                for session in sessions for engine in ("chromium", "webkit")
                for park, live, wakeups in (("frozen", frozen_live, frozen_wakeups), ("rendered", rendered_live, rendered_wakeups))]

    def test_frozen_wins_within_a_frame_with_fewer_wakeups(self):
        decision = webui.park_decision(self.reports((18, 20, 22, 24), (16, 18, 20, 22), (0.0,), (2.0,)))
        self.assertEqual(decision["park"], "frozen")
        self.assertEqual(decision["targets"], {"light": 25.0})  # p95 23.7 ms rounded up to 3 frames at 120 Hz

    def test_rendered_wins_when_frozen_costs_more_than_a_frame(self):
        decision = webui.park_decision(self.reports((30, 34, 38, 40), (10, 12, 14, 16), (0.0,), (2.0,)))
        self.assertEqual(decision["park"], "rendered")
        self.assertIn("1 frame", decision["why"])
        self.assertEqual(decision["targets"], {"light": 16.7})

    def test_rendered_wins_when_frozen_saves_no_wakeups(self):
        decision = webui.park_decision(self.reports((10, 12), (10, 12), (0.0,), (0.0,)))
        self.assertEqual(decision["park"], "rendered")  # Chrome's design unless frozen earns it

    def test_the_target_never_passes_the_ceiling(self):
        decision = webui.park_decision(self.reports((70, 80), (60, 90), (0.0,), (1.0,), sessions=("light", "stress")))
        self.assertEqual(decision["park"], "rendered")
        self.assertEqual(decision["targets"], {"light": 50, "stress": 50})

    def test_missing_variants_decide_nothing(self):
        reports = [park_report("frozen", "chromium"), park_report("rendered", "chromium"),
                   park_report("rendered", "webkit", asked=False)]
        decision = webui.park_decision(reports)
        self.assertIsNone(decision["park"])
        self.assertIn("frozen webkit light", decision["why"])
        self.assertIn("rendered webkit light", decision["why"])

    def test_table_rows_name_sha_host_and_job(self):
        lines = webui.park_table([("4711", park_report("frozen", "chromium")),
                                  ("4712", park_report("rendered", "webkit", asked=False))])
        self.assertTrue(lines[0].startswith("| Park | Engine | Session | Key to cover (ms) p50 / p95 / p99 / max"))
        self.assertIn("| frozen | chromium | light | 6.75 / 8.775 / 8.955 / 9 | 13 / 15.7 / 15.94 / 16 | ", lines[2])
        self.assertIn("| abcabcabcabc | cmux15 | 4711 |", lines[2])
        self.assertIn("not measured: the preload is parked as visible", lines[3])

    def test_park_table_runs_without_an_app(self):
        with tempfile.TemporaryDirectory() as folder:
            args = []
            for index, report in enumerate(self.reports((18, 20), (16, 18), (0.0,), (2.0,))):
                path = os.path.join(folder, f"{index}.json")
                with open(path, "w") as handle:
                    json.dump(report, handle)
                args += ["--run", str(100 + index), path]
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                self.assertEqual(webui.main(["park-table", *args]), 0)
        self.assertIn("Decision: frozen", out.getvalue())
        self.assertIn("D4 key to live frame: light <= 25 ms p95", out.getvalue())


class ThinDriverTests(unittest.TestCase):
    with open(SCRIPT) as handle:
        SOURCE = handle.read()

    def test_no_copy_of_process_counting(self):
        for copied in ("proc_pid_rusage", "libproc", "ps\", \"-axo", "pgrep", "def process_table", "def counters"):
            self.assertNotIn(copied, self.SOURCE, copied)
        for reused in ("procs.py", "bench_launch.py", "bench_renderer_sharing.py", "bench-pages.py", "perf_stats.py",
                       "process_type_kind"):
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

    def test_fleet_entry_prints_build_errors_when_the_reload_fails(self):
        with open(os.path.join(ROOT, "scripts", "measure", "webui-bench.sh")) as handle:
            source = handle.read()
        self.assertRegex(source, r"if ! CMUX_DEV_BACKEND_MODE=local \./scripts/reload\.sh")
        failed = source.split("if ! CMUX_DEV_BACKEND_MODE", 1)[1].split("fi\n", 1)[0]
        self.assertIn("build_errors", failed)

    def test_bad_options_are_refused(self):
        for argv in (["home", "--app", "x", "--settle", "-1"], ["warp", "--app", "x"], ["home", "--app", "x", "--runs", "0"],
                     ["open", "--app", "x", "--cold-runs", "-1"]):
            with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
                webui.parse(argv)


if __name__ == "__main__":
    unittest.main()
