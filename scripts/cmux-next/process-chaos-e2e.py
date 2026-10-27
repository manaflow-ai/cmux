#!/usr/bin/env python3
"""Process chaos on a running tagged cmux-next build, on bare metal (p10-stability-145).

While keys go into a terminal (`debug.key`, one at a time), each fault SIGKILLs one of the app's processes, one
fault at a time, and checks that fault's own expected outcome (the per-fault outcomes of the VM chaos suite,
scripts/fuzz/macos-matrix/chaos.py, p10-stability-009). A main-thread ping runs on a thread of its own through
every kill and its recovery; its p99 must be <= --ping-p99-ms (250 ms) and no ping may take longer than
--ping-hang-ms (1000 ms). VM timing is not perf evidence: run this on a lab mini, not in a VM.

  webkit-webcontent  a WebKit tab's WebContent: the crash page with Reload; Reload brings the page back in a new
                     WebContent process.
  agent-webcontent   an agent page's WebContent: the page reloads in a new process by itself.
  chromium-renderer  Chromium's renderers: the sad tab with Reload; Reload brings the page back (Chrome's sad tab,
                     chrome/browser/ui/sad_tab.cc).
  chromium-utility   Chromium's utility processes (the network service and the rest): Chromium starts new ones and
                     a reload loads the page (content/browser/network_service_instance_impl.cc restarts it).
  chromium-gpu       Chromium's GPU process: Chromium starts a new one and the page answers, after Reload when it
                     showed the crash page (content/browser/gpu/gpu_process_host.cc).
  terminal-host      one terminal's host: the daemon respawns it (a new host pid, the same terminal id, link
                     connected) and a typed echo runs in it.
  holder             the holder above the left terminal's shell, through login(1) when it runs (an app launched with
                     CMUX_TUI_TERMINAL_HOST_MODEL=holder): the app stays up; each pane of that holder shows the ended
                     state with Restart and Restart brings its shell back, or kept the same shell under a new holder;
                     the other holders run on.
  acpmux             the app's acpmux daemon: the app answers and the terminals keep working.
  daemon             the app's cmux-tui daemon: a new daemon connects, every terminal pane re-attaches and a typed
                     echo runs.

Every fault also needs the app's pid unchanged, every main-thread ping answered with p99 <= the limit, and no crash
report (.ips) of the app's processes written from the fault's start. A fault the app cannot offer (no acpmux, no
holder) is `skip` with the reason: no verdict, never ok. With no agent page open, agent-webcontent opens one (New
Agent Chat, in a pane of its own split from the pages' pane, so the typed terminal never hides it), as the VM suite
does. A proved pid that exits by itself before its signal (a short-lived Chromium utility process) is recorded in
`gone_before_kill` and the fault goes on with the others; only a fault left with no pid to signal stops there.

The main-thread ping is `debug.windows`, a `mainActor`-lane method (CmuxNextControl ControlMethod.swift): its reply
waits for a main-thread turn. `system.ping` reads the last published snapshot and answers while the main thread is
stalled, so it measures the socket, not the main thread. A ping with no answer within --ping-bound-ms counts as that
bound and fails the fault, as Chrome's HangWatcher counts a hung main thread (base/threading/hang_watcher.cc).
The pings go out on a fixed 100 ms clock, and a slow reply also records the pings its wait kept from going out (a
reply of R ms records R, R-100, R-200, ... down to 100: HdrHistogram's recordValueWithExpectedInterval), so a
3 s stall is 30 slow samples, not one among hundreds of fast ones (coordinated omission).

It attaches to an app already running and never launches or quits it. It refuses any socket that is not a tagged
debug socket (`cmux-debug-*.sock`) of a tagged DEV build (`system.identify` bundle `com.cmuxterm.app.debug.<tag>`,
the same socket and a process run from that bundle). Every signal names an exact pid proved to be this app's: a
process of its tree, one run from its bundle, a terminal host or holder that names it as its `--owner`, or a
WebContent the app reports whose responsible process is the app's. It opens one workspace of its own (two
terminals, and a pane with a Chromium and a WebKit tab on a page it serves on 127.0.0.1); each page fault first
selects its page's tab in that pane. Only the pings sent from a kill's start through its recovery count, never the
ones of the fault's setup (opening an agent chat).

Output: one JSON line per kill on stdout (and appended to --out): {"fault", "expected", "observed", "outcome":
"ok"|"FAIL"|"skip", "ok", "killed", "app_pid_kept", "main_ping_ms": {n, p50, p95, p99, max, iqr},
"main_ping_replies", "main_ping_unanswered", "main_ping_after_kill", "main_ping_p99_ok", "main_ping_max_ok",
"main_ping_ok", "gone_before_kill", "keys": {"sent", "failed", "reply_ms"}, "crash_reports", "seconds"}.
Progress goes to stderr. Exit 0 when every fault is ok, 1 on any FAIL (or a crash report no fault saw), 3 when a
fault skipped and none failed, 2 when it refuses the socket.

Without --only it runs every fault but the one the app's terminal model rules out (holders run: no terminal-host;
else no holder). Run `--only holder` against an app launched with CMUX_TUI_TERMINAL_HOST_MODEL=holder.

  process-chaos-e2e.py --socket ~/.local/state/cmux/cmux-debug-<tag>.sock [--only a,b] [--out chaos.jsonl]
      [--ping-p99-ms 250] [--ping-hang-ms 1000]
"""
from __future__ import annotations

import argparse
import json
import os
import re
import signal
import sys
import threading
import time
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import bench_launch  # noqa: E402

