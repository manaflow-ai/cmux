#!/usr/bin/env python3
"""One launch path for every GUI bench and live script: start a tagged `cmux DEV <tag>.app`, wait for its
control socket to answer, and say exactly why when it does not.

Why one helper: each bench copied its own launch, and the copies drifted. The benches that import BenchApp or
``launch_app`` launch through it (`git grep -l bench_launch scripts/cmux-next`); bench-startup and home-perf take
its socket paths, session check and launch limits, and pane-perf-terminal, typing-frame-bench, sidebar-churn-typing,
bench_idle, perf-gate and the perf-budgets sub-benches still launch on their own: moving them is open. A tagged build keeps its socket in
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
the console. The warm-up has no deadline: AppKit makes an NSOpenPanel only on the main thread and cannot ask its view
service first, so an app of the console user whose panel service hangs still blocks its main thread once, up to
about 40 s (open; plans/cmux-next/picker.md).

The session rule (the same as the hq worker gate, build-fleet console_session.go readConsoleUser, and the app's
open-panel warm-up, CmuxNextDesign OpenPanelWarmGate; change all three together): the console user is the `Name` of SCDynamicStore `State:/Users/ConsoleUser` (`scutil`); `loginwindow`,
no such key, or no answer at all means nobody, and the check fails closed. This account has a GUI session only
when it is that user. A locked screen is reported (`screen_locked`, from IOConsoleUsers) but does not fail the
check.
`launch()` checks the session first and raises LaunchError("no-gui-session") at once; every other failure gets its
reason after the wait. Nothing in the environment turns the check off. The one launch without a session is a
socket-only check (`BenchApp(..., socket_only=True)`, `check --socket-only`): it reads only the socket and the window
list, never a frame, and every report it writes carries `socket_only: true` and its `gui_session`. A bench that
measures frames never passes it. Tests inject the session read (`BenchApp(..., session=...)`).

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
    python3 scripts/cmux-next/bench_launch.py check --socket-only --app ...   # also with no GUI session; no frames
    python3 scripts/cmux-next/bench_launch.py session    # only the GUI session check, no app

Resource limits: an app opened from Finder or the Dock gets launchd's limits (`launchctl limit`; on the fleet
minis the soft open-file limit is 256), but an app a script starts inherits the script's, and fleet job shells
raise theirs (the cmux-ci worker to 65536 for every job, the hosts' ~/.zshenv to 65536 for nx-remote jobs). A
bench at 65536 hid a Chromium crash that happens at 256 (cmux-lawrence-2, 2026-10-23). So `launch()` starts the
app with launchd's soft limits (``finder_limits``; the hard limits stay); BENCH_LAUNCH_LIMITS=inherit keeps the
caller's. A script or step that starts an app on its own can run under the same limits:

    python3 scripts/cmux-next/bench_launch.py finder-exec -- python3 scripts/cmux-next/my-bench.py ...
    python3 scripts/cmux-next/bench_launch.py limits     # launchd's soft limits and this shell's, one JSON line
"""
import argparse, atexit, contextlib, glob, json, os, platform, plistlib, pwd, re, resource, select, shutil, signal, socket, subprocess, sys, tempfile, time

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


# `launchctl limit` rows -> setrlimit resources. launchctl prints bytes, seconds and counts, as setrlimit takes them.
LAUNCHD_LIMITS = {"cpu": resource.RLIMIT_CPU, "filesize": resource.RLIMIT_FSIZE, "data": resource.RLIMIT_DATA,
                  "stack": resource.RLIMIT_STACK, "core": resource.RLIMIT_CORE, "rss": resource.RLIMIT_RSS,
                  "memlock": resource.RLIMIT_MEMLOCK, "maxproc": resource.RLIMIT_NPROC,
                  "maxfiles": resource.RLIMIT_NOFILE}


