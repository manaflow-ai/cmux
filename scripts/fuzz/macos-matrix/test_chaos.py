#!/usr/bin/env python3
"""Offline checks of chaos.py's verdicts, with a fake guest (no VM, no VNC, no app).

Run: python3 -I scripts/fuzz/macos-matrix/test_chaos.py
"""

from __future__ import annotations

import json
import os
import shlex
import subprocess
import sys
import tempfile
import time
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import chaos  # noqa: E402
import smoke  # noqa: E402

REPORTS = "/Users/admin/Library/Logs/DiagnosticReports/"


class FakeVNC:
    def __init__(self, *_):
        pass

    def screenshot_png(self) -> bytes:
        return b"png"


class FakeApp:
    """The app's layout as `cmux app call` shows it: panes of tabs, one selected per pane, one focused.
    openBrowser opens in the focused pane (TabLifecycle.newBrowser); debug.surfaces names only a pane's
    selected tab."""

    def __init__(self, splits=("splitRight", "splitDown")):
        self.splits = splits
        self.panes: list[dict] = []  # {"pane", "tabs": {id: kind}, "selected"}
        self.focused = -1
        self.ids = 0
        self.refuse: set[str] = set()  # methods or actions that answer with an error

    def new_id(self, prefix: str) -> str:
        self.ids += 1
        return f"{prefix}{self.ids}"

    def add_pane(self) -> None:
        tab = self.new_id("term")
        self.panes.append({"pane": self.new_id("pane"), "tabs": {tab: "terminal"}, "selected": tab})
        self.focused = len(self.panes) - 1

    def call(self, method: str, params: dict) -> dict:
        if method in self.refuse or params.get("action") in self.refuse:
            return {"error": "refused"}
        if method == "debug.windows":
            return {"windows": [{"id": "w1"}]}
        if method == "debug.focus":
            return {"windows": [{"is_key": True, "topology": [p["pane"] for p in self.panes]}]}
        if method == "debug.surfaces":
            return {"windows": [{"panes": [
                {"pane": p["pane"], "selected_tab": p["selected"], "focused": i == self.focused,
                 "kind": p["tabs"][p["selected"]], "link": "connected"} for i, p in enumerate(self.panes)]}]}
        if method == "browser.page.eval":
            return {"value": chaos.TITLE}
        if method != "action.run":
            return {}
        action = params["action"]
        if action == "newTab" or action in self.splits:
            self.add_pane()
        elif action == "openBrowser":
            tab = self.new_id(params["args"]["engine"])
            self.panes[self.focused]["tabs"][tab] = "browser"
            self.panes[self.focused]["selected"] = tab
            return {"created": [tab]}
        elif action == "tab.focus":
            tab = params["target"].removeprefix("tab:")
            for i, p in enumerate(self.panes):
                if tab in p["tabs"]:
                    p["selected"], self.focused = tab, i
        return {}


class FakeGuest:
    """Answers the guest commands chaos.py sends; `reports` are (mtime, path) of DiagnosticReports and
    `contents` their text; `ps` is the process table (pid, ppid, command)."""

    def __init__(self):
        self.app = "/Users/admin/fuzzapp/cmux DEV.app"
        self.socket = "/tmp/cmux-x.sock"
        self.env = ""
        self.binary = ""
        self.reports: list[tuple[int, str]] = []
        self.contents: dict[str, str] = {}
        self.ps: list[tuple[int, int, str]] = []
        self.answers: dict = {}  # a substring of a command -> its output (or a function that returns it)
        self.app_pid: int | None = 4242
        self.pings: list[int | None] = []
        self.commands: list[str] = []
        self.ui: FakeApp | None = None

    def sh(self, cmd: str, timeout: float = 30) -> subprocess.CompletedProcess:
        self.commands.append(cmd)
        if cmd == "date +%s":
            out = str(int(time.time()))
        elif cmd.startswith("cat "):
            out = self.contents.get(shlex.split(cmd)[1], "")
        elif "DiagnosticReports" in cmd:
            out = "".join(f"{int(m)} {p}\n" for m, p in self.reports)
        elif cmd.startswith("ps "):
            out = "".join(f"{pid} {ppid} {args}\n" for pid, ppid, args in self.ps)
        else:
            out = next((v() if callable(v) else v for k, v in self.answers.items() if k in cmd), "")
        return subprocess.CompletedProcess(cmd, 0, out, "")

    def cmux(self, args, timeout: float = 15) -> subprocess.CompletedProcess:
        if self.ui and args[:2] == ["app", "call"]:
            return subprocess.CompletedProcess(args, 0, json.dumps(self.ui.call(args[2], json.loads(args[3]))) + "\n", "")
        return subprocess.CompletedProcess(args, 0, "{}\n", "")

    def _cli(self, args) -> str:
        return "cmux " + " ".join(args)

    def pid(self):
        return self.app_pid

    def ping_ms(self, timeout: float, *_args, **_kw):
        return self.pings.pop(0) if self.pings else 20

    def refocus(self) -> bool:
        return False


