#!/usr/bin/env python3
"""process-chaos-e2e.py (p10-stability-145):

1. It refuses a socket that is not a tagged debug socket of a running tagged DEV build: a release or untagged socket
   name, a release bundle, a socket the app does not answer for, or a pid that does not run from the bundle. main()
   exits 2 on it before any fault.
2. Only the app's pids are signalled: its process tree, a process run from its bundle, a host or holder naming it as
   its --owner, a WebContent the app reports whose responsible process is the app's. The person's cmux, the app
   itself and a WebContent of another app never are.
3. The main-thread ping verdict: p99 <= the limit, every ping answered (an unanswered one counts as the bound).
4. Against a fake app, every fault writes one JSON line with expected and observed, kills only the expected pids
   while keys go into the terminal, and passes when the app recovers; a page that never comes back, a main thread
   that stops answering, and a crash report in the fault's window each fail it; a fault the app cannot offer is a
   skip (exit 3).
5. The holder fault: the killed holder's pane shows the ended state with Restart, Restart brings a shell back, the
   other holder and its terminal are untouched.

Runs on any host (Linux included): no app, no socket, no signal sent.

    python3 -m unittest scripts/cmux-next/tests/test_process_chaos_e2e.py
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
import re
import sys
import tempfile
import time
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent


def load(name: str, path: Path):
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


chaos = load("process_chaos_e2e", HERE / "process-chaos-e2e.py")
crash = chaos.crash
Proc = crash.Proc

APP = 500
BUNDLE = "/Apps/cmux DEV chaos.app"
BUNDLE_ID = "com.cmuxterm.app.debug.chaos"
SOCKET = "/tmp/cmux-debug-chaos.sock"
PERSON = 900  # the person's own cmux: never signalled
OTHER_WEBCONTENT = 950  # a WebContent of another app


class FakeApp:
    """A tagged app's socket and process table. Kills change what the app reports the way the real one recovers."""

    def __init__(self, holders=False, acpmux=True, recover=True, hang_on_kill=False, agent="open"):
        """`agent`: "open" (an agent page shows), "none" (none until New Agent Chat opens one in the focused pane)
        or "several" (two panes show one and neither is focused: the reply names them, a pid needs `pane`)."""
        self.recover, self.hang_on_kill, self.agent_mode = recover, hang_on_kill, agent
        self.next_pid = 1000
        self.procs = {
            APP: Proc(APP, 1, f"{BUNDLE}/Contents/MacOS/cmux DEV"),
            601: Proc(601, APP, f"{BUNDLE}/Contents/Frameworks/Helper --type=renderer"),
            602: Proc(602, APP, f"{BUNDLE}/Contents/Frameworks/Helper --type=gpu-process"),
            603: Proc(603, APP, f"{BUNDLE}/Contents/Frameworks/Helper --type=utility "
                                "--utility-sub-type=network.mojom.NetworkService"),
            700: Proc(700, 1, f"{BUNDLE}/Contents/Resources/bin/cmux-tui __daemon"),
            800: Proc(800, 1, "/System/Library/Frameworks/WebKit.framework/XPCServices/com.apple.WebKit.WebContent"),
            801: Proc(801, 1, "/System/Library/Frameworks/WebKit.framework/XPCServices/com.apple.WebKit.WebContent"),
            PERSON: Proc(PERSON, 1, "/Applications/cmux.app/Contents/MacOS/cmux"),
            OTHER_WEBCONTENT: Proc(OTHER_WEBCONTENT, 1, "/System/Library/com.apple.WebKit.WebContent"),
        }
        if acpmux:
            self.procs[720] = Proc(720, 1, f"{BUNDLE}/Contents/Resources/bin/acpmux serve")
        self.holder_model = holders
        self.daemon = 700
        self.panes = [{"kind": "terminal", "selected_tab": "old", "focused": True, "link": "connected", "text": ""}]
        self.pages = {}
        self.agent = None if agent == "none" else 801
        self.exits_before_kill = set()  # pids that exit by themselves after the proof, before the signal
        self.lines = {}
        self.killed = []
        self.keys = 0
        self.tab_count = 0

    # -- processes
    def table(self):
        return dict(self.procs)

    def responsible(self, pid):
        return 77 if pid == OTHER_WEBCONTENT else APP

    def spawn(self, ppid, command):
        self.next_pid += 1
        self.procs[self.next_pid] = Proc(self.next_pid, ppid, command)
        return self.next_pid

    def kill(self, pid):
        if pid in (APP, PERSON, OTHER_WEBCONTENT):
            raise AssertionError(f"signalled {pid}")
        if pid in self.exits_before_kill:
            self.procs.pop(pid, None)
        if pid not in self.procs:
            raise ProcessLookupError(pid)
        self.killed.append(pid)
        command = self.procs.pop(pid).command
        if "--type=renderer" in command:
            # A shown tab shows the crash page; a hidden one only reloads when shown (CEFTab showProcessExit).
            for tab, page in self.pages.items():
                if page["engine"] == "cef":
                    page["gone" if self.shown(tab) else "dead_hidden"] = "1"
        elif "--type=gpu-process" in command and self.recover:
            self.spawn(APP, f"{BUNDLE}/Contents/Frameworks/Helper --type=gpu-process")
        elif "--type=utility" in command and self.recover:
            self.spawn(APP, f"{BUNDLE}/Contents/Frameworks/Helper --type=utility")
        elif pid == self.agent:
            self.agent = self.spawn(1, "/System/Library/com.apple.WebKit.WebContent")
        elif command.endswith("WebContent"):
            for page in self.pages.values():
                if page["engine"] == "webkit" and page["page_pid"] == pid:
                    page["gone"] = "1"
        elif "__terminal-host" in command:
            for pane in self.panes:
                if pane.get("host_pid") == pid:
                    pane["host_pid"] = self.spawn(self.daemon, command)
        elif pid == self.daemon:
            self.daemon = self.spawn(1, f"{BUNDLE}/Contents/Resources/bin/cmux-tui __daemon")
        elif "cmux-holder" in command:
            for pane in self.panes:
                if pane.get("holder") == pid:
                    pane.update(link="exited", restart_offered=True, status_text="Shell ended")
                    self.procs.pop(pane["shell"], None)
                    self.procs.pop(pane["login"], None)

    # -- the layout
    def focused(self):
        return next(p for p in self.panes if p["focused"])

    def shown(self, tab):
        return any(p["selected_tab"] == tab for p in self.panes)

    def spawn_shell(self, pane):
        """holder -> /usr/bin/login -> -zsh, as holder_spawn.rs runs a shell with the account's HOME: login(1) is
        the PTY child and stays the shell's parent."""
        holder = self.spawn(1, f"/tmp/cmux-holder --owner {BUNDLE_ID}:chaos@{self.daemon}")
        login = self.spawn(holder, "/usr/bin/login -flpq lawrence /bin/bash -c exec -l /bin/zsh")
        pane.update(holder=holder, login=login, shell=self.spawn(login, "-zsh"))

    def add_terminal(self):
        for pane in self.panes:
            pane["focused"] = False
        self.tab_count += 1
        pane = {"kind": "terminal", "selected_tab": f"t{self.tab_count}", "focused": True, "link": "connected",
                "terminal_id": f"term{self.tab_count}", "text": ""}
        if self.holder_model:
            self.spawn_shell(pane)
        else:
            pane["host_pid"] = self.spawn(self.daemon, f"cmux-tui __terminal-host --owner {BUNDLE_ID}:chaos@700")
        self.panes.append(pane)

    def run_line(self, pane, line):
        found = re.fullmatch(r"echo (cmux-chaos-\d+-)\$\(\(6\*7\)\)", line)
        if found and pane["link"] == "connected":
            pane["text"] += f"\n{line}\n{found.group(1)}42"
        found = re.fullmatch(r"echo (cmux-chaos-\d+-)\$\$", line)
        if found and pane["link"] == "connected":
            pane["text"] += f"\n{line}\n{found.group(1)}{pane.get('shell', 4242)}"

    # -- the socket
    def rpc(self, method, params=None, timeout=60):
        params = params or {}
        if method == "system.identify":
            return {"bundle_id": BUNDLE_ID, "tag": "chaos", "pid": APP, "app_bundle_path": BUNDLE,
                    "socket_path": SOCKET, "methods": list(chaos.NEEDED_METHODS)}
        if method == "debug.windows":
            return {"error": {"code": "timeout"}} if self.hang_on_kill and self.killed else {"windows": []}
        if method == "debug.surfaces":
            panes = [{k: v for k, v in p.items() if params.get("text") or k != "text"} for p in self.panes]
            return {"windows": [{"panes": panes}]}
        if method == "debug.daemon":
            return {"pid": self.daemon, "connection": "connected"}
        if method == "debug.agent_pane":
            return self.agent_pane(params.get("pane"))
        if method == "debug.key":
            self.keys += 1
            pane = self.focused()
            key, line = params["key"], self.lines.get(pane["selected_tab"], "")
            if params.get("modifiers") == ["ctrl"]:
                line = ""
            elif key == "return":
                self.run_line(pane, line)
                line = ""
            else:
                line += " " if key == "space" else key
            self.lines[pane["selected_tab"]] = line
            return {}
        if method == "browser.page.eval":
            page = self.pages[params["tab"]]
            if page["gone"] == "1" or page.get("dead_hidden"):
                return {"error": "gone"}
            return {"value": "alive" if "alive" in params["script"] else crash.PAGE_TITLE}
        if method == "debug.browser.page_status":
            page = self.pages[params["tab"]]
            reply = {"gone": page["gone"], "gone_text": "Aw, snap\nThe page crashed\nReload", "page_pid": page["page_pid"]}
            if params.get("press") == "reload" and page["gone"] == "1":
                reply["pressed"] = "1"
                if self.recover:
                    page["gone"] = "0"
                    if page["engine"] == "webkit":
                        page["page_pid"] = self.spawn(1, "/System/Library/com.apple.WebKit.WebContent")
                    else:
                        self.spawn(APP, f"{BUNDLE}/Contents/Frameworks/Helper --type=renderer")
            return reply
        if method == "action.run":
            return self.action(params["action"], params.get("args") or {}, params.get("target"))
        return {"error": {"code": "method_not_found"}}

    def agent_pane(self, pane):
        shown = [p["selected_tab"] for p in self.panes if p["kind"] == "agent"]
        if self.agent_mode == "several":
            shown = ["agent-a", "agent-b"]
        elif self.agent_mode == "open":
            shown = ["agent-pane"]
        if pane:
            return {"pane": pane, "pid": self.agent} if pane in shown else {"error": f"pane {pane} shows no agent tab",
                                                                             "agent_panes": []}
        if self.agent_mode == "open":
            return {"pane": "agent-pane", "pid": self.agent}
        if len(shown) == 1:
            return {"pane": shown[0], "pid": self.agent}
        return {"error": "no focused pane shows an agent tab", "agent_panes": shown}

    def action(self, name, args, target):
        if name in ("newWorkspace", "splitRight", "splitDown"):
            self.add_terminal()
            return {}
        if name == "openBrowser":
            self.tab_count += 1
            tab = f"page{self.tab_count}"
            pane = self.focused()
            pane.update(kind="browser", selected_tab=tab, tabs=pane.get("tabs", []) + [tab])
            pid = 800 if args["engine"] == "webkit" else None
            self.pages[tab] = {"engine": args["engine"], "gone": "0", "page_pid": pid}
            return {"created": [tab]}
        if name == "palette.newAgentChat":
            pane = self.focused()
            pane.update(kind="agent", selected_tab="agent-chat")
            self.agent = self.spawn(1, "/System/Library/com.apple.WebKit.WebContent")
            return {}
        if name == "tab.focus":
            tab = target.removeprefix("tab:")
            for pane in self.panes:
                pane["focused"] = tab in pane.get("tabs", [pane["selected_tab"]])
                if pane["focused"]:
                    pane["selected_tab"] = tab
            if self.pages.get(tab, {}).pop("dead_hidden", None):  # shown again: it reloads in a new renderer
                self.spawn(APP, f"{BUNDLE}/Contents/Frameworks/Helper --type=renderer")
            return {}
        if name == "tab.restart":
            pane = next(p for p in self.panes if p["selected_tab"] == target.removeprefix("tab:"))
            pane.update(link="connected", restart_offered=False, status_text=None)
            self.spawn_shell(pane)
            return {}
        return {"error": f"unknown action {name}"}