crash = bench_launch.load_by_path("child_crash_e2e", os.path.join(HERE, "child-crash-e2e.py"))
perf_stats = crash.perf_stats

FAULTS = {  # in run order, the least disruptive first; the daemon last
    "webkit-webcontent": "app stays up; the WebKit tab shows the crash page with Reload; Reload brings it back in a "
                         "new WebContent process",
    "agent-webcontent": "app stays up; the agent page reloads in a new WebContent process by itself",
    "chromium-renderer": "app stays up; the Chromium tab shows the crash page with Reload; Reload brings it back",
    "chromium-utility": "app stays up; Chromium restarts its utility processes; a reload loads the page",
    "chromium-gpu": "app stays up; Chromium starts a new GPU process; the page answers (after Reload if it crashed)",
    "terminal-host": "app answers; the daemon respawns the terminal (new host pid, same terminal id, link connected) "
                     "and a typed echo runs in it",
    "holder": "app up; each pane of the killed holder shows the ended state with Restart and Restart brings its shell "
              "back, or kept the same shell under a new holder; other holders and shells untouched",
    "acpmux": "app answers; terminals keep working (a typed echo runs)",
    "daemon": "app answers; a new daemon connects; every terminal pane re-attaches and a typed echo runs",
}
DEV_BUNDLE = "com.cmuxterm.app.debug"
TAGGED_SOCKET = re.compile(r"^cmux-debug-[\w.-]+\.sock$")
NEEDED_METHODS = ("debug.key", "debug.surfaces", "debug.windows", "debug.daemon", "debug.browser.page_status",
                  "browser.page.eval", "action.run")
MAIN_PING = "debug.windows"
PING_P99_MS = 250
PING_BOUND_MS = 10000
PING_HANG_MS = 1000  # the longest one main-thread ping may take in a fault
PING_EVERY = 0.1  # s between main-thread pings
PINGS_AFTER_KILL = 5  # the fewest main-thread pings sent after a kill, however fast the recovery
KEY_EVERY = 0.05  # s between typed keys
CLEAR_EVERY = 40  # typed keys between Ctrl-U, so the typed line never runs or grows
STEP_S = 60  # s a step of the layout may take
REPORT_DIRS = ("~/Library/Logs/DiagnosticReports", "/Library/Logs/DiagnosticReports")
REPORT_SETTLE_S = 5.0  # ReportCrash writes a report seconds after a death
LATE_REPORT_S = 20.0  # the last look for a report written late
OK, FAIL, SKIP = "ok", "FAIL", "skip"


class Skip(Exception):
    """The app cannot offer this fault; the reason is the row's observed `why`."""


def log(text):
    print(text, file=sys.stderr, flush=True)


# ---------------------------------------------------------------- the socket (pure; tests feed replies)
def refusal(socket_path, identity, command_of):
    """None when `socket_path` is a tagged debug socket of a running tagged DEV build, else why not.

    `identity` is the app's `system.identify` reply; `command_of(pid)` the command line of a pid ("" when it does
    not run)."""
    if not TAGGED_SOCKET.match(os.path.basename(socket_path)):
        return f"{socket_path} is not a tagged debug socket (cmux-debug-<tag>.sock)"
    if not isinstance(identity, dict) or "error" in identity:
        return f"system.identify did not answer: {json.dumps(identity)[:200]}"
    bundle, tag = identity.get("bundle_id") or "", identity.get("tag") or ""
    if not (bundle.startswith(DEV_BUNDLE + ".") or (bundle == DEV_BUNDLE and tag)):
        return f"the app is {bundle or 'no bundle'!r} (tag {tag or 'none'}), not a tagged DEV build ({DEV_BUNDLE}.<tag>)"
    reported = identity.get("socket_path") or ""
    if not reported or os.path.realpath(reported) != os.path.realpath(socket_path):
        return f"the app answers for socket {reported or 'none'!r}, not {socket_path}"
    pid, path = identity.get("pid"), (identity.get("app_bundle_path") or "").rstrip("/")
    if not isinstance(pid, int) or pid <= 1 or not path.endswith(".app"):
        return f"the app reports no pid or bundle path (pid {pid!r}, bundle {path!r})"
    if not command_of(pid).startswith(path + "/"):
        return f"pid {pid} does not run from {path}"
    return None


def missing_methods(identity):
    methods = set(identity.get("methods") or [])
    return [m for m in NEEDED_METHODS if m not in methods]


def open_loop(replies, every_ms):
    """The samples of pings due every `every_ms`: each reply, and for a reply of R ms the pings it kept from going
    out, R-every, R-2*every, ... while >= every (HdrHistogram recordValueWithExpectedInterval)."""
    samples = []
    for reply in replies:
        samples.append(reply)
        missed = reply - every_ms
        while every_ms > 0 and missed >= every_ms:
            samples.append(missed)
            missed -= every_ms
    return samples


def ping_verdict(replies, limit_ms, bound_ms=PING_BOUND_MS, every_ms=PING_EVERY * 1000, hang_ms=PING_HANG_MS):
    """The main-thread pings of one fault: `replies` are ms, or None for a ping with no answer within the bound
    (counted as the bound). The statistics are open-loop (open_loop). ok needs at least one ping, every one
    answered, p99 <= `limit_ms` and the slowest <= `hang_ms`."""
    values = [bound_ms if r is None else r for r in replies]
    stats = perf_stats.summary(open_loop(values, every_ms))
    unanswered = sum(1 for r in replies if r is None)
    p99_ok = stats["n"] > 0 and unanswered == 0 and stats["p99"] <= limit_ms
    max_ok = stats["n"] > 0 and stats["max"] <= hang_ms
    return {"main_ping_ms": stats, "main_ping_replies": len(replies), "main_ping_unanswered": unanswered,
            "main_ping_p99_ok": p99_ok, "main_ping_max_ok": max_ok, "main_ping_ok": p99_ok and max_ok}


