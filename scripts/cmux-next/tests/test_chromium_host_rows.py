#!/usr/bin/env python3
"""chromium_host_rows.py and chromium_host_process_rows.py, the pass/fail rows of chromium-host-bench.py
(p01-process-160), against a fake app on a fake clock: every check prints PASS or FAIL with its done check's number; a
check the app cannot answer fails with its reason; --list-failing names each failing row once and lists the native UI
rows with no runner yet (Q6), and an asked row with no result fails with the run's error. The fakes refuse
`target: "page"` keys and clicks as host mode does (no page window), so every row's input goes as a person's.
kill-host passes for a host that restarts and restores both tabs (one in a background pane) within 2000 ms, fails for
one that restores late, restores only the focused tab, ignores the signal or never ends its restarts, and for a
terminal that loses keys; the 3rd signal checks the restart budget as task 081 landed it (the 4th goes to a host
Reload started), after the window of every earlier host death (the helper mode's kill too); a build whose backend is
not the host measures nothing; ordering catches a key routed to the wrong tab. Every other row (hang and its hidden
case against the visible control, renderer-hang, ime with Kotoeri (Live Conversion too) and secure input, ax,
visibility, stall at 120 Hz and after idle with cmux frontmost, quit (no Cmd-Q the app cannot ask; later rows fail
after a quit), runtime-update, helper-kill, kill-app with its CDP session, 60 s command, the one adopted host and the
parts with no driver) has a passing and a failing fake; the bench's backend host is never the prototype or an orphan,
and its relaunch adopts the surviving host and reads its launch marks. The bench's own flags select rows and modes.
Runs anywhere (no app, no macOS).
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
    """A host-mode app with Chromium tabs and a Chromium Host process. `restore_s`: how long a killed host takes to
    come back with the tabs' state (None: it comes back without the typed text); `budget`: the crash that ends the
    restarts, as ChromiumHostRestartPolicy counts them (3: the 3rd; None: no limit, the restart budget is missing);
    `report_fields`: the `debug.cef` host fields of the later tasks are there; `misroute`: the ordering tabs swap every
    key after this many; `ignores`: signals the host ignores; `restores_only_focused`: a restart gives back only the
    focused tab's state. A killed host's pages lose their text and scroll until a restart restores them. As in the
    app's host mode, `debug.key`/`debug.mouse` with `target: "page"` find no Chromium page window and answer an
    error: keys go to the focused tab with no target."""

    PAGE_RECT = [0, 0, 800, 600]

    def __init__(self, backend="host", restore_s=0.6, budget=3, report_fields=True, misroute=None, ignores=(),
                 restores_only_focused=False):
        self.backend, self.restore_s, self.budget, self.report_fields, self.misroute = backend, restore_s, budget, report_fields, misroute
        self.ignores = set(ignores)  # signals the host ignores: it keeps running with its page
        self.restores_only_focused = restores_only_focused
        self.now_s, self.pid, self.next_pid, self.app = 0.0, 500, 501, 100
        self.down_until, self.crashes, self.kills, self.restarts, self.counted = None, [], [], 0, 0
        self.context_at, self.cannot_start = 0.0, False
        self.saved = None  # the pages' state a restarted host gives back
        self.tabs, self.focused, self.keys = {}, None, 0
        self.exit_ns = self.page_ns = None
        self.refused_page_targets = 0

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
            # A new host loads each tab's URL; only a restore (task 093) gives back its text and scroll.
            for tab, state in self.tabs.items():
                saved = (self.saved or {}).get(tab) or {}
                if self.restore_s is not None and (not self.restores_only_focused or tab == self.focused):
                    state.update(saved)
                else:
                    state["origin"] = self.now_s

    def host_pid(self):
        return None if self.down_until is not None or self.pid is None else self.pid

    def context_up(self):
        return self.host_pid() is not None and self.now_s >= self.context_at

    def kill(self, pid, sig):
        if pid != self.pid:
            return
        self.kills.append(sig)
        if sig in self.ignores:
            return
        early = not self.context_up()
        self.saved = {tab: dict(state) for tab, state in self.tabs.items()}
        for state in self.tabs.values():
            state.update(field="", scroll=0)
        self.crashes.append({"pid": pid, "code": int(sig), "process_type": "chromium-host",
                             "minidump": {"symbolized_frames": 12}})
        self.exit_ns = self.now_s * 1e9
        self.page_ns = self.exit_ns + 5e6
        if early:
            self.pid, self.cannot_start = None, True  # died before its context: cannot start, no retry
            return
        self.counted += 1
        if self.budget is not None and self.counted >= self.budget:
            self.pid = None  # the budget is spent: the crash page's Reload, no new host
            return
        self.down_until = self.now_s + (self.restore_s if self.restore_s is not None else 0.5)

    def reload(self):
        """The crash page's Reload: a host whose context comes up 0.2 s later, with the pages loaded fresh."""
        if self.host_pid() is not None or self.down_until is not None:
            return
        self.pid, self.next_pid, self.cannot_start = self.next_pid, self.next_pid + 1, False
        self.context_at = self.now_s + 0.2
        for state in self.tabs.values():
            state.update(field="", scroll=0, origin=self.now_s)

    def lab(self, **parts):
        base = dict(rpc=self.rpc, wait=self.wait, sleep=self.sleep, now=self.now, uptime=self.now, kill=self.kill,
                    pid_gone=lambda pid: pid != self.host_pid(), host_pid=self.host_pid,
                    host_pids=lambda: [self.host_pid()] if self.host_pid() else [], app_pid=lambda: self.app,
                    page_rect=lambda: list(self.PAGE_RECT), helpers=lambda pid: [], typing_rows=lambda: [],
                    focus_terminal=lambda: False, terminal_send=lambda text: False,
                    out_path=lambda name: f"/bench/{name}", read_text=lambda path: None,
                    cdp_session=lambda query: {"error": "no CDP in the fake"},
                    secure_pid=lambda: None, ax_text=lambda pid, text: None, front=lambda: self.app,
                    write_page=lambda name, html: f"file:///bench/{name}", stall_pace=lambda ms, every: {},
                    relaunch=lambda: {"error": "not in the fake"}, hz=120.0)
        base.update(parts)
        return process.Lab(**base)

    def refuses_page_target(self, method, params):
        """DebugKey.pageWindow and DebugMouse.clickPage in host mode: no Chromium page window for the pane."""
        if method in ("debug.key", "debug.mouse") and params.get("target") == "page" and self.backend == "host":
            self.refused_page_targets += 1
            return True
        return False

    # the app's socket
    def rpc(self, method, params=None, timeout=60):
        params = params or {}
        if self.refuses_page_target(method, params):
            return {"error": "no Chromium page window for pane"}
        if method == "debug.cef":
            host = {}
            if self.report_fields:
                phase = "running" if self.host_pid() else "cannot start" if self.cannot_start else "ended"
                host = {"pid": self.host_pid(), "crash_page": self.pid is None, "exit_ns": self.exit_ns,
                        "crash_page_ns": self.page_ns, "phase": phase, "context_initialized": self.context_up()}
            return {"backend": self.backend, "host": host}
        if method == "debug.crashes":
            return {"chromium": list(self.crashes)}
        if method == "action.run":
            if params.get("action") == "openBrowser.chromium":
                url = params["args"]["url"]
                tab = f"t{len(self.tabs) + 1}"
                self.tabs[tab] = {"search": "?" + url.split("?", 1)[1], "field": "", "scroll": 0, "origin": 1.0}
                self.focused = tab
            elif params.get("action") in ("focusLeft", "focusRight"):
                self.focused = list(self.tabs)[0 if params["action"] == "focusLeft" else 1]
            elif params.get("action") == "browserReload":
                self.reload()
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
        if self.host_pid() is None or tab not in self.tabs:
            return {"error": "the host or the tab is gone"}
        if script == "1 + 1":
            return {"value": 2}
        if script.endswith(".value = ''"):
            self.tabs[tab]["field"] = ""
            return {"value": None}
        if script.startswith("window.scrollTo"):
            self.tabs[tab]["scroll"] = int(script.split(",")[1].strip(" )"))
            return {"value": None}
        if script == process.RESTORE_STATE:
            return {"value": json.dumps(self.tabs[tab])}
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
        # Every row but select, and the 0-visible-host-windows check with no runner yet (task 068).
        self.assertEqual(len(failing), len(rows.NATIVE_UI_ROWS))
        self.assertIn("task p01-process-068", named[("native-ui.host_windows", "visible")]["reason"])
        seen = by_name(rows.from_result({"modes": {"native_ui": {"host_windows_seen": 1}}}))
        self.assertEqual(seen[("native-ui.host_windows", "visible")]["verdict"], "FAIL")
        self.assertTrue(seen[("native-ui.host_windows", "visible")]["measured"])

    def test_asked_rows_with_no_result_fail_with_the_runs_error(self):
        result = {"error": "tag-in-use", "modes": {}}
        asked = {"modes": ["inproc", "helper"], "native_ui": True, "process_rows": ["ax", "kill-host"]}
        checks = rows.from_result(result, asked=asked)
        failing = rows.failing(checks)
        for row in ("paint.inproc", "paint.helper", "identity", "native-ui.select", "ax", "kill-host"):
            self.assertIn(row, failing)
        self.assertTrue(all(not c["measured"] and "tag-in-use" in c["reason"] for c in checks))
        lines = []
        with tempfile.TemporaryDirectory() as scratch:
            path = os.path.join(scratch, "failing.txt")
            rows.report(checks, lines.append, list_failing=True, failing_path=path)
            with open(path) as written:
                self.assertIn("kill-host\n", written.read())
        # A row that ran is judged by its own checks, not as missing.
        ran = rows.process_row_checks({"rows": {"ax": {"checks": [rows.holds(9, "ax", "remote_children", True)]}}},
                                      ["ax", "quit"])
        self.assertEqual([(c["row"], c["verdict"]) for c in ran], [("ax", "PASS"), ("quit", "FAIL")])
        self.assertEqual(ran[1]["reason"], "did not run")

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
        # The landed policy (task 081): the 3rd crash ends the restarts; the 4th signal goes to a host Reload started.
        app = FakeApp()
        row = process.kill_host(app.lab())
        named = by_name(row["checks"])
        for name in ("TRAP", "SEGV"):
            self.assertEqual(named[(f"kill-host.{name}", "restarted")]["verdict"], "PASS", named)
            self.assertEqual(named[(f"kill-host.{name}", "restore_ms")]["verdict"], "PASS", named)
        for name in ("ABRT", "KILL"):
            self.assertEqual(named[(f"kill-host.{name}", "no_restart")]["verdict"], "PASS", named)
            self.assertEqual(named[(f"kill-host.{name}", "reload_shown")]["verdict"], "PASS")
            self.assertNotIn((f"kill-host.{name}", "restore_ms"), named)
        for name in ("TRAP", "SEGV", "ABRT", "KILL"):
            self.assertEqual(named[(f"kill-host.{name}", "crash_page_frames")]["verdict"], "PASS")
            self.assertEqual(named[(f"kill-host.{name}", "crash_record")]["verdict"], "PASS")
            self.assertEqual(named[(f"kill-host.{name}", "minidump")]["verdict"], "PASS")
            self.assertEqual(named[(f"kill-host.{name}", "app_pid")]["verdict"], "PASS")
        self.assertEqual(named[("kill-host.cannot_start", "no_retry")]["verdict"], "PASS")
        self.assertEqual(named[("kill-host.cannot_start", "cannot_start_shown")]["verdict"], "PASS")
        self.assertEqual(app.kills, [signal.SIGTRAP, signal.SIGSEGV, signal.SIGABRT, signal.SIGKILL, signal.SIGKILL])
        self.assertAlmostEqual(row["kills"][0]["restore_ms"], 600, delta=30)
        self.assertEqual(sorted(row["expected"]), ["?kill", "?kill-back"])  # two tabs, one in a background pane
        self.assertEqual(app.refused_page_targets, 0)  # every key and click went as host mode takes them
        # No terminal in the fake: the typing check is there and fails as not measured.
        self.assertFalse(named[("kill-host.typing", "key_to_frame_p99_ms")]["measured"])

    def test_a_host_that_restarts_after_the_third_crash_fails_it(self):
        named = by_name(process.kill_host(FakeApp(budget=4).lab())["checks"])
        self.assertEqual(named[("kill-host.ABRT", "no_restart")]["verdict"], "FAIL")
        self.assertTrue(named[("kill-host.ABRT", "no_restart")]["measured"])

    def test_a_restart_that_restores_only_the_focused_tab_fails(self):
        named = by_name(process.kill_host(FakeApp(restores_only_focused=True).lab())["checks"])
        late = named[("kill-host.TRAP", "restore_ms")]
        self.assertEqual(late["verdict"], "FAIL")
        self.assertIn("1 of 2 tabs", late["reason"])
        self.assertIn("?kill", late["reason"])

    def test_page_targets_are_refused_in_host_mode_as_the_app_refuses_them(self):
        app = FakeApp()
        refused = {"error": "no Chromium page window for pane"}
        self.assertEqual(app.rpc("debug.key", {"target": "page", "key": "a"}), refused)
        self.assertEqual(app.rpc("debug.mouse", {"target": "page"}), refused)
        for row in (process.ime, lambda lab: process.hang(lab, 5000), process.renderer_hang, process.quit_row):
            fake = RowFake()
            row(fake.lab())
            self.assertEqual(fake.refused_page_targets, 0, row)

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

    def test_a_host_with_no_restart_budget_fails_the_third_signal(self):
        named = by_name(process.kill_host(FakeApp(budget=None).lab())["checks"])
        self.assertEqual(named[("kill-host.ABRT", "no_restart")]["verdict"], "FAIL")
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

    def test_a_host_that_ignores_the_signal_restores_nothing_and_fails(self):
        named = by_name(process.kill_host(FakeApp(ignores={signal.SIGTRAP}).lab())["checks"])
        self.assertEqual(named[("kill-host.TRAP", "restarted")]["verdict"], "FAIL")
        self.assertEqual(named[("kill-host.TRAP", "restarted")]["reason"], "the signaled host did not end")
        self.assertEqual(named[("kill-host.TRAP", "restore_ms")]["verdict"], "FAIL")
        self.assertEqual(named[("kill-host.SEGV", "restarted")]["verdict"], "PASS")

    def test_a_restore_is_timed_from_the_new_host_not_the_old_page(self):
        row = process.kill_host(FakeApp(restore_s=0.6).lab())
        self.assertGreaterEqual(row["kills"][0]["restore_ms"], 600)
        self.assertNotEqual(row["kills"][0]["new_pid"], row["kills"][0]["pid"])

    def test_keys_the_terminal_dropped_while_the_host_died_fail_the_typing_row(self):
        app = FakeApp()
        written = []

        def rpc(method, params=None, timeout=60):
            if method == "debug.key" and "timestamp" in (params or {}):
                index = len(written)
                written.append({"complete": "0" if index % 4 == 3 else "1", "contents_ms": "" if index % 4 == 3 else "6.0"})
            return app.rpc(method, params, timeout)
        lab = app.lab(focus_terminal=lambda: True, typing_rows=lambda: list(written))
        lab.rpc = rpc
        typing = process.Typing(lab)
        while typing.sent < 8:
            time.sleep(0.01)  # test harness: the typing thread's keys
        result = typing.stop()
        self.assertEqual(result["p99"], 6.0)  # the complete presses alone pass the p99
        self.assertGreaterEqual(result["lost"], 2)
        # Through the row: a terminal whose every press stalls fails `lost`, whatever its p99 says.
        stalled = FakeApp()
        rows_written = [{"complete": "1", "contents_ms": "5.0"}]
        lab = stalled.lab(focus_terminal=lambda: True, typing_rows=lambda: list(rows_written))
        lab.rpc = lambda method, params=None, timeout=60: (
            rows_written.append({"complete": "0", "contents_ms": ""}) if method == "debug.key" and "timestamp" in
            (params or {}) else None) or stalled.rpc(method, params, timeout)
        named = by_name(process.kill_host(lab)["checks"])
        self.assertEqual(named[("kill-host.typing", "lost")]["verdict"], "FAIL")
        self.assertGreaterEqual(named[("kill-host.typing", "lost")]["value"], 1)

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