def make(app, **kw):
    procs = chaos.AppProcesses(APP, BUNDLE_ID, BUNDLE, read_table=app.table, responsible=app.responsible)
    reports = kw.pop("reports", None)
    return chaos.Chaos(app.rpc, procs, "http://127.0.0.1:1/", kill=app.kill, reports=reports, pre_s=0, post_s=0,
                       report_settle_s=0, ping_every=0.01, key_every=0.005, step_s=5, patience=0.05, **kw)


class RefusalTests(unittest.TestCase):
    IDENTITY = {"bundle_id": BUNDLE_ID, "tag": "chaos", "pid": APP, "app_bundle_path": BUNDLE, "socket_path": SOCKET}

    def command_of(self, pid):
        return f"{BUNDLE}/Contents/MacOS/cmux DEV" if pid == APP else ""

    def test_a_tagged_debug_socket_of_a_tagged_build_passes(self):
        self.assertIsNone(chaos.refusal(SOCKET, self.IDENTITY, self.command_of))
        moved = dict(self.IDENTITY, socket_path=os.path.expanduser("~/.local/state/cmux/cmux-debug-chaos.sock"))
        self.assertIsNone(chaos.refusal(moved["socket_path"], moved, self.command_of))

    def test_refuses_an_untagged_or_release_socket_name(self):
        for path in ("/tmp/cmux.sock", os.path.expanduser("~/.local/state/cmux/cmux.sock"), "/tmp/cmux-nightly.sock",
                     "/tmp/cmux-debug.sock"):
            self.assertIn("not a tagged debug socket", chaos.refusal(path, dict(self.IDENTITY, socket_path=path),
                                                                     self.command_of))

    def test_refuses_a_build_that_is_not_a_tagged_dev_build(self):
        for bundle, tag in (("com.cmuxterm.app", "chaos"), ("com.cmuxterm.app.nightly", ""), (chaos.DEV_BUNDLE, "")):
            why = chaos.refusal(SOCKET, dict(self.IDENTITY, bundle_id=bundle, tag=tag), self.command_of)
            self.assertIn("not a tagged DEV build", why)

    def test_refuses_another_socket_a_missing_pid_or_one_not_from_the_bundle(self):
        self.assertIn("answers for socket", chaos.refusal(SOCKET, dict(self.IDENTITY, socket_path="/tmp/cmux-debug-x.sock"),
                                                          self.command_of))
        self.assertIn("no pid", chaos.refusal(SOCKET, dict(self.IDENTITY, pid=None), self.command_of))
        self.assertIn("does not run from", chaos.refusal(SOCKET, self.IDENTITY, lambda pid: "/Applications/cmux.app/x"))
        self.assertIn("did not answer", chaos.refusal(SOCKET, {"error": "no socket", "unreachable": True}, self.command_of))

    def test_main_refuses_before_any_fault(self):
        err = io.StringIO()
        with contextlib.redirect_stderr(err), contextlib.redirect_stdout(io.StringIO()) as out:
            status = chaos.main(["--socket", "/tmp/cmux.sock"])
        self.assertEqual(status, 2)
        self.assertIn("refusing", err.getvalue())
        self.assertEqual(out.getvalue(), "")