def report_owner(header, body, bundle_id, bundle_path, app_pid):
    """How a crash report (.ips header and body) is the app's: its bundle, a process run from its bundle, or a
    child of the app. None when it is not."""
    if header.get("bundleID") == bundle_id:
        return "bundle"
    if str(body.get("procPath") or "").startswith(bundle_path + "/"):
        return "process from the bundle"
    if body.get("parentPid") == app_pid:
        return "child of the app"
    return None


def app_reports(since, bundle_id, bundle_path, app_pid, dirs=REPORT_DIRS):
    """Paths of the app's crash reports written at or after `since` (epoch s)."""
    found = []
    for folder in dirs:
        folder = os.path.expanduser(folder)
        try:
            names = sorted(os.listdir(folder))
        except OSError:
            continue
        for name in names:
            path = os.path.join(folder, name)
            try:
                if not name.endswith(".ips") or os.path.getmtime(path) < since:
                    continue
                with open(path, encoding="utf-8", errors="replace") as handle:
                    header = json.loads(handle.readline() or "{}")
                    body = json.loads(handle.read() or "{}")
            except (OSError, ValueError):
                continue
            if report_owner(header, body, bundle_id, bundle_path, app_pid):
                found.append(path)
    return found


# ---------------------------------------------------------------- the app's processes
def owner_names(bundle_id, bundle_path):
    """The `--owner <name>:` names a terminal host or holder of this build carries: its bundle id, or the .app's
    name with every character but [A-Za-z0-9._-] made `_` (cmux-tui host_session.rs host_owner_args)."""
    name = re.sub(r"[^A-Za-z0-9._-]", "_", os.path.basename(bundle_path.rstrip("/")).removesuffix(".app"))
    return [n for n in (bundle_id, name) if n]


class AppProcesses:
    """Finds the app's processes and proves a pid is the app's before anything signals it. `read_table` and
    `responsible` are seams (tests)."""

    def __init__(self, app_pid, bundle_id, bundle_path, read_table=crash.read_ps, responsible=crash.responsible_pid):
        self.app_pid, self.bundle_id, self.bundle_path = app_pid, bundle_id, bundle_path.rstrip("/")
        self.read_table = read_table
        self.webcontent = crash.Ownership(app_pid, read_table, responsible)
        self.owners = owner_names(bundle_id, self.bundle_path)

    def owned_command(self, command):
        return command.startswith(self.bundle_path + "/") or any(f"--owner {o}:" in command for o in self.owners)

    def proof(self, pid, reported_by_app=False):
        """(True, how) when `pid` is the app's, else (False, why)."""
        if not isinstance(pid, int) or pid <= 1 or pid in (self.app_pid, os.getpid()):
            return False, f"pid {pid!r} is not a child process of the app"
        table = self.read_table()
        if pid in crash.descendants(table, self.app_pid):
            return True, "in the app's process tree"
        proc = table.get(pid)
        if proc is None:
            return False, f"pid {pid} does not run"
        if self.owned_command(proc.command):
            return True, "runs from the app's bundle or names it as its owner"
        return self.webcontent.proof(pid, reported_by_app)

    def chromium(self, kind):
        return crash.chromium_children(self.read_table(), self.app_pid, kind)

    def acpmux(self):
        """The build's acpmux daemons, by the rule proof() signals on: in the app's tree, run from its bundle or
        naming it as its --owner."""
        table = self.read_table()
        tree = crash.descendants(table, self.app_pid)
        return sorted(p.pid for p in table.values() if re.search(r"/acpmux(\s|$)", p.command)
                      and (p.pid in tree or self.owned_command(p.command)))

    def holders(self, table=None):
        """The build's terminal holders: the standalone holder (argv0 `cmux-holder`) or the one built into
        cmux-tui-host (a `__holder` argument), that names this build as its owner or runs from its bundle. A path
        can hold spaces (`cmux DEV <tag>.app`), so names are matched, never split out of the command line."""
        return sorted(p.pid for p in (table or self.read_table()).values()
                      if re.search(r"(^|/)cmux-holder(\s|$)|\s__holder(\s|$)", p.command)
                      and self.owned_command(p.command))

    def holder_of(self, pid):
        """The holder above `pid` in the process tree, or None. The shell is not always the holder's child: with the
        account's HOME the PTY child is login(1), which stays the shell's parent (cmux-tui holder_spawn.rs and
        login_shell.rs wrap)."""
        table = self.read_table()
        holders, seen = set(self.holders(table)), set()
        while pid in table and pid not in seen:
            if pid in holders:
                return pid
            seen.add(pid)
            pid = table[pid].ppid
        return None

    def running(self, pid):
        return pid in self.read_table()


# ---------------------------------------------------------------- background loops
class Loop:
    """Runs `step()` on a fixed clock of `every` s on a thread of its own, at least once, until stopped; keeps the
    results and when each step started. A step that overruns its slot skips the slots it covered (the next step
    starts on the next slot), so the clock never drifts with the replies."""

    def __init__(self, step, every, name):
        self.step, self.every = step, every
        self.results, self.starts, self.done = [], [], threading.Event()
        self.thread = threading.Thread(target=self._run, name=name, daemon=True)

    def _run(self):
        start = time.monotonic()
        while True:
            self.starts.append(time.monotonic())
            self.results.append(self.step())
            elapsed = time.monotonic() - start
            slot = (int(elapsed / self.every) + 1) * self.every if self.every > 0 else elapsed
            if self.done.wait(slot - elapsed):
                return

    def start(self):
        self.thread.start()
        return self

    def stop(self, join_s, since=None):
        """The results of the steps started at or after `since` (time.monotonic(); all of them when None); the step
        still running past `join_s` adds a None (no answer)."""
        self.done.set()
        self.thread.join(join_s)
        results = list(self.results) + ([None] if self.thread.is_alive() else [])
        return [r for began, r in zip(self.starts, results) if since is None or began >= since]