class RowFake(FakeApp):
    """FakeApp with what the other rows read. Each switch is one way a correct host behaves, off for a broken one:
    `hang_gate` (no hang timer while hidden), `banner_at` (seconds from an unacked key to cmux's banner), `host_block`
    (debug.cef host_block_ms exists), `renderer_prompt` (the per-tab unresponsive prompt), `renderer_banner` (the host
    banner shows for a renderer hang: wrong), `dead_keys`, `kotoeri`, `secure_balanced`, `ax_connected`,
    `hidden_throttle`, `stay` (Stay keeps cmux), `runtime` (stage_runtime_update), `helper_records`, `sad_tab`,
    `adopt` (the relaunch keeps the host), `screens_ms` (the relaunch's terminal_screens_shown after its first frame),
    `live_conversion` (Kotoeri commits 日本, macOS's default, not にほん), `quit_asks` (debug.cef host
    quit_beforeunload: True, False, or None when the app does not report it; a Cmd-Q that does not ask ends cmux),
    `cdp_alive` (a CDP session outlives the relaunch), `command_survives` (a terminal's command outlives cmux),
    `lingering` (the old host, not adopted, still runs beside the new one and is listed first)."""

    def __init__(self, **switches):
        defaults = dict(hang_gate=True, banner_at=2.0, host_block=True, renderer_prompt=True, renderer_banner=False,
                        dead_keys=True, kotoeri=True, secure_balanced=True, ax_connected=True, hidden_throttle=True,
                        stay=True, runtime=True, helper_records=True, sad_tab=True, adopt=True, screens_ms=120.0,
                        live_conversion=False, quit_asks=True, cdp_alive=True, command_survives=True, lingering=False)
        self.switches = {**defaults, **{k: v for k, v in switches.items() if k in defaults}}
        super().__init__(**{k: v for k, v in switches.items() if k not in defaults})
        self.hidden = self.stopped = False
        self.block_until = self.key_at = self.mouse_at = None
        self.workspaces, self.hidden_workspace = ["w1"], False
        self.source, self.composing = "com.apple.keylayout.US", ""
        self.focus_element, self.secure, self.gone, self.unresponsive = None, False, False, False
        self.titles, self.dialogs, self.raf, self.helper_pids = {}, [], 0.0, {"gpu-process": [700], "renderer": [701, 702]}
        self.staged = None
        self.ime = {}  # per tab: {start: compositions begun, end: their committed texts}
        self.orphans, self.commands = [], {}  # hosts left running beside a new one; terminal commands by start time

    # what a row reads of the host
    def blocked(self):
        return self.stopped or (self.block_until is not None and self.now_s < self.block_until)

    def armed(self):
        return self.key_at is not None and self.blocked() and not (self.hidden and self.switches["hang_gate"])

    def tick(self):
        super().tick()
        if self.key_at is not None and not self.blocked():
            self.key_at = None  # acked
        if not (self.hidden or self.hidden_workspace) or not self.switches["hidden_throttle"]:
            self.raf = getattr(self, "raf", 0.0) + 60 * 0.001  # counted per ms of the fake clock below

    def sleep(self, seconds):
        steps = max(1, int(round(seconds / 0.001)))
        for _ in range(min(steps, 20000)):
            self.now_s += seconds / min(steps, 20000)
            self.tick()

    def host_fields(self):
        banner = bool(self.armed() and self.now_s - self.key_at >= self.switches["banner_at"])
        banner = banner or (self.switches["renderer_banner"] and self.mouse_at is not None and self.titles.get(
            self.focused) == "hang probe")
        fields = {"hang_banner": banner, "hang_timer_armed": self.armed(), "first_rect_max_ms": 0.04,
                  **({"runtime_version": self.staged} if self.staged and self.restarts else {"runtime_version": "1"})}
        if self.switches["quit_asks"] is not None:
            fields["quit_beforeunload"] = self.switches["quit_asks"]
        return fields

    def kill(self, pid, sig):
        if pid == self.pid and sig in (signal.SIGSTOP, signal.SIGCONT):
            self.stopped = sig == signal.SIGSTOP
            self.tick()
            return
        for kind, pids in self.helper_pids.items():
            if pid in pids:
                pids.remove(pid)
                if self.switches["helper_records"]:
                    self.crashes.append({"pid": pid, "process_type": kind, "code": int(sig)})
                if kind == "renderer" and pid == 702:  # the probe tab's renderer, the second in ps order
                    self.gone = self.switches["sad_tab"]
                return
        if pid == self.pid:
            self.secure = self.secure and not self.switches["secure_balanced"]
            self.focus_element = None
        super().kill(pid, sig)

    def lab(self, **parts):
        base = dict(sleep=self.sleep, helpers=lambda pid: [{"pid": p, "type": kind} for kind, pids in
                                                            self.helper_pids.items() for p in pids] if pid == self.pid else [],
                    secure_pid=lambda: self.app if self.secure else 0,
                    ax_text=lambda pid, text: self.switches["ax_connected"] and text == process.AX_HEADING,
                    input_source=self.select_source, activate=lambda: {"activated": True, "error": ""},
                    relaunch=self.relaunch, front=lambda: self.app, focus_terminal=lambda: True,
                    host_pids=lambda: self.orphans + ([self.host_pid()] if self.host_pid() else []),
                    terminal_send=self.terminal_send, read_text=self.read_text, cdp_session=self.cdp_session)
        base.update(parts)
        return super().lab(**base)

    def terminal_send(self, text):
        path = text.split("> ", 1)[1].strip().strip("'")
        self.commands[path] = self.now_s
        return True

    def read_text(self, path):
        started = self.commands.get(path)
        ran = started is not None and self.now_s - started >= process.SHELL_COMMAND_S
        return "done\n" if ran and self.switches["command_survives"] else None

    def cdp_session(self, query):
        fake = self
        tab = next((t for t, v in self.tabs.items() if v["search"] == query), None)

        class Session:
            def evaluate(self, expression):
                if not fake.switches["cdp_alive"]:
                    raise ConnectionResetError("the DevTools socket closed")
                assert expression == "performance.timeOrigin"
                return fake.tabs[tab]["origin"]

            def close(self):
                pass
        return {"session": Session()} if tab else {"error": "no target"}

    def select_source(self, source):
        previous, self.source = self.source, source
        return previous

    def relaunch(self):
        self.app += 1
        if not self.switches["adopt"]:
            if self.switches["lingering"]:
                self.orphans.append(self.pid)
            self.pid, self.next_pid = self.next_pid, self.next_pid + 1
            for state in self.tabs.values():
                state["origin"] = self.now_s + 1000.0  # a reload: a new timeOrigin
        first = 400.0
        marks = {process.FIRST_FRAME_MARK: first}
        if self.switches["screens_ms"] is not None:
            marks[process.TERMINAL_SCREENS_MARK] = first + self.switches["screens_ms"]
        return process.relaunch_timings({"launch_ms_since_process_start": marks})

    def rpc(self, method, params=None, timeout=60):
        params = params or {}
        if self.refuses_page_target(method, params):
            return {"error": "no Chromium page window for pane"}
        if method == "debug.cef":
            if "host_block_ms" in params:
                if not self.switches["host_block"]:
                    return {"backend": self.backend, "host": self.host_fields()}
                self.block_until = self.now_s + params["host_block_ms"] / 1000
                return {"host_blocked": True}
            if "stage_runtime_update" in params:
                if not self.switches["runtime"]:
                    return {}
                self.staged = "2.0"
                self.kills.append("idle-restart")
                self.down_until = self.now_s + 1.0
                return {"staged_runtime": self.staged}
            reply = super().rpc(method, params, timeout)
            reply["host"].update(self.host_fields())
            reply["devtools"] = [{"tab": tab, "page_accessibility": "connected" if self.switches["ax_connected"]
                                  else "none"} for tab in self.tabs]
            return reply
        if method == "debug.chromium_host":
            return {"ime_sync_requests": 0}
        if method == "debug.hangs":
            blocked_by_host = self.switches["host_block"] and self.block_until is not None
            return {"turn_histogram": {"main_turn": {"p99_ms": 2.5}},
                    "records": [{"process": "chromium-host", "duration_ms": 5000}] if blocked_by_host else []}
        if method == "debug.browser.page_status":
            if params.get("press") == "exit":
                self.unresponsive = False
            hung = (self.mouse_at is not None and self.titles.get(self.focused) == "hang probe"
                    and self.now_s - self.mouse_at >= rows.RENDERER_HANG_PROMPT_S)
            self.unresponsive = self.unresponsive or (hung and self.switches["renderer_prompt"])
            return {"gone": "1" if self.gone else "0", "unresponsive": "1" if self.unresponsive else "0"}
        if method == "debug.dialog":
            if params.get("press") == "cancel":
                self.dialogs = []
                if not self.switches["stay"]:
                    self.app, self.pid = None, None
            return {"dialogs": list(self.dialogs)}
        if method == "snapshot.get":
            return {"topology": {"workspaces": [{"id": w} for w in self.workspaces]}}
        if method == "debug.mouse":
            if params["y"] < 200:  # an element's point (f at 50, pw at 150), not the page's center
                self.focus_element = "pw" if params["y"] > 100 else "f"
                self.secure = self.focus_element == "pw" and self.host_pid() is not None
            else:
                self.mouse_at = self.now_s
                if self.titles.get(self.focused) == "unload probe":
                    self.titles[self.focused] = "unload armed"
            return {}
        if method == "debug.key":
            if self.focused in self.tabs and self.blocked() and self.key_at is None:
                self.key_at = self.now_s
            if params.get("modifiers") == ["cmd"] and params.get("key") == "q":
                if self.titles.get(self.focused) == "unload armed" and self.switches["quit_asks"]:
                    self.dialogs = [{"identifier": dialogs_question(), "visible": True}]
                else:
                    self.app, self.pid = None, None  # a quit that asks nothing ends cmux
                return {}
            if self.source == process.KOTOERI_SOURCE and self.switches["kotoeri"] and self.focused in self.tabs:
                ime = self.ime.setdefault(self.focused, {"start": 0, "end": []})
                if params["key"] == "return":
                    converted = "日本" if self.switches["live_conversion"] else "にほん"
                    text = {"nihon": converted}.get(self.composing, self.composing)
                    self.tabs[self.focused]["field"] += text
                    ime["end"].append(text)
                    self.composing = ""
                else:
                    ime["start"] += not self.composing
                    self.composing += params["key"]
                return {}
            if params.get("modifiers") == ["alt"] and not self.switches["dead_keys"]:
                return {}
            return super().rpc(method, params, timeout)
        if method == "action.run":
            action = params.get("action")
            if action == "openBrowser.chromium":
                super().rpc(method, params, timeout)
                url = params["args"]["url"]
                name = url.rsplit("/", 1)[-1].split("?")[0]
                self.titles[self.focused] = {"hang.html": "hang probe", "unload.html": "unload probe",
                                             "ax.html": "ax probe"}.get(name, "restore probe")
            elif action == "showHideAllWindows":
                self.hidden = params["args"]["hidden"]
            elif action == "newTab":
                self.workspaces.append("w2")
                self.hidden_workspace = True
            elif action == "closeWorkspace":
                self.workspaces.remove(params["target"].split(":", 1)[1])
                self.hidden_workspace = False
            elif action == "closeTab":
                self.tabs.pop(params["target"].split(":", 1)[1], None)
                self.secure = self.secure and not self.switches["secure_balanced"]
            else:
                return super().rpc(method, params, timeout)
            return {"ok": True}
        return super().rpc(method, params, timeout)

    def evaluate(self, script, tab):
        if "document.readyState" in script:
            return {"value": True, "tab": tab}
        if "getBoundingClientRect" in script:
            return {"value": [100, 150] if "'pw'" in script else [100, 50], "tab": tab}
        if self.host_pid() is None or tab not in self.tabs:
            return {"error": "the host or the tab is gone"}
        if script == "1 + 1":
            return {"value": 2}
        if script == "window.__raf":
            return {"value": round(self.raf)}
        if script == "document.visibilityState":
            return {"value": "hidden" if (self.hidden or self.hidden_workspace) and self.switches["hidden_throttle"]
                    else "visible"}
        if script == "document.title":
            return {"value": self.titles.get(tab)}
        if script == "location.search":
            return {"value": self.tabs[tab]["search"]}
        if script == process.IME_RESET:
            self.ime[tab] = {"start": 0, "end": []}
            return {"value": None}
        if script == process.IME_STATE:
            return {"value": json.dumps(self.ime.get(tab, {"start": 0, "end": []}))}
        return super().evaluate(script, tab)