class OwnershipTests(unittest.TestCase):
    def setUp(self):
        self.app = FakeApp()
        self.app.add_terminal()
        self.procs = chaos.AppProcesses(APP, BUNDLE_ID, BUNDLE, read_table=self.app.table,
                                        responsible=self.app.responsible)

    def test_the_apps_processes_are_proved(self):
        host = self.app.panes[-1]["host_pid"]
        for pid in (601, 602, 700, 720, host):
            self.assertTrue(self.procs.proof(pid)[0], pid)
        self.assertTrue(self.procs.proof(800, reported_by_app=True)[0])

    def test_never_the_person_the_app_itself_or_another_apps_webcontent(self):
        for pid, reported in ((PERSON, False), (APP, False), (OTHER_WEBCONTENT, True), (800, False), (4242, False)):
            self.assertFalse(self.procs.proof(pid, reported)[0], pid)

    def test_finds_chromium_children_acpmux_and_holders(self):
        self.assertEqual(self.procs.chromium("renderer"), [601])
        self.assertEqual(self.procs.acpmux(), [720])
        self.assertEqual(self.procs.holders(), [])
        holders = FakeApp(holders=True)
        holders.add_terminal()
        procs = chaos.AppProcesses(APP, BUNDLE_ID, BUNDLE, read_table=holders.table)
        self.assertEqual(procs.holders(), [holders.panes[-1]["holder"]])

    def test_the_holder_of_a_shell_is_found_through_login(self):
        app = FakeApp(holders=True)
        app.add_terminal()
        pane = app.panes[-1]
        procs = chaos.AppProcesses(APP, BUNDLE_ID, BUNDLE, read_table=app.table)
        self.assertEqual(app.procs[pane["shell"]].ppid, pane["login"])
        self.assertEqual(procs.holder_of(pane["shell"]), pane["holder"])
        self.assertIsNone(procs.holder_of(PERSON))
        self.assertIsNone(procs.holder_of(4242))

    def test_acpmux_of_another_build_whose_bundle_id_extends_this_ones_is_not_this_builds(self):
        other = "com.cmuxterm.app.debug.chaos2"
        self.app.procs[730] = Proc(730, 1, f"/Apps/cmux DEV chaos2.app/Contents/Resources/bin/acpmux serve "
                                           f"--state ~/Library/Application Support/{other}/acpmux")
        self.assertEqual(self.procs.acpmux(), [720])
        self.assertFalse(self.procs.proof(730)[0])


