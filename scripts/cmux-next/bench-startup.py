#!/usr/bin/env python3
"""Startup phase bench for cmux-next: app launch to the first live terminal frame.

Launches a tagged build with a clean environment (no activation, windows on
the last screen, a scratch cmux.json) and reads every launch mark as an
event: the app writes one `<name> <ms-since-process-start>` line per mark to
the pipe named by CMUX_NEXT_LAUNCH_MARKS_FD (Control/LaunchMarkSink.swift).
Nothing here polls: it blocks on the pipe (select with the run deadline),
on waitpid for the app, and on kqueue NOTE_EXIT for the tag's daemon.

  cold  no daemon for the tag runs: the app starts it (`server ensure`);
        its terminal hosts were stopped too (a reboot or logout)
  restart  only the daemon was stopped; its terminal hosts live on and the
        new daemon adopts them (a crash or a version handoff)
  warm  a priming launch leaves the daemon running (keep sessions); only
        the app quits before the measured launch
  daemon  the daemon side alone, with the tag's bundled cmux-tui: `--version`
        (process spawn), `server ensure` after only the owner was stopped
        (state kept, terminal hosts adopted), `server ensure` on an empty
        state root, then one connection's identify and snapshot round trips

  scripts/cmux-next/bench-startup.py --tag nxboot [--tag other] [--runs 5]
      [--mode cold --mode warm] [--json out.json]

Several tags run interleaved (A run 1, B run 1, A run 2, ...), so machine
load affects them alike. Prints the load average and, per tag and mode, one
row per mark: median and max ms since process start, and the median gap from
the previous row. Kills only processes started from the tag's DerivedData.
"""
import argparse
import glob
import json
import os
import select
import signal
import statistics
import subprocess
import sys
import tempfile
import time

DERIVED = os.path.expanduser("~/Library/Developer/Xcode/DerivedData")
FINAL_MARK = "first_terminal_frame"

# Rows in launch order; a mark a build does not emit is left out.
MARKS = [
    ("main_start", "process start -> main()"),
    ("did_finish_launching_start", "AppKit ready (applicationDidFinishLaunching)"),
    ("daemon.binary_resolved", "daemon binary resolved"),
    ("launch_snapshot_applied", "cached layout read (launch snapshot)"),
    ("launch_snapshot_shown", "cached layout window made"),
    ("did_finish_launching_end", "applicationDidFinishLaunching end"),
    ("first_window_frame_committed", "first window frame committed"),
    ("daemon.connect_start", "first connect attempt"),
    ("daemon.status_start", "server status spawn"),
    ("daemon.status_end", "server status exit"),
    ("daemon.login_env_start", "login env wait (cold)"),
    ("daemon.login_env_end", "login env ready (cold)"),
    ("daemon.ensure_start", "server ensure spawn (cold)"),
    ("daemon.ensure_end", "daemon ready (cold)"),
    ("daemon.endpoint_resolved", "endpoint resolved"),
    ("daemon.socket_connected", "control socket connected"),
    ("daemon.identify_end", "identify answered"),
    ("daemon.handshake_end", "handshake done (client info, subscribe)"),
    ("daemon_connected", "connection published"),
    ("daemon.snapshot_start", "snapshot requested"),
    ("daemon.snapshot_end", "snapshot received"),
    ("daemon.first_tree_applied", "first live tree applied"),
    ("daemon_snapshot_loaded", "windows restored from live tree"),
    ("first_terminal_surface_created", "first Ghostty surface"),
    ("terminal.attach_start", "first terminal attach started"),
    ("terminal.attach_end", "first terminal attached (replay)"),
    ("first_terminal_content", "first terminal content decoded"),
    ("first_terminal_content_applied", "first content in a surface"),
    (FINAL_MARK, "first live terminal frame"),
]


def app_binary(tag):
    matches = glob.glob(f"{DERIVED}/cmux-{tag}/Build/Products/Debug/cmux DEV*.app/Contents/MacOS/cmux DEV")
    if not matches:
        raise SystemExit(f"no tagged app for {tag} under {DERIVED}/cmux-{tag}")
    return matches[0]


def pgrep(pattern):
    out = subprocess.run(["pgrep", "-f", pattern], capture_output=True, text=True).stdout
    return [int(p) for p in out.split() if int(p) != os.getpid()]


def tag_pids(tag):
    """The tag's app, daemon and terminal hosts (started from its bundle)."""
    return pgrep(f"DerivedData/cmux-{tag}/Build/Products/Debug/cmux DEV")