def launchd_soft_limits(text=None):
    """{name: soft limit} that launchd gives the apps it starts (a Finder or Dock launch), from `launchctl limit`
    (or `text`, its output); resource.RLIM_INFINITY for unlimited. {} when launchctl does not answer."""
    if text is None:
        try:
            text = subprocess.run(["/bin/launchctl", "limit"], capture_output=True, text=True, timeout=10).stdout
        except (OSError, subprocess.TimeoutExpired):
            return {}
    limits = {}
    for line in text.splitlines():
        parts = line.split()
        if len(parts) == 3 and parts[0] in LAUNCHD_LIMITS:
            soft = parts[1]
            if soft == "unlimited":
                limits[parts[0]] = resource.RLIM_INFINITY
            elif soft.isdigit():
                limits[parts[0]] = int(soft)
    return limits


def shown(value):
    return "unlimited" if value == resource.RLIM_INFINITY else value


@contextlib.contextmanager
def finder_limits(text=None):
    """Runs the block with this process's soft limits set to launchd's (``launchd_soft_limits``), so a process
    started inside it gets what a Finder launch gets; restores them after. Hard limits stay (a soft limit above
    this process's hard limit is capped at it). The limits are the whole process's while the block runs: start
    only the app inside it, not from other threads.

    Yields {name: [before, now]} for each changed limit, or None when nothing was applied: BENCH_LAUNCH_LIMITS=inherit,
    or `launchctl limit` did not answer (``limits_line`` says which). Raises ``LaunchError`` ("caller-fds") when this
    process already holds as many open files as launchd's maxfiles: the spawn itself would fail with EMFILE."""
    if os.environ.get("BENCH_LAUNCH_LIMITS") == "inherit":
        yield None
        return
    launchd = launchd_soft_limits(text)
    if not launchd:
        yield None
        return
    changed, saved = {}, []
    try:
        for name, soft in launchd.items():
            res = LAUNCHD_LIMITS[name]
            before, hard = resource.getrlimit(res)
            want = soft if hard == resource.RLIM_INFINITY or soft != resource.RLIM_INFINITY and soft <= hard else hard
            if want == before:
                continue
            if res == resource.RLIMIT_NOFILE and want != resource.RLIM_INFINITY:
                held = len(os.listdir("/dev/fd"))
                if held + 8 >= want:
                    raise LaunchError("caller-fds", {"detail": f"this process holds {held} open files, about launchd's "
                                                               f"maxfiles {want}: close files before the launch",
                                                     "log_tail": ""})
            try:
                resource.setrlimit(res, (want, hard))
            except (OSError, ValueError):
                continue  # the kernel refused (for example maxfiles above kern.maxfilesperproc): keep the limit
            saved.append((res, before, hard))
            changed[name] = [shown(before), shown(want)]
        yield changed
    finally:
        for res, before, hard in reversed(saved):
            resource.setrlimit(res, (before, hard))


def limits_line(changed):
    """One line for a log: the limits a process started inside ``finder_limits`` got (`changed`, what it yielded)."""
    if changed is None:
        return ("the caller's (BENCH_LAUNCH_LIMITS=inherit)" if os.environ.get("BENCH_LAUNCH_LIMITS") == "inherit"
                else "the caller's (launchctl limit did not answer: NOT a Finder launch's)")
    if not changed:
        return "launchd's (the caller's were the same)"
    return "launchd's: " + ", ".join(f"{k} {v[1]} (caller {v[0]})" for k, v in changed.items())


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


def bundle_id(app):
    """The app's own bundle id (Info.plist): `scripts/reload.sh --tag split-spring` makes
    `com.cmuxterm.app.debug.split.spring`, not `...debug.split-spring`, so a script never builds it from the tag."""
    import plistlib
    try:
        with open(os.path.join(os.path.realpath(app), "Contents/Info.plist"), "rb") as f:
            return plistlib.load(f).get("CFBundleIdentifier")
    except (OSError, ValueError):
        return None


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


def require_gui_session(who="bench", argv=None, session=None):
    """Exits 1 at once, with one BENCH-LAUNCH line (and the --json report when argv names one), when this
    account has no GUI session. `session` reads the session (default ``gui_session``; tests pass their own)."""
    session = (session or gui_session)()
    if session["ok"]:
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
    return {"host": platform.node(), "macos": macos, "low_power_mode": low_power_mode()}