class PingVerdictTests(unittest.TestCase):
    def test_p99_within_the_limit_passes(self):
        verdict = chaos.ping_verdict([5.0] * 99 + [240.0], 250)
        self.assertTrue(verdict["main_ping_p99_ok"])
        self.assertEqual(verdict["main_ping_unanswered"], 0)

    def test_p99_over_the_limit_or_an_unanswered_ping_fails(self):
        self.assertFalse(chaos.ping_verdict([5.0] * 90 + [400.0] * 10, 250)["main_ping_p99_ok"])
        verdict = chaos.ping_verdict([5.0] * 200 + [None], 250, bound_ms=10000)
        self.assertFalse(verdict["main_ping_p99_ok"])
        self.assertEqual(verdict["main_ping_unanswered"], 1)
        self.assertEqual(verdict["main_ping_ms"]["max"], 10000)
        self.assertFalse(chaos.ping_verdict([], 250)["main_ping_p99_ok"])

    def test_one_long_stall_among_fast_pings_fails(self):
        # Closed loop, a 3 s stall is one sample in ~270 and p99 stays fast; open loop it is the 30 pings it held up.
        verdict = chaos.ping_verdict([8.0] * 270 + [3000.0], 250, every_ms=100)
        self.assertFalse(verdict["main_ping_p99_ok"])
        self.assertFalse(verdict["main_ping_ok"])
        self.assertEqual(verdict["main_ping_replies"], 271)
        self.assertEqual(verdict["main_ping_ms"]["n"], 271 + 29)
        self.assertGreater(verdict["main_ping_ms"]["p99"], 250)
        stall = chaos.ping_verdict([5.0] * 300 + [4000.0], 250, every_ms=100)
        self.assertFalse(stall["main_ping_ok"])

    def test_a_ping_over_the_hang_bound_fails_even_with_p99_within_the_limit(self):
        verdict = chaos.ping_verdict([5.0] * 2000 + [1500.0], 250, every_ms=100, hang_ms=1000)
        self.assertTrue(verdict["main_ping_p99_ok"])
        self.assertFalse(verdict["main_ping_max_ok"])
        self.assertFalse(verdict["main_ping_ok"])

    def test_open_loop_adds_the_pings_a_slow_reply_held_up(self):
        self.assertEqual(chaos.open_loop([350.0, 5.0], 100), [350.0, 250.0, 150.0, 5.0])
        self.assertEqual(chaos.open_loop([199.0], 100), [199.0])