class Typist:
    """Keys into the focused terminal, one at a time (`debug.key`, timestamped when sent, as a real key's wait in
    the event queue), with Ctrl-U every CLEAR_EVERY keys, so the line never runs or grows."""

    LETTERS = "abcdefghijklmnopqrstuvwxyz"

    def __init__(self, rpc, every):
        self.rpc, self.sent = rpc, 0
        self.loop = Loop(self._key, every, "chaos-typist")

    def _key(self):
        self.sent += 1
        if self.sent % CLEAR_EVERY == 0:
            params = {"key": "u", "modifiers": ["ctrl"]}
        else:
            params = {"key": self.LETTERS[self.sent % len(self.LETTERS)], "timestamp": crash.uptime()}
        began = time.monotonic()
        reply = self.rpc("debug.key", params, timeout=10)
        failed = isinstance(reply, dict) and "error" in reply
        return None if failed else round((time.monotonic() - began) * 1000, 1)

    def __enter__(self):
        self.loop.start()
        return self

    def __exit__(self, *exc):
        self.samples = self.loop.stop(15)

    def summary(self):
        samples = getattr(self, "samples", [])
        return {"sent": len(samples), "failed": sum(1 for s in samples if s is None),
                "reply_ms": perf_stats.summary([s for s in samples if s is not None])}


