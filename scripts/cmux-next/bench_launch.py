#!/usr/bin/env python3
"""One launch path for every GUI bench and live script: start a tagged `cmux DEV <tag>.app`, wait for its
control socket to answer, and say exactly why when it does not.

Why one helper: each bench copied its own launch, and the copies drifted. So far five scripts launch through it
(split-spring-terminal.py's default suite, tab-switch-stages.py, palette-open-stages.py,
instant-new-surfaces-bench.py, omnibar-click-bench.py); pane-perf-terminal, app-perf, anim-perf-terminal,
typing-frame-bench, every-action-sweep, sidebar-churn-typing, perf-gate, bench-startup and the perf-budgets
sub-benches still launch on their own (/tmp socket, no failure reason): moving them is open. A tagged build keeps its socket in
the account's state folder (`~/.local/state/cmux/cmux-debug-<tag>.sock`, with a `/tmp/cmux-debug-<tag>.sock`
link; `/tmp` only when the path is too long for `sun_path`), and `~` there is the account's home from the
password database, not `$HOME` (a fleet step's HOME is a scratch folder). A launch also needs the bench
environment below, and a GUI login session of this account on the console: from SSH or a fleet worker
(which runs its steps over SSH as the worker account) an app whose account is not the console user gets no
working session: its display does not tick (frame numbers mean nothing), and the made-ahead open panel
blocked its main thread about 40 s on ViewBridge (`HostCallsAuxiliary: Connection interrupted`), so the
socket often never answered, then crashed it (MadeAheadOpenPanel; the crash fixed in c41e7e7296a, and the
warm-up runs only when this account is the console user, and never again after a dead panel, since the
review-pl-fleet-gui fixes). Found on the AWS measure workers 2026-10-23, where only aws-m4pro-9 had ec2-user on
the console.

The session rule (the same as the hq worker gate, build-fleet console_session.go readConsoleUser, and the app's
open-panel warm-up, CmuxNextDesign OpenPanelWarmGate; change all three together): the console user is the `Name` of SCDynamicStore `State:/Users/ConsoleUser` (`scutil`); `loginwindow`,
no such key, or no answer at all means nobody, and the check fails closed. This account has a GUI session only
when it is that user. A locked screen is reported (`screen_locked`, from IOConsoleUsers) but does not fail the
check.
`launch()` checks the session first and raises LaunchError("no-gui-session") at once
(BENCH_LAUNCH_ANY_SESSION=1 launches anyway, for socket-only checks); every other failure gets its reason
after the wait.

On the fleet: `scripts/measure/split-spring.sh --suite=launch-check` builds the app and runs `check` below (with no
session `check` itself reports no-gui-session; the build has run by then, only the launch timeout is saved).

Use from a bench:

    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from bench_launch import BenchApp, LaunchError
    app = BenchApp(opts.app, out=opts.out, env={"CMUX_NEXT_TYPING_PROBE": probe})
    try:
        app.launch()                      # raises LaunchError (a SystemExit) with the reason and the log tail
        app.rpc("debug.windows")
    finally:
        app.stop()                        # debug.quit, then the tag's daemons (tag_teardown.py)

Check a host by hand or from a fleet step (exit 0 when the socket answered and a window is up; one
`BENCH-LAUNCH {json}` line either way):

    python3 scripts/cmux-next/bench_launch.py check --app "/path/cmux DEV <tag>.app" [--out DIR] [--timeout 180]
    python3 scripts/cmux-next/bench_launch.py session    # only the GUI session check, no app
"""
import argparse, glob, json, os, platform, pwd, re, signal, socket, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))

# Variables a bench launch always gets. SHELL: the daemon starts terminals with it (a step has none).
# CMUX_DEV_BACKEND_MODE: local backend for a DEV build (no dev web server on a fleet host).
# CMUX_NEXT_AGENT_PANE_MOCK: the agent pane needs no agent login. NO_ACTIVATE: never take focus.
# SOCKET_MODE automation: a process of the same account (this script) may connect.
# CHIEF_ISOLATED: the launch never touches the account's Chief state. ACPMUX_AGENT_LAUNCH deny: no real agent.
BASE_ENV = {
    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
    "SHELL": "/bin/zsh",
    "CMUX_DEV_BACKEND_MODE": "local",
    "CMUX_NEXT_AGENT_PANE_MOCK": "1",
    "CMUX_NEXT_NO_ACTIVATE": "1",
    "CMUX_NEXT_SOCKET_MODE": "automation",
    "CMUX_NEXT_CHIEF_ISOLATED": "1",
    "ACPMUX_AGENT_LAUNCH": "deny",
}
# Never passed to the app: NX_REMOTE makes it act as an nx-remote job; the rest name another cmux.
DROPPED_ENV = ("NX_REMOTE", "CMUX_SOCKET_PATH", "CMUX_SOCKET", "CMUX_TAG", "CMUX_BUNDLE_ID", "CMUX_WORKSPACE_ID",
               "CMUX_SURFACE_ID", "CMUX_PANEL_ID", "CMUX_TAB_ID")


