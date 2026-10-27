#!/usr/bin/env python3
"""Process and system chaos on one cmux-next DEV build inside a macOS VM, driven from the VM host.

vm.sh runs it per major (`--suite chaos`) with the same guest, VNC and app arguments as smoke.py and
fuzz.py, and reuses their guest connection: app calls go through the guest's bundled `cmux app call`
over SSH, faults are guest commands over the same SSH connection, screenshots are VNC frames.

During a typing and split tour (two terminal panes, and a third pane with a Chromium and a WebKit tab
on a page served in the guest), each fault runs on its own and has its own expected outcome. Keys are typed into a terminal
right before and right after every kill; the checked echo comes after recovery.

  terminal-host      SIGKILL one terminal's host process: the daemon respawns that terminal (a new
                     host on the same terminal id, link connected) and a typed echo runs in it.
  chromium-renderer  SIGKILL Chromium's renderers: the tab shows the crash page with Reload, and Reload
                     brings the page back (Chromium's sad tab, content/browser/renderer_host).
  chromium-gpu       SIGKILL Chromium's GPU process: Chromium starts a new one and the page answers
                     (after Reload when it showed the crash page).
  chromium-utility   SIGKILL Chromium's utility processes (network service and the rest): the page
                     loads again (a reload of the page served in the guest).
  webkit-webcontent  SIGKILL a WebKit tab's WebContent: the crash page with Reload, and Reload brings the
                     page back in a new WebContent process.
  agent-webcontent   SIGKILL an agent page's WebContent: the page reloads in a new process by itself.
  acpmux             SIGKILL the app's acpmux daemon: the app answers and the terminals keep working.
  daemon             SIGKILL the app's cmux-tui daemon: a new daemon connects (debug.daemon), every
                     terminal pane re-attaches and a typed echo runs.
  memory-pressure    `memory_pressure -S -l critical` for 15 s (skip when the level never reads
                     critical): the app answers, terminals work.
  network-off        pf drops every packet but loopback and the driving SSH for at most 45 s: the app
                     answers, terminals work, a page that cannot load shows a load error (the cmux
                     error page or Chromium's, not the crash page), the page served in the guest
                     still answers.
  holder             (relaunch with CMUX_TUI_TERMINAL_HOST_MODEL=holder) SIGKILL the holder whose child
                     is the left terminal's shell (`cmux-holder`, or `__holder` in cmux-tui-host): the
                     app stays up, each pane of that holder either shows the ended state with "Restart
                     Shell Here" (debug.surfaces status_text, restart_offered) and Restart (tab.restart,
                     the button's action) brings its shell back, or kept the same shell while a new
                     holder runs (it adopted the masters the daemon holds: pty-holder design); other
                     holders and their shells are untouched.
  fd-limit           (relaunch under `ulimit -n 256`, hard and soft, so the app cannot raise it) 12
                     workspaces and 8 pages: the app stays up, refuses what does not fit with an
                     error, and a typed echo runs.
  full-disk          (relaunch with HOME on a 512 MB sparse image, then the image filled) a new
                     workspace, a split and Settings while the home volume is full (skip when dd left
                     1 MB or more): the app stays up, nothing refuses, and a typed echo runs in the
                     new workspace; it keeps working after the space is freed.

The quit storm (phase `quit`) presses Cmd-Q as real keys over VNC while something is in flight, then
relaunches. A quit sheet, whenever it shows before the exit, is answered by a second Cmd-Q (its default,
QuitAlert.answerDefault), and only when that leaves it open (or debug.quit cannot say) by `debug.quit`
pressing its default button. Each needs: the app exits with status 0 within 30 s of the first Cmd-Q and
not by its hard quit deadline (QuitDeadline logs the app.quit fault "quit still running" and then exits 0:
that fault between the first Cmd-Q and the exit fails it), every Chromium child it had (`--type=`) ends
within 10 s of the exit, and a relaunch answers a ping and passes the tour (two terminals, the pages, a
typed echo). Any crash report of a cmux, daemon or acpmux process in the window (the quit through the
relaunch's tour) fails it.

  quit-page-load     Cmd-Q while a Chromium and a WebKit tab load from a guest server that accepts and
                     never answers.
  quit-typing        Cmd-Q in the middle of a line typed into a terminal; the rest of it typed after.
  quit-daemon-restart Cmd-Q right after a SIGKILL of the cmux-tui daemon, while the app reconnects.
  quit-split-animation Cmd-Q right after Cmd-D, while the new split animates (skip when neither the app
                     at the quit nor the relaunch's restored layout has the new pane).

Every fault also needs: the app's pid unchanged, every main-thread ping answered within 10 s (one a
second on a thread of its own while the fault and its recovery run, three after; their times are
recorded "VM, not comparable"), and no crash report (.ips) of a cmux process whose crash time (the
report's captureTime, in the guest's clock like every window) is in the fault's window. A crash in a
launch, a tour or a quit is no fault's and fails the run. A fault the guest cannot inject (no
passwordless sudo, no holder process, a level or a full volume that never came) is `skip` with the
reason, which is no verdict for the run: never a PASS. A quit fault has no pings while the app is down
(its three come from the relaunched app), and its `app_pid_kept` is about the relaunched pid.

result.json: {"suite": "chaos", "os", "build", "faults": [{"fault", "phase", "expected", "outcome":
"ok"|"FAIL"|"skip", "ok", "detail", "seconds", "window", "app_pid_kept", "ping_ms_vm", "crash_reports"}],
"segments", "crashes", "crashes_outside_faults", "failed_steps", "skipped", "ok"}.

Usage (vm.sh does this): chaos.py --ssh admin@IP --vnc HOST:PORT:PW --app APP --out DIR [--faults a,b]
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import re
import shlex
import sys
import threading
import time
import traceback

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fuzz import Guest, report_kind  # noqa: E402
import smoke  # noqa: E402  (smoke.RFB for a VNC reconnect: the class tests replace)
from smoke import LAUNCH_DEADLINE, PERL_HTTP, STEP_DEADLINE, Smoke  # noqa: E402

TITLE = "cmux-chaos-page"
PAGE_PORT = 8739
EXIT_FILE = "/tmp/cmux-chaos-app-exit"
PING_BOUND_MS = 10000  # an unanswered or longer ping is a hung app
PING_EVERY = 1.0  # s between the background pings that run through a fault
PRESSURE_CRITICAL = "4"  # kern.memorystatus_vm_pressure_level while memory_pressure holds critical
FULL_FREE_KB = 1024  # a home volume with less free space than this is full
REPORT_DEADLINE = 30  # s: ReportCrash writes a report up to ~20 s after a death
NETWORK_OFF_SECONDS = 45  # the guest turns pf off again by itself after this, whatever the host does
PRESSURE_SECONDS = 15
HOME_IMAGE = "/tmp/cmux-chaos-home.sparseimage"
HOME_MOUNT = "/tmp/cmux-chaos-home"
BASE_ENV = "CMUX_NEXT_SOCKET_MODE=automation"
PF_ANCHOR = "com.apple/cmux-chaos"  # /etc/pf.conf evaluates every com.apple/* anchor
QUIT_EXIT_DEADLINE = 30  # s from the first Cmd-Q to the exit: the app's hard quit deadline is 15 s (QuitDeadline)
QUIT_ASK_WAIT = 3  # s for the quit sheet to close after the second Cmd-Q before debug.quit presses its default
QUIT_POLL = 0.25  # s between looks at the exit and the quit sheet
CHILD_EXIT_DEADLINE = 10  # s after the app's exit for its Chromium children to end
TARPIT_PORT = 8740
TARPIT_PID = "/tmp/cmux-chaos-tarpit.pid"
# Accepts every connection and never answers, so a page that loads from it is still loading at the quit.
PERL_TARPIT = ("my $s = IO::Socket::INET->new(LocalPort => shift, Listen => 64, ReuseAddr => 1) or die $!;"
               " my @held; while (my $c = $s->accept) { push @held, $c }")
QUIT_EXPECTED = ("the app exits 0 within 30 s (a quit sheet answered by a second Cmd-Q), not by its hard quit "
                 "deadline; its Chromium children end; a relaunch tours and a typed echo runs; no crash report")
# The app.quit fault QuitDeadline logs right before its forced exit, which is status 0 too.
FORCED_QUIT_LINE = "quit still running"
PF_RULES = ("pass quick on lo0 all\n"
            "pass in quick proto tcp from any to any port 22 flags any keep state\n"
            "pass out quick proto tcp from any port 22 to any flags any keep state\n"
            "block drop quick all\n")

# Each fault: its phase (one app launch each), what it must show, and its method.
FAULTS = {
    "terminal-host": ("app", "app answers; the daemon respawns the terminal (new host pid, same terminal id, "
                             "link connected) and a typed echo runs in it"),
    "chromium-renderer": ("app", "app stays up; the Chromium tab shows the crash page with Reload; Reload brings it back"),
    "chromium-gpu": ("app", "app stays up; Chromium starts a new GPU process; the page answers (after Reload if it crashed)"),
    "chromium-utility": ("app", "app stays up; Chromium restarts its utility processes; a reload loads the page"),
    "webkit-webcontent": ("app", "app stays up; the WebKit tab shows the crash page with Reload; Reload brings it back "
                                 "in a new WebContent process"),
    "agent-webcontent": ("app", "app stays up; the agent page reloads in a new WebContent process by itself"),
    "acpmux": ("app", "app answers; terminals keep working (a typed echo runs)"),
    "daemon": ("app", "app answers; a new daemon connects; every terminal pane re-attaches and a typed echo runs"),
    "memory-pressure": ("app", "app answers through critical memory pressure; a typed echo runs"),
    "network-off": ("app", "app answers with the network off; a typed echo runs; a page that cannot load shows a load "
                           "error, not the crash page; the guest-served page still answers"),
    "holder": ("holder", "app up; each pane of the killed holder shows the ended state with Restart and Restart brings "
                         "its shell back, or kept the same shell under a new holder; other holders and shells untouched"),
    "fd-limit": ("fd-limit", "app stays up under RLIMIT_NOFILE 256 with 12 workspaces and 8 pages (or refuses the "
                             "rest with an error); a typed echo runs"),
    "full-disk": ("full-disk", "app stays up with its home volume full: a new workspace, a split and Settings, none "
                               "refused; a typed echo runs in the new workspace; it still answers after the space is freed"),
    "quit-page-load": ("quit", "Cmd-Q while a Chromium and a WebKit page load: " + QUIT_EXPECTED),
    "quit-typing": ("quit", "Cmd-Q in the middle of keys typed into a terminal: " + QUIT_EXPECTED),
    "quit-daemon-restart": ("quit", "Cmd-Q right after the daemon is SIGKILLed: " + QUIT_EXPECTED),
    "quit-split-animation": ("quit", "Cmd-Q right after Cmd-D, while the split animates (skip when the split never "
                                     "came): " + QUIT_EXPECTED),
}
PHASES = {  # phase: (extra environment, shell prelude) of its launch
    "app": ("", ""),
    "holder": ("CMUX_TUI_TERMINAL_HOST_MODEL=holder", ""),
    "fd-limit": ("", "ulimit -Sn 256 && ulimit -Hn 256 &&"),
    "full-disk": (f"HOME={HOME_MOUNT} CFFIXED_USER_HOME={HOME_MOUNT}", ""),
    "quit": ("", ""),
}


class Skip(Exception):
    """The guest cannot inject this fault; the reason is the row's detail."""