# ---------------------------------------------------------------- the run
class Chaos:
    """The faults on one running app. `rpc(method, params, timeout)` is its socket; `procs` an AppProcesses; `kill`
    sends SIGKILL to one pid; `reports(since)` lists the app's crash reports. The waits are parameters so tests run
    them at once."""

    def __init__(self, rpc, procs, url, *, kill=None, reports=None, ping_limit_ms=PING_P99_MS,
                 ping_bound_ms=PING_BOUND_MS, ping_hang_ms=PING_HANG_MS, ping_every=PING_EVERY, key_every=KEY_EVERY,
                 pre_s=0.5, post_s=1.0, report_settle_s=REPORT_SETTLE_S, step_s=STEP_S, patience=1.0):
        self.rpc, self.procs, self.url = rpc, procs, url
        self.kill_pid = kill or (lambda pid: os.kill(pid, signal.SIGKILL))
        self.reports = reports or (lambda since: [])
        self.ping_limit_ms, self.ping_bound_ms, self.ping_hang_ms = ping_limit_ms, ping_bound_ms, ping_hang_ms
        self.ping_every, self.key_every = ping_every, key_every
        self.pre_s, self.post_s, self.report_settle_s, self.step_s = pre_s, post_s, report_settle_s, step_s
        self.patience = patience  # scales every recovery wait (tests)
        self.pinger = self.typist = None
        self.pings_at_kill = None  # the pinger's count when the first kill was sent
        self.window_start = None  # time.monotonic() when the first kill() began: pings sent before it are setup's
        self.tabs = {}  # role -> tab id: left, right (terminals), cef, webkit (pages)
        self.marker = 0
        self.killed, self.gone = [], []  # this fault's signalled pids; proved pids that exited before their signal
        self.seen_reports = set()

    # -- app reads and input
    def call(self, method, params=None, timeout=40):
        reply = self.rpc(method, params or {}, timeout=timeout)
        return reply if isinstance(reply, dict) else {"value": reply}

    def action(self, name, args=None, target=None, focus=True, wait_for=None):
        params = {"action": name, "focus": focus, "confirm": True, "origin": "script"}
        if args:
            params["args"] = args
        if target:
            params["target"] = target
        if wait_for is not None:
            params["wait"] = wait_for
        return self.call("action.run", params, timeout=self.step_s)

    def wait(self, check, seconds):
        return crash.wait(check, seconds * self.patience, 0.1)

    def panes(self, text=False):
        reply = self.call("debug.surfaces", {"text": True} if text else {})
        return [p for w in reply.get("windows") or [] for p in w.get("panes") or []]

    def pane_of(self, tab, text=False):
        return next((p for p in self.panes(text) if p.get("selected_tab") == tab), {})

    def focused_terminal(self):
        return next((p.get("selected_tab") for p in self.panes() if p.get("kind") == "terminal" and p.get("focused")),
                    None)

    def focus(self, tab):
        return self.action("tab.focus", target="tab:" + tab)

    def js(self, tab, script):
        reply = self.call("browser.page.eval", {"tab": tab, "script": script})
        return None if "error" in reply else reply.get("value")

    def page_status(self, tab, press=None):
        return self.call("debug.browser.page_status", {"tab": tab, **({"press": press} if press else {})})

    def answers(self, tab):
        return self.js(tab, "document.getElementById('alive')?.textContent") == "alive"

    def key(self, key, modifiers=None):
        return self.call("debug.key", {"key": key, **({"modifiers": modifiers} if modifiers else {})}, timeout=10)

    def keys(self, text):
        for ch in text:
            self.key("space" if ch == " " else "return" if ch == "\n" else ch)

    def typed(self, role, words, output):
        """A fresh line (Ctrl-C drops what the typist left) runs `echo cmux-chaos-N-<words>` in the `role` terminal;
        the match of `cmux-chaos-N-<output>` in what it shows (the output line, never the typed command)."""
        tab = self.tabs.get(role)
        if not tab:
            return None
        self.marker += 1
        self.focus(tab)
        self.key("c", ["ctrl"])
        self.keys(f"echo cmux-chaos-{self.marker}-{words}\n")
        expected = re.compile(f"cmux-chaos-{self.marker}-{output}(?:\\s|$)")
        return self.wait(lambda: expected.search(self.pane_of(tab, text=True).get("text") or ""), 30)

    def echo(self, role):
        return self.typed(role, "$((6*7))", "42") is not None

    def shell_ids(self, role):
        """The `role` terminal's shell pid, as the shell reports it, and the holder above it (None when none is)."""
        found = self.typed(role, "$$", r"(\d+)")
        return (int(found.group(1)), self.procs.holder_of(int(found.group(1)))) if found else None

    # -- the layout: a workspace of its own
    def split(self, action, existing):
        before = len(self.panes())
        self.action(action)
        return self.wait(lambda: len(self.panes()) > before and (
            lambda t: t if t and t not in existing else None)(self.focused_terminal()), self.step_s)

    def open_page(self, engine):
        reply = self.action("openBrowser", {"url": f"{self.url}?{engine}", "engine": engine})
        tab = (reply.get("created") or [None])[0]
        return tab if tab and self.wait(lambda: self.js(tab, "document.title") == crash.PAGE_TITLE, self.step_s) else None

    def tour(self):
        """Two terminals side by side and, below them, a pane with a Chromium and a WebKit tab on the served page;
        what failed. openBrowser opens in the focused pane, so the pages get a pane of their own."""
        problems = {}
        known = {p.get("selected_tab") for p in self.panes()}
        self.action("newWorkspace", wait_for=True)
        left = self.wait(lambda: (lambda t: t if t and t not in known else None)(self.focused_terminal()), self.step_s)
        if not left:
            return {"terminal": "newWorkspace made no focused terminal"}
        self.tabs["left"] = left
        right = self.split("splitRight", known | {left})
        if right:
            self.tabs["right"] = right
        else:
            problems["split"] = "splitRight made no second terminal"
        web = self.split("splitDown", known | {left, right})
        if not web:
            problems["web_pane"] = "splitDown made no pane for the pages"
        for engine in ("cef", "webkit"):
            tab = self.open_page(engine)
            if tab:
                self.tabs[engine] = tab
            else:
                problems[engine] = "the page did not load"
        if not self.echo("left"):
            problems["echo"] = "a typed echo did not run before any fault"
        return problems

    # -- one fault
    def typing(self):
        """Keys into the left terminal while the block runs (the kill and its recovery)."""
        if self.tabs.get("left"):
            self.focus(self.tabs["left"])
        self.typist = Typist(self.rpc, self.key_every)
        return self.typist

    def kill(self, pids, reported_by_app=False):
        """SIGKILL each of `pids` once proved the app's; a FAIL (RuntimeError) on one the app reported that the proof
        refuses, a Skip on one it found itself. A pid it found itself that exited by itself before its proof, or any
        proved pid that exited before its signal, goes to `gone`; the others are still signalled. With none left to
        signal: a FAIL when the app reported the pid, else a Skip."""
        if self.window_start is None:
            self.window_start = time.monotonic()
        proved = []
        for pid in pids:
            owned, why = self.procs.proof(pid, reported_by_app)
            if owned:
                proved.append(pid)
            elif not reported_by_app and not self.procs.running(pid):
                self.gone.append(pid)
            elif reported_by_app:
                raise RuntimeError(f"the pid the app reports is not proved the app's: {why}")
            else:
                raise Skip(f"refused to signal {pid}: {why}")
        time.sleep(self.pre_s)  # test harness: keys before the kill are the window's baseline
        if self.typist:  # the kill lands while keys go in
            crash.wait(lambda: self.typist.loop.results, 10, 0.01)
        if self.pings_at_kill is None and self.pinger:
            self.pings_at_kill = len(self.pinger.results)
        for pid in proved:
            try:
                self.kill_pid(pid)
            except ProcessLookupError:
                self.gone.append(pid)
                continue
            self.killed.append(pid)
        if self.gone:
            log(f"exited by itself before its signal: {', '.join(map(str, self.gone))}")
        if not self.killed:
            why = f"every pid exited by itself before its signal ({', '.join(map(str, pids))})"
            if reported_by_app:
                raise RuntimeError(why)
            raise Skip(why)
        log(f"killed {', '.join(map(str, self.killed))}")

    def ping(self):
        began = time.monotonic()
        reply = self.call(MAIN_PING, timeout=self.ping_bound_ms / 1000)
        ms = round((time.monotonic() - began) * 1000, 1)
        return None if "error" in reply or ms >= self.ping_bound_ms else ms

    def run_fault(self, name):
        row = {"fault": name, "expected": FAULTS[name]}
        started, clock = time.time(), time.monotonic()
        self.killed, self.gone, self.typist, self.pings_at_kill, self.window_start = [], [], None, None, None
        pinger = self.pinger = Loop(self.ping, self.ping_every, "chaos-pinger").start()
        try:
            try:
                ok, observed = getattr(self, "fault_" + name.replace("-", "_"))()
                time.sleep(self.post_s)  # test harness: pings after the recovery
                if self.pings_at_kill is not None:  # pings through the kill, however fast the recovery was
                    crash.wait(lambda: len(pinger.results) >= self.pings_at_kill + PINGS_AFTER_KILL,
                               PINGS_AFTER_KILL * (self.ping_every + self.ping_bound_ms / 1000), 0.01)
            finally:
                # The pings sent from the kill's baseline through its recovery: a stall of the fault's setup (a new
                # agent chat's first load) is not the kill's.
                pings = pinger.stop(self.ping_bound_ms / 1000 + 5, since=self.window_start)
            verdict = ping_verdict(pings, self.ping_limit_ms, self.ping_bound_ms, self.ping_every * 1000,
                                   self.ping_hang_ms)
            verdict["main_ping_after_kill"] = len(pinger.results) - (self.pings_at_kill or 0)
            kept = crash.alive(self.procs.app_pid)
            time.sleep(self.report_settle_s)  # test harness: ReportCrash writes seconds after a death
            reports = [r for r in self.reports(started - 1) if r not in self.seen_reports]
            self.seen_reports.update(reports)
            good = ok and kept and verdict["main_ping_ok"] and not reports
            row.update(observed=observed, outcome=OK if good else FAIL, app_pid_kept=kept, crash_reports=reports,
                       **verdict)
        except Skip as why:
            row.update(observed={"why": str(why)}, outcome=SKIP)
        except Exception as error:  # a runner error is this fault's FAIL, never the end of the run
            row.update(observed={"error": repr(error), "trace": traceback.format_exc()[-1500:]}, outcome=FAIL,
                       app_pid_kept=crash.alive(self.procs.app_pid))
        row["ok"] = row["outcome"] == OK
        row["killed"] = list(self.killed)
        row["gone_before_kill"] = list(self.gone)
        row["keys"] = self.typist.summary() if self.typist else None
        row["seconds"] = round(time.monotonic() - clock, 1)
        return row

    # -- the faults: each returns (ok, observed) or raises Skip
    def sad_tab_reloads(self, tab):
        gone = self.wait(lambda: (lambda s: s if s.get("gone") == "1" else None)(self.page_status(tab)), 20)
        lines = ((gone or {}).get("gone_text") or "").split("\n")
        shown = bool(gone) and len(lines) == 3 and lines[2] != ""
        pressed = bool(gone) and self.page_status(tab, press="reload").get("pressed") == "1"
        back = pressed and self.wait(lambda: self.page_status(tab).get("gone") == "0" and self.answers(tab), 30)
        return {"crash_page": shown, "crash_text": lines, "reloaded": bool(back)}

    def page(self, role):
        """The `role` page's tab, made the selected tab of its pane: the cef and webkit tabs share a pane, and a
        hidden crashed tab only reloads when shown (CEFTab+Processes.swift showProcessExit), so the fault checks
        what the person sees. typing() then focuses the left terminal; the page stays selected in its own pane."""
        tab = self.tabs.get(role)
        if not tab:
            raise RuntimeError(f"the layout has no {role} tab")
        self.focus(tab)
        if not self.wait(lambda: self.pane_of(tab), self.step_s):
            raise RuntimeError(f"tab.focus did not select the {role} tab in its pane")
        return tab

    def fault_webkit_webcontent(self):
        tab = self.page("webkit")
        page = self.wait(lambda: self.page_status(tab).get("page_pid"), 20)
        if not page:
            return False, {"why": "the WebKit tab reports no WebContent pid", "status": self.page_status(tab)}
        with self.typing():
            self.kill([int(page)], reported_by_app=True)
            seen = self.sad_tab_reloads(tab)
        fresh = self.page_status(tab).get("page_pid")
        return seen["crash_page"] and seen["reloaded"] and bool(fresh) and fresh != page, {"new_page_pid": fresh, **seen}

    def agent_pid(self, pane=None):
        """(pane, WebContent pid) of the agent page shown in `pane`, or else in the focused pane or the only pane
        that shows one; with several and none focused the reply names them and no pid, so ask the first."""
        reply = self.call("debug.agent_pane", {"action": "pid", **({"pane": pane} if pane else {})})
        found = reply.get("pane") or ((reply.get("agent_panes") or [None])[0])
        if not reply.get("pid") and found and not pane:
            return self.agent_pid(found)
        return found, reply.get("pid")

    def open_agent_chat(self):
        """New Agent Chat in a pane of its own, split from the pages' pane: the typist focuses the left terminal,
        and an agent tab in that pane would be hidden then (debug.agent_pane reports only a shown agent tab)."""
        page_tab = self.tabs.get("cef") or self.tabs.get("webkit")
        if page_tab:
            self.focus(page_tab)
        known = {p.get("selected_tab") for p in self.panes()}
        if not self.split("splitRight", known):
            raise RuntimeError("splitRight made no pane for the agent chat")
        self.action("palette.newAgentChat")
        return self.wait(lambda: (lambda found: found if found[1] else None)(self.agent_pid()), 60)

    def fault_agent_webcontent(self):
        pane, page = self.agent_pid()
        opened = not page
        if opened:
            pane, page = self.open_agent_chat() or (None, None)
        if not page:
            raise Skip("no agent page reports a WebContent pid (debug.agent_pane), even after New Agent Chat")
        with self.typing():
            self.kill([int(page)], reported_by_app=True)
            fresh = self.wait(lambda: (lambda p: p if p and p != page else None)(self.agent_pid(pane)[1]), 30)
        return bool(fresh), {"pane": pane, "opened_chat": opened, "new_pid": fresh}

    def fault_chromium_renderer(self):
        tab = self.page("cef")
        renderers = self.procs.chromium("renderer")
        if not renderers:
            return False, {"why": "the app has no Chromium renderer"}
        with self.typing():
            self.kill(renderers)
            seen = self.sad_tab_reloads(tab)
        return seen["crash_page"] and seen["reloaded"], seen

    def fault_chromium_utility(self):
        tab = self.page("cef")
        utilities = self.procs.chromium("utility")
        if not utilities:
            return False, {"why": "Chromium runs no utility process"}
        with self.typing():
            self.kill(utilities)
            fresh = self.wait(lambda: sorted(set(self.procs.chromium("utility")) - set(utilities)), 30)
        seen = self.sad_tab_reloads(tab) if self.page_status(tab).get("gone") == "1" else {}
        self.js(tab, "document.title = 'reloading'; location.reload(); 1")
        loaded = self.wait(lambda: self.js(tab, "document.title") == crash.PAGE_TITLE, 60)
        return bool(fresh) and bool(loaded) and seen.get("reloaded", True), {
            "new_utility": fresh, "crash_page": seen, "reloaded": bool(loaded)}

    def fault_chromium_gpu(self):
        tab = self.page("cef")
        gpus = self.procs.chromium("gpu-process")
        if not gpus:
            return False, {"why": "Chromium runs no GPU process"}
        with self.typing():
            self.kill(gpus)
            fresh = self.wait(lambda: sorted(set(self.procs.chromium("gpu-process")) - set(gpus)), 30)
        seen = self.sad_tab_reloads(tab) if self.page_status(tab).get("gone") == "1" else {}
        answers = self.wait(lambda: self.answers(tab), 30)
        return bool(fresh) and bool(answers) and seen.get("reloaded", True), {
            "new_gpu": fresh, "crash_page": seen, "page_answers": bool(answers)}

    def fault_terminal_host(self):
        role = "right" if self.tabs.get("right") else "left"
        tab = self.tabs.get(role)
        pane = self.pane_of(tab) if tab else {}
        host, terminal = pane.get("host_pid"), pane.get("terminal_id")
        if not host:
            raise Skip("the terminal reports no host pid (an in-daemon PTY or a holder terminal)")
        with self.typing():
            self.kill([int(host)], reported_by_app=True)
            back = self.wait(lambda: (lambda p: p if p.get("host_pid") not in (None, host)
                                      and p.get("link") == "connected" else None)(self.pane_of(tab)), 60)
        echoed = bool(back) and self.echo(role)
        after = back or self.pane_of(tab)
        return bool(back) and after.get("terminal_id") == terminal and echoed, {
            "terminal_id": terminal, "after": {k: after.get(k) for k in ("host_pid", "terminal_id", "link")},
            "echo": echoed}

    def fault_holder(self):
        holders = self.procs.holders()
        if not holders:
            raise Skip("no terminal holder runs (launch the app with CMUX_TUI_TERMINAL_HOST_MODEL=holder)")
        roles = [role for role in ("left", "right") if self.tabs.get(role)]
        shells = {role: self.shell_ids(role) for role in roles}  # (shell pid, the holder above it)
        if not (shells.get("left") and shells["left"][1] in holders):
            raise Skip(f"no holder is above the left terminal's shell (shell and holder {shells.get('left')}, "
                       f"holders {holders})")
        victim = shells["left"][1]
        others = [pid for pid in holders if pid != victim]
        with self.typing():
            self.kill([victim])
            settled = {role: self.holder_settled(role, shells[role], victim, holders) for role in roles}
        panes = {role: self.after_holder_kill(role, shells[role], victim, settled[role]) for role in roles}
        untouched = [pid for pid in others if self.procs.running(pid)]
        ok = all(p["echo"] and p["observed"] in ("ended", "kept", "untouched") for p in panes.values()) \
            and untouched == others
        return ok, {"shells_before": shells, "other_holders": others, "untouched": untouched, "panes": panes}

    def holder_settled(self, role, before, victim, holders):
        """The `role` pane once the daemon reports its shell ended or a new holder adopted it; {} for a pane of
        another holder, or when neither came."""
        if not before or before[1] != victim:
            return {}
        tab = self.tabs[role]
        return self.wait(lambda: (lambda p, new: {**p, "new_holders": new} if p.get("link") == "exited"
                                  or (p.get("link") == "connected" and new) else None)(
            self.pane_of(tab), sorted(set(self.procs.holders()) - set(holders))), 30) or {}

    def after_holder_kill(self, role, before, victim, settled):
        """What the `role` terminal shows after the holder was killed."""
        tab = self.tabs[role]
        if not before or before[1] != victim:
            now = self.shell_ids(role)  # another holder's terminal keeps its shell
            return {"observed": "untouched" if before and now == before else f"shell {before} -> {now}",
                    "echo": now is not None}
        if settled.get("link") == "exited":
            # What the person sees: the banner and "Restart Shell Here", whose action is tab.restart.
            overlay = self.wait(lambda: (lambda p: p if p.get("restart_offered") and p.get("status_text") else None)(
                self.pane_of(tab)), 10) or self.pane_of(tab)
            seen = {"status_text": overlay.get("status_text"), "restart_offered": overlay.get("restart_offered")}
            if not (overlay.get("restart_offered") and overlay.get("status_text")):
                return {"observed": "ended without the Restart overlay", **seen, "echo": False}
            self.action("tab.restart", target="tab:" + tab)
            back = self.wait(lambda: self.pane_of(tab).get("link") == "connected", 60)
            return {"observed": "ended", **seen, "restarted": bool(back), "echo": bool(back) and self.echo(role)}
        if settled.get("link") == "connected":
            now = self.shell_ids(role)  # the same shell, its master now held by the new holder
            kept = now is not None and now[0] == before[0]
            return {"observed": "kept" if kept else f"shell {before[0]} -> {now}",
                    "new_holders": settled["new_holders"], "echo": now is not None}
        return {"observed": f"link {self.pane_of(tab).get('link')} and no new holder", "echo": False}

    def fault_acpmux(self):
        pids = self.procs.acpmux()
        if not pids:
            raise Skip("the app runs no acpmux daemon")
        with self.typing():
            self.kill(pids)
        echoed = self.echo("left")
        return echoed, {"echo": echoed, "agent_page_pid_after": self.agent_pid()[1]}

    def fault_daemon(self):
        before = self.call("debug.daemon")
        old = before.get("pid")
        if not old:
            return False, {"why": "debug.daemon names no connected daemon", "daemon": before}
        with self.typing():
            self.kill([int(old)], reported_by_app=True)
            back = self.wait(lambda: (lambda d: d if d.get("connection") == "connected"
                                      and d.get("pid") not in (None, old) else None)(self.call("debug.daemon")), 90)
        panes = {role: bool(self.wait(lambda t=self.tabs[role]: self.pane_of(t).get("link") == "connected", 60))
                 for role in ("left", "right") if self.tabs.get(role)}
        echoed = bool(back) and self.echo("left")
        return bool(back) and all(panes.values()) and echoed, {
            "new_pid": (back or {}).get("pid"), "connection": (back or self.call("debug.daemon")).get("connection"),
            "panes_connected": panes, "echo": echoed}

    # -- every fault
    def plan(self, only):
        """The faults to run: `only`, or every fault but the one the app's terminal model rules out."""
        if only:
            return [f for f in FAULTS if f in only], []
        ruled_out = "terminal-host" if self.procs.holders() else "holder"
        return [f for f in FAULTS if f != ruled_out], [ruled_out]

    def run(self, faults, emit):
        rows = []
        for name in faults:
            if not crash.alive(self.procs.app_pid):
                row = {"fault": name, "expected": FAULTS[name], "outcome": FAIL, "ok": False,
                       "observed": {"why": "the app was gone before this fault (see the one before)"}, "killed": []}
            else:
                row = self.run_fault(name)
            log(f"{name:18} {row['outcome']} {json.dumps(row.get('observed'))[:300]}")
            emit(row)
            rows.append(row)
        return rows