# Low Power Mode (2026-10-23): a Mac in Low Power Mode runs slower clocks and caps frame rates, so a bench there
# measures wrong numbers. `launch()` refuses ("low-power-mode") unless the bench passes low_power_mode_ok=True (a
# bench of the Low Power Mode behavior itself). Such a bench switches it with ``LowPowerModeSwitch``: only in an
# exclusive fleet step (a system setting of a shared Mac, `sudo -n pmset`), and it switches it back at exit, SIGTERM
# and SIGHUP. The switch writes a record (the value before it) under the account's state folder; while the record
# says a switch is not proved undone and Low Power Mode differs from its value before, every launch is refused
# ("low-power-mode-not-restored"). BENCH_LAUNCH_PMSET and BENCH_LAUNCH_LPM_MARKER replace pmset and the record's
# path, and BENCH_LAUNCH_TEST_NO_SUDO runs pmset without sudo (tests only).

# Sound (2026-10-23): a bench app on a fleet Mac played a video's sound out loud in a shared room. `launch()` mutes
# this account's sound output first (`osascript set volume with output muted`; a mute, not a volume change, so the
# owner's level stays) and `stop()` checks it is still muted. BENCH_LAUNCH_AUDIO=keep leaves the output as it is (a
# bench of sound itself); BENCH_LAUNCH_OSASCRIPT replaces osascript (tests only).

def osascript_path():
    return os.environ.get("BENCH_LAUNCH_OSASCRIPT") or "/usr/bin/osascript"


def output_muted():
    """True or False: whether this account's sound output is muted; None when osascript does not answer."""
    try:
        out = subprocess.run([osascript_path(), "-e", "output muted of (get volume settings)"], capture_output=True,
                             text=True, timeout=10).stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        return None
    return {"true": True, "false": False}.get(out)