def app_pids(tag):
    return pgrep(f"DerivedData/cmux-{tag}/Build/Products/Debug/cmux DEV.*/Contents/MacOS/")


def wait_exit(pids, timeout):
    """Blocks until every pid exited (kqueue NOTE_EXIT) or the timeout passes."""
    queue = select.kqueue()
    live = set()
    for pid in pids:
        try:
            queue.control([select.kevent(pid, select.KQ_FILTER_PROC, select.KQ_EV_ADD | select.KQ_EV_ONESHOT,
                                         select.KQ_NOTE_EXIT)], 0, 0)
            live.add(pid)
        except (ProcessLookupError, OSError):
            pass  # already gone
    deadline = time.monotonic() + timeout
    while live:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        for event in queue.control(None, len(live), remaining):
            live.discard(event.ident)
    queue.close()
    return not live


def stop(pids, timeout=10):
    for pid in pids:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    if not wait_exit(pids, timeout):
        for pid in pids:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        wait_exit(pids, 5)


class Launch:
    """One app process whose launch marks arrive on a pipe."""

    def __init__(self, tag, scratch, extra_env=None):
        read_fd, write_fd = os.pipe()
        env = {
            "HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
            "CMUX_NEXT_TEST_WINDOW_SCREEN": "last",
            "CMUX_NEXT_CONFIG_FILE": os.path.join(scratch, "cmux.json"),
            "CMUX_NEXT_LAUNCH_MARKS_FD": str(write_fd),
            **(extra_env or {}),
        }
        self.process = subprocess.Popen([app_binary(tag)], env=env, stdout=subprocess.DEVNULL,
                                        stderr=subprocess.DEVNULL, start_new_session=True, pass_fds=(write_fd,))
        os.close(write_fd)
        self.read_fd = read_fd
        self.buffer = b""
        self.marks = {}

    def wait_for(self, mark, timeout):
        """Reads marks until `mark` arrives, the app exits (EOF) or the timeout."""
        deadline = time.monotonic() + timeout
        while mark not in self.marks:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return False
            ready, _, _ = select.select([self.read_fd], [], [], remaining)
            if not ready:
                return False
            chunk = os.read(self.read_fd, 65536)
            if not chunk:
                return False
            self.buffer += chunk
            *lines, self.buffer = self.buffer.split(b"\n")
            for line in lines:
                name, _, ms = line.decode().partition(" ")
                if name and ms:
                    self.marks.setdefault(name, float(ms))
        return True

    def quit(self):
        """Quits the app only; the daemon keeps running (keep sessions)."""
        os.close(self.read_fd)
        stop([self.process.pid], timeout=20)
        self.process.wait()


RUN_TAGS = []


def one_run(tag, mode, timeout):
    scratch = tempfile.mkdtemp(prefix=f"bench-startup-{tag}-")
    with open(os.path.join(scratch, "cmux.json"), "w") as out:
        out.write("{}\n")
    if app_pids(tag):
        raise SystemExit(f"tag {tag} has an app running; quit it first (this bench only stops what it starts)")
    if mode == "cold":
        # Builds of one tag (a before and an after copy) share its daemon.
        for other in RUN_TAGS or [tag]:
            stop(tag_pids(other))
        if tag_pids(tag):
            raise SystemExit(f"tag {tag}: daemon processes did not exit")
    elif mode == "restart":
        if not owner_pids(f"cmux-app-{tag}"):
            prime = Launch(tag, scratch)
            prime.wait_for(FINAL_MARK, timeout)
            prime.quit()
        stop(owner_pids(f"cmux-app-{tag}"))
    elif not [p for p in tag_pids(tag) if p not in app_pids(tag)]:
        prime = Launch(tag, scratch)
        prime.wait_for(FINAL_MARK, timeout)
        prime.quit()
    launch = Launch(tag, scratch)
    try:
        reached = launch.wait_for(FINAL_MARK, timeout)
    finally:
        launch.quit()
    if not reached:
        print(f"  {tag} {mode}: {FINAL_MARK} not reached within {timeout} s", file=sys.stderr)
    return launch.marks


def owner_pids(session):
    """The session's daemon (owner) process, not its terminal hosts."""
    return pgrep(f"cmux-tui.*--session {session}( |$)")