def exit_status(rows, late_reports):
    if late_reports or any(r["outcome"] == FAIL for r in rows):
        return 1
    if any(r["outcome"] == SKIP for r in rows):
        return 3
    return 0


def command_of(pid):
    proc = crash.read_ps().get(pid)
    return proc.command if proc else ""


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--socket", required=True, help="the tagged build's debug socket (cmux-debug-<tag>.sock)")
    parser.add_argument("--only", default="", help=f"faults, comma separated: {', '.join(FAULTS)}")
    parser.add_argument("--out", help="also append each JSON line to this file")
    parser.add_argument("--ping-p99-ms", type=float, default=PING_P99_MS)
    parser.add_argument("--ping-bound-ms", type=float, default=PING_BOUND_MS)
    parser.add_argument("--ping-hang-ms", type=float, default=PING_HANG_MS)
    opts = parser.parse_args(argv)
    only = [f for f in opts.only.split(",") if f]
    unknown = [f for f in only if f not in FAULTS]
    if unknown:
        parser.error(f"unknown fault {', '.join(unknown)}; faults: {', '.join(FAULTS)}")

    rpc = lambda method, params=None, timeout=60: bench_launch.rpc_at(opts.socket, method, params, timeout)  # noqa: E731
    identity = rpc("system.identify", timeout=10)
    why = refusal(opts.socket, identity, command_of)
    if why is None and missing_methods(identity):
        why = f"the app lacks {', '.join(missing_methods(identity))}: chaos needs a DEV build"
    if why:
        log(f"refusing: {why}")
        return 2
    app_pid, bundle_id, bundle_path = identity["pid"], identity["bundle_id"], identity["app_bundle_path"].rstrip("/")
    procs = AppProcesses(app_pid, bundle_id, bundle_path)
    server, url = crash.serve()
    reports = lambda since: app_reports(since, bundle_id, bundle_path, app_pid)  # noqa: E731
    chaos = Chaos(rpc, procs, url, reports=reports, ping_limit_ms=opts.ping_p99_ms, ping_bound_ms=opts.ping_bound_ms,
                  ping_hang_ms=opts.ping_hang_ms)
    began = time.time()
    log(f"app pid {app_pid} ({bundle_id}), page {url}")
    out = open(opts.out, "a") if opts.out else None

    def emit(row):
        line = json.dumps(row, default=str)
        print(line, flush=True)
        if out:
            out.write(line + "\n")
            out.flush()

    try:
        problems = chaos.tour()
        if problems:
            log(f"layout: {json.dumps(problems)}")
        if "terminal" in problems:
            log("refusing to inject: the layout has no terminal to type into")
            return 1
        faults, ruled_out = chaos.plan(only)
        for name in ruled_out:
            log(f"not run: {name} (the app's terminal model rules it out; run --only {name} on an app that has it)")
        rows = chaos.run(faults, emit)
        time.sleep(LATE_REPORT_S)  # test harness: the last look for a crash report written late
        late = [r for r in app_reports(began - 1, bundle_id, bundle_path, app_pid) if r not in chaos.seen_reports]
        for path in late:
            log(f"FAIL crash report no fault saw: {path}")
    finally:
        server.shutdown()
        if out:
            out.close()
    status = exit_status(rows, late)
    log({0: "PASS every fault is contained", 1: "FAIL", 3: "INCOMPLETE: a fault skipped"}[status])
    return status


if __name__ == "__main__":
    sys.exit(main())
