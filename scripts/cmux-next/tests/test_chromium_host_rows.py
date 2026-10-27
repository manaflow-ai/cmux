#!/usr/bin/env python3
"""chromium_host_rows.py and chromium_host_process_rows.py, the pass/fail rows of chromium-host-bench.py
(p01-process-160), against a fake app on a fake clock: every check prints PASS or FAIL with its done check's number; a
check the app cannot answer fails with its reason; --list-failing names each failing row once and lists the native UI
rows with no runner yet (Q6). kill-host passes for a host that restarts and restores within 2000 ms, fails for one
that restores late or never ends its restarts, and the 4th signal checks the restart budget; a build whose backend is
not the host measures nothing; ordering catches a key routed to the wrong tab. The bench's own flags select rows and
modes. Runs anywhere (no app, no macOS).
Run: python3 -I scripts/cmux-next/tests/test_chromium_host_rows.py"""
import importlib.util, json, os, signal, sys, tempfile, time, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
import chromium_host_process_rows as process  # noqa: E402
import chromium_host_rows as rows  # noqa: E402


def load_bench():
    spec = importlib.util.spec_from_file_location("chromium_host_bench", os.path.join(HERE, "..", "chromium-host-bench.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class FakeApp:
    """A host-mode app with one Chromium tab and a Chromium Host process. `restore_s`: how long a killed host takes
    to come back with the tab's state (None: it comes back without the typed text); `budget`: restarts the host
    allows before it stays ended (None: no limit, the restart budget is missing); `report_fields`: the `debug.cef`
    host fields of the later tasks are there; `misroute`: the ordering tabs swap every key after this many."""

    def __init__(self, backend="host", restore_s=0.6, budget=3, report_fields=True, misroute=None):
        self.backend, self.restore_s, self.budget, self.report_fields, self.misroute = backend, restore_s, budget, report_fields, misroute
        self.now_s, self.pid, self.next_pid, self.app = 0.0, 500, 501, 100
        self.down_until, self.crashes, self.kills, self.restarts = None, [], [], 0
        self.state = {"search": "?kill", "field": "", "scroll": 0, "origin": 1.0}
        self.tabs, self.focused, self.keys = {}, None, 0
        self.exit_ns = self.page_ns = None

    # the Lab parts
    def sleep(self, seconds):
        self.now_s += seconds
        self.tick()

    def now(self):
        return self.now_s

    def wait(self, check, seconds, step=0.1):
        end = self.now_s + seconds
        while self.now_s <= end:
            value = check()
            if value:
                return value
            self.sleep(step)
        return None

    def tick(self):
        if self.down_until is not None and self.now_s >= self.down_until:
            self.down_until = None
            self.pid, self.next_pid = self.next_pid, self.next_pid + 1
            self.restarts += 1
            if self.restore_s is None:
                self.state["field"] = ""

    def host_pid(self):
        return None if self.down_until is not None or self.pid is None else self.pid

    def kill(self, pid, sig):
        if pid != self.pid:
            return
        self.kills.append(sig)
        self.crashes.append({"pid": pid, "code": int(sig), "process_type": "chromium-host",
                             "minidump": {"symbolized_frames": 12}})
        self.exit_ns = self.now_s * 1e9
        self.page_ns = self.exit_ns + 5e6
        if self.budget is not None and len(self.kills) > self.budget:
            self.pid = None  # the budget is spent: the crash page's Reload, no new host
            return
        self.down_until = self.now_s + (self.restore_s if self.restore_s is not None else 0.5)

    def lab(self, **parts):
        base = dict(rpc=self.rpc, wait=self.wait, sleep=self.sleep, now=self.now, uptime=self.now, kill=self.kill,
                    pid_gone=lambda pid: pid != self.host_pid(), host_pid=self.host_pid, app_pid=lambda: self.app,
                    helpers=lambda pid: [], typing_rows=lambda: [], focus_terminal=lambda: False,
                    secure_pid=lambda: None, ax_text=lambda pid, text: None, front=lambda: self.app,
                    write_page=lambda name, html: f"file:///bench/{name}", stall_pace=lambda ms, every: {},
                    relaunch=lambda: {"error": "not in the fake"}, hz=120.0)
        base.update(parts)
        return process.Lab(**base)

    # the app's socket
    def rpc(self, method, params=None, timeout=60):
        params = params or {}
        if method == "debug.cef":
            host = {}
            if self.report_fields:
                host = {"crash_page": self.pid is None, "exit_ns": self.exit_ns, "crash_page_ns": self.page_ns,
                        "phase": "running" if self.host_pid() else "ended", "context_initialized": True}
            return {"backend": self.backend, "host": host}
        if method == "debug.crashes":
            return {"chromium": list(self.crashes)}
        if method == "action.run":
            if params.get("action") == "openBrowser.chromium":
                url = params["args"]["url"]
                tab = f"t{len(self.tabs) + 1}"
                self.tabs[tab] = {"search": "?" + url.split("?", 1)[1], "field": ""}
                self.focused = tab
            elif params.get("action") in ("focusLeft", "focusRight"):
                self.focused = list(self.tabs)[0 if params["action"] == "focusLeft" else 1]
            return {"ok": True}
        if method == "debug.key":
            if params.get("modifiers") == ["alt"]:
                self.dead = True
                return {"ok": True}
            key = params["key"]
            if getattr(self, "dead", False):
                key, self.dead = "é", False
            target = self.focused
            if target not in self.tabs:
                return {"ok": True}  # a terminal's key
            self.keys += 1
            if self.misroute is not None and self.keys > self.misroute and len(self.tabs) > 1:
                target = next(t for t in self.tabs if t != self.focused)
            self.tabs[target]["field"] += key
            if self.tabs[target]["search"] == "?kill":
                self.state["field"] += key
            return {"ok": True}
        if method in ("debug.mouse", "debug.window_frame", "debug.hangs"):
            return {}
        if method == "browser.page.eval":
            return self.evaluate(params["script"], params.get("tab") or self.focused)
        raise AssertionError(f"unexpected method {method}")

    def evaluate(self, script, tab):
        if "document.readyState" in script:
            return {"value": True, "tab": tab}
        if "getBoundingClientRect" in script:
            return {"value": [100, 50], "tab": tab}
        if self.host_pid() is None:
            return {"error": "the host is gone"}
        if script.endswith(".value = ''"):
            self.state["field"] = ""
            return {"value": None}
        if script.startswith("window.scrollTo"):
            self.state["scroll"] = int(script.split(",")[1].strip(" )"))
            return {"value": None}
        if script == process.RESTORE_STATE:
            return {"value": json.dumps(self.state)}
        if script == "document.getElementById('f').value":
            return {"value": self.tabs[tab]["field"]}
        raise AssertionError(f"unexpected script {script}")


def by_name(checks):
    return {(c["row"], c["name"]): c for c in checks}


class CheckLineTests(unittest.TestCase):
    def test_each_check_prints_pass_or_fail_with_its_number(self):
        passed = rows.at_most(4, "kill-host.SEGV", "restore_ms", 1430.0, 2000.0)
        late = rows.at_most(4, "kill-host.KILL", "restore_ms", 2600.0, 2000.0)
        missing = rows.unmeasured(10, "native-ui.color", "pass", "no runner yet: task p01-process-228")
        self.assertEqual(rows.line(passed), "ROW 4 kill-host.SEGV restore_ms PASS 1430 (<= 2000 ms)")
        self.assertTrue(rows.line(late).startswith("ROW 4 kill-host.KILL restore_ms FAIL 2600"))
        self.assertEqual(rows.line(missing), "ROW 10 native-ui.color pass FAIL - (no runner yet: task p01-process-228)")
        self.assertFalse(missing["measured"])

    def test_list_failing_names_each_failing_row_once_and_writes_the_queue(self):
        checks = [rows.holds(4, "kill-host.SEGV", "app_pid", True), rows.holds(4, "kill-host.SEGV", "url", False),
                  rows.holds(4, "kill-host.SEGV", "text", False), rows.unmeasured(9, "ax", "h1_readable", "no grant")]
        lines = []
        with tempfile.TemporaryDirectory() as scratch:
            path = os.path.join(scratch, "failing.txt")
            summary = rows.report(checks, lines.append, list_failing=True, failing_path=path)
            with open(path) as written:
                self.assertEqual(written.read(), "kill-host.SEGV\nax\n")
        self.assertEqual([line for line in lines if line.startswith("FAILING")], ["FAILING kill-host.SEGV", "FAILING ax"])
        self.assertEqual(summary["pass"], 1)
        self.assertEqual(summary["fail"], 3)
        self.assertEqual(summary["unmeasured"], 1)


class FromResultTests(unittest.TestCase):
    def test_native_ui_lists_every_row_of_done_check_10_with_the_missing_runners_as_failing(self):
        result = {"modes": {"native_ui": {"select": {"ok": True}, "date": {"ok": False, "error": "never shown"}}}}
        checks = rows.from_result(result)
        named = by_name(checks)
        self.assertEqual(named[("native-ui.select", "pass")]["verdict"], "PASS")
        self.assertEqual(named[("native-ui.date", "pass")]["reason"], "never shown")
        self.assertIn("task p01-process-229", named[("native-ui.fullscreen", "pass")]["reason"])
        failing = rows.failing(checks)
        self.assertNotIn("native-ui.select", failing)
        self.assertEqual(len(failing), len(rows.NATIVE_UI_ROWS) - 1)

    def test_only_the_asked_native_ui_rows_are_judged(self):
        checks = rows.from_result({"modes": {"native_ui": {"select": {"ok": True}}}}, native_rows=["select"])
        self.assertEqual([c["row"] for c in checks], ["native-ui.select"])

    def test_the_older_modes_rows_and_paint_thresholds(self):
        result = {"modes": {
            "inproc": {"key_to_paint_ms": {"n": 60, "sent": 60, "p50": 6.0, "p95": 9.0, "p99": 12.0},
                       "click_to_paint_ms": {"n": 60, "sent": 60, "p50": 7.0, "p95": 10.0, "p99": 14.0}},
            "helper": {"key_to_paint_ms": {"n": 58, "sent": 60, "p50": 7.0, "p95": 11.0, "p99": 15.0},
                       "click_to_paint_ms": {"n": 60, "sent": 60, "p50": 9.0, "p95": 10.5, "p99": 18.0},
                       "identity": {"pass": True}, "kill": {"pass": False}, "pixels": {"not_measurable": "no grant"},
                       "geometry": {"pass": None, "unavailable": "no counters"}, "input": {"typing": {"pass": True},
                                                                                         "not_forwarded": {}}}}}
        named = by_name(rows.from_result(result))
        self.assertEqual(named[("paint.helper", "key_lost")]["verdict"], "FAIL")
        self.assertEqual(named[("paint.helper", "key_p95_over_inproc_ms")]["verdict"], "FAIL")
        self.assertEqual(named[("paint.helper", "click_p95_over_inproc_ms")]["verdict"], "PASS")
        self.assertEqual(named[("paint.helper", "click_p50_ms")]["verdict"], "FAIL")
        self.assertEqual(named[("identity", "pass")]["verdict"], "PASS")
        self.assertEqual(named[("kill", "restart")]["number"], 4)
        self.assertEqual(named[("pixels", "composited")]["reason"], "no grant")
        self.assertFalse(named[("geometry", "placements")]["measured"])
        self.assertEqual(named[("input.typing", "pass")]["verdict"], "PASS")
        self.assertNotIn(("input.not_forwarded", "pass"), named)

    def test_a_process_row_that_timed_out_fails_with_its_reason(self):
        checks = rows.from_result({"rows": {"ordering": {"error": "timed out after 900 s", "pass": False}}})
        self.assertEqual(rows.line(checks[0]), "ROW 7 ordering pass FAIL - (timed out after 900 s)")


class KillHostTests(unittest.TestCase):
    def test_a_host_that_restores_within_the_limit_and_honors_the_budget_passes(self):
        app = FakeApp()
        row = process.kill_host(app.lab())
        named = by_name(row["checks"])
        for name in ("TRAP", "SEGV", "ABRT"):
            self.assertEqual(named[(f"kill-host.{name}", "restore_ms")]["verdict"], "PASS", named)
            self.assertEqual(named[(f"kill-host.{name}", "crash_page_frames")]["verdict"], "PASS")
            self.assertEqual(named[(f"kill-host.{name}", "crash_record")]["verdict"], "PASS")
            self.assertEqual(named[(f"kill-host.{name}", "minidump")]["verdict"], "PASS")
            self.assertEqual(named[(f"kill-host.{name}", "app_pid")]["verdict"], "PASS")
        self.assertEqual(named[("kill-host.KILL", "no_restart")]["verdict"], "PASS")
        self.assertEqual(named[("kill-host.KILL", "reload_shown")]["verdict"], "PASS")
        self.assertEqual(app.kills, [signal.SIGTRAP, signal.SIGSEGV, signal.SIGABRT, signal.SIGKILL])
        self.assertAlmostEqual(row["kills"][0]["restore_ms"], 600, delta=30)
        # No terminal in the fake: the typing check is there and fails as not measured.
        self.assertFalse(named[("kill-host.typing", "key_to_frame_p99_ms")]["measured"])

    def test_a_late_restore_fails_its_row(self):
        named = by_name(process.kill_host(FakeApp(restore_s=2.5).lab())["checks"])
        late = named[("kill-host.SEGV", "restore_ms")]
        self.assertEqual(late["verdict"], "FAIL")
        self.assertTrue(late["measured"])
        self.assertGreater(late["value"], 2000)

    def test_a_restore_without_the_typed_text_fails(self):
        named = by_name(process.kill_host(FakeApp(restore_s=None).lab())["checks"])
        self.assertEqual(named[("kill-host.TRAP", "restore_ms")]["verdict"], "FAIL")
        self.assertIn("not back", named[("kill-host.TRAP", "restore_ms")]["reason"])

    def test_a_host_with_no_restart_budget_fails_the_fourth_signal(self):
        named = by_name(process.kill_host(FakeApp(budget=None).lab())["checks"])
        self.assertEqual(named[("kill-host.KILL", "no_restart")]["verdict"], "FAIL")

    def test_fields_the_app_does_not_report_yet_fail_as_not_measured_naming_the_task(self):
        named = by_name(process.kill_host(FakeApp(report_fields=False).lab())["checks"])
        frames = named[("kill-host.SEGV", "crash_page_frames")]
        self.assertFalse(frames["measured"])
        self.assertIn("p01-process-082", frames["reason"])
        self.assertIn("p01-process-081", named[("kill-host.cannot_start", "no_retry")]["reason"])

    def test_earlier_host_deaths_are_waited_out_before_the_budget_is_counted(self):
        app = FakeApp()
        lab = app.lab()
        lab.host_deaths.append(app.now() - 10)
        row = process.kill_host(lab)
        self.assertAlmostEqual(row["rested_s"], rows.RESTART_WINDOW_S - 10, delta=0.01)

    def test_typing_across_the_kills_reads_the_probe_rows_written_meanwhile(self):
        app = FakeApp()
        written = [{"complete": "1", "contents_ms": "5.0"}]
        lab = app.lab(focus_terminal=lambda: True, typing_rows=lambda: written)
        lab.rpc = lambda method, params=None, timeout=60: (written.append({"complete": "1", "contents_ms": "9.0"})
                                                           if method == "debug.key" and "timestamp" in (params or {})
                                                           else None) or app.rpc(method, params, timeout)
        typing = process.Typing(lab)
        app.sleep(0.2)
        while typing.sent < 3:
            time.sleep(0.01)  # test harness: the typing thread's keys
        result = typing.stop()
        self.assertGreaterEqual(result["frames"], 3)
        self.assertEqual(result["p99"], 9.0)

    def test_an_in_process_backend_measures_nothing(self):
        row = process.kill_host(FakeApp(backend="inProcess").lab())
        self.assertEqual(len(row["checks"]), 1)
        self.assertEqual(row["checks"][0]["verdict"], "FAIL")
        self.assertIn("'inProcess'", row["checks"][0]["reason"])


class OrderingTests(unittest.TestCase):
    def test_keys_that_land_on_the_active_tab_pass(self):
        row = process.ordering(FakeApp().lab(), 1200)
        named = by_name(row["checks"])
        self.assertEqual(named[("ordering", "keys_on_active_page")]["verdict"], "PASS", row)
        self.assertEqual(named[("ordering", "ime_in_send_order")]["verdict"], "PASS")

    def test_a_key_on_the_wrong_tab_fails(self):
        row = process.ordering(FakeApp(misroute=600).lab(), 1200)
        named = by_name(row["checks"])
        self.assertEqual(named[("ordering", "keys_on_active_page")]["verdict"], "FAIL")
        self.assertGreater(row["misplaced"], 0)


class BenchFlagTests(unittest.TestCase):
    def setUp(self):
        self.bench = load_bench()
        self.app = os.path.join(tempfile.gettempdir(), "cmux DEV probe.app")

    def parse(self, *argv):
        return self.bench.parse(["--app", self.app, "--out", "/tmp/out", *argv])

    def test_process_rows_run_alone_in_their_order(self):
        args = self.parse("--kill-host", "--ax", "--rows", "ordering,helper-kill")
        self.assertEqual(args.process_rows, ["ax", "ordering", "helper-kill", "kill-host"])
        self.assertEqual(args.modes, "")
        self.assertEqual(args.signals, ["TRAP", "SEGV", "ABRT", "KILL"])

    def test_without_rows_the_modes_are_the_defaults(self):
        self.assertEqual(self.parse().modes, "inproc,helper")

    def test_mode_rows_and_ime_add_their_modes(self):
        args = self.parse("--ime", "--rows", "display,identity")
        self.assertEqual(args.process_rows, ["ime"])
        self.assertEqual(args.modes.split(","), ["helper", "display"])

    def test_stall_and_signals_are_parsed(self):
        args = self.parse("--stall", "--hang", "--signals", "segv,SIGKILL")
        self.assertEqual(args.stall, (50, 100))
        self.assertEqual(args.hang, 5000)
        self.assertEqual(args.signals, ["SEGV", "KILL"])
        self.assertEqual(self.parse("--stall", "20/40").stall, (20, 40))

    def test_bad_rows_are_refused(self):
        for argv in (["--rows", "nope"], ["--stall", "100/50"], ["--signals", "NOPE"]):
            with self.assertRaises(SystemExit):
                with open(os.devnull, "w") as quiet:
                    stderr, sys.stderr = sys.stderr, quiet
                    try:
                        self.parse(*argv)
                    finally:
                        sys.stderr = stderr

    def test_native_ui_alone_asks_for_every_row(self):
        args = self.parse("--native-ui", "--list-failing")
        self.assertTrue(args.native_ui_all)
        self.assertTrue(args.list_failing)
        self.assertFalse(self.parse("--native-ui", "select").native_ui_all)


if __name__ == "__main__":
    unittest.main()