class RunTests(unittest.TestCase):
    def setUp(self):
        original = crash.alive
        self.addCleanup(lambda: setattr(crash, "alive", original))
        self.app = None
        crash.alive = lambda pid: self.app is not None and pid in self.app.procs
        self.err = contextlib.redirect_stderr(io.StringIO())
        self.err.__enter__()
        self.addCleanup(self.err.__exit__, None, None, None)

    def run_all(self, app, only=(), **kw):
        self.app = app
        run = make(app, **kw)
        self.assertEqual(run.tour(), {})
        faults, ruled_out = run.plan(set(only))
        lines = []
        rows = run.run(faults, lambda row: lines.append(json.dumps(row, default=str)))
        return run, faults, ruled_out, rows, [json.loads(line) for line in lines]

    def test_every_fault_recovers_one_json_line_each(self):
        app = FakeApp()
        run, faults, ruled_out, rows, lines = self.run_all(app)
        self.assertEqual(ruled_out, ["holder"])
        self.assertEqual([line["fault"] for line in lines], faults)
        for line in lines:
            self.assertEqual(line["outcome"], "ok", line)
            self.assertTrue(line["expected"] and isinstance(line["observed"], dict))
            self.assertTrue(line["app_pid_kept"] and line["main_ping_ok"])
            self.assertGreaterEqual(line["main_ping_after_kill"], chaos.PINGS_AFTER_KILL)
            self.assertGreater(line["keys"]["sent"], 0, line["fault"])
        by_fault = {line["fault"]: line["killed"] for line in lines}
        self.assertEqual(by_fault["chromium-renderer"], [601])
        self.assertEqual(by_fault["chromium-gpu"], [602])
        self.assertEqual(by_fault["webkit-webcontent"], [800])
        self.assertEqual(by_fault["agent-webcontent"], [801])
        self.assertEqual(by_fault["acpmux"], [720])
        self.assertEqual(by_fault["daemon"], [700])
        self.assertEqual(len(by_fault["terminal-host"]), 1)
        self.assertNotIn(PERSON, app.killed)
        self.assertEqual(chaos.exit_status(rows, []), 0)

    def test_a_page_that_never_comes_back_fails_its_fault(self):
        _, _, _, rows, lines = self.run_all(FakeApp(recover=False), only={"chromium-renderer", "chromium-gpu"})
        self.assertEqual([line["outcome"] for line in lines], ["FAIL", "FAIL"])
        self.assertFalse(lines[0]["observed"]["reloaded"])
        self.assertEqual(chaos.exit_status(rows, []), 1)

    def test_a_main_thread_that_stops_answering_fails_the_fault(self):
        _, _, _, _, lines = self.run_all(FakeApp(hang_on_kill=True), only={"chromium-renderer"})
        self.assertEqual(lines[0]["outcome"], "FAIL")
        self.assertTrue(lines[0]["observed"]["reloaded"])
        self.assertGreater(lines[0]["main_ping_unanswered"], 0)
        self.assertFalse(lines[0]["main_ping_p99_ok"])
        self.assertFalse(lines[0]["main_ping_ok"])

    def test_a_main_thread_stall_inside_the_fault_fails_it(self):
        app = FakeApp()
        rpc = app.rpc

        def stalling(method, params=None, timeout=60):
            if method == "debug.windows" and app.killed and not app.stalled:
                app.stalled = True
                time.sleep(0.3)  # 30 ping slots of 10 ms
            return rpc(method, params, timeout)

        app.stalled = False
        app.rpc = stalling
        _, _, _, _, lines = self.run_all(app, only={"chromium-gpu"}, ping_hang_ms=100)
        self.assertEqual(lines[0]["outcome"], "FAIL", lines[0])
        self.assertFalse(lines[0]["main_ping_ok"])
        self.assertGreaterEqual(lines[0]["main_ping_ms"]["max"], 250)

    def test_a_main_thread_stall_in_the_faults_setup_is_not_the_kills(self):
        # New Agent Chat's first load stalls the main thread before any kill: the fault's verdict starts at the kill.
        app = FakeApp(agent="none")
        rpc = app.rpc
        app.stall_next_ping = False

        def stalling(method, params=None, timeout=60):
            if method == "action.run" and params.get("action") == "palette.newAgentChat":
                app.stall_next_ping = True
            if method == "debug.windows" and app.stall_next_ping:
                app.stall_next_ping = False
                time.sleep(0.3)  # 30 ping slots of 10 ms, all before the kill
            return rpc(method, params, timeout)

        app.rpc = stalling
        run = make(app, ping_hang_ms=100)
        original_kill = run.kill
        run.kill = lambda *a, **kw: (time.sleep(0.35), original_kill(*a, **kw))  # the setup goes on past the stall
        self.app = app
        self.assertEqual(run.tour(), {})
        lines = run.run(["agent-webcontent"], lambda row: None)
        self.assertEqual(lines[0]["outcome"], "ok", lines[0])
        self.assertTrue(lines[0]["observed"]["opened_chat"])
        self.assertTrue(lines[0]["main_ping_ok"])
        self.assertLess(lines[0]["main_ping_ms"]["max"], 100)

    def test_a_chromium_fault_shows_the_cef_tab_hidden_behind_the_webkit_tab(self):
        # tour() opens webkit last in the pages' pane, so cef is a background tab until the fault selects it.
        app = FakeApp()
        run, _, _, rows, lines = self.run_all(app, only={"chromium-renderer"})
        self.assertEqual(lines[0]["outcome"], "ok", lines[0])
        self.assertTrue(lines[0]["observed"]["crash_page"])
        self.assertTrue(app.shown(run.tabs["cef"]))
        self.assertEqual(app.focused()["selected_tab"], run.tabs["left"])
        # An agent page already open: no New Agent Chat selects cef on the way.
        _, _, _, _, lines = self.run_all(FakeApp(), only={"webkit-webcontent", "agent-webcontent", "chromium-renderer"})
        self.assertEqual([line["outcome"] for line in lines], ["ok", "ok", "ok"], lines)
        self.assertFalse(lines[1]["observed"]["opened_chat"])

    def test_acpmux_of_another_build_with_a_longer_bundle_id_does_not_skip_the_fault(self):
        app = FakeApp()
        app.procs[730] = Proc(730, 1, "/Apps/cmux DEV chaos2.app/Contents/Resources/bin/acpmux serve "
                                      "--state ~/Library/Application Support/com.cmuxterm.app.debug.chaos2/acpmux")
        _, _, _, rows, lines = self.run_all(app, only={"acpmux"})
        self.assertEqual(lines[0]["outcome"], "ok", lines[0])
        self.assertEqual(lines[0]["killed"], [720])
        self.assertNotIn(730, app.killed)

    def test_agent_page_opened_by_new_agent_chat_when_none_shows(self):
        app = FakeApp(agent="none")
        run, _, _, rows, lines = self.run_all(app, only={"agent-webcontent", "acpmux"})
        self.assertEqual([line["outcome"] for line in lines], ["ok", "ok"], lines)
        self.assertTrue(lines[0]["observed"]["opened_chat"])
        self.assertEqual(lines[0]["observed"]["pane"], "agent-chat")
        self.assertEqual(len(lines[0]["killed"]), 1)
        agent = next(p for p in app.panes if p["kind"] == "agent")
        self.assertNotIn(agent["selected_tab"], (run.tabs["left"], run.tabs["right"]))
        self.assertEqual(chaos.exit_status(rows, []), 0)

    def test_several_agent_panes_and_none_focused_asks_the_first(self):
        _, _, _, _, lines = self.run_all(FakeApp(agent="several"), only={"agent-webcontent"})
        self.assertEqual(lines[0]["outcome"], "ok", lines[0])
        self.assertEqual(lines[0]["observed"]["pane"], "agent-a")
        self.assertFalse(lines[0]["observed"]["opened_chat"])
        self.assertEqual(lines[0]["killed"], [801])

    def test_a_utility_process_that_exits_before_its_signal_is_gone_not_a_fail(self):
        app = FakeApp()
        app.procs[599] = Proc(599, APP, f"{BUNDLE}/Contents/Frameworks/Helper --type=utility "
                                        "--utility-sub-type=data_decoder.mojom.DataDecoderService")
        app.exits_before_kill = {599}
        _, _, _, rows, lines = self.run_all(app, only={"chromium-utility"})
        self.assertEqual(lines[0]["outcome"], "ok", lines[0])
        self.assertEqual(lines[0]["gone_before_kill"], [599])
        self.assertEqual(lines[0]["killed"], [603])
        self.assertEqual(chaos.exit_status(rows, []), 0)

    def test_every_utility_process_gone_before_its_signal_skips(self):
        app = FakeApp()
        app.exits_before_kill = {603}
        _, _, _, _, lines = self.run_all(app, only={"chromium-utility"})
        self.assertEqual(lines[0]["outcome"], "skip", lines[0])
        self.assertEqual(lines[0]["killed"], [])
        self.assertEqual(lines[0]["gone_before_kill"], [603])

    def test_a_crash_report_in_the_window_fails_the_fault_once(self):
        _, _, _, _, lines = self.run_all(FakeApp(), only={"chromium-renderer", "chromium-gpu"},
                                         reports=lambda since: ["/x/cmux DEV-2026.ips"])
        self.assertEqual([line["outcome"] for line in lines], ["FAIL", "ok"])
        self.assertEqual(lines[0]["crash_reports"], ["/x/cmux DEV-2026.ips"])

    def test_a_fault_the_app_cannot_offer_skips(self):
        app = FakeApp(acpmux=False)
        _, _, _, rows, lines = self.run_all(app, only={"acpmux", "holder"})
        self.assertEqual([line["outcome"] for line in lines], ["skip", "skip"])
        self.assertEqual(app.killed, [])
        self.assertEqual(chaos.exit_status(rows, []), 3)
        self.assertEqual(chaos.exit_status(rows, ["/late.ips"]), 1)

    def test_holder_kill_ends_its_pane_with_restart_and_spares_the_other_holder(self):
        app = FakeApp(holders=True)
        run, faults, ruled_out, _, lines = self.run_all(app, only={"holder"})
        left, right = (next(p for p in app.panes if p["selected_tab"] == run.tabs[r]) for r in ("left", "right"))
        line = lines[0]
        self.assertEqual(line["outcome"], "ok", line)
        self.assertEqual(line["observed"]["panes"]["left"]["observed"], "ended")
        self.assertTrue(line["observed"]["panes"]["left"]["restarted"])
        self.assertEqual(line["observed"]["panes"]["right"]["observed"], "untouched")
        self.assertIn(right["holder"], line["observed"]["untouched"])
        self.assertEqual(line["observed"]["untouched"], line["observed"]["other_holders"])
        self.assertNotIn(right["holder"], app.killed)
        self.assertEqual(left["link"], "connected")

    def test_holder_model_rules_out_terminal_host_by_default(self):
        app = FakeApp(holders=True)
        self.app = app
        run = make(app)
        self.assertEqual(run.tour(), {})
        faults, ruled_out = run.plan(set())
        self.assertIn("holder", faults)
        self.assertEqual(ruled_out, ["terminal-host"])