def dialogs_question():
    return process.dialogs.QUESTION


def run(fake, row, *args, **parts):
    """`row` over `fake`'s Lab (with `parts` replaced): its checks by (row, name)."""
    return by_name(row(fake.lab(**parts), *args)["checks"])


class HangTests(unittest.TestCase):
    def test_a_banner_at_two_seconds_that_clears_and_no_timer_while_hidden_passes(self):
        named = by_name(process.hang(RowFake().lab(), 5000)["checks"])
        for name in ("banner_ms", "main_turn_p99_ms", "banner_clears", "host_report"):
            self.assertEqual(named[("hang", name)]["verdict"], "PASS", named[("hang", name)])
        self.assertEqual(named[("hang.hidden", "no_timer")]["verdict"], "PASS")

    def test_a_late_banner_fails(self):
        named = by_name(process.hang(RowFake(banner_at=2.5).lab(), 5000)["checks"])
        self.assertEqual(named[("hang", "banner_ms")]["verdict"], "FAIL")
        self.assertTrue(named[("hang", "banner_ms")]["measured"])

    def test_a_timer_armed_while_hidden_fails(self):
        named = by_name(process.hang(RowFake(hang_gate=False).lab(), 5000)["checks"])
        self.assertEqual(named[("hang.hidden", "no_timer")]["verdict"], "FAIL")
        self.assertTrue(named[("hang.hidden", "no_timer")]["measured"])

    def test_no_timer_while_hidden_proves_nothing_without_the_visible_control(self):
        fake = RowFake()
        fake.armed = lambda: False  # a host whose input arms no timer at all
        named = by_name(process.hang(fake.lab(), 5000)["checks"])
        self.assertFalse(named[("hang.hidden", "no_timer")]["measured"])
        self.assertIn("visible hang armed no timer", named[("hang.hidden", "no_timer")]["reason"])

    def test_without_host_block_ms_the_host_report_is_not_measured(self):
        named = by_name(process.hang(RowFake(host_block=False).lab(), 5000)["checks"])
        self.assertEqual(named[("hang", "banner_ms")]["verdict"], "PASS")  # SIGSTOP stands in
        self.assertIn("p01-process-084", named[("hang", "host_report")]["reason"])