class LaunchError(SystemExit):
    """The app did not come up. `reason` is one short code; str() is the full report."""

    def __init__(self, reason, report):
        self.reason = reason
        self.report = report
        super().__init__(f"bench-launch: {reason}: {report.get('detail', '')}\n{report.get('log_tail', '')}")


def note(text):
    print(text, flush=True)


def account_home():
    """The home the app resolves (`FileManager.homeDirectoryForCurrentUser`): the password database's."""
    try:
        return pwd.getpwuid(os.getuid()).pw_dir
    except KeyError:
        return os.path.expanduser("~")


def tag_of(app):
    name = os.path.basename(os.path.realpath(app).rstrip("/"))
    match = re.fullmatch(r"cmux DEV (.+)\.app", name)
    if not match:
        raise SystemExit(f"bench-launch: expected a `cmux DEV <tag>.app` bundle, got {name}")
    return re.sub(r"[^a-z0-9]+", "-", match.group(1).lower()).strip("-")


def socket_candidates(tag):
    """Where a tagged DEV build's control socket can be, most likely first (ControlSocketPath.swift)."""
    name = f"cmux-debug-{tag}.sock"
    paths = [os.path.join(account_home(), ".local/state/cmux", name), f"/tmp/{name}"]
    home = os.environ.get("HOME")
    if home and os.path.join(home, ".local/state/cmux", name) not in paths:
        paths.append(os.path.join(home, ".local/state/cmux", name))
    return paths


def rpc_at(path, method, params=None, timeout=60):
    """One newline-JSON request on the control socket; the result, or {"error": ..., "unreachable": bool}."""
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
        conn.connect(path)
        conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = conn.recv(1 << 22)
            if not chunk:
                break
            buf += chunk
        conn.close()
        reply = json.loads(buf)
    except (OSError, ValueError) as error:
        return {"error": str(error), "unreachable": True}
    return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}


def socket_in_use(path):
    """Whether a process accepts connections on the socket at `path`. Only a refused connect (nothing listens) or a
    missing file (a dangling link) is free: a socket that accepts but answers slowly (a busy main thread, a long
    restore, the ViewBridge block above) belongs to a live app, and any other error (permissions) is treated as in
    use too, so a probe never unlinks a live app's socket."""
    conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    conn.settimeout(2)
    try:
        conn.connect(path)
    except (ConnectionRefusedError, FileNotFoundError):
        return False
    except OSError:
        return True
    finally:
        conn.close()
    return True


def unique_paths(paths):
    """`paths` with the ones that resolve to the same file dropped (the state-folder socket and its /tmp link)."""
    seen, out = set(), []
    for path in paths:
        real = os.path.realpath(path)
        if real not in seen:
            seen.add(real)
            out.append(path)
    return out


def console_user():
    """The user logged in on the console (SCDynamicStore State:/Users/ConsoleUser), or None at the login window.

    Not /dev/console's owner (it reads root on a mini whose cmux session is up) and not `who` (it keeps console
    lines of sessions that ended or went to the background)."""
    try:
        out = subprocess.run(["/usr/sbin/scutil"], input="show State:/Users/ConsoleUser\n", capture_output=True,
                             text=True, timeout=10).stdout
    except (OSError, subprocess.TimeoutExpired):
        out = ""
    match = re.search(r"^\s*Name : (\S+)", out, re.M)
    if match:
        return None if match.group(1) == "loginwindow" else match.group(1)
    # No such key, a dictionary with no name, or no answer at all: nobody, fail closed like the hq worker gate (not
    # /dev/console's owner, which disagrees with scutil).
    return None