class ReportTests(unittest.TestCase):
    def write(self, folder, name, header, body):
        path = os.path.join(folder, name)
        with open(path, "w") as handle:
            handle.write(json.dumps(header) + "\n" + json.dumps(body))
        return path

    def test_only_the_apps_reports_since_the_fault(self):
        with tempfile.TemporaryDirectory() as folder:
            mine = self.write(folder, "cmux DEV-1.ips", {"bundleID": BUNDLE_ID}, {})
            child = self.write(folder, "Helper-1.ips", {}, {"parentPid": APP, "procPath": "/elsewhere/Helper"})
            daemon = self.write(folder, "cmux-tui-1.ips", {}, {"procPath": f"{BUNDLE}/Contents/Resources/bin/cmux-tui"})
            self.write(folder, "cmux-2.ips", {"bundleID": "com.cmuxterm.app"}, {"procPath": "/Applications/cmux.app/x"})
            old = self.write(folder, "cmux DEV-0.ips", {"bundleID": BUNDLE_ID}, {})
            os.utime(old, (1000, 1000))
            found = chaos.app_reports(2000, BUNDLE_ID, BUNDLE, APP, dirs=(folder,))
        self.assertEqual(sorted(found), sorted([mine, child, daemon]))


if __name__ == "__main__":
    unittest.main()