class RendererHangTests(unittest.TestCase):
    def test_the_tabs_own_prompt_and_no_host_banner_pass(self):
        named = run(RowFake(), process.renderer_hang)
        self.assertEqual(named[("renderer-hang", "prompt_s")]["verdict"], "PASS")
        self.assertEqual(named[("renderer-hang", "no_host_banner")]["verdict"], "PASS")

    def test_the_host_banner_for_a_renderer_hang_fails(self):
        named = run(RowFake(renderer_banner=True), process.renderer_hang)
        self.assertEqual(named[("renderer-hang", "no_host_banner")]["verdict"], "FAIL")

    def test_no_prompt_fails(self):
        named = run(RowFake(renderer_prompt=False), process.renderer_hang)
        self.assertEqual(named[("renderer-hang", "prompt_s")]["verdict"], "FAIL")


class ImeTests(unittest.TestCase):
    def test_dead_key_kotoeri_and_secure_input_pass(self):
        fake = RowFake()
        named = run(fake, process.ime, secure_pid=lambda: fake.app if fake.secure else 0)
        for row, name in (("ime.dead_key", "commit"), ("ime.kotoeri", "commit"), ("ime.first_rect", "max_ms"),
                          ("ime.sync", "requests"), ("ime.secure_input", "focused"), ("ime.secure_input", "blurred"),
                          ("ime.secure_input", "after_crash"), ("ime.secure_input", "after_close")):
            self.assertEqual(named[(row, name)]["verdict"], "PASS", named[(row, name)])
        self.assertEqual(fake.source, "com.apple.keylayout.US")  # the input source before it is back
        for source in ("emoji_picker", "dictation"):
            self.assertIn("task p01-process-04", named[(f"ime.{source}", "commit")]["reason"])

    def test_a_dead_key_or_kotoeri_that_does_not_compose_fails(self):
        named = run(RowFake(dead_keys=False, kotoeri=False), process.ime)
        self.assertEqual(named[("ime.dead_key", "commit")]["verdict"], "FAIL")
        self.assertEqual(named[("ime.kotoeri", "commit")]["verdict"], "FAIL")
        self.assertTrue(named[("ime.kotoeri", "commit")]["measured"])

    def test_kotoeri_with_live_conversion_commits_its_conversion(self):
        named = run(RowFake(live_conversion=True), process.ime)
        self.assertEqual(named[("ime.kotoeri", "commit")]["verdict"], "PASS", named[("ime.kotoeri", "commit")])
        self.assertEqual(named[("ime.kotoeri", "commit")]["value"]["value"], "日本")

    def test_kotoeri_text_with_no_composition_fails(self):
        fake = RowFake()
        named = run(fake, process.ime, input_source=lambda source: "com.apple.keylayout.US")  # no Kotoeri selected
        self.assertEqual(named[("ime.kotoeri", "commit")]["verdict"], "FAIL")
        self.assertEqual(named[("ime.kotoeri", "commit")]["value"]["compositions"], 0)

    def test_kotoeri_without_an_input_source_driver_is_not_measured(self):
        named = run(RowFake(), process.ime, input_source=lambda source: None)
        self.assertFalse(named[("ime.kotoeri", "commit")]["measured"])

    def test_secure_input_left_on_after_a_crash_and_close_fails(self):
        named = run(RowFake(secure_balanced=False), process.ime)
        self.assertEqual(named[("ime.secure_input", "focused")]["verdict"], "PASS")
        self.assertEqual(named[("ime.secure_input", "after_crash")]["verdict"], "FAIL")

    def test_the_crash_counts_toward_the_restart_window(self):
        fake = RowFake()
        lab = fake.lab()
        process.ime(lab)
        self.assertEqual(len(lab.host_deaths), 1)