def screen_locked(user):
    """Whether `user`'s console session has its screen locked (IOConsoleUsers CGSSessionScreenIsLocked), None
    when ioreg does not say. Reported only: the session rule does not use it."""
    try:
        import plistlib
        out = subprocess.run(["/usr/sbin/ioreg", "-n", "Root", "-d1", "-a"], capture_output=True, timeout=10).stdout
        root = plistlib.loads(out)
    except Exception:  # ioreg missing, timed out or not a plist: unknown
        return None
    if isinstance(root, list):
        root = root[0] if root else {}
    for entry in root.get("IOConsoleUsers") or []:
        if entry.get("kCGSSessionUserNameKey") == user and entry.get("kCGSSessionOnConsoleKey"):
            return bool(entry.get("CGSSessionScreenIsLocked", False))
    return None


def gui_session():
    """Whether an app this account starts gets a GUI session: the console user must be this account.

    Nobody on the console is the login window (or no answer); another name is someone else's session.
    """
    me = pwd.getpwuid(os.getuid()).pw_name
    console = console_user()
    ok = console == me
    if ok:
        detail = f"{me} is the console user"
    elif console is None:
        detail = f"nobody is logged in on the console (login window); {me} has no GUI session"
    else:
        detail = f"the console session belongs to {console}, not {me}; {me}'s apps get no working GUI session"
    locked = screen_locked(me) if ok else None
    if locked:
        detail += " (its screen is locked: frames may not be comparable)"
    return {"ok": ok, "user": me, "console_user": console, "screen_locked": locked, "detail": detail}


def no_session_detail(session):
    return (f"{session['detail']}. Log {session['user']} in on the console (auto-login, or Screen Sharing as "
            f"{session['user']}), or run GUI steps only on hosts where it is the console user")


def require_gui_session(who="bench", argv=None):
    """Exits 1 at once, with one BENCH-LAUNCH line (and the --json report when argv names one), when this
    account has no GUI session; BENCH_LAUNCH_ANY_SESSION=1 skips the check."""
    session = gui_session()
    if session["ok"] or os.environ.get("BENCH_LAUNCH_ANY_SESSION"):
        return session
    argv = sys.argv[1:] if argv is None else argv
    report = {"ok": False, "reason": "no-gui-session", **host_facts(), "gui_session": session,
              "detail": no_session_detail(session)}
    note(f"{who}: no-gui-session: {report['detail']}")
    note("BENCH-LAUNCH " + json.dumps(report))
    path = next((a.split("=", 1)[1] for a in argv if a.startswith("--json=")), None)
    if path is None and "--json" in argv and argv.index("--json") + 1 < len(argv):
        path = argv[argv.index("--json") + 1]
    if path:
        try:
            with open(path, "w") as f:
                json.dump({"error": f"no-gui-session: {report['detail']}", "launch": report}, f, indent=1)
        except OSError:
            pass
    sys.exit(1)


def host_facts():
    macos = subprocess.run(["sw_vers", "-productVersion"], capture_output=True, text=True).stdout.strip()
    return {"host": platform.node(), "macos": macos}


def report_matches(path, pid=None, binary=None):
    """Whether the crash or hang report at `path` is of process `pid` or of the executable `binary` (another tag's
    app on the same host writes `cmux DEV*` reports too). No filter given: every report matches."""
    if pid is None and binary is None:
        return True
    try:
        text = open(path, errors="replace").read()
    except OSError:
        return False
    if text.lstrip().startswith("{"):  # .ips: a JSON header line, then the JSON body with pid and procPath
        try:
            body = json.loads(text.split("\n", 1)[1])
            if pid is not None and body.get("pid") == pid:
                return True
            return binary is not None and os.path.realpath(body.get("procPath") or "") == os.path.realpath(binary)
        except (ValueError, IndexError):
            pass
    # Text reports: "Process: name [pid]" and "Path: /path/to/binary".
    if pid is not None and re.search(rf"^\s*Process:\s.*\[{pid}\]", text, re.M):
        return True
    return binary is not None and re.search(rf"^\s*Path:\s+{re.escape(binary)}\s*$", text, re.M) is not None


def crash_reports(since, name="cmux DEV", pid=None, binary=None):
    """Crash and hang reports of the app written after `since` (epoch seconds); with `pid` or `binary`, only
    those of that process or executable."""
    found = []
    for folder in (os.path.join(account_home(), "Library/Logs/DiagnosticReports"), "/Library/Logs/DiagnosticReports"):
        for path in glob.glob(os.path.join(folder, f"{name}*")):
            try:
                if os.path.getmtime(path) >= since and report_matches(path, pid, binary):
                    found.append(path)
            except OSError:
                pass
    return sorted(found, key=os.path.getmtime)