def mute_output():
    """Mutes the sound output unless BENCH_LAUNCH_AUDIO=keep; returns one line for the log."""
    if os.environ.get("BENCH_LAUNCH_AUDIO") == "keep":
        return f"sound output left as it is (BENCH_LAUNCH_AUDIO=keep; muted: {output_muted()})"
    if output_muted() is True:
        return "sound output muted (it was)"
    try:
        subprocess.run([osascript_path(), "-e", "set volume with output muted"], capture_output=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        pass
    muted = output_muted()
    return "sound output muted" if muted else f"sound output NOT muted (osascript answered {muted})"


def pmset_path():
    return os.environ.get("BENCH_LAUNCH_PMSET") or "/usr/bin/pmset"


def low_power_mode():
    """True or False from `pmset -g` (its `lowpowermode` key), None when the key is absent or pmset fails."""
    try:
        out = subprocess.run([pmset_path(), "-g"], capture_output=True, text=True, timeout=10).stdout
    except (OSError, subprocess.TimeoutExpired):
        return None
    for line in out.splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[0] == "lowpowermode" and parts[1] in ("0", "1"):
            return parts[1] == "1"
    return None


def lpm_marker_path():
    return os.environ.get("BENCH_LAUNCH_LPM_MARKER") or os.path.join(account_home(), ".local/state/cmux",
                                                                     "bench-low-power-mode-switch.json")


def pid_alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def lpm_switch_problem():
    """None when no Low Power Mode switch is left unproved, else the detail. A record of a switch still running
    (its process alive) is fine; an unproved one clears once Low Power Mode is back at its value before."""
    path = lpm_marker_path()
    try:
        with open(path) as f:
            record = json.load(f)
    except FileNotFoundError:
        return None
    except (OSError, ValueError) as error:
        return f"unreadable Low Power Mode switch record {path}: {error}"
    if record.get("active") and isinstance(record.get("pid"), int) and pid_alive(record["pid"]):
        return None
    now = low_power_mode()
    if now is not None and now == record.get("before"):
        os.unlink(path)  # back at the value before the switch: proved
        return None
    return (f"a bench switched Low Power Mode at {record.get('at')} (pid {record.get('pid')}) and nobody proved it "
            f"switched back: it was {record.get('before')}, it is {now} now. Set it back (sudo pmset -a lowpowermode "
            f"{int(bool(record.get('before')))}); the next launch then clears {path}")


class LowPowerModeSwitch:
    """Switches Low Power Mode to `enabled` for the `with` block, then back, also at SIGTERM and SIGHUP (the step
    timeout, a lost terminal) and at interpreter exit. Raises ``LaunchError``: "low-power-mode-switch" outside an
    exclusive step or when pmset fails, "low-power-mode-not-restored" when the switch back does not take."""

    def __init__(self, enabled):
        self.enabled = bool(enabled)
        self.before = None
        self.switched = False
        self.handlers = {}

    def _pmset(self, value):
        cmd = [pmset_path(), "-a", "lowpowermode", "1" if value else "0"]
        if not os.environ.get("BENCH_LAUNCH_TEST_NO_SUDO"):
            cmd = ["/usr/bin/sudo", "-n"] + cmd
        try:
            done = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        except (OSError, subprocess.TimeoutExpired) as error:
            return str(error)
        return None if done.returncode == 0 else (done.stderr.strip() or f"exit {done.returncode}")

    def _record(self, active):
        path = lpm_marker_path()
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path + ".tmp", "w") as f:
            json.dump({"before": self.before, "wanted": self.enabled, "pid": os.getpid(), "active": active,
                       "at": time.strftime("%Y-%m-%dT%H:%M:%S%z")}, f)
        os.replace(path + ".tmp", path)

    def __enter__(self):
        problem = lpm_switch_problem()
        if problem:
            raise LaunchError("low-power-mode-not-restored", {"detail": problem, "log_tail": ""})
        if os.environ.get("CMUX_CI_STEP_CLASS") != "exclusive":
            raise LaunchError("low-power-mode-switch", {"detail": "Low Power Mode is a system setting of a shared Mac: "
                                                                  "a bench switches it only in an exclusive step "
                                                                  "(cmux-ci run --class exclusive)", "log_tail": ""})
        self.before = low_power_mode()
        if self.before is None:
            raise LaunchError("low-power-mode-switch", {"detail": "pmset -g shows no lowpowermode key", "log_tail": ""})
        if self.before == self.enabled:
            return self
        self._record(True)
        for sig in (signal.SIGTERM, signal.SIGHUP):
            self.handlers[sig] = signal.signal(sig, self._on_signal)
        atexit.register(self.restore)
        self.switched = True
        error = self._pmset(self.enabled)
        if error or low_power_mode() != self.enabled:
            self.restore()
            raise LaunchError("low-power-mode-switch", {"detail": f"pmset could not switch Low Power Mode to "
                                                                  f"{self.enabled}: {error or 'no change'}", "log_tail": ""})
        note(f"bench-launch: Low Power Mode switched to {self.enabled} (was {self.before})")
        return self

    def restore(self):
        """Switches back once and proves it; True when Low Power Mode is at its value before the switch."""
        if not self.switched:
            return True
        self.switched = False
        for sig, handler in self.handlers.items():
            signal.signal(sig, handler)
        atexit.unregister(self.restore)
        self._pmset(self.before)
        if low_power_mode() == self.before:
            try:
                os.unlink(lpm_marker_path())
            except FileNotFoundError:
                pass
            note(f"bench-launch: Low Power Mode switched back to {self.before}")
            return True
        self._record(False)
        note(f"bench-launch: Low Power Mode NOT switched back to {self.before}: {lpm_switch_problem()}")
        return False

    def _on_signal(self, signum, frame):
        self.restore()
        signal.signal(signum, signal.SIG_DFL)
        os.kill(os.getpid(), signum)  # die of the signal, as without the handler

    def __exit__(self, *exc):
        if not self.restore():
            raise LaunchError("low-power-mode-not-restored", {"detail": lpm_switch_problem() or "", "log_tail": ""})
        return False


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