class AxVisibilityTests(unittest.TestCase):
    def test_remote_children_and_a_readable_h1_pass(self):
        named = run(RowFake(), process.ax)
        self.assertEqual(named[("ax", "remote_children")]["verdict"], "PASS")
        self.assertEqual(named[("ax", "h1_readable")]["verdict"], "PASS")

    def test_no_remote_children_fails(self):
        named = run(RowFake(ax_connected=False), process.ax)
        self.assertEqual(named[("ax", "remote_children")]["verdict"], "FAIL")
        self.assertEqual(named[("ax", "h1_readable")]["verdict"], "FAIL")

    def test_hidden_pages_that_stop_drawing_pass(self):
        named = run(RowFake(), process.visibility)
        for row in ("visibility.workspace_hidden", "visibility.app_hidden"):
            self.assertEqual(named[(row, "state_hidden")]["verdict"], "PASS")
            self.assertEqual(named[(row, "raf_per_s")]["verdict"], "PASS")
        self.assertEqual(named[("visibility.shown_again", "draws")]["verdict"], "PASS")

    def test_hidden_pages_that_keep_drawing_fail(self):
        named = run(RowFake(hidden_throttle=False), process.visibility)
        self.assertEqual(named[("visibility.app_hidden", "raf_per_s")]["verdict"], "FAIL")
        self.assertEqual(named[("visibility.workspace_hidden", "state_hidden")]["verdict"], "FAIL")