def crash_summary(path, lines=40):
    try:
        text = open(path, errors="replace").read()
    except OSError:
        return ""
    if text.lstrip().startswith("{"):  # .ips: a JSON header line, then the JSON body
        try:
            body = json.loads(text.split("\n", 1)[1])
            exc = body.get("exception", {})
            term = body.get("termination", {})
            return json.dumps({"exception": exc, "termination": {k: term.get(k) for k in ("namespace", "indicator", "reasons")},
                               "asi": body.get("asi")})[:3000]
        except (ValueError, IndexError):
            pass
    return "\n".join(text.splitlines()[:lines])


class BenchApp:
    """A tagged DEV app launched for a bench, its socket, and its teardown.

    `env` adds to (and overrides) BASE_ENV; `config` is written as the app's cmux.json; `window` is
    (x, y, width, height) or None; `screen` is CMUX_NEXT_TEST_WINDOW_SCREEN (`0` = the main display).
    """

    def __init__(self, app, out=None, env=None, config=None, window=(40, 40, 1440, 900), screen="0",
                 log_name=None, teardown=True):
        self.app = os.path.realpath(app).rstrip("/")
        self.tag = tag_of(self.app)
        self.out = os.path.abspath(out or tempfile.mkdtemp(prefix=f"bench-launch-{self.tag}-"))
        os.makedirs(self.out, exist_ok=True)
        self.scratch = tempfile.mkdtemp(prefix=f"bench-{self.tag}-")
        self.extra_env = dict(env or {})
        self.config = {"appearance": {"backgroundOpacity": 1}} if config is None else config
        self.window, self.screen = window, screen
        self.log_path = os.path.join(self.out, log_name or f"app-{self.tag}.log")
        self.process = None
        self.socket = socket_candidates(self.tag)[0]
        self.launched_at = None
        self.ready_seconds = None
        self.teardown = None
        if teardown:
            sys.path.insert(0, HERE)
            from tag_teardown import TagTeardown
            self.teardown = TagTeardown(self.app)

    @property
    def binary(self):
        main = os.path.join(self.app, "Contents/MacOS/cmux DEV")
        if os.path.exists(main):
            return main
        found = [p for p in sorted(glob.glob(os.path.join(self.app, "Contents/MacOS/*"))) if not p.endswith(".dylib")]
        if not found:
            raise SystemExit(f"bench-launch: no executable in {self.app}/Contents/MacOS")
        return found[0]

    def running_pids(self):
        """PIDs of processes running an executable of this bundle (another run of the same app)."""
        out = subprocess.run(["ps", "-axo", "pid=,command="], capture_output=True, text=True).stdout
        prefix = self.app + "/Contents/MacOS/"
        pids = []
        for line in out.splitlines():
            pid, _, command = line.strip().partition(" ")
            if command.lstrip().startswith(prefix) and pid.isdigit() and int(pid) != os.getpid():
                pids.append(int(pid))
        return pids

    @property
    def cli(self):
        return os.path.join(self.app, "Contents/Resources/bin/cmux")

    def environment(self):
        config_path = os.path.join(self.scratch, "cmux.json")
        with open(config_path, "w") as f:
            json.dump(self.config, f)
        ghostty = os.path.join(self.scratch, "ghostty")
        open(ghostty, "a").close()
        env = {"HOME": os.environ.get("HOME", account_home()), "USER": pwd.getpwuid(os.getuid()).pw_name,
               "TMPDIR": os.environ.get("TMPDIR", "/tmp"), **BASE_ENV,
               "CMUX_NEXT_CONFIG_FILE": config_path, "CMUX_NEXT_GHOSTTY_CONFIG": ghostty,
               "CMUX_NEXT_CHIEF_HOME": os.path.join(self.scratch, "chief")}
        if self.window:
            env["CMUX_NEXT_TEST_WINDOW_FRAME"] = ",".join(str(v) for v in self.window)
        if self.screen is not None:
            env["CMUX_NEXT_TEST_WINDOW_SCREEN"] = str(self.screen)
        env.update(self.extra_env)
        for key in DROPPED_ENV + tuple(k for k, v in self.extra_env.items() if v is None):
            env.pop(key, None)  # None in `env` removes a BASE_ENV variable (for example NO_ACTIVATE)
        return env

    def rpc(self, method, params=None, timeout=60):
        return rpc_at(self.socket, method, params, timeout)

    def launch(self, timeout=180, ready="debug.windows", settle=0.0, on_start=None):
        """Starts the app and returns once `ready` answers (debug.windows: with a window).

        `on_start(process)` runs right after the spawn (a script's own PID list for its cleanup). On a
        failure the report is printed to stdout (a fleet step log is stdout only), then LaunchError is raised.
        """
        session = gui_session()
        if not session["ok"] and not os.environ.get("BENCH_LAUNCH_ANY_SESSION"):
            # Without the console session the display does not tick and the open-panel warm-up blocks the main
            # thread ~40 s; say so now instead of after the timeout. BENCH_LAUNCH_ANY_SESSION=1 tries anyway.
            self._fail("no-gui-session", {"tag": self.tag, **host_facts(), "gui_session": session,
                                          "detail": no_session_detail(session), "log_tail": ""})
        running = self.running_pids()
        if running:
            self._fail("tag-in-use", {"tag": self.tag, **host_facts(), "pids": running, "log_tail": "",
                                      "detail": f"an app of {self.app} already runs (pid {', '.join(map(str, running))}); "
                                                "quit it or pick a fresh tag"})
        for path in socket_candidates(self.tag):
            if os.path.lexists(path) and not os.path.isdir(path):
                if socket_in_use(path):
                    # Another app of this tag (another bundle path) accepts there, maybe slowly: never cut it off.
                    self._fail("tag-in-use", {"tag": self.tag, **host_facts(), "socket": path, "log_tail": "",
                                              "detail": f"an app of tag {self.tag} accepts on {path}; quit it or pick a fresh tag"})
                os.unlink(path)  # nothing listens: a socket a killed run of this tag left; the app makes it again
        if self.teardown:
            self.teardown.install()
        log = open(self.log_path, "a")
        self.launched_at = time.time()
        self.process = subprocess.Popen([self.binary], env=self.environment(), stdout=log, stderr=log,
                                        stdin=subprocess.DEVNULL)
        note(f"bench-launch: {self.tag} pid {self.process.pid}")
        if on_start:
            on_start(self.process)
        start = time.monotonic()
        deadline = start + timeout
        last = None
        while time.monotonic() < deadline:  # bounded poll of the socket of the app this script started
            if self.process.poll() is not None:
                break
            # The state-folder socket and its /tmp link are one socket: probe it once, and never past the deadline.
            for path in unique_paths(p for p in socket_candidates(self.tag) if os.path.exists(p)):
                left = deadline - time.monotonic()
                if left <= 0:
                    break
                self.socket = path
                last = rpc_at(path, ready, timeout=min(10, left))
                if isinstance(last, dict) and not last.get("error") and (ready != "debug.windows" or last.get("windows")):
                    self.ready_seconds = round(time.monotonic() - start, 2)
                    note(f"bench-launch: {self.tag} answered on {path} after {self.ready_seconds} s")
                    if settle:
                        time.sleep(settle)  # bench: launch work (restore, first pages) ends before a measure
                    return self
            time.sleep(0.25)  # the poll interval
        log.flush()
        self._fail(*self.diagnose(last, timeout))

    @staticmethod
    def _fail(reason, report):
        error = LaunchError(reason, report)
        note(str(error))
        note("BENCH-LAUNCH " + json.dumps({"ok": False, "reason": reason,
                                            **{k: v for k, v in report.items() if k != "log_tail"}}))
        raise error

    def diagnose(self, last, timeout):
        """(reason, report) for a launch that did not answer."""
        session = gui_session()
        sockets = {p: os.path.exists(p) for p in socket_candidates(self.tag)}
        exit_code = self.process.poll() if self.process else None
        report = {"tag": self.tag, **host_facts(), "pid": self.process.pid if self.process else None, "exit": exit_code,
                  "sockets": sockets, "last_reply": last, "gui_session": session, "log": self.log_path}
        crashes = self.wait_for_crash_report(exit_code)
        if crashes:
            report["crash_report"] = crashes[-1]
            report["crash"] = crash_summary(crashes[-1])
        ended = f"the app ended (exit {exit_code}) before its socket answered" + \
                (f"; crash report {crashes[-1]}" if crashes else "") if exit_code is not None else None
        if not session["ok"]:
            reason = "no-gui-session"
            report["detail"] = no_session_detail(session) + (f"; {ended}" if ended else "")
        elif ended:
            reason = "crashed" if crashes or exit_code < 0 else "exited"
            report["detail"] = ended
        elif not any(sockets.values()):
            reason = "no-socket"
            report["detail"] = f"no control socket after {timeout} s at {', '.join(sockets)} (still running)"
        else:
            reason = "socket-silent"
            report["detail"] = f"the socket exists but `debug.windows` gave {json.dumps(last)[:300]} after {timeout} s"
        if exit_code is None and self.process:
            report["main_thread"] = self.sample_main_thread()
        try:
            report["log_tail"] = open(self.log_path, errors="replace").read()[-4000:]
        except OSError:
            report["log_tail"] = ""
        return reason, report

    def wait_for_crash_report(self, exit_code, wait=10):
        """This launch's crash and hang reports. After a signal exit (exit < 0) ReportCrash writes the .ips a few
        seconds after the process ends, so this waits up to `wait` seconds for one; otherwise it reads once."""
        if not self.launched_at:
            return []
        pid = self.process.pid if self.process else None
        deadline = time.monotonic() + (wait if exit_code is not None and exit_code < 0 else 0)
        while True:
            found = crash_reports(self.launched_at - 1, pid=pid, binary=self.binary)
            if found or time.monotonic() >= deadline:
                return found
            time.sleep(0.5)  # bounded wait for ReportCrash, which gives no signal when it is done

    def sample_main_thread(self, seconds=2):
        path = os.path.join(self.out, f"sample-launch-{self.tag}.txt")
        try:
            subprocess.run(["/usr/bin/sample", str(self.process.pid), str(seconds), "-file", path],
                           capture_output=True, timeout=60)
            text = open(path, errors="replace").read()
        except (OSError, subprocess.TimeoutExpired):
            return None
        graph = text.split("Call graph:", 1)[-1].splitlines()
        main = [l for l in graph[:60] if l.strip()]
        return "\n".join(l.rstrip()[:180] for l in main[:40])

    def stop(self, quit_timeout=30):
        """Quits the app (debug.quit, then TERM and KILL of its own PID) and ends the tag's daemons.

        Nothing when this BenchApp started no app (launch() refused: no-gui-session, tag-in-use): the bundle's
        processes are then another run's, and the teardown would end that live app and its daemons."""
        if self.process is None:
            return
        try:
            if self.process and self.process.poll() is None:
                self.rpc("debug.quit", {"fixture_quit": "end-sessions"}, timeout=10)
                try:
                    self.process.wait(quit_timeout)
                except subprocess.TimeoutExpired:
                    self.process.terminate()  # the PID this script started
                    try:
                        self.process.wait(15)
                    except subprocess.TimeoutExpired:
                        self.process.kill()
        finally:
            if self.teardown:
                self.teardown.end()