def crash_report_folders():
    """Where ReportCrash writes reports: this account's folder first (its own processes' reports; ReportCrash creates it
    with the account's first report), then the system's (0770 root:_analyticsusers: not every account can open it)."""
    return (os.path.join(account_home(), "Library/Logs/DiagnosticReports"), "/Library/Logs/DiagnosticReports")


class FolderEvents:
    """Wakes when any of `folders` gains, loses or renames an entry, or a file added with ``watch_file`` grows (kqueue
    EVFILT_VNODE NOTE_WRITE, plus NOTE_EXTEND on files): the signal for a file another process writes with no signal of
    its own (ReportCrash's .ips, which may be created before its body is written). A folder that cannot be opened is
    not watched: `watched` lists the folders it watches and `unwatched` maps each other one to its error, so a caller
    reports a wait that had nothing to wake it. With nothing watched, `wait` returns False at once."""

    def __init__(self, folders):
        self.folders = folders
        self.queue = None
        self.fds = []
        self.files = set()
        self.watched = []
        self.unwatched = {}

    def __enter__(self):
        for folder in self.folders:
            try:
                self._add(folder, select.KQ_NOTE_WRITE)
                self.watched.append(folder)
            except OSError as error:
                self.unwatched[folder] = error.strerror or str(error)
        return self

    def watch_file(self, path):
        """Also wakes when the file at `path` is written or grows (once per path)."""
        if path in self.files:
            return
        try:
            self._add(path, select.KQ_NOTE_WRITE | select.KQ_NOTE_EXTEND)
            self.files.add(path)
        except (FileNotFoundError, PermissionError):
            # Gone since the folder read (the folder's event covers what replaces it), or another account's report in
            # the system folder that this account cannot read, so it could not match anyway.
            pass

    def _add(self, path, fflags):
        fd = os.open(path, getattr(os, "O_EVTONLY", os.O_RDONLY))  # O_EVTONLY: watch without keeping the volume busy
        try:
            if self.queue is None:
                self.queue = select.kqueue()
            self.queue.control([select.kevent(fd, filter=select.KQ_FILTER_VNODE,
                                              flags=select.KQ_EV_ADD | select.KQ_EV_CLEAR, fflags=fflags)], 0)
        except OSError:
            os.close(fd)
            raise
        self.fds.append(fd)

    def wait(self, timeout):
        """True when a watched folder or file changed within `timeout` seconds."""
        if self.queue is None:
            return False
        return bool(self.queue.control(None, len(self.fds), timeout))

    def __exit__(self, *_):
        if self.queue is not None:
            self.queue.close()
        for fd in self.fds:
            os.close(fd)


def crash_report_candidates(since, name="cmux DEV"):
    """Report files of the app (`name*`) in the report folders, written after `since` (epoch seconds), oldest first,
    whatever process they are of."""
    found = []
    for folder in crash_report_folders():
        for path in glob.glob(os.path.join(folder, f"{name}*")):
            try:
                mtime = os.path.getmtime(path)
            except OSError:
                continue
            if mtime >= since:
                found.append((mtime, path))
    return [path for _, path in sorted(found)]