def daemon_side(tag, runs):
    """Times the daemon's own start and first answers (no app)."""
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    from bench_cli_storm import Client  # noqa: E402
    binary = os.path.join(os.path.dirname(os.path.dirname(app_binary(tag))), "Resources/bin/cmux-tui")
    if app_pids(tag):
        raise SystemExit(f"tag {tag} has an app running; quit it first")
    tmp = subprocess.run(["getconf", "DARWIN_USER_TEMP_DIR"], capture_output=True, text=True).stdout.strip()
    state = os.path.expanduser(f"~/Library/Application Support/cmux/tags/{tag}/tui")

    def env(state_dir):
        return {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "TMPDIR": tmp, "CMUX_TUI_STATE_DIR": state_dir}

    def timed(args, state_dir):
        started = time.monotonic()
        out = subprocess.run([binary, *args], env=env(state_dir), capture_output=True, text=True)
        return (time.monotonic() - started) * 1000, out.stdout

    rows = {}
    for _ in range(runs):
        rows.setdefault("spawn cmux-tui --version", []).append(timed(["--version"], state)[0])
        session = f"cmux-app-{tag}"
        stop(owner_pids(session))
        ms, out = timed(["--session", session, "--json", "server", "ensure"], state)
        rows.setdefault("server ensure, state kept (adopt hosts)", []).append(ms)
        socket = json.loads([line for line in out.splitlines() if line.startswith("{")][-1])["socket"]
        client = Client(socket, timeout=10)
        for cmd in ("identify", "list-workspaces", "list-personal"):
            started = time.monotonic()
            client.call(cmd, cmd_key="cmd")
            rows.setdefault(f"{cmd} round trip (first connection)", []).append((time.monotonic() - started) * 1000)
        client.close()
        ms, _ = timed(["--session", session, "--json", "server", "status"], state)
        rows.setdefault("server status (running owner)", []).append(ms)
        fresh = tempfile.mkdtemp(prefix=f"bench-startup-daemon-{tag}-")
        fresh_session = f"bench-{os.getpid()}"
        ms, _ = timed(["--session", fresh_session, "--json", "server", "ensure"], fresh)
        rows.setdefault("server ensure, empty state root", []).append(ms)
        stop(owner_pids(fresh_session))
        subprocess.run(["rm", "-rf", fresh])
    print(f"\n{tag} daemon side ({runs} runs), ms")
    print(f"  {'phase':<46} {'median':>8} {'max':>8}")
    for label, values in rows.items():
        print(f"  {label:<46} {statistics.median(values):>8.0f} {max(values):>8.0f}")


def table(runs):
    rows = []
    previous = 0.0
    for mark, label in MARKS:
        values = [run[mark] for run in runs if mark in run]
        if not values:
            continue
        median = statistics.median(values)
        rows.append((label, mark, median, max(values), median - previous, len(values)))
        previous = median
    return rows


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--tag", action="append", required=True)
    parser.add_argument("--runs", type=int, default=5)
    parser.add_argument("--mode", action="append", choices=["cold", "restart", "warm", "daemon"])
    parser.add_argument("--timeout", type=float, default=30.0, help="seconds per launch to reach the first frame")
    parser.add_argument("--json", help="write every run's marks here")
    args = parser.parse_args()
    RUN_TAGS.extend(args.tag)
    modes = args.mode or ["cold", "warm"]
    if "daemon" in modes:
        modes.remove("daemon")
        for tag in args.tag:
            daemon_side(tag, args.runs)
        if not modes:
            return
    results = {tag: {mode: [] for mode in modes} for tag in args.tag}
    print(f"load average: {' '.join(f'{x:.0f}' for x in os.getloadavg())}")
    try:
        for mode in modes:
            for index in range(args.runs):
                for tag in args.tag:
                    marks = one_run(tag, mode, args.timeout)
                    results[tag][mode].append(marks)
                    final = marks.get(FINAL_MARK)
                    print(f"  {tag} {mode} run {index + 1}: first live frame "
                          f"{'%.0f ms' % final if final is not None else 'missing'}", flush=True)
    finally:
        for tag in args.tag:
            stop(tag_pids(tag))
    print(f"load average: {' '.join(f'{x:.0f}' for x in os.getloadavg())}")
    for tag in args.tag:
        for mode in modes:
            runs = results[tag][mode]
            print(f"\n{tag} {mode} ({len(runs)} runs), ms since process start")
            print(f"  {'phase':<46} {'median':>8} {'max':>8} {'gap':>8}  n")
            for label, mark, median, worst, gap, count in table(runs):
                print(f"  {label:<46} {median:>8.0f} {worst:>8.0f} {gap:>+8.0f}  {count}")
    if args.json:
        with open(args.json, "w") as out:
            json.dump(results, out, indent=1)


if __name__ == "__main__":
    main()