def main(argv=None):
    parser = argparse.ArgumentParser(description="Launch-and-socket check of a tagged cmux DEV app.")
    sub = parser.add_subparsers(dest="command", required=True)
    check = sub.add_parser("check", help="launch the app, wait for its socket and a window, quit it")
    check.add_argument("--app", required=True)
    check.add_argument("--out")
    check.add_argument("--timeout", type=float, default=180)
    check.add_argument("--json", help="also write the result here")
    sub.add_parser("session", help="only report whether this account has a GUI session")
    opts = parser.parse_args(argv)
    if opts.command == "session":
        result = {**host_facts(), "gui_session": gui_session()}
        print("BENCH-LAUNCH " + json.dumps(result), flush=True)
        return 0 if result["gui_session"]["ok"] else 1
    app = BenchApp(opts.app, out=opts.out)
    result = {"tag": app.tag, **host_facts(), "gui_session": gui_session()}
    try:
        app.launch(timeout=opts.timeout)
        windows = app.rpc("debug.windows")
        result.update(ok=True, socket=app.socket, ready_seconds=app.ready_seconds,
                      windows=len((windows or {}).get("windows") or []))
    except LaunchError as error:
        result.update(ok=False, reason=error.reason, **{k: v for k, v in error.report.items() if k not in result})
    finally:
        app.stop()
    line = json.dumps({k: v for k, v in result.items() if k != "log_tail"})
    if result.get("ok"):
        print("BENCH-LAUNCH " + line, flush=True)
    if opts.json:
        with open(opts.json, "w") as f:
            f.write(line + "\n")
    return 0 if result.get("ok") else 1


if __name__ == "__main__":
    sys.exit(main())