def crash_reports(since, name="cmux DEV", pid=None, binary=None):
    """Crash and hang reports of the app written after `since` (epoch seconds); with `pid` or `binary`, only
    those of that process or executable."""
    return [path for path in crash_report_candidates(since, name) if report_matches(path, pid, binary)]


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
    `session` reads whether this account has a GUI session (default ``gui_session``, read at each launch;
    tests pass a stub). `socket_only=True` launches without a GUI session for a check that reads only the socket
    and the window list: its failure reports carry `socket_only` and `gui_session`, and its crash or exit is
    reported as such, not as no-gui-session. A bench that measures frames never passes it.
    """

    def __init__(self, app, out=None, env=None, config=None, window=(40, 40, 1440, 900), screen="0",
                 log_name=None, teardown=True, low_power_mode_ok=False, session=None, socket_only=False,
                 fresh_state=True, args=()):
        self.low_power_mode_ok = low_power_mode_ok
        self.args = list(args)  # arguments after the executable (an AppKit default as `-AppleInterfaceStyle Dark`)
        self.fresh_state = fresh_state
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
        self.launched_env = None  # the environment the app was really started with (launch()), for a bench's record
        self.socket = socket_candidates(self.tag)[0]
        self.launched_at = None
        self.ready_seconds = None
        self.limits = None
        self.read_session = session
        self.socket_only = socket_only
        self.gui_session = None  # the session read at the last launch
        self.crash_report_wait = None  # the folders this launch's crash-report wait watched, and the ones it could not
        self.teardown = None
        if teardown:
            sys.path.insert(0, HERE)
            from tag_teardown import TagTeardown
            self.teardown = TagTeardown(self.app)

    @property
    def binary(self):
        """The bundle's main executable: Info.plist's CFBundleExecutable. A bench (Release) build's is not `cmux DEV`
        (close-flash job 12728f0a2b37 started a `cmux DEV` that was not there), and the first file in Contents/MacOS
        can be another executable; only a bundle with no Info.plist falls back to those guesses."""
        try:
            with open(os.path.join(self.app, "Contents/Info.plist"), "rb") as f:
                info = plistlib.load(f)
        except Exception:  # noqa: BLE001  any unreadable plist (OSError, a truncated XML's ExpatError, ...): no name
            info = None
        named = info.get("CFBundleExecutable") if isinstance(info, dict) else None
        if named:
            main = os.path.join(self.app, "Contents/MacOS", named)
            if not os.path.exists(main):
                raise SystemExit(f"bench-launch: {self.app} names CFBundleExecutable {named!r}, which is not in Contents/MacOS")
            return main
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

    def session(self):
        """This account's GUI session now (the injected read, else ``gui_session``)."""
        return (self.read_session or gui_session)()

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

    def state_root(self):
        """The tag's saved state: `~/Library/Application Support/cmux/tags/<tag>` (BuildIdentity
        daemonStateDirectory's parent; its `tui` holds the daemon's saved sessions and their workspaces)."""
        base = os.environ.get("BENCH_LAUNCH_STATE_BASE") or os.path.join(account_home(), "Library/Application Support/cmux")
        return os.path.join(base, "tags", self.tag)

    def start_fresh(self):
        """Every bench launch starts from an empty saved session for its tag (2026-10-24: STRESS refused "the app
        already has 60 workspaces", restored from an earlier run on that host). The tag's state moves aside to
        `<root>.bench-prev` (one kept, the older one removed). BENCH_LAUNCH_KEEP_STATE=1, or
        BenchApp(fresh_state=False), keeps it."""
        root = self.state_root()
        if not os.path.lexists(root):
            return
        prev = root + ".bench-prev"
        if os.path.lexists(prev):
            shutil.rmtree(prev, ignore_errors=True)
        os.rename(root, prev)
        # The build's Debug Settings file lives beside the saved session (DebugSettingsService.fileURL): keep it, so an
        # override a harness set for this run (cef-layer-ab.py's layerHosting) still applies.
        tunables = os.path.join(prev, "debug-tunables.json")
        if os.path.isfile(tunables):
            os.makedirs(root, exist_ok=True)
            shutil.copy2(tunables, os.path.join(root, "debug-tunables.json"))
        note(f"bench-launch: {self.tag} starts from an empty saved session (earlier state moved to {prev})")

    def launch(self, timeout=180, ready="debug.windows", on_start=None):
        """Starts the app and returns once `ready` answers (debug.windows: with a window).

        `on_start(process)` runs right after the spawn (a script's own PID list for its cleanup). On a
        failure the report is printed to stdout (a fleet step log is stdout only), then LaunchError is raised.
        """
        session = self.gui_session = self.session()
        if not session["ok"] and not self.socket_only:
            # Without the console session the display does not tick (frame numbers mean nothing); say so now
            # instead of after the timeout. Only a socket-only check launches anyway, and says so in its reports.
            self._fail("no-gui-session", {"tag": self.tag, **host_facts(), "gui_session": session,
                                          "detail": no_session_detail(session), "log_tail": ""})
        problem = lpm_switch_problem()
        if problem:
            self._fail("low-power-mode-not-restored", {"tag": self.tag, **host_facts(), "detail": problem, "log_tail": ""})
        if low_power_mode() and not self.low_power_mode_ok:
            self._fail("low-power-mode", {"tag": self.tag, **host_facts(), "log_tail": "",
                                          "detail": "this Mac is in Low Power Mode: its numbers are not comparable. Turn "
                                                    "it off, or pass low_power_mode_ok=True for a bench of Low Power "
                                                    "Mode itself"})
        note(f"bench-launch: {mute_output()}")
        running = self.running_pids()
        if not running and self.fresh_state and not os.environ.get("BENCH_LAUNCH_KEEP_STATE"):
            self.start_fresh()  # only with no app of the tag running: its state is not in use
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
        env = self.environment()
        self.launched_env = dict(env)
        try:
            with finder_limits() as changed:
                self.launched_at = time.time()
                self.process = subprocess.Popen([self.binary, *self.args], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
        except LaunchError as error:
            log.close()
            self._fail(error.reason, {"tag": self.tag, **host_facts(), **error.report})
        self.limits = limits_line(changed)
        note(f"bench-launch: {self.tag} pid {self.process.pid}, limits {self.limits}")
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
                    return self
            time.sleep(0.25)  # the poll interval
        log.flush()
        self._fail(*self.diagnose(last, timeout))

    def _fail(self, reason, report):
        report.setdefault("gui_session", self.gui_session)
        if self.socket_only:
            report["socket_only"] = True
        error = LaunchError(reason, report)
        note(str(error))
        note("BENCH-LAUNCH " + json.dumps({"ok": False, "reason": reason,
                                            **{k: v for k, v in report.items() if k != "log_tail"}}))
        raise error

    def diagnose(self, last, timeout):
        """(reason, report) for a launch that did not answer."""
        session = self.session()
        sockets = {p: os.path.exists(p) for p in socket_candidates(self.tag)}
        exit_code = self.process.poll() if self.process else None
        report = {"tag": self.tag, **host_facts(), "pid": self.process.pid if self.process else None, "exit": exit_code,
                  "sockets": sockets, "last_reply": last, "gui_session": session, "log": self.log_path}
        crashes = self.wait_for_crash_report(exit_code)
        if self.crash_report_wait is not None:
            report["crash_report_wait"] = self.crash_report_wait
        if crashes:
            report["crash_report"] = crashes[-1]
            report["crash"] = crash_summary(crashes[-1])
        ended = f"the app ended (exit {exit_code}) before its socket answered" + \
                (f"; crash report {crashes[-1]}" if crashes else "") if exit_code is not None else None
        if not session["ok"] and not self.socket_only:
            # The session went away during the launch (a socket-only check launched without one on purpose: its
            # crash or silence is reported as what it is).
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
        seconds after the process ends, so this waits for a report folder to gain a file (kqueue), at most `wait`
        seconds; otherwise it reads once. The account's own folder is created first, so the wait can watch it before the
        account's first report (ReportCrash would create it inside ~/Library/Logs, which is not watched).
        `crash_report_wait` then records which folders were watched and why the others were not; it describes only
        this call's wait and is None when this call did not wait (one BenchApp may launch again)."""
        self.crash_report_wait = None
        if not self.launched_at:
            return []
        pid = self.process.pid if self.process else None

        def found():
            return crash_reports(self.launched_at - 1, pid=pid, binary=self.binary)

        if exit_code is None or exit_code >= 0:
            return found()
        folders = crash_report_folders()
        unmade = {}
        try:
            os.makedirs(folders[0], exist_ok=True)  # the folder ReportCrash writes this account's reports into
        except OSError as error:
            unmade[folders[0]] = f"cannot create it: {error.strerror or error}"
        with FolderEvents(folders) as events:
            self.crash_report_wait = {"watched": events.watched, "unwatched": {**events.unwatched, **unmade}}
            deadline = time.monotonic() + wait
            while True:
                # Each report file seen is watched before the read below, so one whose body is still being written
                # wakes the wait when it grows; reading after the watches are armed misses nothing written meanwhile.
                for path in crash_report_candidates(self.launched_at - 1):
                    events.watch_file(path)
                reports = found()
                left = deadline - time.monotonic()
                if reports or left <= 0 or not events.wait(left):
                    return reports or found()

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
        if os.environ.get("BENCH_LAUNCH_AUDIO") != "keep" and output_muted() is False:
            note("bench-launch: WARNING: the sound output was unmuted while the bench ran (it was muted at launch)")
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


def launch_app(app, env, log_path, timeout=120, on_start=None, ready="debug.windows"):
    """For a script that keeps its own env, log and cleanup: launches `app` through ``BenchApp`` (the bench defaults
    under `env`, no window frame or screen of its own, no teardown) and returns (process, socket path). Raises
    ``LaunchError`` with the reason printed; `on_start(process)` runs at the spawn, so a failed launch is still the
    caller's to clean up."""
    bench = BenchApp(app, out=os.path.dirname(os.path.abspath(log_path)), env=env, window=None, screen=None,
                     log_name=os.path.basename(log_path), teardown=False)
    bench.launch(timeout=timeout, ready=ready, on_start=on_start)
    return bench.process, bench.socket


def main(argv=None):
    parser = argparse.ArgumentParser(description="Launch-and-socket check of a tagged cmux DEV app.")
    sub = parser.add_subparsers(dest="command", required=True)
    check = sub.add_parser("check", help="launch the app, wait for its socket and a window, quit it")
    check.add_argument("--app", required=True)
    check.add_argument("--out")
    check.add_argument("--timeout", type=float, default=180)
    check.add_argument("--json", help="also write the result here")
    check.add_argument("--low-power-mode-ok", action="store_true", help="launch even in Low Power Mode")
    check.add_argument("--socket-only", action="store_true",
                       help="launch even with no GUI session: only the socket and the window list are checked, no "
                            "frames; the result says socket_only and gui_session")
    sub.add_parser("session", help="only report whether this account has a GUI session")
    sub.add_parser("limits", help="launchd's soft limits (a Finder launch's) and this process's, one JSON line")
    finder = sub.add_parser("finder-exec", help="run COMMAND with launchd's soft limits, as a Finder launch gets")
    finder.add_argument("cmd", nargs=argparse.REMAINDER, metavar="-- COMMAND")
    opts = parser.parse_args(argv)
    if opts.command == "limits":
        launchd = launchd_soft_limits()
        print("BENCH-LAUNCH " + json.dumps({"launchd_soft": {k: shown(v) for k, v in launchd.items()},
                                            "this_soft": {k: shown(resource.getrlimit(LAUNCHD_LIMITS[k])[0])
                                                          for k in launchd}}), flush=True)
        return 0 if launchd else 1
    if opts.command == "finder-exec":
        cmd = opts.cmd[1:] if opts.cmd[:1] == ["--"] else opts.cmd
        if not cmd:
            parser.error("finder-exec needs a command after --")
        with finder_limits() as changed:
            print(f"bench-launch: finder-exec: {cmd[0]} runs with {limits_line(changed)}", file=sys.stderr, flush=True)
            try:
                os.execvp(cmd[0], cmd)  # the limits set here are the command's (exec keeps them)
            except OSError as error:
                parser.error(f"finder-exec: cannot run {cmd[0]}: {error}")
    if opts.command == "session":
        result = {**host_facts(), "gui_session": gui_session()}
        print("BENCH-LAUNCH " + json.dumps(result), flush=True)
        return 0 if result["gui_session"]["ok"] else 1
    app = BenchApp(opts.app, out=opts.out, low_power_mode_ok=opts.low_power_mode_ok, socket_only=opts.socket_only)
    result = {"tag": app.tag, **host_facts(), "gui_session": app.session()}
    if opts.socket_only:
        result["socket_only"] = True
    try:
        app.launch(timeout=opts.timeout)
        windows = app.rpc("debug.windows")
        result.update(ok=True, socket=app.socket, ready_seconds=app.ready_seconds, limits=app.limits,
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