class StallTests(unittest.TestCase):
    PACE = {"stalls": 30, "long_frames": 0}

    def test_cmux_made_frontmost_before_the_idle_and_still_frontmost_passes(self):
        activations = []
        named = run(RowFake(), process.stall, 50, 100, 10, stall_pace=lambda ms, every: dict(self.PACE),
                    activate=lambda: activations.append(1) or {"activated": True, "error": ""})
        self.assertEqual(named[("stall.after_idle", "cmux_frontmost")]["verdict"], "PASS")
        self.assertEqual(named[("stall.after_idle", "long_frames")]["verdict"], "PASS")
        self.assertEqual(len(activations), 2)  # before the idle and before the second pacing

    def test_cmux_not_frontmost_after_the_idle_fails(self):
        named = run(RowFake(), process.stall, 50, 100, 10, stall_pace=lambda ms, every: dict(self.PACE), front=lambda: 1)
        self.assertEqual(named[("stall.after_idle", "cmux_frontmost")]["verdict"], "FAIL")

    def test_an_app_that_refuses_activation_measures_no_after_idle_row(self):
        named = run(RowFake(), process.stall, 50, 100, 10, stall_pace=lambda ms, every: dict(self.PACE),
                    activate=lambda: {"activated": False, "error": "launched with CMUX_NEXT_NO_ACTIVATE=1"})
        self.assertFalse(named[("stall.after_idle", "long_frames")]["measured"])
        self.assertIn("NO_ACTIVATE", named[("stall.after_idle", "cmux_frontmost")]["reason"])

    def test_a_display_below_120_hz_fails_the_row_as_not_measured(self):
        named = run(RowFake(), process.stall, 50, 100, 0, stall_pace=lambda ms, every: dict(self.PACE), hz=60.0)
        self.assertEqual(named[("stall", "long_frames")]["verdict"], "PASS")
        self.assertFalse(named[("stall", "refresh_hz")]["measured"])
        self.assertIn("60 Hz", named[("stall", "refresh_hz")]["reason"])
        named = run(RowFake(), process.stall, 50, 100, 0, stall_pace=lambda ms, every: dict(self.PACE))
        self.assertEqual(named[("stall", "refresh_hz")]["verdict"], "PASS")

    def test_long_frames_fail(self):
        named = run(RowFake(), process.stall, 50, 100, 0, stall_pace=lambda ms, every: {"stalls": 30, "long_frames": 3})
        self.assertEqual(named[("stall", "long_frames")]["verdict"], "FAIL")