class ChaosVerdicts(unittest.TestCase):
    def setUp(self):
        smoke.RFB = FakeVNC
        chaos.REPORT_DEADLINE = 0
        self.out = tempfile.mkdtemp(prefix="chaos-test-")
        self.g = FakeGuest()
        self.c = chaos.Chaos(self.g, "127.0.0.1:5900:pw", self.out)
        self.c.app_pid = 4242
        self.c.quit = lambda: setattr(self.c, "app_pid", None)
        self.c.shot = lambda name: None
        self.c.wait = lambda probe, seconds, every=1.0: probe()  # one look: the fakes answer at once

    def result(self) -> dict:
        with open(os.path.join(self.out, "result.json")) as f:
            return json.load(f)

    @staticmethod
    def row(fault: str, start: float, end: float, outcome: str = "ok") -> dict:
        return {"fault": fault, "outcome": outcome, "ok": outcome == "ok", "window": [start, end], "crash_reports": []}

    def test_every_fault_has_a_phase_and_a_method(self):
        for name, (phase, expected) in chaos.FAULTS.items():
            self.assertIn(phase, chaos.PHASES, name)
            self.assertTrue(expected, name)
            self.assertTrue(callable(getattr(chaos.Chaos, "fault_" + name.replace("-", "_"), None)), name)

    def test_ok_fault_needs_the_same_pid_and_answered_pings(self):
        self.c.fault_acpmux = lambda: (True, {"echo": True})
        self.assertEqual(self.c.run_fault("acpmux", "app")["outcome"], "ok")
        self.g.pings = [20, chaos.PING_BOUND_MS, 20]  # one ping ran into its bound: a hang
        self.assertEqual(self.c.run_fault("acpmux", "app")["outcome"], "FAIL")
        self.g.app_pid = 5000  # the app died and something restarted it
        row = self.c.run_fault("acpmux", "app")
        self.assertEqual((row["outcome"], row["app_pid_kept"]), ("FAIL", False))

    def test_a_hang_during_the_fault_fails_it(self):
        """The main thread hung while the daemon was down and answered again before the fault returned."""
        def fault():
            time.sleep(0.2)
            return True, {"echo": True}
        self.c.fault_daemon = fault
        self.g.pings = [chaos.PING_BOUND_MS]  # the first ping, sent while the fault runs
        row = self.c.run_fault("daemon", "app")
        self.assertEqual((row["outcome"], row["pings_during_fault"]), ("FAIL", 1))
        self.assertEqual(row["ping_ms_vm"], [chaos.PING_BOUND_MS, 20, 20, 20])

    def test_skip_and_runner_errors_are_rows(self):
        def cannot():
            raise chaos.Skip("no passwordless sudo in the guest")
        self.c.fault_memory_pressure = cannot
        self.c.fault_daemon = lambda: 1 / 0
        skip = self.c.run_fault("memory-pressure", "app")
        fail = self.c.run_fault("daemon", "app")
        self.assertEqual((skip["outcome"], skip["detail"]), ("skip", "no passwordless sudo in the guest"))
        self.assertEqual(fail["outcome"], "FAIL")
        self.assertIn("ZeroDivisionError", fail["detail"]["error"])

    def test_a_skip_is_no_pass(self):
        self.c.result["faults"] = [{"fault": "acpmux", "outcome": "skip", "ok": False, "crash_reports": []}]
        self.c.finish()
        r = self.result()
        self.assertFalse(r["ok"])
        self.assertEqual((r["skipped"], r["failed_steps"]), (["acpmux"], []))

    # --- crash reports --------------------------------------------------------------------------
    def test_crash_reports_go_to_the_fault_whose_window_holds_them(self):
        t = self.c.since + 100
        self.c.result["faults"] = [self.row("daemon", t, t + 10), self.row("acpmux", t + 20, t + 30)]
        self.g.reports = [(t + 25, REPORTS + "cmux DEV-2026-10-26-1.ips"),
                          (t + 22, REPORTS + "cmux DEV-2026-10-26-2.hang")]  # a hang report is no crash
        self.c.finish()
        r = self.result()
        daemon, acpmux = r["faults"]
        self.assertEqual((daemon["outcome"], acpmux["outcome"]), ("ok", "FAIL"))
        self.assertEqual(acpmux["crash_reports"], ["cmux DEV-2026-10-26-1.ips"])
        self.assertEqual((r["crashes"], r["failed_steps"], r["ok"]), (1, ["acpmux"], False))

    def test_a_report_written_late_goes_to_the_fault_that_crashed(self):
        """ReportCrash wrote it during the next fault; its captureTime is in the first one."""
        t = 1_800_000_000  # 2027-01-15 08:00:00 UTC
        self.c.since = t - 50
        self.c.result["faults"] = [self.row("daemon", t, t + 10), self.row("acpmux", t + 12, t + 30)]
        path = REPORTS + "cmux DEV-2026-10-26-3.ips"
        self.g.reports = [(t + 20, path)]
        self.g.contents[path] = ('{"app_name":"cmux DEV","timestamp":"2027-01-15 08:00:20.00 +0000"}\n'
                                 '{\n  "captureTime" : "2027-01-15 08:00:05.1234 +0000",\n  "pid" : 900\n}\n')
        self.assertEqual(chaos.Chaos.crash_time(self.g.contents[path], 0), (t + 5, "captureTime"))
        self.c.finish()
        daemon, acpmux = self.result()["faults"]
        self.assertEqual((daemon["outcome"], daemon["crash_reports"], acpmux["outcome"]),
                         ("FAIL", ["cmux DEV-2026-10-26-3.ips"], "ok"))

    def test_a_crash_before_any_fault_fails_the_run(self):
        t = self.c.since + 100
        self.c.result["faults"] = [self.row("daemon", t, t + 10)]
        self.g.reports = [(t - 50, "/Library/Logs/DiagnosticReports/cmux DEV-tour.ips")]
        self.c.finish()
        r = self.result()
        self.assertEqual([u["report"] for u in r["crashes_outside_faults"]], ["cmux DEV-tour.ips"])
        self.assertFalse(r["ok"])

    def test_a_crash_in_a_later_launch_is_no_earlier_faults(self):
        """The holder phase's last fault ended; the fd-limit launch crashed after it."""
        t = self.c.since + 100
        self.c.result["faults"] = [self.row("holder", t, t + 10)]
        self.c.result["segments"] = [{"phase": "holder", "part": "quit", "window": [t + 10, t + 15]},
                                     {"phase": "fd-limit", "part": "launch and tour", "window": [t + 15, t + 60]}]
        self.g.reports = [(t + 40, REPORTS + "cmux DEV-launch.ips")]
        self.c.finish()
        r = self.result()
        self.assertEqual((r["faults"][0]["outcome"], r["faults"][0]["crash_reports"]), ("ok", []))
        self.assertEqual([(u["report"], u["during"]) for u in r["crashes_outside_faults"]],
                         [("cmux DEV-launch.ips", "fd-limit: launch and tour")])
        self.assertFalse(r["ok"])

    def test_a_phase_that_never_reached_its_faults_owns_its_launch_crash(self):
        t = self.c.since + 100
        self.c.result["faults"] = [self.row("fd-limit", t, t + 40, "FAIL")]
        self.g.reports = [(t + 20, REPORTS + "cmux DEV-fd.ips")]
        self.c.finish()
        r = self.result()
        self.assertEqual((r["faults"][0]["crash_reports"], r["crashes_outside_faults"]), (["cmux DEV-fd.ips"], []))

    def test_all_ok_is_a_pass(self):
        t = self.c.since + 100
        self.c.result["faults"] = [self.row(f, t, t + 1) for f in chaos.FAULTS]
        self.c.finish()
        self.assertTrue(self.result()["ok"])

    # --- processes ------------------------------------------------------------------------------
    def test_owned_processes(self):
        self.c.bundle_id = "com.cmuxterm.app.debug.tag"
        self.assertTrue(self.c.owned(self.g.app + "/Contents/MacOS/cmux-tui --headless"))
        self.assertTrue(self.c.owned("cmux-tui-host __holder --owner com.cmuxterm.app.debug.tag:tag@12"))
        # No CMUX_BUNDLE_ID in the daemon: the owner is the .app's name, its space made `_`.
        self.assertTrue(self.c.owned("cmux-holder --socket /x --owner cmux_DEV:tag@12"))
        self.assertFalse(self.c.owned("cmux-tui-host __holder --owner com.cmuxterm.app:-@12"))

    def test_holders_include_the_standalone_holder(self):
        """The daemon spawns the bundled holder with argv0 `cmux-holder` and no `__holder` argument."""
        self.c.bundle_id = "com.cmuxterm.app.debug.tag"
        self.g.ps = [(700, 1, "cmux-holder --socket /x --owner com.cmuxterm.app.debug.tag:tag@12"),
                     (701, 1, "/opt/cmux/cmux-tui-host __holder --owner com.cmuxterm.app.debug.tag:tag@12"),
                     (702, 1, "cmux-holder --socket /y --owner com.cmuxterm.app:-@99"),  # the person's cmux
                     (703, 1, "/usr/bin/vim cmux-holder --owner com.cmuxterm.app.debug.tag:x")]
        self.assertEqual(self.c.holders(), [700, 701])

    # --- the tour's layout ----------------------------------------------------------------------
    def test_the_pages_get_a_pane_of_their_own(self):
        self.g.ui = FakeApp()
        self.c.echo = lambda role: True
        self.assertEqual(self.c.tour(), {})
        for role in ("left", "right"):
            self.assertEqual(self.c.pane_of(self.c.tabs[role]).get("kind"), "terminal", role)
        self.assertLessEqual({self.c.tabs["cef"], self.c.tabs["webkit"]}, set(self.g.ui.panes[2]["tabs"]))

    def test_pages_that_share_the_right_pane_are_a_tour_problem(self):
        """With no third pane the pages open over `right`, whose host, link and text no read shows."""
        self.g.ui = FakeApp(splits=("splitRight",))
        self.c.echo = lambda role: True
        problems = self.c.tour()
        self.assertIn("web_pane", problems)
        self.assertIn("right", problems["layout"])
        self.assertEqual(self.c.pane_of(self.c.tabs["right"]), {})

    def test_the_tour_forgets_the_last_phases_tabs(self):
        self.g.ui = FakeApp(splits=())
        self.c.echo = lambda role: True
        self.c.tabs = {"left": "old1", "right": "old2", "cef": "old3", "webkit": "old4"}
        self.c.tour()
        self.assertNotIn("right", self.c.tabs)
        self.assertNotEqual(self.c.tabs.get("left"), "old1")

    # --- injection and outcome checks -----------------------------------------------------------
    def test_memory_pressure_that_never_reaches_critical_is_a_skip(self):
        self.c.tabs["left"] = "t1"
        self.c.echo = lambda role: True
        self.c.keys = lambda text: None
        self.g.answers["kern.memorystatus_vm_pressure_level"] = "1"
        with self.assertRaises(chaos.Skip):
            self.c.fault_memory_pressure()
        levels = iter(["4", "4", "1"])  # critical while the echo runs, then back to normal
        self.g.answers["kern.memorystatus_vm_pressure_level"] = lambda: next(levels, "1")
        ok, detail = self.c.fault_memory_pressure()
        self.assertEqual((ok, detail["level_during"]), (True, "4"))

    def test_a_disk_that_did_not_fill_is_a_skip(self):
        self.g.answers["df -k"] = "400000"
        with self.assertRaises(chaos.Skip):
            self.c.fault_full_disk()

    def test_full_disk_needs_the_new_workspace_and_clean_replies(self):
        self.g.answers["df -k"] = "12"
        self.g.ui = FakeApp()
        self.c.echo = lambda role: role == "full"
        ok, detail = self.c.fault_full_disk()
        self.assertEqual((ok, detail["new_workspace"], detail["free_kb_when_full"]), (True, True, 12))
        self.g.ui.refuse.add("settings.open")
        ok, _ = self.c.fault_full_disk()
        self.assertFalse(ok)

    def test_a_load_error_is_shown_not_blank(self):
        self.assertIsNone(chaos.Chaos.load_error({"gone": "0", "error": "", "enginePage": "0"}))  # blank or loading
        self.assertIsNone(chaos.Chaos.load_error({"gone": "1", "error": "", "enginePage": "0"}))  # the crash page
        self.assertIsNone(chaos.Chaos.load_error({"error": "no browser tab"}))  # no page status at all
        self.assertTrue(chaos.Chaos.load_error({"gone": "0", "error": "Can't reach example.com", "enginePage": "0"}))
        self.assertTrue(chaos.Chaos.load_error({"gone": "0", "error": "", "enginePage": "1"}))

    def test_network_off_turns_pf_on_in_the_foreground(self):
        """Only the off-timer may run in the background: the token must reach the host."""
        self.c.tabs["cef"] = "tab1"
        self.g.sh = lambda cmd, timeout=30: self.capture(cmd)
        self.captured: list[str] = []
        with self.assertRaises(chaos.Skip):  # the fake prints no token
            self.c.fault_network_off()
        on = next(c for c in self.captured if "pfctl -E" in c)
        foreground, _, background = on.partition("( sleep")
        self.assertIn("pfctl -E", foreground)
        self.assertNotIn("&", foreground.replace("2>&1", ""))
        self.assertIn(f"{chaos.NETWORK_OFF_SECONDS};", background)

    def capture(self, cmd):
        self.captured.append(cmd)
        return subprocess.CompletedProcess(cmd, 0, "", "")

    # --- holder ---------------------------------------------------------------------------------
    def holder_fault(self, after: dict, shells_after: dict, new_holders=()):
        """fault_holder with the left and right shells children of holder 700, and holder 701 apart.
        `after` is each tab's pane after the kill; tab.restart makes a pane connected."""
        self.c.tabs = {"left": "tL", "right": "tR"}
        before = {"left": (900, 700), "right": (901, 700)}
        killed, restarted = [], set()
        state = {"killed": False}
        self.c.holders = lambda: [701, *new_holders] if state["killed"] else [700, 701]
        self.c.shell_ids = lambda role: (shells_after if state["killed"] else before).get(role)
        self.c.type_around = lambda inject: (inject(), state.update(killed=True))
        self.c.kill = lambda pids: killed.extend(pids)
        self.c.pane_of = lambda tab, text=False: {"link": "connected"} if tab in restarted else after[tab]
        self.c.echo = lambda role: True

        def call(method, params=None, timeout=60):
            if (params or {}).get("action") == "tab.restart":
                restarted.add(params["target"].removeprefix("tab:"))
            return {}
        self.c.call = call
        ok, detail = self.c.fault_holder()
        self.assertEqual(killed, [700])
        return ok, detail

    def test_holder_kill_needs_the_restart_overlay(self):
        ended = {"link": "exited", "status_text": "Shell ended", "restart_offered": True}
        ok, detail = self.holder_fault({"tL": ended, "tR": ended}, {})
        self.assertTrue(ok, detail)
        self.assertEqual(detail["panes"]["left"]["observed"], "ended")
        bare = {"link": "exited", "status_text": None, "restart_offered": False}
        ok, detail = self.holder_fault({"tL": bare, "tR": bare}, {})
        self.assertFalse(ok)
        self.assertEqual(detail["panes"]["left"]["observed"], "ended without the Restart overlay")

    def test_holder_kill_kept_needs_the_same_shell_and_a_new_holder(self):
        live = {"link": "connected"}
        ok, detail = self.holder_fault({"tL": live, "tR": live}, {"left": (900, 1), "right": (901, 1)}, new_holders=(710,))
        self.assertTrue(ok, detail)
        self.assertEqual(detail["panes"]["left"]["new_holders"], [710])
        ok, _ = self.holder_fault({"tL": live, "tR": live}, {"left": (900, 1), "right": (901, 1)})
        self.assertFalse(ok)  # still connected and no new holder: the kill was never seen
        ok, _ = self.holder_fault({"tL": live, "tR": live}, {"left": (950, 1), "right": (901, 1)}, new_holders=(710,))
        self.assertFalse(ok)  # a new shell is no kept shell

    def test_a_left_shell_with_no_holder_parent_is_a_skip(self):
        self.c.tabs = {"left": "tL"}
        self.c.holders = lambda: [700]
        self.c.shell_ids = lambda role: (900, 650)  # a terminal host's child, not the holder's
        with self.assertRaises(chaos.Skip):
            self.c.fault_holder()


