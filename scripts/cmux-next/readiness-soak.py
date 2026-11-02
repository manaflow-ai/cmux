#!/usr/bin/env python3
"""cmux-next readiness soak (hq#1870 gate: "a 24h soak with 10 agents: CPU, memory, no crash").

Runs a cmux-next app copy for --hours with --agents agent sessions, --terminals terminals that
keep printing and --browsers Chromium tabs, and samples every --sample seconds:

  - CPU share, memory footprint and wakeups/s per process kind (app, cmux-tui daemon, terminal
    hosts, acpmux, agents, Chromium helpers or WebKit processes), from proc_pid_rusage
    (bench_idle.usage), and open file descriptors (proc_pidinfo PROC_PIDLISTFDS). Browser tabs are Chromium when the build has it, else WebKit; WebKit's
    processes are launchd's children, so a WebKit process counts when the app is responsible for
    it (responsibility_get_pid_responsible_for_pid), not other apps' or iOS simulators';
  - control-socket round trips (system.ping, snapshot.get): a reply slower than --hang-after
    seconds is a hang; an instant failure (a missing socket file, a refused connect, an error
    reply) is a control-error event that names the error;
  - crashes: a new DiagnosticReports .ips of this app copy (its bundle ID), of a process of it
    the soak saw (every kind but WebKit, launchd's children) or of a child of the app, or the
    app, daemon or acpmux PID changing.
    Other builds crashing on the same host (a capture mini's tagged builds) do not count;
  - agent turns: every agent gets a streaming turn ("slow") every --turn-every seconds; a turn
    still running after 5 minutes is stuck.

The last --idle seconds are quiet: no new turns, and the terminals stop printing and wait on input.
Once every turn has ended and --settle seconds have passed, those samples are the idle cost.

The agents are acpmux's test agent (cmux-tui/crates/acpmux/tests/fake_agent.py): no account, no
network, no credential on the host. The app runs with its own ACPMUX_HOME and config in a scratch
folder; the soak never touches the host's ~/.acpmux or settings.

At the end it writes report.json and report.md to --out and exits 1 when a criterion failed:
no crash, no hang, no control error, no stuck turn, memory growth (median of the last hour of load against an hour mid-load,
or quarters of a shorter load phase) within --max-growth-percent and --max-growth-mb per kind, open fds of the
app, daemon and acpmux growing by at most --max-fd-growth, the mean CPU of the app and the daemon
under --max-app-cpu and --max-daemon-cpu. Idle CPU over --max-idle-*-cpu (app, daemon,
acpmux) is a WARN line until --idle-cpu-gate fail. report.md ends with a memory and fd trend. Teardown goes through
the app's quit path, then TagTeardown (acpmux and cmux-tui shutdown, exact PIDs of this copy).

Host rules: an Aqua GUI session for this user; nothing else answering on the app's control
socket. Use a copy of the app (the nightly runner unpacks cmux-next-dev into the scratch folder).

  scripts/cmux-next/readiness-soak.py --app PATH [--hours 24] [--agents 10] [--terminals 10]
      [--browsers 4] [--sample 60] [--turn-every 300] [--out DIR]
"""
from __future__ import annotations

import argparse
import ctypes
import datetime as dt
import functools
import glob
import json
import os
import plistlib
import re
import shlex
import shutil
import socket
import statistics
import subprocess
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from bench_idle import Client, process_table, usage  # noqa: E402
from daemon_teardown import daemon_status, request, terminal_hosts  # noqa: E402
from tag_teardown import TagTeardown  # noqa: E402

FAKE_AGENT = os.path.join(HERE, "../../cmux-tui/crates/acpmux/tests/fake_agent.py")
FAKE_HARNESS = "readiness-soak-agent"
CRASH_NAMES = ("cmux", "acpmux")
STUCK_TURN_S = 300
# Each terminal prints until the quiet phase creates {stop}, then waits on its input (an idle shell).
TERMINAL_WORK = ("i=0; while [ ! -e {stop} ]; do i=$((i+1)); echo \"soak $i $(date +%T)\"; ls -l /usr/bin | head -30; "
                 "sleep 2; done; echo soak quiet; exec cat")
STATIC_PAGE = "<!doctype html><title>soak static</title><h1>static</h1><p>no script</p>"
TICKING_PAGE = ("<!doctype html><title>soak ticking</title><h1 id=t>0</h1>"
                "<script>let n=0;setInterval(()=>{document.getElementById('t').textContent=++n},5000)</script>")


PROC_PIDLISTFDS, PROC_FDINFO_SIZE = 1, 8


@functools.cache
def libproc():
    return ctypes.CDLL("/usr/lib/libproc.dylib")  # on first use, so the module imports off macOS (its tests)


def open_fds(pid):
    """Open file descriptors of pid (proc_pidinfo PROC_PIDLISTFDS), or None when it is gone."""
    size = libproc().proc_pidinfo(ctypes.c_int(pid), PROC_PIDLISTFDS, ctypes.c_uint64(0), None, 0)
    if size <= 0:
        return None
    buffer = ctypes.create_string_buffer(size + 64 * PROC_FDINFO_SIZE)
    used = libproc().proc_pidinfo(ctypes.c_int(pid), PROC_PIDLISTFDS, ctypes.c_uint64(0), buffer, len(buffer))
    return used // PROC_FDINFO_SIZE if used > 0 else None