class Pinger:
    """Main-thread pings through a fault, on a thread of their own (each ping is its own SSH session over
    the guest's control connection), so a hang while a process is down or recovering is seen."""

    def __init__(self, g: Guest):
        self.g = g
        self.samples: list[int | None] = []
        self.done = threading.Event()
        self.thread = threading.Thread(target=self.loop, name="chaos-pinger", daemon=True)

    def loop(self) -> None:
        while True:  # at least one ping, however short the fault
            self.samples.append(self.g.ping_ms(PING_BOUND_MS / 1000))
            if self.done.wait(PING_EVERY):
                return

    def start(self) -> None:
        self.thread.start()

    def stop(self) -> list[int | None]:
        """Ends the pings after the one in flight; a ping still unanswered past its bound is a hang."""
        self.done.set()
        self.thread.join(PING_BOUND_MS / 1000 + 20)
        return list(self.samples) + ([PING_BOUND_MS] if self.thread.is_alive() else [])


class Chaos(Smoke):
    def __init__(self, g: Guest, vnc_arg: str, out: str):
        super().__init__(g, vnc_arg, out)
        self.result = {"suite": "chaos", "faults": [], "findings": []}
        self.app_pid: int | None = None
        self.bundle_id = ""
        self.tabs: dict[str, str] = {}  # role -> layout tab id
        self.marker = 0

    # --- the app ------------------------------------------------------------------------------
    def launch(self, phase: str) -> bool:
        """Start the app for `phase` (its environment and shell prelude); wait for a ping."""
        g = self.g
        env, prelude = PHASES[phase]
        g.env = f"{BASE_ENV} {env}".strip()
        plist = g.sh(f"/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' -c 'Print :CFBundleIdentifier' "
                     f"{shlex.quote(g.app + '/Contents/Info.plist')}").stdout.split("\n")
        g.binary = f"{g.app}/Contents/MacOS/{plist[0].strip()}"
        self.bundle_id = plist[1].strip() if len(plist) > 1 else ""
        g.sh(f"rm -f {EXIT_FILE}")
        g.sh(f"( trap '' HUP; export {g.env}; {prelude} {shlex.quote(g.binary)} >>/tmp/cmux-fuzz-app.log 2>&1 </dev/null; "
             f"echo $? >{EXIT_FILE} ) & disown; true")
        end = time.time() + LAUNCH_DEADLINE
        while time.time() < end:
            g.socket = g.sh("ls -t /tmp/cmux-*.sock 2>/dev/null | head -1").stdout.strip()
            ms = g.ping_ms(3) if g.socket else None
            if ms is not None and ms < 3000:
                g.sh(f"open -a {shlex.quote(g.app)}")
                self.app_pid = g.pid()
                return self.app_pid is not None
            time.sleep(2)
        return False

    def quit(self) -> None:
        """quitEndEverything, then end whatever of the build still runs (terminal hosts name their owner)."""
        g = self.g
        if g.pid() is not None:
            self.call("action.run", {"action": "quitEndEverything"}, timeout=20)
            end = time.time() + 30
            while g.sh(f"test -e {EXIT_FILE}").returncode != 0 and time.time() < end:
                time.sleep(0.5)
        patterns = [g.app + "/Contents/"] + ([f"--owner {self.bundle_id}:"] if self.bundle_id else [])
        g.sh("; ".join(f"pkill -9 -f -- {shlex.quote(p)}" for p in patterns) + "; sleep 1; true")
        self.app_pid = None

    def tour(self) -> dict:
        """Two terminal panes, and a third pane with a Chromium and a WebKit tab on a page served in the
        guest; returns what failed.

        A pane reports a terminal's link, text and host only for its selected tab, and openBrowser opens
        in the focused pane, so the pages get a pane of their own and `left` and `right` stay selected.
        """
        self.tabs = {}  # a role the tour does not set is missing, never the last phase's tab
        problems = {}
        if not self.wait(self.windows, 30):
            problems["window"] = "no window"
        self.call("action.run", {"action": "newTab", "focus": True, "wait": True})
        left = self.wait(self.focused_terminal, STEP_DEADLINE)
        if not left:
            problems["terminal"] = "newTab made no focused terminal"
            return problems
        self.tabs["left"] = left
        right = self.split("splitRight", {left})
        if right:
            self.tabs["right"] = right
        else:
            problems["split"] = "splitRight made no second terminal"
        web = self.split("splitDown", {left, right} - {None})
        if web:
            self.tabs["web"] = web
        else:
            problems["web_pane"] = "splitDown made no pane for the pages"
        self.g.sh(f"mkdir -p /tmp/cmux-chaos-www && printf '<!doctype html><title>{TITLE}</title><p id=alive>alive</p>' "
                  "> /tmp/cmux-chaos-www/index.html && cd /tmp/cmux-chaos-www && "
                  f"( trap '' HUP; exec /usr/bin/perl -MIO::Socket::INET -e '{PERL_HTTP}' {PAGE_PORT} "
                  ">/tmp/cmux-chaos-www.log 2>&1 </dev/null ) & echo $! >/tmp/cmux-chaos-www.pid; disown; true")
        for engine in ("cef", "webkit"):
            tab = self.open_page(engine, f"http://127.0.0.1:{PAGE_PORT}/?{engine}")
            if tab:
                self.tabs[engine] = tab
            else:
                problems[engine] = "the page did not load"
        covered = [role for role in ("left", "right") if self.tabs.get(role) and not self.pane_of(self.tabs[role])]
        if covered:
            problems["layout"] = f"a page took the selected tab of the {', '.join(covered)} terminal pane"
        if not self.echo("left"):
            problems["echo"] = "a typed echo did not run"
        return problems

    def split(self, action: str, existing: set) -> str | None:
        """Runs a split from the focused pane; the new pane's terminal tab, focused."""
        before = self.panes()
        self.call("action.run", {"action": action, "focus": True})
        return self.wait(lambda: self.panes() > before and (lambda t: t if t and t not in existing else None)(
            self.focused_terminal()), 30)

    # --- app reads and input --------------------------------------------------------------------
    def surfaces(self, text: bool = False) -> list[dict]:
        reply = self.call("debug.surfaces", {"text": True} if text else {})
        return [p for w in reply.get("windows") or [] for p in w.get("panes") or []]

    def focused_terminal(self) -> str | None:
        return next((p.get("selected_tab") for p in self.surfaces() if p.get("kind") == "terminal" and p.get("focused")), None)

    def pane_of(self, tab: str, text: bool = False) -> dict:
        return next((p for p in self.surfaces(text) if p.get("selected_tab") == tab), {})

    def open_page(self, engine: str, url: str) -> str | None:
        reply = self.call("action.run", {"action": "openBrowser", "args": {"url": url, "engine": engine}, "focus": True},
                          timeout=STEP_DEADLINE)
        created = reply.get("created") or []
        tab = created[0] if created else None
        if tab and self.wait(lambda: self.js(tab, "document.title") == TITLE, STEP_DEADLINE):
            return tab
        return None

    def js(self, tab: str, script: str):
        reply = self.call("browser.page.eval", {"tab": tab, "script": script})
        return None if "error" in reply else reply.get("value")

    def page_status(self, tab: str, press: str | None = None) -> dict:
        return self.call("debug.browser.page_status", {"tab": tab, **({"press": press} if press else {})})

    def focus(self, tab: str) -> dict:
        return self.call("action.run", {"action": "tab.focus", "target": "tab:" + tab, "focus": True})

    def keys(self, text: str) -> None:
        """Types `text` (and Return for a trailing newline) into the focused view: one guest round trip."""
        keys = [{"key": "space" if ch == " " else "return" if ch == "\n" else ch} for ch in text]
        self.g.sh("; ".join(self.g._cli(["app", "call", "debug.key", json.dumps(k)]) for k in keys) + "; true", timeout=90)

    def typed(self, role: str, words: str, output: str) -> re.Match | None:
        """A fresh line (Ctrl-C drops what an outage left half typed) runs `echo cmux-chaos-N-<words>` in the
        `role` terminal; the match of `cmux-chaos-N-<output>` in what the terminal shows."""
        tab = self.tabs.get(role)
        if not tab:
            return None
        self.marker += 1
        self.focus(tab)
        self.g.sh(self.g._cli(["app", "call", "debug.key", json.dumps({"key": "c", "modifiers": ["ctrl"]})]))
        self.keys(f"echo cmux-chaos-{self.marker}-{words}\n")
        expected = re.compile(f"cmux-chaos-{self.marker}-{output}")  # the output line, never the typed command
        return self.wait(lambda: expected.search(self.pane_of(tab, text=True).get("text") or ""), 30)

    def echo(self, role: str) -> bool:
        return self.typed(role, "$((6*7))", "42") is not None

    def shell_ids(self, role: str) -> tuple[int, int] | None:
        """The `role` terminal's shell pid and its parent's (its holder or host), as the shell reports them."""
        found = self.typed(role, "$$-$(ps -o ppid= -p $$)", r"(\d+)-\s*(\d+)")
        return (int(found.group(1)), int(found.group(2))) if found else None

    def type_around(self, inject) -> None:
        """Half a line typed right before the fault and the rest right after: input during the fault."""
        if self.tabs.get("left"):
            self.focus(self.tabs["left"])
            self.keys("echo during")
        inject()
        self.keys("-chaos\n")

    # --- the guest's processes ------------------------------------------------------------------
    def procs(self) -> list[tuple[int, int, str]]:
        out = self.g.sh("ps -Ao pid=,ppid=,command=").stdout
        rows = []
        for line in out.splitlines():
            parts = line.split(None, 2)
            if len(parts) == 3 and parts[0].isdigit() and parts[1].isdigit():
                rows.append((int(parts[0]), int(parts[1]), parts[2]))
        return rows

    def owned(self, args: str) -> bool:
        """Run from the build's bundle, or a terminal host or holder that names the build as its owner:
        `--owner <bundle>:<tag>@<daemon pid>`, the bundle being CMUX_BUNDLE_ID or else the .app's name with
        every character but [A-Za-z0-9._-] made `_` (host_session.rs host_owner_args)."""
        if args.startswith(self.g.app + "/"):
            return True
        app_name = re.sub(r"[^A-Za-z0-9._-]", "_", os.path.basename(self.g.app.rstrip("/")).removesuffix(".app"))
        return any(f"--owner {owner}:" in args for owner in (self.bundle_id, app_name) if owner)

    def holders(self) -> list[int]:
        """The build's terminal holders: the standalone holder (argv0 `cmux-holder`, which the daemon spawns
        from a copy outside the bundle) or the holder built into cmux-tui-host (a `__holder` argument)."""
        return [pid for pid, _, args in self.procs()
                if (os.path.basename(args.split()[0]) == "cmux-holder" or "__holder" in args.split()) and self.owned(args)]

    def children(self, kind: str) -> list[int]:
        """The app's Chromium children started with --type=<kind>."""
        return [pid for pid, ppid, args in self.procs() if ppid == self.app_pid and f"--type={kind}" in args]

    def kill(self, pids) -> None:
        self.g.sh("kill -9 " + " ".join(str(int(p)) for p in pids) + " 2>/dev/null; true")

    def sudo(self) -> None:
        if self.g.sh("sudo -n true").returncode != 0:
            raise Skip("no passwordless sudo in the guest")

    def reports_since(self, since: float) -> list[tuple[float, str]]:
        """(mtime, path) of crash, hang and Jetsam reports of cmux processes written after `since`."""
        perl = ("for my $d (glob('~/Library/Logs/DiagnosticReports'), '/Library/Logs/DiagnosticReports') {"
                " for my $p (glob(\"$d/*\")) { my ($n) = $p =~ m{([^/]+)$};"
                " next unless $n =~ /cmux|acpmux|optchat/ || $n =~ /\\.hang$/ || $n =~ /^JetsamEvent/;"
                " my $m = (stat $p)[9]; print \"$m $p\\n\" if $m > $ARGV[0] } }")
        found = []
        for line in self.g.sh(f"/usr/bin/perl -e {shlex.quote(perl)} {since}").stdout.splitlines():
            mtime, _, path = line.partition(" ")
            if path and mtime.isdigit():
                found.append((float(mtime), path))
        return found

    # --- one fault ------------------------------------------------------------------------------
    def guest_time(self) -> float:
        """The guest's clock: crash reports carry its times, so every window is in it too."""
        out = self.g.sh("date +%s").stdout.strip()
        if out.isdigit():
            return float(out)
        self.result["findings"].append({"kind": "guest-clock-unread", "reply": out[-200:]})
        return time.time()

    def run_fault(self, name: str, phase: str) -> dict:
        row = {"fault": name, "phase": phase, "expected": FAULTS[name][1]}
        started, clock = self.guest_time(), time.time()
        # A quit fault ends the app on purpose: its pings come from the relaunched app, after it.
        pinger = None if phase == "quit" else Pinger(self.g)
        try:
            if pinger:
                pinger.start()
            try:
                ok, detail = getattr(self, "fault_" + name.replace("-", "_"))()
            finally:
                during = pinger.stop() if pinger else []
            pings = during + [self.g.ping_ms(PING_BOUND_MS / 1000) for _ in range(3)]
            answered = all(ms is not None and ms < PING_BOUND_MS for ms in pings)
            kept = self.app_pid is not None and self.g.pid() == self.app_pid
            row.update(outcome="ok" if ok and answered and kept else "FAIL", detail=detail,
                       app_pid_kept=kept, ping_ms_vm=pings, pings_during_fault=len(during))
        except Skip as why:
            row.update(outcome="skip", detail=str(why))
        except Exception as error:  # a runner error is that fault's FAIL, never the end of the run
            row.update(outcome="FAIL", detail={"error": repr(error), "trace": traceback.format_exc()[-1500:]})
        row["crash_reports"] = []  # finish() files each report under the fault whose window holds its crash
        row["ok"] = row["outcome"] == "ok"
        print("%-18s %s %s" % (name, row["outcome"], json.dumps(row.get("detail"))[:400]), flush=True)
        try:
            self.shot("fault-" + name)
        except Exception as error:  # a screenshot is evidence, never the verdict
            self.result["findings"].append({"kind": "screenshot-failed", "fault": name, "error": str(error)})
        row["seconds"] = round(time.time() - clock, 1)
        row["window"] = [started, self.guest_time()]
        return row

    # --- the faults (each returns ok and its evidence) ------------------------------------------
    def fault_terminal_host(self):
        tab = self.tabs.get("right") or self.tabs.get("left")
        pane = self.pane_of(tab) if tab else {}
        host, terminal = pane.get("host_pid"), pane.get("terminal_id")
        if not host:
            raise Skip("the terminal reports no host pid (an in-daemon PTY or a holder terminal)")
        self.type_around(lambda: self.kill([host]))
        role = "right" if tab == self.tabs.get("right") else "left"
        back = self.wait(lambda: (lambda p: p if p.get("host_pid") not in (None, host) and p.get("link") == "connected"
                                  else None)(self.pane_of(tab)), 60)
        echoed = bool(back) and self.echo(role)
        return bool(back) and (back or {}).get("terminal_id") == terminal and echoed, {
            "killed_host": host, "terminal_id": terminal, "after": {k: (back or self.pane_of(tab)).get(k)
                                                                    for k in ("host_pid", "terminal_id", "link")},
            "echo": echoed}

    def sad_tab_reloads(self, tab: str) -> dict:
        gone = self.wait(lambda: (lambda s: s if s.get("gone") == "1" else None)(self.page_status(tab)), 20)
        lines = ((gone or {}).get("gone_text") or "").split("\n")
        shown = bool(gone) and len(lines) == 3 and lines[2] != ""
        pressed = bool(gone) and self.page_status(tab, press="reload").get("pressed") == "1"
        back = pressed and self.wait(lambda: self.page_status(tab).get("gone") == "0"
                                     and self.js(tab, "document.getElementById('alive')?.textContent") == "alive", 30)
        return {"crash_page": shown, "crash_text": lines, "reloaded": bool(back)}

    def fault_chromium_renderer(self):
        tab = self.tabs.get("cef") or self.missing("cef")
        renderers = self.children("renderer")
        if not renderers:
            return False, {"renderers": [], "why": "the app has no Chromium renderer child"}
        self.type_around(lambda: self.kill(renderers))
        seen = self.sad_tab_reloads(tab)
        return seen["crash_page"] and seen["reloaded"], {"killed": renderers, **seen}

    def fault_chromium_gpu(self):
        tab = self.tabs.get("cef") or self.missing("cef")
        gpus = self.children("gpu-process")
        if not gpus:
            return False, {"why": "Chromium runs no GPU process"}
        self.type_around(lambda: self.kill(gpus))
        fresh = self.wait(lambda: sorted(set(self.children("gpu-process")) - set(gpus)), 30)
        seen = self.sad_tab_reloads(tab) if self.page_status(tab).get("gone") == "1" else {}
        answers = self.wait(lambda: self.js(tab, "document.getElementById('alive')?.textContent") == "alive", 30)
        return bool(fresh) and bool(answers) and seen.get("reloaded", True), {
            "killed": gpus, "new_gpu": fresh, "crash_page": seen, "page_answers": bool(answers)}

    def fault_chromium_utility(self):
        tab = self.tabs.get("cef") or self.missing("cef")
        utilities = self.children("utility")
        if not utilities:
            return False, {"why": "Chromium runs no utility process"}
        self.type_around(lambda: self.kill(utilities))
        fresh = self.wait(lambda: sorted(set(self.children("utility")) - set(utilities)), 30)
        seen = self.sad_tab_reloads(tab) if self.page_status(tab).get("gone") == "1" else {}
        self.js(tab, "document.title = 'reloading'; location.reload(); 1")
        loaded = self.wait(lambda: self.js(tab, "document.title") == TITLE, 60)
        return bool(fresh) and bool(loaded) and seen.get("reloaded", True), {
            "killed": utilities, "new_utility": fresh, "crash_page": seen, "reloaded": bool(loaded)}

    def fault_webkit_webcontent(self):
        tab = self.tabs.get("webkit") or self.missing("webkit")
        page = self.wait(lambda: self.page_status(tab).get("page_pid"), 20)
        if not page:
            return False, {"why": "the WebKit tab reports no WebContent pid", "status": self.page_status(tab)}
        self.type_around(lambda: self.kill([page]))
        seen = self.sad_tab_reloads(tab)
        fresh = self.page_status(tab).get("page_pid")
        return seen["crash_page"] and seen["reloaded"] and bool(fresh) and fresh != page, {
            "killed": page, "new_page_pid": fresh, **seen}

    def agent_pid(self, pane: str | None = None):
        reply = self.call("debug.agent_pane", {"action": "pid", **({"pane": pane} if pane else {})})
        return reply.get("pane") or ((reply.get("agent_panes") or [None])[0]), reply.get("pid")

    def fault_agent_webcontent(self):
        pane, page = self.agent_pid()
        if not page:
            self.call("action.run", {"action": "palette.newAgentChat", "focus": True})
            found = self.wait(lambda: (lambda r: r if r[1] else None)(self.agent_pid()), 60)
            pane, page = found or (None, None)
        if not page:
            raise Skip("no agent page reports a WebContent pid (debug.agent_pane), even after New Agent Chat")
        self.type_around(lambda: self.kill([int(page)]))
        fresh = self.wait(lambda: (lambda p: p if p and p != page else None)(self.agent_pid(pane)[1]), 30)
        return bool(fresh), {"pane": pane, "killed": page, "new_pid": fresh}

    def fault_acpmux(self):
        pids = [pid for pid, _, args in self.procs()
                if re.search(r"/acpmux(\s|$)", args) and (self.g.app in args or (self.bundle_id and self.bundle_id in args))]
        if not pids:
            raise Skip("the app runs no acpmux daemon")
        self.type_around(lambda: self.kill(pids))
        echoed = self.echo("left")
        _, agent = self.agent_pid()
        return echoed, {"killed": pids, "echo": echoed, "agent_page_pid_after": agent}

    def fault_daemon(self):
        before = self.call("debug.daemon")
        old = before.get("pid")
        if not old:
            return False, {"why": "debug.daemon names no connected daemon", "daemon": before}
        self.type_around(lambda: self.kill([int(old)]))
        back = self.wait(lambda: (lambda d: d if d.get("connection") == "connected" and d.get("pid") not in (None, old)
                                  else None)(self.call("debug.daemon")), 90)
        panes = [self.wait(lambda t=t: self.pane_of(t).get("link") == "connected", 60) for t in
                 (self.tabs.get("left"), self.tabs.get("right")) if t]
        echoed = bool(back) and self.echo("left")
        return bool(back) and all(panes) and echoed, {
            "killed": old, "new_pid": (back or {}).get("pid"), "connection": (back or self.call("debug.daemon")).get("connection"),
            "panes_connected": panes, "echo": echoed}

    def fault_memory_pressure(self):
        self.sudo()
        level = "/usr/sbin/sysctl -n kern.memorystatus_vm_pressure_level"
        # The guest bounds the pressure itself (an alarm ends memory_pressure), then sets the level back to normal.
        self.type_around(lambda: self.g.sh(
            f"( sudo -n /usr/bin/perl -e 'alarm {PRESSURE_SECONDS}; exec @ARGV' /usr/bin/memory_pressure -S -l critical "
            f">/tmp/cmux-chaos-pressure.log 2>&1 & sleep {PRESSURE_SECONDS}; "
            "sudo -n /usr/sbin/sysctl -w kern.memorystatus_vm_pressure_level=1 >/dev/null 2>&1 ) "
            "</dev/null >/dev/null 2>&1 & true"))
        during = self.wait(lambda: (lambda v: v if v == PRESSURE_CRITICAL else None)(self.g.sh(level).stdout.strip()), 10, 0.5)
        if not during:
            raise Skip(f"the pressure level never reached critical ({PRESSURE_CRITICAL}): it is "
                       f"{self.g.sh(level).stdout.strip()!r}; memory_pressure said "
                       f"{self.g.sh('tail -c 300 /tmp/cmux-chaos-pressure.log').stdout.strip()!r}")
        echoed = self.echo("left")
        hibernation = self.call("debug.surfaces").get("hibernation") or {}
        end = time.time() + PRESSURE_SECONDS + 10
        while self.g.sh(level).stdout.strip() not in ("1", "") and time.time() < end:
            time.sleep(1)
        return echoed, {"level_during": during, "level_after": self.g.sh(level).stdout.strip(), "echo": echoed,
                        "app_pressure": hibernation.get("pressure")}

    def fault_network_off(self):
        self.sudo()
        tab = self.tabs.get("cef") or self.missing("cef")
        # The rules load and pf turns on in the foreground; only the guest's own off-timer runs in the background.
        on = (f"printf %s {shlex.quote(PF_RULES)} | sudo -n /sbin/pfctl -a {PF_ANCHOR} -f - 2>/dev/null || exit 3; "
              "t=$(sudo -n /sbin/pfctl -E 2>&1 | sed -n 's/^Token : //p'); [ -n \"$t\" ] || exit 3; "
              f"( sleep {NETWORK_OFF_SECONDS}; sudo -n /sbin/pfctl -a {PF_ANCHOR} -F all; sudo -n /sbin/pfctl -X \"$t\" ) "
              "</dev/null >/dev/null 2>&1 & echo \"token=$t\"")
        enabled = {}
        self.type_around(lambda: enabled.update(reply=self.g.sh(on).stdout.strip()))
        token = enabled.get("reply", "").partition("token=")[2]
        if not token:
            raise Skip(f"pf did not turn on: {enabled.get('reply')!r}")
        created, failed = None, None
        try:
            offline = self.g.sh("/usr/bin/curl -s -m 5 -o /dev/null http://example.com/").returncode != 0
            echoed = self.echo("left")
            self.focus(tab)  # the unreachable page opens in the pages' pane, not over a terminal
            remote = self.call("action.run", {"action": "openBrowser", "args": {"url": "http://example.com/?chaos-offline",
                                                                                "engine": "cef"}, "focus": True})
            created = (remote.get("created") or [None])[0]
            if created:
                failed = self.wait(lambda: self.load_error(self.page_status(created)), 30)
            status = self.page_status(created) if created else {}
            local = self.js(tab, "document.getElementById('alive')?.textContent") == "alive"
        finally:
            self.g.sh(f"sudo -n /sbin/pfctl -a {PF_ANCHOR} -F all >/dev/null 2>&1; sudo -n /sbin/pfctl -X {shlex.quote(token)} "
                      ">/dev/null 2>&1; true")
        if created:
            self.call("action.run", {"action": "closeTab", "target": "tab:" + created})
        return offline and echoed and bool(failed) and local, {
            "offline": offline, "echo": echoed, "unloadable_tab": created, "load_error_shown": bool(failed),
            "unloadable_status": {k: status.get(k) for k in ("gone", "error", "enginePage", "title")},
            "local_page_answers": local}

    @staticmethod
    def load_error(status: dict) -> dict | None:
        """A page that shows its load error (the cmux error page, `error`, or Chromium's own, `enginePage`)
        and not the crash page. A reply without `gone` is no page status (an unknown tab or a failed call)."""
        shown = status.get("gone") == "0" and (bool(status.get("error")) or status.get("enginePage") == "1")
        return status if shown else None

    def fault_holder(self):
        holders = self.holders()
        if not holders:
            raise Skip("no terminal holder runs (CMUX_TUI_TERMINAL_HOST_MODEL=holder started none)")
        roles = [role for role in ("left", "right") if self.tabs.get(role)]
        shells = {role: self.shell_ids(role) for role in roles}  # (shell pid, the holder it is a child of)
        if not (shells.get("left") and shells["left"][1] in holders):
            raise Skip(f"the left terminal's shell is no holder's child (shell and parent {shells.get('left')}, "
                       f"holders {holders})")
        victim = shells["left"][1]
        others = [pid for pid in holders if pid != victim]
        self.type_around(lambda: self.kill([victim]))
        panes = {role: self.after_holder_kill(role, shells[role], victim, holders) for role in roles}
        untouched = [pid for pid in others if self.g.sh(f"kill -0 {pid}").returncode == 0]
        ok = all(p["echo"] and p["observed"] in ("ended", "kept", "untouched") for p in panes.values()) and untouched == others
        return ok, {"killed": victim, "shells_before": shells, "other_holders": others, "untouched": untouched,
                    "panes": panes}

    def after_holder_kill(self, role: str, before: tuple[int, int] | None, victim: int, holders: list[int]) -> dict:
        """What the `role` terminal shows after its holder (or another one) was killed."""
        tab = self.tabs[role]
        if not before or before[1] != victim:
            now = self.shell_ids(role)  # another holder's terminal keeps its shell
            return {"observed": "untouched" if before and now == before else f"shell {before} -> {now}",
                    "echo": now is not None}
        # The daemon reports the shell ended, or a new holder adopted the masters it holds.
        settled = self.wait(lambda: (lambda p, new: {**p, "new_holders": new} if p.get("link") == "exited"
                                     or (p.get("link") == "connected" and new) else None)(
            self.pane_of(tab), sorted(set(self.holders()) - set(holders))), 30) or {}
        if settled.get("link") == "exited":
            # What the person sees: the banner and "Restart Shell Here", whose action is tab.restart.
            overlay = self.wait(lambda: (lambda p: p if p.get("restart_offered") and p.get("status_text") else None)(
                self.pane_of(tab)), 10) or self.pane_of(tab)
            offered = bool(overlay.get("restart_offered")) and bool(overlay.get("status_text"))
            seen = {"status_text": overlay.get("status_text"), "restart_offered": overlay.get("restart_offered")}
            if not offered:
                return {"observed": "ended without the Restart overlay", **seen, "echo": False}
            ran = self.call("action.run", {"action": "tab.restart", "target": "tab:" + tab, "focus": True})
            back = self.wait(lambda: self.pane_of(tab).get("link") == "connected", 60)
            return {"observed": "ended", **seen, "restart": ran, "restarted": bool(back),
                    "echo": bool(back) and self.echo(role)}
        if settled.get("link") == "connected":
            now = self.shell_ids(role)  # the same shell, its master now held by the new holder
            kept = now is not None and now[0] == before[0]
            return {"observed": "kept" if kept else f"shell {before[0]} -> {now}", "new_holders": settled["new_holders"],
                    "echo": now is not None}
        return {"observed": f"link {self.pane_of(tab).get('link')} and no new holder", "echo": False}

    def fault_fd_limit(self):
        limit = self.g.sh(f"/usr/sbin/lsof -p {self.app_pid} 2>/dev/null | wc -l").stdout.strip()
        refused = []
        for _ in range(12):
            reply = self.call("action.run", {"action": "newTab", "focus": True, "wait": True})
            if "error" in reply:
                refused.append(reply["error"][:200])
        for engine in ("cef", "webkit") * 4:
            reply = self.call("action.run", {"action": "openBrowser", "args": {"url": f"http://127.0.0.1:{PAGE_PORT}/?fd",
                                                                               "engine": engine}, "focus": True})
            if "error" in reply:
                refused.append(reply["error"][:200])
        self.call("action.run", {"action": "newTab", "focus": True, "wait": True})
        last = self.wait(self.focused_terminal, STEP_DEADLINE)
        if last:
            self.tabs["last"] = last
        echoed = bool(last) and self.echo("last")
        return echoed, {"open_files_at_start": limit, "refused": refused[:6], "refusals": len(refused),
                        "open_files_after": self.g.sh(f"/usr/sbin/lsof -p {self.app_pid} 2>/dev/null | wc -l").stdout.strip(),
                        "echo": echoed}

    def fault_full_disk(self):
        g = self.g
        g.sh(f"dd if=/dev/zero of={HOME_MOUNT}/fill bs=1048576 >/dev/null 2>&1; true", timeout=180)
        free = g.sh(f"df -k {HOME_MOUNT} | awk 'NR==2 {{print $4}}'").stdout.strip()
        if not free.isdigit() or int(free) >= FULL_FREE_KB:
            g.sh(f"rm -f {HOME_MOUNT}/fill")
            raise Skip(f"dd did not fill the home volume: {free or 'no df'} KB free")
        try:
            known = set(self.tabs.values())
            self.call("action.run", {"action": "newTab", "focus": True, "wait": True})
            fresh = self.wait(lambda: (lambda t: t if t and t not in known else None)(self.focused_terminal()), 60)
            if fresh:
                self.tabs["full"] = fresh
            split = self.call("action.run", {"action": "splitRight", "focus": True})
            settings = self.call("settings.open", {"focus": True})
            echoed = bool(fresh) and self.echo("full")
        finally:
            g.sh(f"rm -f {HOME_MOUNT}/fill")
        after = self.g.ping_ms(PING_BOUND_MS / 1000)
        answered = after is not None and after < PING_BOUND_MS
        return bool(fresh) and "error" not in split and "error" not in settings and echoed and answered, {
            "free_kb_when_full": int(free), "new_workspace": bool(fresh), "split": split, "settings": settings,
            "echo": echoed, "ping_after_free_ms_vm": after}

    # --- the quit storm ---------------------------------------------------------------------------
    def poll(self, probe, seconds: float, every: float = 0.5):
        """Smoke.wait without its early end when the app is gone: a quit waits for exactly that."""
        end = time.time() + seconds
        while True:
            value = probe()
            if value or time.time() >= end:
                return value
            time.sleep(every)

    def vnc_send(self, send) -> None:
        """Real keys over VNC (the server drops idle clients: one reconnect)."""
        try:
            send(self.vnc)
        except (ConnectionError, OSError, RuntimeError):
            self.vnc = smoke.RFB(*self.vnc_args)
            send(self.vnc)

    def press(self, chord: str) -> None:
        self.vnc_send(lambda vnc: vnc.chord(chord))

    def type_keys(self, text: str) -> None:
        self.vnc_send(lambda vnc: vnc.type_text(text, gap=0.005))

    def exited(self) -> int | None:
        """The app's exit status, once launch()'s shell wrote it."""
        out = self.g.sh(f"cat {EXIT_FILE} 2>/dev/null").stdout.strip()
        return int(out) if out.isdigit() else None

    def chromium_children(self) -> list[int]:
        return sorted(pid for pid, ppid, args in self.procs() if ppid == self.app_pid and "--type=" in args)

    def still_running(self, pids: list[int]) -> list[int]:
        """Which of `pids` still run as a Chromium child (a reused pid runs something else)."""
        return sorted(pid for pid, _, args in self.procs() if pid in pids and "--type=" in args)

    def quit_sheet(self) -> str | None:
        """`asking` or `closed` as debug.quit says; None when it did not answer, which is unknown, never closed."""
        reply = self.call("debug.quit", timeout=5)
        if "error" in reply:
            return None
        return "asking" if reply.get("asking") else "closed"

    def await_exit(self) -> tuple[int | None, str]:
        """The exit status within QUIT_EXIT_DEADLINE (None: no exit), answering a quit sheet whenever it shows
        before then. How it was answered: `none` (never asked), `cmd-q` (a second Cmd-Q, its default) or
        `press-default` (still up or unknown QUIT_ASK_WAIT after that Cmd-Q: debug.quit pressed its default;
        "quit" is Keep on a sheet without Quit). A look that acts is always followed by another."""
        deadline = time.time() + QUIT_EXIT_DEADLINE
        sheet, answered_at, closed = "none", 0.0, False
        while True:
            status = self.exited()
            if status is not None:
                return status, sheet
            state = self.quit_sheet()
            acted = False
            if sheet == "none" and state == "asking":
                self.press("cmd+q")
                sheet, answered_at, acted = "cmd-q", time.time(), True
            elif sheet == "cmd-q":
                closed = state == "closed" or (closed and state is None)
                if not closed and time.time() - answered_at >= QUIT_ASK_WAIT:
                    self.call("debug.quit", {"press": "quit"}, timeout=5)
                    sheet, acted = "press-default", True
            if not acted and time.time() >= deadline:
                return self.exited(), sheet
            time.sleep(QUIT_POLL)

    def forced_quits(self, since: float, until: float) -> list[str]:
        """QuitDeadline's "quit still running" faults logged in [since, until] (guest clock)."""
        out = self.g.sh(f"log show --style ndjson --start '@{int(since)}' --end '@{int(until) + 1}' --predicate "
                        "'category == \"app.quit\" AND messageType == fault' 2>/dev/null | tail -50", timeout=120).stdout
        found = []
        for line in out.splitlines():
            try:
                message = json.loads(line).get("eventMessage", "") if line.startswith("{") else ""
            except ValueError:
                continue
            if FORCED_QUIT_LINE in message:
                found.append(message)
        return found

    def quit_storm(self, before=None, after=None, relaunched=None) -> tuple[bool, dict]:
        """Cmd-Q (real keys) between `before` and `after`; then the exit, the Chromium children and a
        relaunch (`relaunched` runs before its tour) with the tour. Leaves the relaunched app as self.app_pid."""
        old = self.app_pid
        children = self.chromium_children()
        self.g.refocus()
        quit_from = self.guest_time()
        if before:
            before()
        self.press("cmd+q")
        if after:
            after()
        clock = time.time()
        status, sheet = self.await_exit()
        forced = self.forced_quits(quit_from, self.guest_time())
        detail = {"old_pid": old, "sheet": sheet, "exit_status": status, "forced_exit": forced,
                  "quit_seconds_vm": round(time.time() - clock, 1), "chromium_children": children}
        if status is None:
            detail["quit_state"] = self.call("debug.quit", timeout=10)
            self.quit()  # ends what still runs of the build, so the relaunch starts clean
        self.poll(lambda: not self.still_running(children), CHILD_EXIT_DEADLINE)
        left = self.still_running(children)
        if left:
            self.kill(left)
        detail["children_left"] = left
        self.app_pid = None
        if not self.launch("quit"):
            return False, {**detail, "relaunch": f"no ping within {LAUNCH_DEADLINE} s"}
        if relaunched:
            relaunched()
        problems = self.tour()
        detail.update(new_pid=self.app_pid, relaunch_tour=problems or "ok")
        return status == 0 and not forced and not left and not problems, detail

    def fault_quit_page_load(self):
        pages = self.tabs.get("cef") or self.missing("cef")
        self.g.sh(f"( trap '' HUP; exec /usr/bin/perl -MIO::Socket::INET -e '{PERL_TARPIT}' {TARPIT_PORT} "
                  f">/tmp/cmux-chaos-tarpit.log 2>&1 </dev/null ) & echo $! >{TARPIT_PID}; disown; true")
        try:
            self.focus(pages)  # the loading tabs open in the pages' pane
            loading = {}
            for engine in ("cef", "webkit"):
                reply = self.call("action.run", {"action": "openBrowser", "focus": True, "args": {
                    "url": f"http://127.0.0.1:{TARPIT_PORT}/?{engine}", "engine": engine}})
                loading[engine] = (reply.get("created") or [None])[0]
            ok, detail = self.quit_storm()
        finally:
            self.g.sh(f"kill $(cat {TARPIT_PID} 2>/dev/null) 2>/dev/null; true")
        return ok and all(loading.values()), {"loading_tabs": loading, **detail}

    def fault_quit_typing(self):
        self.focus(self.tabs.get("left") or self.missing("left"))
        line = "echo cmux-chaos-quit-typing-" + "abcdefghij" * 4
        half = len(line) // 2
        ok, detail = self.quit_storm(before=lambda: self.type_keys(line[:half]),
                                     after=lambda: self.type_keys(line[half:]))
        return ok, {"typed": len(line), "cmd_q_after": half, **detail}

    def fault_quit_daemon_restart(self):
        old = self.call("debug.daemon").get("pid")
        if not old:
            return False, {"why": "debug.daemon names no connected daemon"}
        ok, detail = self.quit_storm(before=lambda: self.kill([int(old)]))
        return ok, {"killed_daemon": old, **detail}

    def pane_count(self, timeout: float) -> int:
        """Smoke.panes with a bound: a quitting app may not answer."""
        windows = self.call("debug.focus", timeout=timeout).get("windows") or []
        window = next((w for w in windows if w.get("is_key")), windows[0] if windows else {})
        return len(window.get("topology") or [])

    def fault_quit_split_animation(self):
        self.focus(self.tabs.get("left") or self.missing("left"))
        before = self.pane_count(STEP_DEADLINE)
        seen = {}

        def restored():  # the relaunch's restored layout, before the tour adds panes
            seen["restored"] = self.wait(lambda: (lambda n: n if n > before else None)(self.pane_count(5)), 10) or 0
        ok, detail = self.quit_storm(before=lambda: self.press("cmd+d"),  # Ghostty's split right
                                     after=lambda: seen.update(at_quit=self.pane_count(3)), relaunched=restored)
        detail = {"panes_before": before, "panes_at_quit": seen.get("at_quit"),
                  "panes_restored": seen.get("restored"), **detail}
        if ok and max(seen.values(), default=0) <= before:
            raise Skip(f"Cmd-D made no split before the quit: {json.dumps(detail)[:600]}")
        return ok, detail

    def missing(self, role: str):
        raise RuntimeError(f"the tour has no {role} tab")

    # --- phases ---------------------------------------------------------------------------------
    def prepare(self, phase: str) -> str | None:
        """Guest setup a phase needs before its launch; the reason when it cannot be made."""
        if phase != "full-disk":
            return None
        r = self.g.sh(f"rm -f {HOME_IMAGE}; mkdir -p {HOME_MOUNT} && hdiutil create -quiet -size 512m -type SPARSE -fs APFS "
                      f"-volname cmuxchaos {HOME_IMAGE} && hdiutil attach -quiet -nobrowse -mountpoint {HOME_MOUNT} {HOME_IMAGE}",
                      timeout=120)
        return None if r.returncode == 0 else f"the home image did not attach: {(r.stderr or r.stdout).strip()[-300:]}"

    def cleanup(self, phase: str) -> None:
        if phase == "full-disk":
            self.g.sh(f"hdiutil detach -quiet -force {HOME_MOUNT}; rm -f {HOME_IMAGE}; true", timeout=60)

    def run(self, faults: list[str]) -> None:
        g = self.g
        self.since = self.guest_time() - 5  # report mtimes and the unified log are in the guest's clock
        self.result["os"] = g.sh("sw_vers -productVersion").stdout.strip()
        self.result["build"] = g.sh("sw_vers -buildVersion").stdout.strip()
        g.sh(": >/tmp/cmux-fuzz-app.log")
        rows = self.result["faults"]
        for phase in dict.fromkeys(FAULTS[f][0] for f in faults):
            names = [f for f in faults if FAULTS[f][0] == phase]
            begun = self.guest_time()
            if self.app_pid is not None:
                self.quit()
            why = self.prepare(phase)
            if why is None and not self.launch(phase):
                why = f"the app did not answer a ping within {LAUNCH_DEADLINE} s"
            elif why is None and "error" in self.call("system.identify"):
                why = "the app refused `cmux app call`: chaos needs a DEV build"
            problems = {} if why else self.tour()
            setup = self.segment(phase, "launch and tour", begun)
            if problems:
                # A fault that needs a missing tab fails on it (Chaos.missing); the rest still run.
                self.result.setdefault("tour", {})[phase] = problems
            if why or "terminal" in problems:
                # The phase never reached its faults: each is a FAIL with the reason and owns a crash in its setup.
                for name in names:
                    rows.append({"fault": name, "phase": phase, "expected": FAULTS[name][1], "outcome": "FAIL",
                                 "ok": False, "detail": {"phase_setup": why or problems}, "window": setup,
                                 "crash_reports": []})
                    print("%-18s FAIL %s" % (name, json.dumps(why or problems)[:400]), flush=True)
                self.cleanup(phase)
                continue
            for name in names:
                if g.pid() is None or g.pid() != self.app_pid:
                    rows.append({"fault": name, "phase": phase, "expected": FAULTS[name][1], "outcome": "FAIL",
                                 "ok": False, "detail": {"why": "the app was gone before this fault (see the one before)"},
                                 "crash_reports": []})
                    continue
                rows.append(self.run_fault(name, phase))
            ending = self.guest_time()
            self.quit()
            self.cleanup(phase)
            self.segment(phase, "quit", ending)

    def segment(self, phase: str, part: str, begun: float) -> list[float]:
        """Records a stretch of the run that is no fault (a launch and tour, a quit), in the guest's clock."""
        window = [begun, self.guest_time()]
        self.result.setdefault("segments", []).append({"phase": phase, "part": part, "window": window})
        return window

    @staticmethod
    def crash_time(text: str, mtime: float) -> tuple[float, str]:
        """When the process crashed, in the guest's clock: the report's `captureTime`, else its header's
        `timestamp`. The file's mtime is when ReportCrash wrote it, up to ~20 s later (into the next fault)."""
        for key in ("captureTime", "timestamp"):
            found = re.search(r'"%s"\s*:\s*"(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)(?:\.\d+)? ([+-]\d{4})"' % key, text)
            if found:
                stamp = datetime.datetime.strptime(" ".join(found.groups()), "%Y-%m-%d %H:%M:%S %z")
                return stamp.timestamp(), key
        return mtime, "mtime"

    @staticmethod
    def owners(rows: list[dict], at: float) -> list[dict]:
        """The fault rows whose window holds `at` (1 s either side: the guest clock has whole seconds). Two
        fault windows meet at most at an edge, where the later one owns it; the phase-setup rows of a phase
        share one window, so a crash there is each one's."""
        held = [r for r in rows if r.get("window") and r["window"][0] - 1 <= at <= r["window"][1] + 1]
        if not held:
            return []
        start = max(r["window"][0] for r in held)
        return [r for r in held if r["window"][0] == start]

    def finish(self) -> None:
        g = self.g
        if self.app_pid is not None:
            ending = self.guest_time()
            self.quit()
            self.segment("end", "quit", ending)
        g.sh(f"kill $(cat /tmp/cmux-chaos-www.pid {TARPIT_PID} 2>/dev/null) 2>/dev/null; "
             f"sudo -n /sbin/pfctl -a {PF_ANCHOR} -F all >/dev/null 2>&1; "
             f"hdiutil detach -quiet -force {HOME_MOUNT} >/dev/null 2>&1; true", timeout=60)
        rows = self.result["faults"]
        time.sleep(REPORT_DEADLINE)  # ReportCrash writes a report up to ~20 s after a death
        reports = self.reports_since(self.since)
        unowned = []
        for mtime, path in reports:
            name = os.path.basename(path)
            text = g.sh(f"cat {shlex.quote(path)}", timeout=30).stdout
            open(os.path.join(self.out, name), "w").write(text)
            if report_kind(name) != "crash":
                continue
            at, source = self.crash_time(text, mtime)
            owners = self.owners(rows, at)
            for row in owners:
                row["crash_reports"].append(name)
                row.update(outcome="FAIL", ok=False)
            if not owners:
                # A crash at a launch, in a tour or at a quit: no fault's, and it fails the run.
                during = next((f"{s['phase']}: {s['part']}" for s in self.result.get("segments", [])
                               if s["window"][0] - 1 <= at <= s["window"][1] + 1), None)
                unowned.append({"report": name, "crashed_at": at, "time_from": source, "during": during})
        open(os.path.join(self.out, "app.log"), "w").write(g.sh("cat /tmp/cmux-fuzz-app.log", timeout=30).stdout)
        faults = g.sh(f"log show --style ndjson --start '@{int(self.since)}' --predicate "
                      "'(process CONTAINS \"cmux\") AND (messageType == fault)' 2>/dev/null | tail -500", timeout=120)
        open(os.path.join(self.out, "faults.ndjson"), "w").write(faults.stdout)
        crashes = sorted({n for r in rows for n in r.get("crash_reports", [])} | {u["report"] for u in unowned})
        failed = [r["fault"] for r in rows if r["outcome"] == "FAIL"]
        skipped = [r["fault"] for r in rows if r["outcome"] == "skip"]
        self.result.update(reports=[{"kind": report_kind(os.path.basename(p)), "report": os.path.basename(p)} for _, p in reports],
                           crashes=len(crashes), crashes_outside_faults=unowned, failed_steps=failed, skipped=skipped,
                           faults_log=sum(1 for line in faults.stdout.splitlines() if line.startswith("{")),
                           ok=bool(rows) and not failed and not skipped and not crashes)
        json.dump(self.result, open(os.path.join(self.out, "result.json"), "w"), indent=1)
        print("CHAOS %s os=%s failed=%s skipped=%s crashes=%d" % (
            "PASS" if self.result["ok"] else ("FAIL" if failed or crashes else "NO-VERDICT"), self.result.get("os"),
            ",".join(failed) or "-", ",".join(skipped) or "-", len(crashes)), flush=True)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--ssh", required=True, help="guest user@ip")
    ap.add_argument("--vnc", required=True, help="host:port[:password]")
    ap.add_argument("--app", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--faults", default=",".join(FAULTS), help="comma-separated subset of: " + ", ".join(FAULTS))
    ap.add_argument("--ssh-opt", action="append", default=[], help="extra ssh option (repeatable)")
    o = ap.parse_args()
    faults = [f for f in o.faults.split(",") if f]
    unknown = [f for f in faults if f not in FAULTS]
    if unknown or not faults:
        sys.exit(f"unknown faults {unknown}; known: {', '.join(FAULTS)}")
    os.makedirs(o.out, exist_ok=True)
    g = Guest(o.ssh, o.app, o.ssh_opt)
    if g.sh(f"test -d {shlex.quote(o.app)}").returncode != 0:
        sys.exit(f"no app at {o.app!r} in the guest")
    chaos = Chaos(g, o.vnc, o.out)
    try:
        chaos.run(faults)
    finally:
        chaos.finish()
    return 0


if __name__ == "__main__":
    sys.exit(main())