class QuitRuntimeTests(unittest.TestCase):
    def test_stay_keeps_cmux_the_host_and_the_tab(self):
        named = run(RowFake(), process.quit_row)
        for name in ("asked", "stay_keeps_cmux", "host_kept", "tab_kept"):
            self.assertEqual(named[("quit", name)]["verdict"], "PASS", named[("quit", name)])

    def test_a_quit_that_ignores_stay_fails(self):
        named = run(RowFake(stay=False), process.quit_row)
        self.assertEqual(named[("quit", "stay_keeps_cmux")]["verdict"], "FAIL")

    def test_no_cmd_q_when_the_app_does_not_ask_host_pages_on_quit(self):
        for asks, reason in ((None, "quit_beforeunload"), (False, "does not ask")):
            fake = RowFake(quit_asks=asks)
            named = run(fake, process.quit_row)
            self.assertIsNotNone(fake.app)  # cmux still runs: the row sent no Cmd-Q
            for name in ("asked", "stay_keeps_cmux", "host_kept", "tab_kept"):
                self.assertFalse(named[("quit", name)]["measured"])
                self.assertIn(reason, named[("quit", name)]["reason"])
                self.assertIn("p01-process-087", named[("quit", name)]["reason"])

    def test_rows_after_a_row_that_ended_cmux_fail_with_that_cause(self):
        fake = RowFake(stay=False)
        ran = []

        def bounded(out, name, run_row):
            ran.append(name)
            out[name] = run_row()
        out = process.run_rows(fake.lab(), ["quit", "kill-app", "kill-host"], {}, bounded)
        self.assertEqual(ran, ["quit"])
        for name, number in (("kill-app", 20), ("kill-host", 4)):
            self.assertEqual(out[name]["checks"][0]["reason"], "cmux quit during the quit row")
            self.assertEqual(out[name]["checks"][0]["number"], number)

    def test_a_staged_runtime_used_after_the_idle_restart_passes(self):
        named = run(RowFake(), process.runtime_update)
        for name in ("idle_restart", "tab_back", "uses_staged"):
            self.assertEqual(named[("runtime-update", name)]["verdict"], "PASS", named[("runtime-update", name)])

    def test_no_staged_runtime_fails_naming_the_task(self):
        named = run(RowFake(runtime=False), process.runtime_update)
        self.assertIn("p01-process-087", named[("runtime-update", "pass")]["reason"])


class HelperKillTests(unittest.TestCase):
    def test_every_renderer_is_killed_so_the_probe_tab_shows_its_sad_tab(self):
        fake = RowFake()
        row = process.helper_kill(fake.lab())
        named = by_name(row["checks"])
        for helper in ("gpu", "renderer"):
            for name in ("one_record", "host_alive", "app_alive"):
                self.assertEqual(named[(f"helper-kill.{helper}", name)]["verdict"], "PASS")
        self.assertEqual(named[("helper-kill.gpu", "page_answers")]["verdict"], "PASS")
        self.assertEqual(named[("helper-kill.renderer", "sad_tab")]["verdict"], "PASS")
        self.assertEqual(row["renderer"]["pids"], [701, 702])  # the probe's renderer is not the first in ps order

    def test_no_sad_tab_or_no_record_fails(self):
        named = run(RowFake(sad_tab=False), process.helper_kill)
        self.assertEqual(named[("helper-kill.renderer", "sad_tab")]["verdict"], "FAIL")
        named = run(RowFake(helper_records=False), process.helper_kill)
        self.assertIn("p01-process-225", named[("helper-kill.gpu", "one_record")]["reason"])


class KillAppTests(unittest.TestCase):
    MEASURED = ("host_adopted", "no_reload", "cdp_session", "terminal_screens_ms", "terminal_command")

    def test_a_relaunch_that_adopts_the_host_with_no_reload_passes(self):
        named = run(RowFake(), process.kill_app)
        for name in self.MEASURED:
            self.assertEqual(named[("kill-app", name)]["verdict"], "PASS", named[("kill-app", name)])
        self.assertEqual(named[("kill-app", "terminal_screens_ms")]["value"], 120.0)
        self.assertGreaterEqual(named[("kill-app", "terminal_command")]["value"], process.SHELL_COMMAND_S)

    def test_the_parts_of_done_check_20_with_no_driver_fail_naming_their_task(self):
        named = run(RowFake(), process.kill_app)
        for name in ("shell_mode_command", "remote_tabs", "vscode_url"):
            self.assertEqual(named[("kill-app", name)]["verdict"], "FAIL")
            self.assertFalse(named[("kill-app", name)]["measured"])
            self.assertIn("p01-process-239", named[("kill-app", name)]["reason"])
        self.assertEqual(rows.failing(list(named.values())), ["kill-app"])

    def test_a_relaunch_with_a_new_host_and_a_reload_fails(self):
        named = run(RowFake(adopt=False, screens_ms=450.0), process.kill_app)
        for name in ("host_adopted", "no_reload", "cdp_session", "terminal_screens_ms"):
            self.assertEqual(named[("kill-app", name)]["verdict"], "FAIL")
            self.assertTrue(named[("kill-app", name)]["measured"])

    def test_an_orphaned_host_listed_first_beside_a_new_one_is_no_adoption(self):
        named = run(RowFake(adopt=False, lingering=True), process.kill_app)
        adopted = named[("kill-app", "host_adopted")]
        self.assertEqual(adopted["verdict"], "FAIL")
        self.assertEqual(adopted["value"]["running"], [500, 501])
        # The same host reported after, with an orphan of another run beside it, fails too.
        fake = RowFake()
        named = run(fake, process.kill_app, host_pids=lambda: [499, fake.host_pid()])
        self.assertIn("2 Chromium Host processes", named[("kill-app", "host_adopted")]["reason"])

    def test_a_command_or_cdp_session_that_died_with_cmux_fails(self):
        named = run(RowFake(command_survives=False, cdp_alive=False), process.kill_app)
        self.assertIn("ended with cmux", named[("kill-app", "terminal_command")]["reason"])
        self.assertIn("the session ended", named[("kill-app", "cdp_session")]["reason"])
        named = run(RowFake(), process.kill_app, cdp_session=lambda query: {"error": "no CDP page target"})
        self.assertFalse(named[("kill-app", "cdp_session")]["measured"])

    def test_without_the_hosts_reported_pid_adoption_is_not_measured(self):
        fake = RowFake()
        real = fake.rpc

        def rpc(method, params=None, timeout=60):
            reply = real(method, params, timeout)
            if method == "debug.cef" and isinstance(reply.get("host"), dict):
                reply["host"].pop("pid", None)
            return reply
        named = run(fake, process.kill_app, rpc=rpc)
        self.assertFalse(named[("kill-app", "host_adopted")]["measured"])
        self.assertIn("p01-process-080", named[("kill-app", "host_adopted")]["reason"])

    def test_no_terminal_screens_mark_names_task_152(self):
        named = run(RowFake(screens_ms=None), process.kill_app)
        self.assertIn("terminal_screens_shown", named[("kill-app", "terminal_screens_ms")]["reason"])
        self.assertIn("p01-process-152", named[("kill-app", "terminal_screens_ms")]["reason"])

    def test_a_refused_relaunch_fails_with_its_reason(self):
        named = run(RowFake(), process.kill_app, relaunch=lambda: {"error": "tag-in-use"})
        self.assertIn("tag-in-use", named[("kill-app", "pass")]["reason"])