@functools.lru_cache(None)
def responsibility_call():
    """libSystem's responsibility_get_pid_responsible_for_pid, or None where it does not exist."""
    try:
        call = ctypes.CDLL("/usr/lib/libSystem.B.dylib").responsibility_get_pid_responsible_for_pid
    except (OSError, AttributeError):
        return None
    call.argtypes, call.restype = [ctypes.c_int], ctypes.c_int
    return call


def responsible_pid(pid):
    """The process macOS holds responsible for pid (an XPC service's host app); -1 when the call has no
    answer for pid (it exited), None when the call does not exist on this host."""
    call = responsibility_call()
    if call is None:
        return None
    owner = call(pid)
    return owner if owner > 0 else -1


def now_iso():
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")


def say(line):
    print(f"{now_iso()} {line}", flush=True)


def run(*argv, timeout=60, env=None):
    return subprocess.run(list(argv), capture_output=True, text=True, timeout=timeout, env=env)


def bundle_tag(app):
    with open(os.path.join(app, "Contents/Info.plist"), "rb") as handle:
        info = plistlib.load(handle)
    bundle_id, executable = info.get("CFBundleIdentifier", ""), info.get("CFBundleExecutable", "")
    prefix = "com.cmuxterm.app.debug."
    if not bundle_id.startswith(prefix):
        raise SystemExit(f"readiness-soak: {app} is {bundle_id!r}, not a tagged build ({prefix}<tag>)")
    # The app's own tag rule (ControlSocketPath.sanitize): lowercase, [^a-z0-9]+ -> "-".
    return re.sub(r"[^a-z0-9]+", "-", bundle_id[len(prefix):].lower()).strip("-"), executable


def own_copy(app, work):
    """A copy of app in work with its own bundle id (<id>.soak<pid>), ad hoc signed like a capture slot's clone.

    A tagged build's control socket, cmux-tui session and acpmux tag home all follow its bundle id, so any
    other copy of the same build on the host (an installed cmux NEXT DEV) neither blocks the soak's copy nor
    shares its daemons."""
    copy = os.path.join(work, os.path.basename(app.rstrip("/")))
    copied = run("ditto", app, copy, timeout=900)
    if copied.returncode:
        raise SystemExit(f"readiness-soak: copying {app} failed: {copied.stderr.strip()[-300:]}")
    plist = os.path.join(copy, "Contents/Info.plist")
    with open(plist, "rb") as handle:
        info = plistlib.load(handle)
    info["CFBundleIdentifier"] = f"{info.get('CFBundleIdentifier', '')}.soak{os.getpid()}"
    with open(plist, "wb") as handle:
        plistlib.dump(info, handle)
    signed = run("codesign", "--force", "--deep", "--sign", "-", copy, timeout=900)
    if signed.returncode:
        raise SystemExit(f"readiness-soak: signing the copy failed: {signed.stderr.strip()[-300:]}")
    return copy