class QuitStorm(unittest.TestCase):
    """The quit faults against a fake app: Cmd-Q shows the sheet, a second Cmd-Q answers it and the app exits."""

    def setUp(self):
        smoke.RFB = FakeVNC
        chaos.REPORT_DEADLINE = 0
        self.saved = (chaos.QUIT_EXIT_DEADLINE, chaos.QUIT_ASK_WAIT, chaos.CHILD_EXIT_DEADLINE)
        chaos.QUIT_EXIT_DEADLINE = chaos.QUIT_ASK_WAIT = chaos.CHILD_EXIT_DEADLINE = 0  # one look each
        self.out = tempfile.mkdtemp(prefix="chaos-quit-")
        self.g = FakeGuest()
        self.c = chaos.Chaos(self.g, "127.0.0.1:5900:pw", self.out)
        self.c.app_pid = 4242
        self.c.shot = lambda name: None
        self.c.wait = lambda probe, seconds, every=1.0: probe()
        self.keys: list[str] = []
        self.asks = True  # the first Cmd-Q shows the quit sheet
        self.exit_code = 0  # what the app exits with once quit
        self.ignores_quit = False
        self.status: int | None = None
        self.sheet = False
        self.left_children: list[int] = []  # Chromium children still running after the exit
        self.ps = [(800, 4242, "/x/Chromium Helper --type=renderer"), (801, 4242, "/x/Chromium Helper --type=gpu-process")]
        self.relaunch_problems: dict = {}
        self.quits: list[int | None] = []
        self.c.press = self.press
        self.c.type_keys = lambda text: self.keys.append("type:" + text)
        self.c.exited = lambda: self.status
        self.c.procs = lambda: self.ps
        self.c.call = self.call
        self.c.launch = lambda phase: setattr(self.c, "app_pid", 5000) or True
        self.c.tour = lambda: self.relaunch_problems
        self.c.quit = lambda: self.quits.append(self.c.app_pid)
        self.c.kill = lambda pids: self.keys.append("kill:" + ",".join(map(str, pids)))

    def tearDown(self):
        chaos.QUIT_EXIT_DEADLINE, chaos.QUIT_ASK_WAIT, chaos.CHILD_EXIT_DEADLINE = self.saved

    def press(self, chord: str) -> None:
        self.keys.append(chord)
        if chord != "cmd+q" or self.ignores_quit:
            return
        if self.asks and not self.sheet and self.status is None and self.keys.count("cmd+q") == 1:
            self.sheet = True
            return
        self.sheet, self.status = False, self.exit_code
        self.ps = [row for row in self.ps if row[0] in self.left_children]

    def call(self, method: str, params: dict | None = None, timeout: float = 60) -> dict:
        if method == "debug.quit":
            return {"asking": self.sheet, "quitting": self.sheet}
        if method == "debug.daemon":
            return {"pid": 31, "connection": "connected"}
        return {}

    def test_a_clean_quit_answers_the_sheet_with_a_second_cmd_q_and_relaunches(self):
        ok, detail = self.c.quit_storm()
        self.assertTrue(ok, detail)
        self.assertEqual((detail["sheet"], detail["exit_status"], detail["children_left"]), ("cmd-q", 0, []))
        self.assertEqual((detail["chromium_children"], detail["new_pid"], self.c.app_pid), ([800, 801], 5000, 5000))
        self.assertEqual(self.keys, ["cmd+q", "cmd+q"])
        self.assertEqual(self.quits, [], "a clean quit needs no clean-up")

    def test_a_quit_without_a_sheet_is_one_cmd_q(self):
        self.asks = False
        ok, detail = self.c.quit_storm()
        self.assertTrue(ok, detail)
        self.assertEqual((detail["sheet"], self.keys), ("none", ["cmd+q"]))

    def test_an_app_that_never_exits_fails_and_is_cleaned_up(self):
        self.ignores_quit, self.asks = True, False
        ok, detail = self.c.quit_storm()
        self.assertFalse(ok)
        self.assertIsNone(detail["exit_status"])
        self.assertEqual(self.quits, [4242])
        self.assertIn("quit_state", detail)

    def test_a_nonzero_exit_fails(self):
        self.exit_code = 137  # the hard quit deadline's forced exit, or a crash
        ok, detail = self.c.quit_storm()
        self.assertFalse(ok)
        self.assertEqual(detail["exit_status"], 137)

    def test_a_chromium_child_left_after_the_exit_fails_and_is_killed(self):
        self.left_children = [801]
        ok, detail = self.c.quit_storm()
        self.assertFalse(ok)
        self.assertEqual(detail["children_left"], [801])
        self.assertIn("kill:801", self.keys)

    def test_a_relaunch_that_fails_its_tour_fails_the_fault(self):
        self.relaunch_problems = {"echo": "a typed echo did not run"}
        ok, detail = self.c.quit_storm()
        self.assertFalse(ok)
        self.assertEqual(detail["relaunch_tour"], self.relaunch_problems)

    def test_quit_typing_presses_cmd_q_in_the_middle_of_the_line(self):
        self.c.tabs = {"left": "tL"}
        self.c.focus = lambda tab: {}
        ok, detail = self.c.fault_quit_typing()
        self.assertTrue(ok, detail)
        first, cmd_q, rest = self.keys[:3]
        self.assertEqual(cmd_q, "cmd+q")
        self.assertTrue(first.startswith("type:echo ") and rest.startswith("type:"))
        self.assertEqual(len(first) + len(rest) - 10, detail["typed"])

    def test_quit_daemon_restart_kills_the_daemon_right_before_cmd_q(self):
        ok, detail = self.c.fault_quit_daemon_restart()
        self.assertTrue(ok, detail)
        self.assertEqual(self.keys[:2], ["kill:31", "cmd+q"])

    def test_quit_split_animation_presses_cmd_d_right_before_cmd_q(self):
        self.c.tabs = {"left": "tL"}
        self.c.focus = lambda tab: {}
        self.c.panes = lambda: 2
        ok, _ = self.c.fault_quit_split_animation()
        self.assertTrue(ok)
        self.assertEqual(self.keys[:2], ["cmd+d", "cmd+q"])

    def test_quit_page_load_opens_both_engines_on_a_server_that_never_answers(self):
        opened = []
        self.c.tabs = {"cef": "tC"}
        self.c.focus = lambda tab: {}
        plain = self.call

        def call(method, params=None, timeout=60):
            if method == "action.run" and (params or {}).get("action") == "openBrowser":
                opened.append(params["args"])
                return {"created": ["load-" + params["args"]["engine"]]}
            return plain(method, params, timeout)
        self.c.call = call
        ok, detail = self.c.fault_quit_page_load()
        self.assertTrue(ok, detail)
        self.assertEqual([a["engine"] for a in opened], ["cef", "webkit"])
        self.assertTrue(all(f":{chaos.TARPIT_PORT}/" in a["url"] for a in opened))
        self.assertTrue(any("kill $(cat " + chaos.TARPIT_PID in c for c in self.g.commands), "the tarpit is stopped")

    def test_a_quit_fault_has_no_pings_while_the_app_is_down_and_keeps_the_relaunched_pid(self):
        self.g.app_pid = 5000  # the relaunched app
        self.c.fault_quit_daemon_restart = lambda: (setattr(self.c, "app_pid", 5000), (True, {}))[1]
        row = self.c.run_fault("quit-daemon-restart", "quit")
        self.assertEqual((row["outcome"], row["pings_during_fault"], row["app_pid_kept"]), ("ok", 0, True))
        self.assertEqual(len(row["ping_ms_vm"]), 3)

    def test_every_quit_fault_is_one_row_of_the_quit_phase(self):
        quit_faults = [f for f, (phase, _) in chaos.FAULTS.items() if phase == "quit"]
        self.assertEqual(quit_faults, ["quit-page-load", "quit-typing", "quit-daemon-restart", "quit-split-animation"])
        self.g.app_pid = 5000
        self.c.app_pid = None
        self.c.call = lambda method, params=None, timeout=60: {}
        for name in quit_faults:
            setattr(self.c, "fault_" + name.replace("-", "_"), lambda: (True, {}))
        self.c.run(quit_faults)
        rows = self.c.result["faults"]
        self.assertEqual([(r["fault"], r["phase"], r["outcome"]) for r in rows], [(f, "quit", "ok") for f in quit_faults])
        self.assertTrue(all(r["expected"].endswith(chaos.QUIT_EXPECTED) for r in rows))


if __name__ == "__main__":
    unittest.main()