class BenchRelaunchTests(unittest.TestCase):
    """relaunch_after_kill over a fake BenchApp that refuses, as BenchApp.launch does, any launch beside the tag's
    surviving processes unless it adopts them."""

    class Process:
        def __init__(self, pid):
            self.pid, self.killed = pid, False

        def kill(self):
            self.killed = True

        def wait(self, timeout=None):
            return -9

        def poll(self):
            return -9 if self.killed else None

    class Bench:
        def __init__(self, bench, marks):
            self.bench, self.marks, self.launches = bench, marks, []
            self.process, self.first_answer_ms, self.features = BenchRelaunchTests.Process(10), None, None
            self.host_pid = 500  # survives the kill: browserHost.survivesAppCrash

        def launch(self, probe_first_answer=False, adopt=False, **_):
            self.launches.append(adopt)
            if self.host_pid and not adopt:
                raise self.bench.LaunchError("tag-in-use", {"detail": "an app of the bundle already runs"})
            self.process, self.first_answer_ms = BenchRelaunchTests.Process(11), 42.0
            return self

        def rpc(self, method, params=None, timeout=60):
            if method == "debug.timings":
                return {"launch_ms_since_process_start": dict(self.marks)}
            return {}

        def read_features(self):
            return {"cefHelperHost": {"state": "on", "source": "local"}}, "fh", "off"

        def activate(self):
            return {"activated": True, "error": ""}

    def setUp(self):
        self.bench = load_bench()
        self.bench.opts = self.bench.parse(["--app", "/tmp/cmux DEV probe.app", "--out", tempfile.mkdtemp(), "--kill-app"])

    def test_the_relaunch_adopts_the_surviving_host_and_reads_its_launch_marks(self):
        app = self.Bench(self.bench, {"first_window_frame_committed": 400.0, "terminal_screens_shown": 610.0})
        old = app.process
        result = self.bench.relaunch_after_kill(app)()
        self.assertTrue(old.killed)
        self.assertEqual(app.launches, [True])
        self.assertEqual(result["first_answer_ms"], 42.0)
        self.assertEqual(result["first_frame_ms"], 400.0)
        self.assertEqual(result["terminal_screens_ms"], 210.0)

    def test_a_relaunch_with_no_terminal_screens_mark_says_which_mark_is_missing(self):
        self.bench.RELAUNCH_MARKS_WAIT_S = 0.2
        result = self.bench.relaunch_after_kill(self.Bench(self.bench, {"first_window_frame_committed": 400.0}))()
        self.assertIsNone(result["terminal_screens_ms"])
        self.assertIn("terminal_screens_shown", result["terminal_screens_missing"])

    def test_the_helper_modes_kill_is_one_death_of_the_restart_window(self):
        del self.bench.HOST_DEATHS[:]
        killed = self.bench.kill_host_by_op(lambda method, params=None, timeout=60: {"killed_pid": 500})
        self.assertEqual(killed, 500)
        self.assertEqual(len(self.bench.HOST_DEATHS), 1)
        self.bench.RESULT["refresh_hz"] = 60.0
        lab = self.bench.process_lab(self.Bench(self.bench, {}), "file:///probe.html")
        self.assertIs(lab.host_deaths, self.bench.HOST_DEATHS)
        # kill-host then rests out the window after that kill before it spends the budget.
        fake = FakeApp()
        seeded = fake.lab()
        seeded.host_deaths.append(fake.now() - 30)
        self.assertAlmostEqual(process.kill_host(seeded)["rested_s"], rows.RESTART_WINDOW_S - 30, delta=0.01)

    def test_the_backend_host_is_the_reported_one_never_the_prototype_or_an_orphan(self):
        listed = [600, 500]
        self.bench.chromium_host_pids = lambda: list(listed)
        self.bench.pid_gone = lambda pid: pid not in listed

        def rpc_of(reported, prototype):
            def rpc(method, params=None, timeout=60):
                if method == "debug.cef":
                    return {"backend": "host", "host": {"pid": reported} if reported else {}}
                if method == "debug.chromium_host":
                    return {"pid": prototype} if prototype else {}
                return {}
            return rpc
        self.assertEqual(self.bench.backend_host_pid(rpc_of(500, None)), 500)
        self.assertEqual(self.bench.backend_host_pid(rpc_of(None, 600)), 500)
        self.assertEqual(self.bench.backend_host_pids(rpc_of(None, 600)), [500])
        self.assertIsNone(self.bench.backend_host_pid(rpc_of(None, None)))  # two hosts, none reported: ambiguous
        self.assertIsNone(self.bench.backend_host_pid(rpc_of(700, None)))  # the reported host is gone

    def test_the_kill_app_run_gives_the_host_a_devtools_port(self):
        self.assertIsNone(self.bench.cdp_session(None)("?app").get("session"))
        self.assertIn("no DevTools port", self.bench.cdp_session(None)("?app")["error"])

    def test_asked_rows_follow_the_flags(self):
        asked = self.bench.asked_rows(self.bench.opts)
        self.assertEqual(asked, {"modes": [], "native_ui": False, "process_rows": ["kill-app"]})
        native = self.bench.parse(["--app", "/tmp/cmux DEV probe.app", "--out", "/tmp/out", "--native-ui"])
        self.assertEqual(self.bench.asked_rows(native)["modes"], [])
        self.assertTrue(self.bench.asked_rows(native)["native_ui"])


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