def acpmux_socket(home):
    """acpmux's socket for ACPMUX_HOME (config.rs socket_path): a long home falls back to
    /tmp/acpmux-<uid>/<fnv1a(home)>.sock."""
    preferred = os.path.join(home, "acpmux.sock")
    if len(preferred) < 96:
        return preferred
    value = 0xcbf29ce484222325
    for byte in home.encode():
        value = ((value ^ byte) * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
    return f"/tmp/acpmux-{os.getuid()}/{value:016x}.sock"


class Acpmux:
    """JSON-RPC over the app's acpmux socket, one request per connection."""

    def __init__(self, path):
        self.path = path

    def call(self, method, params=None, timeout=10):
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.settimeout(timeout)
            try:
                sock.connect(self.path)
                init = {"jsonrpc": "2.0", "id": 1, "method": "initialize",
                        "params": {"protocolVersion": 1, "clientInfo": {"name": "readiness-soak", "version": "1"}}}
                req = {"jsonrpc": "2.0", "id": 2, "method": method, "params": params or {}}
                sock.sendall((json.dumps(init) + "\n" + json.dumps(req) + "\n").encode())
                buffer = b""
                while True:
                    chunk = sock.recv(1 << 16)
                    if not chunk:
                        return None
                    buffer += chunk
                    while b"\n" in buffer:
                        line, buffer = buffer.split(b"\n", 1)
                        message = json.loads(line or b"{}")
                        if message.get("id") == 2:
                            return {"error": message["error"]} if "error" in message else message.get("result")
            except (OSError, ValueError) as error:
                return {"error": str(error)}

    def sessions(self):
        reply = self.call("_acpmux/sessions") or {}
        return {s.get("sessionId"): s.get("status") for s in reply.get("sessions", [])} if "error" not in reply else {}


def wait(condition, seconds, step=1.0):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = condition()
        if value:
            return value
        time.sleep(step)  # soak script: waiting for setup to take effect
    return None


class Soak:
    def __init__(self, args):
        self.args = args
        self.app = os.path.realpath(args.app)
        self.out = args.out
        os.makedirs(self.out, exist_ok=True)
        # Resolved (/var -> /private/var), so the copy and its helpers have one path that TagTeardown matches.
        self.work = os.path.realpath(tempfile.mkdtemp(prefix="cmux-soak-"))
        self.acpmux_home = os.path.join(self.work, "acpmux")
        self.quiet_file = os.path.join(self.work, "quiet")
        self.acp = Acpmux(acpmux_socket(self.acpmux_home))
        self.samples = None  # opened by begin(), after preflight: a refused soak never touches another's files
        self.stage = "setup"
        self.events = []
        self.setup = {}
        self.agents = {}  # session id -> {"started": monotonic or None, "turns": n, "done": n}
        self.started = time.time()
        self.pids = {}
        self.app_pid = None
        self.seen_pids = set()  # every PID of this copy but WebKit's, for crash reports
        self.webkit_before = set()

    def event(self, kind, detail):
        self.events.append({"at": now_iso(), "kind": kind, "detail": detail})
        say(f"EVENT {kind}: {detail}")

    # ---- setup ---------------------------------------------------------------------------

    def identify(self):
        """Run this soak's own tagged copy of --app (own_copy) unless --same-tag."""
        if not self.args.same_tag:
            self.app = own_copy(self.app, self.work)
        self.tag, executable = bundle_tag(self.app)
        with open(os.path.join(self.app, "Contents/Info.plist"), "rb") as handle:
            self.bundle_id = plistlib.load(handle)["CFBundleIdentifier"]
        self.binary = os.path.join(self.app, "Contents/MacOS", executable)
        self.tui = os.path.join(self.app, "Contents/Resources/bin/cmux-tui")
        # The app's own rule (ControlSocketPath.resolve): the state folder, or the old /tmp name when that
        # path would not fit sun_path. The app also keeps a /tmp symlink, so the soak uses the real path.
        # A build from before the move listens on the /tmp name only; connect() settles on the one that answers.
        moved, old = os.path.expanduser(f"~/.local/state/cmux/cmux-debug-{self.tag}.sock"), f"/tmp/cmux-debug-{self.tag}.sock"
        self.sockets = [self.args.socket] if self.args.socket else [moved, old] if len(moved.encode()) <= 103 else [old]
        self.socket = self.sockets[0]
        self.setup["tag"] = self.tag

    def preflight(self):
        if run("launchctl", "print", f"gui/{os.getuid()}").returncode != 0:
            raise SystemExit("readiness-soak: no Aqua GUI session for this user")
        for path in self.sockets:
            if os.path.exists(path):
                try:
                    Client(path, timeout=3).call("system.ping")
                    raise SystemExit(f"readiness-soak: something already answers on {path}")
                except OSError:
                    pass
        table = process_table()
        # Two soaks on one host would measure each other.
        parents, mine, pid = {p: pp for p, pp, _ in table}, set(), os.getpid()
        while pid and pid not in mine:  # this soak and the shells that started it
            mine.add(pid)
            pid = parents.get(pid)
        others = [pid for pid, _, cmd in table if "readiness-soak.py" in cmd and pid not in mine]
        if others:
            raise SystemExit(f"readiness-soak: another soak runs on this host (PID {others[0]})")
        if any(cmd.startswith(self.binary) for _, _, cmd in table):
            raise SystemExit(f"readiness-soak: {self.binary} is already running")
        self.webkit_before = {pid for pid, _, cmd in table if "com.apple.WebKit." in cmd}

    def forget(self):
        """Remove the state the app keeps under this run's own bundle id and tag (both carry the soak's PID,
        so no other build shares them). --same-tag runs the build as it is and keeps its state."""
        if self.args.same_tag or not getattr(self, "bundle_id", None):
            return
        bundle, tag = self.bundle_id, self.tag
        support = os.path.expanduser("~/Library/Application Support")
        run("defaults", "delete", bundle)
        for path in (os.path.expanduser(f"~/Library/Preferences/{bundle}.plist"),
                     os.path.join(support, bundle),
                     os.path.join(support, "cmux-next", bundle),
                     os.path.join(support, "cmux", bundle),
                     os.path.join(support, "cmux", f"managed-status.{bundle}.json"),
                     os.path.join(support, "cmux", "tags", tag),
                     os.path.expanduser(f"~/.cmux/chief/isolated/{tag}")):
            if os.path.isdir(path) and not os.path.islink(path):
                shutil.rmtree(path, ignore_errors=True)
            elif os.path.lexists(path):
                os.remove(path)

    def begin(self):
        self.samples = open(os.path.join(self.out, "samples.jsonl"), "w")

    def launch(self):
        os.makedirs(self.acpmux_home)
        agent = os.path.join(self.work, "fake_agent.py")
        shutil.copy(FAKE_AGENT, agent)
        with open(os.path.join(self.acpmux_home, "config.json"), "w") as handle:
            json.dump({"harnesses": {FAKE_HARNESS: {"argv": [sys.executable, agent]}}}, handle)
        self.config = os.path.join(self.work, "cmux.json")
        with open(self.config, "w") as handle:
            json.dump({"app": {"quitBehavior": "keep"}}, handle)
        env = {"CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
               "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": self.config,
               "ACPMUX_HOME": self.acpmux_home}
        log = os.path.join(self.out, "app.log")
        argv = ["open", "-n", "-g", "--stdout", log, "--stderr", log]
        for key, value in env.items():
            argv += ["--env", f"{key}={value}"]
        # LaunchServices starts the app in the Aqua session even from SSH.
        opened = run(*argv, self.app)
        if opened.returncode != 0:
            raise SystemExit(f"readiness-soak: open failed: {opened.stderr}")
        self.control = wait(lambda: self.connect(), 120, 1)
        if not self.control:
            raise SystemExit(f"readiness-soak: no control socket at {self.socket}")
        identity = self.control.call("system.identify").get("result", {})
        self.setup["identity"] = {k: identity.get(k) for k in ("pid", "build", "version", "bundle_identifier") if k in identity}
        self.app_pid = self.setup["identity"].get("pid")
        say(f"app up: {self.setup['identity']}")

    def connect(self):
        for path in self.sockets:
            try:
                client = Client(path, timeout=10)
                if "error" not in client.call("system.ping"):
                    self.socket = path
                    return client
            except OSError:
                continue
        return None

    def start_terminals(self):
        status = wait(lambda: daemon_status(self.tui, self.tag), 60, 2)
        if not status:
            self.setup["terminals"] = "no running daemon"
            return
        made = 0
        for index in range(self.args.terminals):
            reply = request(status["socket"], {"id": 10 + index, "cmd": "run", "argv": ["/bin/sh", "-c", TERMINAL_WORK.format(stop=shlex.quote(self.quiet_file))],
                                               "new_workspace": True, "name": f"soak-terminal-{index + 1}"}, 30)
            made += bool(reply.get("ok"))
            if not reply.get("ok"):
                self.setup.setdefault("terminal_errors", []).append(str(reply.get("error"))[:200])
        self.setup["terminals"] = made

    def start_browsers(self):
        made = 0
        for index in range(self.args.browsers):
            page = os.path.join(self.work, f"page-{index}.html")
            with open(page, "w") as handle:
                handle.write(TICKING_PAGE if index % 2 else STATIC_PAGE)
            engine = self.setup.get("browser_engine", "chromium")
            reply = self.control.action(f"openBrowser.{engine}", timeout=90, url="file://" + page)
            if engine == "chromium" and (reply.get("error") or {}).get("code") == "unavailable":
                # A build without CEF (cmux NEXT DEV): WebKit tabs.
                self.setup["browser_engine"] = engine = "webkit"
                reply = self.control.action("openBrowser.webkit", timeout=90, url="file://" + page)
            self.setup.setdefault("browser_engine", engine)
            timed_out = (reply.get("error") or {}).get("code") == "timeout"
            made += timed_out or "error" not in reply
            if "error" in reply and not timed_out:
                self.setup.setdefault("browser_errors", []).append(str(reply.get("error"))[:200])
        self.setup["browsers"] = made

    def start_agents(self):
        if not wait(lambda: "error" not in (self.acp.call("_acpmux/status", timeout=3) or {"error": 1}), 120, 2):
            self.setup["agents"] = "acpmux did not answer"
            return
        self.acp.call("_acpmux/reload_config")
        for index in range(self.args.agents):
            cwd = os.path.join(self.work, f"agent-{index + 1}")
            os.makedirs(cwd)
            self.acp.call("acp.trust.set", {"cwd": cwd, "level": "trusted"})
            created = self.acp.call("session/new", {"cwd": cwd, "mcpServers": [],
                                                    "_meta": {"acpmux": {"harness": FAKE_HARNESS}}}) or {}
            if created.get("sessionId"):
                self.agents[created["sessionId"]] = {"started": None, "turns": 0, "done": 0, "cwd": cwd}
            else:
                self.setup.setdefault("agent_errors", []).append(str(created)[:200])
        self.setup["agents"] = len(self.agents)

    def prompt(self, session):
        entry = self.agents[session]
        entry["started"], entry["turns"] = time.monotonic(), entry["turns"] + 1

        def hold():
            self.acp.call("session/prompt", {"sessionId": session, "prompt": [{"type": "text", "text": "slow"}]},
                          timeout=STUCK_TURN_S + 60)
        threading.Thread(target=hold, daemon=True).start()

    # ---- sampling ------------------------------------------------------------------------

    def kinds(self):
        """{pid: kind} for every process of this app copy and its agents."""
        app_pid = self.setup["identity"].get("pid")
        found = {}
        tui = os.path.join(self.app, "Contents/Resources/bin/cmux-tui")
        acpmux = os.path.join(self.app, "Contents/Resources/bin/acpmux")
        for pid, ppid, cmd in process_table():
            # self.app is resolved (/private/var/...); the app names some helpers by /var/... (TagTeardown too).
            cmd = "/private" + cmd if cmd.startswith(("/var/", "/tmp/")) else cmd
            if pid == app_pid:
                found[pid] = "app"
            elif ppid == app_pid and " Helper" in cmd:
                found[pid] = "chromium-helper"
            elif cmd.startswith(tui):
                found[pid] = "terminal-host" if "__terminal-host" in cmd else "daemon"
            elif cmd.startswith(acpmux + " daemon run"):
                found[pid] = "acpmux"
            elif cmd.startswith(acpmux):
                found[pid] = "acpmux-helper"  # its router and per-agent hosts come and go with turns
            elif self.work in cmd and "fake_agent.py" in cmd:
                found[pid] = "agent"
            elif "com.apple.WebKit." in cmd and self.owns_webkit(pid, app_pid):
                found[pid] = "webkit"
        # A host's command line names neither the tag nor the bundle: the daemon's children and
        # the host records in the tag's state folder find them.
        for daemon in [pid for pid, kind in found.items() if kind == "daemon"]:
            for host in terminal_hosts(daemon, self.tag):
                found[host] = "terminal-host"
        return found

    def owns_webkit(self, pid, app_pid):
        """Whether the app is responsible for a WebKit process (launchd's child, so not by parent). Other
        apps' and iOS simulators' WebKit processes on the host do not count. Without the responsibility
        call on the host, every WebKit process started after the app counts (the old rule); a process the
        call has no answer for is not counted."""
        owner = responsible_pid(pid)
        return owner == app_pid if owner is not None else pid not in self.webkit_before

    def round_trip(self, method):
        """(milliseconds, None) on a good reply, else (milliseconds, (kind, text)): kind "slow" when no reply
        came within --hang-after, "error" for an instant failure (connect refused, a missing socket file, an
        error reply, a closed connection), with the error class and message. A good reply that took --hang-after
        or longer is slow too. An app that stops accepting fills its listen backlog, and macOS then refuses
        a connect at once, so that hang shows as an error (ConnectionRefusedError); it still fails the run."""
        started = time.monotonic()
        try:
            reply = Client(self.socket, timeout=self.args.hang_after).call(method)
            failure = ("error", f"{method}: error reply {json.dumps(reply['error'])[:300]}") if "error" in reply else None
        except (socket.timeout, TimeoutError) as error:
            failure = ("slow", f"{method}: no reply within {self.args.hang_after} s ({type(error).__name__})")
        except (OSError, ValueError) as error:
            failure = ("error", f"{method}: {type(error).__name__}: {error}")
        ms = round((time.monotonic() - started) * 1000, 1)
        if failure is None and ms >= self.args.hang_after * 1000:
            failure = ("slow", f"{method}: reply after {ms} ms")
        return ms, failure

    def check_control(self):
        """One system.ping and one snapshot.get. An instant failure is a control-error event with its text;
        only a reply slower than --hang-after (or none within it) is a hang."""
        ping_ms, ping_failure = self.round_trip("system.ping")
        snapshot_ms, snapshot_failure = self.round_trip("snapshot.get")
        failures = [f for f in (ping_failure, snapshot_failure) if f]
        timing = f"ping {ping_ms} ms, snapshot {snapshot_ms} ms"
        errors = [text for kind, text in failures if kind == "error"]
        if errors:
            self.event("control-error", f"control error: {'; '.join(errors)} ({timing})")
        slow = [text for kind, text in failures if kind == "slow"]
        if slow:
            self.event("hang", f"control round trip slow: {'; '.join(slow)} ({timing})")
        return ping_ms, snapshot_ms

    def crash_reports(self):
        """This copy's crash reports since the soak started (other builds' reports do not count)."""
        found = []
        for path in glob.glob(os.path.expanduser("~/Library/Logs/DiagnosticReports/*.ips")):
            name = os.path.basename(path).lower()
            if any(n in name for n in CRASH_NAMES) and os.path.getmtime(path) >= self.started and self.owns_report(path):
                found.append(path)
        return sorted(found)

    def owns_report(self, path):
        """Whether an .ips names this copy's bundle ID, a PID of this copy or a child of its app. A
        report still being written does not parse yet; it counts on a later tick, once it does."""
        try:
            with open(path, errors="replace") as handle:
                header = json.loads(handle.readline())
                if header.get("bundleID") == self.bundle_id:
                    return True
                body = json.loads(handle.read())
        except (OSError, ValueError):
            return False
        # parentPid: a helper that started and crashed between two ticks (acpmux hosts come and go with turns).
        return body.get("pid") in self.seen_pids or body.get("parentPid") in self.seen_pids | {self.app_pid} - {None}

    def track(self, kinds):
        """Remembers the PIDs whose crash reports are this copy's (not WebKit's: any app's)."""
        self.seen_pids.update(pid for pid, kind in kinds.items() if kind != "webkit")

    def sample(self, before, kinds, wall):
        rows = {}
        for pid, kind in kinds.items():
            first, last = before.get(pid), usage(pid)
            if first is None or last is None:
                continue
            row = rows.setdefault(kind, {"count": 0, "cpu_percent": 0.0, "footprint_mb": 0.0, "wakeups_per_s": 0.0, "fds": 0})
            row["count"] += 1
            row["fds"] += open_fds(pid) or 0
            row["cpu_percent"] += 100.0 * (last[0] - first[0]) / (wall * 1e9)
            row["wakeups_per_s"] += (last[1] - first[1]) / wall
            row["footprint_mb"] += last[2] / 1048576
        return {kind: {k: round(v, 2) if isinstance(v, float) else v for k, v in row.items()} for kind, row in rows.items()}

    def loop(self):
        end = time.monotonic() + self.args.hours * 3600
        # The last --idle seconds are quiet: no new turns, terminals stop printing, so what the app,
        # daemon and acpmux use then is their idle cost.
        quiet_at = end - self.args.idle
        quiet = False
        next_turn = {session: time.monotonic() + i * self.args.turn_every / max(len(self.agents), 1)
                     for i, session in enumerate(self.agents)}
        kinds = self.kinds()
        self.track(kinds)
        seen_reports = set(self.crash_reports())
        before = {pid: usage(pid) for pid in kinds}
        for key in ("app", "daemon", "acpmux"):
            self.pids[key] = sorted(pid for pid, kind in kinds.items() if kind == key)
        tick = time.monotonic()
        while time.monotonic() < end:
            time.sleep(self.args.sample)  # soak script: the sampling interval
            if not quiet and time.monotonic() >= quiet_at:
                quiet = True
                open(self.quiet_file, "w").close()
                self.event("quiet", "no new turns; terminals stop printing")
            wall = time.monotonic() - tick
            tick = time.monotonic()
            processes = self.sample(before, kinds, wall)
            kinds = self.kinds()
            self.track(kinds)
            before = {pid: usage(pid) for pid in kinds}
            for key in ("app", "daemon", "acpmux"):
                pids = sorted(pid for pid, kind in kinds.items() if kind == key)
                if pids != self.pids[key]:
                    self.event("crash" if not pids or key == "app" else "restart", f"{key} pids {self.pids[key]} -> {pids}")
                    self.pids[key] = pids
            reports = set(self.crash_reports())
            for path in sorted(reports - seen_reports):
                self.event("crash", f"crash report {os.path.basename(path)}")
            seen_reports = reports
            ping_ms, snapshot_ms = self.check_control()
            statuses = self.acp.sessions()
            for session, entry in self.agents.items():
                running = statuses.get(session) == "running"
                if entry["started"] is not None and not running:
                    entry["started"], entry["done"] = None, entry["done"] + 1
                if entry["started"] is not None and time.monotonic() - entry["started"] > STUCK_TURN_S:
                    self.event("stuck-turn", f"agent {session} turn {entry['turns']} running for over {STUCK_TURN_S} s")
                    entry["started"] = None
                if not quiet and entry["started"] is None and time.monotonic() >= next_turn[session]:
                    self.prompt(session)
                    next_turn[session] = time.monotonic() + self.args.turn_every
            record = {"at": now_iso(), "elapsed_s": round(time.time() - self.started), "processes": processes,
                      "phase": "quiet" if quiet else "load",
                      "running": sum(e["started"] is not None or statuses.get(session) == "running"
                                     for session, e in self.agents.items()),
                      "ping_ms": ping_ms, "snapshot_ms": snapshot_ms,
                      "turns": sum(e["turns"] for e in self.agents.values()),
                      "turns_done": sum(e["done"] for e in self.agents.values())}
            self.samples.write(json.dumps(record) + "\n")
            self.samples.flush()

    # ---- report --------------------------------------------------------------------------

    def report(self):
        stem = "report"
        if self.samples:
            self.samples.close()
            with open(os.path.join(self.out, "samples.jsonl")) as handle:
                samples = [json.loads(line) for line in handle if line.strip()]
        else:
            samples = []
            if os.path.exists(os.path.join(self.out, "samples.jsonl")):
                stem = "refused"  # --out holds another soak's run; keep its report
        warm = [s for s in samples if s["elapsed_s"] >= self.args.warmup]
        # Idle: quiet samples once every turn has ended and --settle seconds have passed.
        quiet_from = min((s["elapsed_s"] for s in samples if s.get("phase") == "quiet"), default=None)
        idle = [s for s in samples if quiet_from is not None and s["elapsed_s"] >= quiet_from + self.args.settle
                and not s.get("running")]
        # Growth is the middle of the load phase against its end: a bounded buffer (terminal scrollback, 50 MB
        # per copy) that fills in the first half passes, and a steady leak still shows half its growth. Each
        # window is an hour, or a quarter of a shorter load phase.
        load = [s for s in warm if s.get("phase", "load") == "load"]
        span = (load[-1]["elapsed_s"] - load[0]["elapsed_s"]) if load else 0
        window = min(3600, span / 4)
        middle = (load[0]["elapsed_s"] + span / 2) if load else 0
        first = [s for s in load if middle - window / 2 <= s["elapsed_s"] < middle + window / 2]
        last = [s for s in load if s["elapsed_s"] >= load[-1]["elapsed_s"] - window] if load else []
        kinds = sorted({k for s in samples for k in s["processes"]})
        summary, failures, warnings = {}, [], []

        def median(rows, kind, key):
            values = [s["processes"][kind].get(key) for s in rows if kind in s["processes"]]
            values = [v for v in values if v is not None]
            return round(statistics.median(values), 2) if values else None

        def mean(rows, kind, key):
            values = [s["processes"][kind][key] for s in rows if kind in s["processes"]]
            return round(statistics.fmean(values), 2) if values else None

        for kind in kinds:
            cpu = [s["processes"][kind]["cpu_percent"] for s in warm if kind in s["processes"]]
            summary[kind] = {
                "mean_cpu_percent": round(statistics.fmean(cpu), 2) if cpu else None,
                "max_cpu_percent": round(max(cpu), 2) if cpu else None,
                "footprint_mb_mid": median(first, kind, "footprint_mb"),
                "footprint_mb_end": median(last, kind, "footprint_mb"),
                "wakeups_per_s_median": median(warm, kind, "wakeups_per_s"),
                "fds_mid": median(first, kind, "fds"),
                "fds_end": median(last, kind, "fds"),
                "idle_cpu_percent": mean(idle, kind, "cpu_percent"),
                "idle_wakeups_per_s": mean(idle, kind, "wakeups_per_s"),
            }
            row = summary[kind]
            start_mb, end_mb = row["footprint_mb_mid"], row["footprint_mb_end"]
            if start_mb and end_mb and kind in ("app", "daemon", "acpmux"):
                growth = end_mb - start_mb
                row["growth_mb"], row["growth_percent"] = round(growth, 1), round(100 * growth / start_mb, 1)
                if growth > self.args.max_growth_mb and row["growth_percent"] > self.args.max_growth_percent:
                    failures.append(f"{kind} memory grew {growth:.0f} MB ({row['growth_percent']}%) from mid-run to the end of the load")
            start_fds, end_fds = row["fds_mid"], row["fds_end"]
            if start_fds is not None and end_fds is not None and kind in ("app", "daemon", "acpmux"):
                row["fd_growth"] = round(end_fds - start_fds)
                if row["fd_growth"] > self.args.max_fd_growth:
                    failures.append(f"{kind} open fds grew by {row['fd_growth']} ({start_fds:g} -> {end_fds:g}) from mid-run to the end of the load")
        for kind in ("app", "daemon", "acpmux"):
            if samples and kind not in summary:
                failures.append(f"no {kind} process was found, so its checks did not run")
        for kind, limit in (("app", self.args.max_app_cpu), ("daemon", self.args.max_daemon_cpu)):
            mean = (summary.get(kind) or {}).get("mean_cpu_percent")
            if mean is not None and mean > limit:
                failures.append(f"{kind} mean CPU {mean}% over {limit}%")
        if self.args.idle:
            if not idle:
                failures.append("no idle samples (the quiet phase never settled)")
            for kind, limit in (("app", self.args.max_idle_app_cpu), ("daemon", self.args.max_idle_daemon_cpu),
                                ("acpmux", self.args.max_idle_acpmux_cpu)):
                value = (summary.get(kind) or {}).get("idle_cpu_percent")
                if value is not None and value > limit:
                    (failures if self.args.idle_cpu_gate == "fail" else warnings).append(f"{kind} idle CPU {value}% over {limit}%")
        for kind in ("crash", "hang", "control-error", "stuck-turn"):
            count = sum(1 for e in self.events if e["kind"] == kind)
            if count:
                failures.append(f"{count} {kind} event(s)")
        for name in ("terminals", "browsers", "agents"):
            wanted, got = getattr(self.args, name), self.setup.get(name)
            if got != wanted:
                failures.append(f"setup: {got} of {wanted} {name}")
        if self.args.agents and samples and not samples[-1]["turns_done"]:
            failures.append("no agent turn finished")
        if self.setup.get("error"):
            failures = [f"setup stopped: {self.setup['error']}"]  # the rest follow from it
        hours = round((samples[-1]["elapsed_s"] if samples else 0) / 3600, 2)
        if hours < self.args.hours * 0.95:
            failures.append(f"ran {hours} h of {self.args.hours} h")
        pings = sorted(s["snapshot_ms"] for s in samples)
        result = {"ok": not failures, "failures": failures, "warnings": warnings, "hours": hours, "setup": self.setup,
                  "app": self.app, "summary": summary, "events": self.events,
                  "snapshot_ms_p50": pings[len(pings) // 2] if pings else None,
                  "snapshot_ms_p99": pings[int(len(pings) * 0.99)] if pings else None,
                  "turns": samples[-1]["turns"] if samples else 0, "turns_done": samples[-1]["turns_done"] if samples else 0}
        with open(os.path.join(self.out, f"{stem}.json"), "w") as handle:
            json.dump(result, handle, indent=1)
        lines = [f"# cmux-next readiness soak: {'PASS' if result['ok'] else 'FAIL'}", "",
                 f"Build {self.setup.get('identity', {}).get('build')} ({self.setup.get('identity', {}).get('version')}), "
                 f"{hours} h, {self.setup.get('agents')} agents ({result['turns_done']}/{result['turns']} turns done), "
                 f"{self.setup.get('terminals')} terminals, {self.setup.get('browsers')} {self.setup.get('browser_engine', '')} browser tabs.", ""]
        lines += [f"- FAIL: {failure}" for failure in failures] or ["- No failures."]
        lines += [f"- WARN: {warning}" for warning in warnings]
        lines += ["", f"Control round trip (snapshot.get): p50 {result['snapshot_ms_p50']} ms, p99 {result['snapshot_ms_p99']} ms.", "",
                  "| Process | Mean CPU % | Max CPU % | Memory mid-run (MB) | Memory end (MB) | Wakeups/s | fds mid-run | fds end | Idle CPU % | Idle wakeups/s |",
                  "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |"]
        for kind, row in summary.items():
            lines.append(f"| {kind} | {row['mean_cpu_percent']} | {row['max_cpu_percent']} | {row['footprint_mb_mid']} | "
                         f"{row['footprint_mb_end']} | {row['wakeups_per_s_median']} | {row['fds_mid']} | "
                         f"{row['fds_end']} | {row['idle_cpu_percent']} | {row['idle_wakeups_per_s']} |")
        # Trend: memory and fds of the app, daemon and acpmux at about twelve points, so a slow leak shows its slope.
        if samples:
            step = max(1, len(samples) // 12)
            lines += ["", "Trend (memory MB / open fds):", "",
                      "| Elapsed min | Phase | app | daemon | acpmux |", "| --- | --- | --- | --- | --- |"]
            for s in samples[::step] + ([samples[-1]] if (len(samples) - 1) % step else []):
                cells = [f"{s['processes'][k]['footprint_mb']:g} / {s['processes'][k].get('fds')}" if k in s["processes"] else "-"
                         for k in ("app", "daemon", "acpmux")]
                lines.append(f"| {s['elapsed_s'] // 60} | {s.get('phase', 'load')} | " + " | ".join(cells) + " |")
        if self.events:
            lines += ["", "Events:"] + [f"- {e['at']} {e['kind']}: {e['detail']}" for e in self.events]
        with open(os.path.join(self.out, f"{stem}.md"), "w") as handle:
            handle.write("\n".join(lines) + "\n")
        print("\n".join(lines))
        return result

    def quit(self):
        try:
            with open(self.config, "w") as handle:
                json.dump({"app": {"quitBehavior": "end-everything"}}, handle)
            time.sleep(2)  # soak script: the app reloads cmux.json from its file watcher
            pids = [pid for pid, kind in self.kinds().items() if kind == "app"]
            # A remembered End Everything no longer deletes workspaces on a
            # scripted quit (it keeps them); the flag asks for it outright.
            Client(self.socket, timeout=10).call("action.run", {"action": "quit", "args": {"endEverything": True}, "wait": False})
            wait(lambda: not any(run("kill", "-0", str(pid)).returncode == 0 for pid in pids), 90)
        except (OSError, ValueError, KeyError) as error:
            say(f"quit: {error}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", required=True, help="a copy of a tagged cmux-next app (bundle com.cmuxterm.app.debug.<tag>)")
    parser.add_argument("--socket", help="the app's control socket (default ~/.local/state/cmux/cmux-debug-<tag>.sock)")
    parser.add_argument("--same-tag", action="store_true",
                        help="run --app as it is instead of a copy with its own bundle id and tag")
    parser.add_argument("--hours", type=float, default=24)
    parser.add_argument("--agents", type=int, default=10)
    parser.add_argument("--terminals", type=int, default=10)
    parser.add_argument("--browsers", type=int, default=4)
    parser.add_argument("--sample", type=float, default=60)
    parser.add_argument("--turn-every", type=float, default=300)
    parser.add_argument("--warmup", type=float, default=900, help="seconds before the first-hour memory baseline")
    parser.add_argument("--hang-after", type=float, default=10)
    parser.add_argument("--max-growth-mb", type=float, default=300)
    parser.add_argument("--max-growth-percent", type=float, default=25)
    parser.add_argument("--max-app-cpu", type=float, default=10)
    parser.add_argument("--max-daemon-cpu", type=float, default=5)
    parser.add_argument("--max-fd-growth", type=float, default=100,
                        help="open fds the app, daemon or acpmux may gain from mid-run to the end of the load")
    parser.add_argument("--idle", type=float, default=1800,
                        help="seconds at the end with no new turns and quiet terminals (0: none)")
    parser.add_argument("--settle", type=float, default=300, help="seconds into the quiet phase before idle samples count")
    parser.add_argument("--max-idle-app-cpu", type=float, default=1)
    parser.add_argument("--max-idle-daemon-cpu", type=float, default=0.5)
    parser.add_argument("--max-idle-acpmux-cpu", type=float, default=0.5)
    parser.add_argument("--idle-cpu-gate", choices=("warn", "fail"), default="warn",
                        help="an idle CPU over its limit warns (default, until a 24h report shows real idle numbers) or fails")
    parser.add_argument("--out", default=os.path.join(os.getcwd(), "readiness-soak"))
    args = parser.parse_args()
    if args.warmup + args.idle >= args.hours * 3600:
        parser.error("--warmup plus --idle must leave a load phase within --hours")  # else every load check is empty
    soak = Soak(args)
    teardown = None
    result = {"ok": False}
    try:
        soak.identify()
        soak.preflight()
        soak.begin()
        teardown = TagTeardown(soak.app, acpmux_home=soak.acpmux_home, acpmux_socket=soak.acp.path, log=say)
        teardown.install()
        soak.launch()
        soak.start_terminals()
        soak.start_browsers()
        soak.start_agents()
        say(f"setup: {json.dumps(soak.setup)}")
        soak.stage = "run"
        soak.loop()
    except SystemExit as stop:
        if soak.stage == "setup":
            # A refused or failed setup still writes report.json and report.md, naming why.
            soak.setup["error"] = str(stop.code)
        else:
            soak.event("stopped", f"the soak was stopped ({stop.code}); the report covers what ran")
        raise
    finally:
        try:
            result = soak.report()
        finally:
            if "identity" in soak.setup:
                soak.quit()
            if teardown:
                teardown.end()
                soak.forget()
            shutil.rmtree(soak.work, ignore_errors=True)
    sys.exit(0 if result.get("ok") else 1)


if __name__ == "__main__":
    main()
