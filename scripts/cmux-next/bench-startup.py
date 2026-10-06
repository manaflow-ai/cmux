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
      [--mode cold --mode warm] [--profile empty|realistic] [--json out.json]
  scripts/cmux-next/bench-startup.py --app "/path/cmux DEV launch-1.app" ...

--app runs a fleet artifact staged anywhere (its tag comes from the
`cmux DEV <tag>.app` name, as the app's own LaunchIdentity reads it).
--profile empty deletes the tag's daemon, agent and sidebar state before
each run (a first launch on a new Mac; cold mode only). --profile realistic
seeds one priming launch with REALISTIC_WORKSPACES workspaces of three
terminal tabs and a split, then splits the selected pane and opens an agent
chat in it, so the measured launch restores a full sidebar, a terminal and
an agent pane. Its runs wait for the agent pane's handshake as well as the
first terminal frame.

Several tags run interleaved (A run 1, B run 1, A run 2, ...), so machine
load affects them alike. Prints the load average and, per tag and mode, one
row per mark: median and max ms since process start, and the median gap from
the previous row. Kills only processes started from the tag's DerivedData.
"""
import argparse
import glob
import json
import os
import re
import shutil
import select
import signal
import statistics
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

DERIVED = os.path.expanduser("~/Library/Developer/Xcode/DerivedData")
FINAL_MARK = "first_terminal_frame"
AGENT_MARK = "agent_pane.handshake_end"

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
    ("sidebar_rows_shown", "sidebar rows shown"),
    ("reveal.sidebar", "sidebar revealed"),
    ("reveal.tabs", "tab strips revealed"),
    ("reveal.pane", "pane content revealed"),
    ("agent_pane.view_created", "first agent pane view made"),
    ("agent_pane.page_loaded", "agent page loaded (didFinish)"),
    ("agent_pane.handshake_start", "agent page asked for its handshake"),
    (AGENT_MARK, "agent pane handshake answered"),
]
REALISTIC_WORKSPACES = 24

# Apps given with --app, by tag; other tags are DerivedData builds.
APPS = {}


def app_tag(path):
    """The tag of a staged `cmux DEV <tag>.app` (LaunchIdentity.taggedAppName)."""
    name = os.path.basename(os.path.normpath(path))
    match = re.fullmatch(r"cmux DEV (.+)\.app", name)
    if not match:
        raise SystemExit(f"{path}: expected a `cmux DEV <tag>.app` bundle")
    return re.sub(r"[^a-z0-9-]", "-", match.group(1).lower())


def bundle_root(tag):
    """The path every process of the tag starts from, as a pgrep pattern."""
    if tag in APPS:
        # /tmp is /private/tmp: a process may show either spelling.
        path = re.sub(r"([.^$*+?()\[\]{}|\\])", r"\\\1", APPS[tag].removeprefix("/private"))
        return f"(/private)?{path}" if path.startswith("/tmp/") else path
    return f"DerivedData/cmux-{tag}/Build/Products/Debug/cmux DEV"


def app_binary(tag):
    if tag in APPS:
        return os.path.join(APPS[tag], "Contents/MacOS/cmux DEV")
    matches = glob.glob(f"{DERIVED}/cmux-{tag}/Build/Products/Debug/cmux DEV*.app/Contents/MacOS/cmux DEV")
    if not matches:
        raise SystemExit(f"no tagged app for {tag} under {DERIVED}/cmux-{tag}")
    return matches[0]


def pgrep(pattern):
    out = subprocess.run(["pgrep", "-f", pattern], capture_output=True, text=True).stdout
    return [int(p) for p in out.split() if int(p) != os.getpid()]


def tag_pids(tag):
    """The tag's app, daemon and terminal hosts (started from its bundle)."""
    return pgrep(bundle_root(tag))


def app_pids(tag):
    return pgrep(f"{bundle_root(tag)}.*/Contents/MacOS/")


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
            **({"CMUX_NEXT_HANG_THRESHOLD_MS": str(HANG_THRESHOLD_MS)} if HANG_THRESHOLD_MS else {}),
            **(extra_env or {}),
        }
        self.process = subprocess.Popen([app_binary(tag)], env=env, stdout=subprocess.DEVNULL,
                                        stderr=subprocess.DEVNULL, start_new_session=True, pass_fds=(write_fd,))
        os.close(write_fd)
        self.read_fd = read_fd
        self.buffer = b""
        self.marks = {}

    def wait_for(self, mark, timeout, any_of=False):
        """Reads marks until `mark` (or every mark of a list; with `any_of`,
        one of them) arrived, the app exits (EOF) or the timeout."""
        wanted = [mark] if isinstance(mark, str) else list(mark)
        landed = any if any_of else all
        deadline = time.monotonic() + timeout
        while not landed(name in self.marks for name in wanted):
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
# --hangs: main-thread stalls over this many ms are recorded with stacks (debug.hangs).
HANG_THRESHOLD_MS = None


def state_directories(tag):
    """Where a tagged build keeps its sessions: daemon state and the sidebar
    snapshot, agent sessions (acpmux), Home's memory."""
    home = os.path.expanduser("~")
    return [os.path.join(home, "Library/Application Support/cmux/tags", tag),
            os.path.join(home, ".acpmux/tags", tag), os.path.join(home, ".cmux/mux/tags", tag)]


def reset_state(tag):
    """A first launch: no daemon, no saved workspaces, sidebar or agent sessions."""
    stop(tag_pids(tag))
    for directory in state_directories(tag):
        shutil.rmtree(directory, ignore_errors=True)


def daemon_socket(tag, timeout=20):
    tmp = subprocess.run(["getconf", "DARWIN_USER_TEMP_DIR"], capture_output=True, text=True).stdout.strip()
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        found = glob.glob(os.path.join(tmp, "cmux-tui-*", f"cmux-app-{tag}.sock"))
        if found:
            return found[0]
        time.sleep(0.2)
    raise SystemExit(f"tag {tag}: no daemon socket")


def app_client(tag, timeout=30):
    from bench_cli_storm import Client  # noqa: E402
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            return Client(f"/tmp/cmux-debug-{tag}.sock", timeout=10)
        except OSError:
            time.sleep(0.2)
    raise SystemExit(f"tag {tag}: control socket did not answer")


def seed_realistic(tag, scratch, timeout):
    """Fills the tag's state with a day's work (see --profile realistic) and
    leaves the daemon running."""
    from bench_cli_storm import Client  # noqa: E402
    reset_state(tag)
    prime = Launch(tag, scratch)
    try:
        if not prime.wait_for([FINAL_MARK, AGENT_MARK], timeout, any_of=True):
            raise SystemExit(f"tag {tag}: the seeding launch never drew a terminal")
        daemon = Client(daemon_socket(tag), timeout=10)

        def workspaces():
            return {w["id"]: w for w in daemon.call("list-workspaces", cmd_key="cmd")["data"]["workspaces"]}

        focus_tab = None
        for index in range(REALISTIC_WORKSPACES):
            before = workspaces()
            created = daemon.call("new-workspace", {"name": f"project-{index + 1:02d}"}, cmd_key="cmd")
            if not created.get("ok"):
                raise SystemExit(f"tag {tag}: new-workspace failed: {created.get('error')}")
            workspace = next(w for key, w in workspaces().items() if key not in before)
            pane = workspace["screens"][0]["panes"][0]
            for _ in range(2):
                daemon.call("new-tab", {"pane": pane["id"]}, cmd_key="cmd")
            daemon.call("split", {"pane": pane["id"], "dir": "right"}, cmd_key="cmd")
            first_tab = (pane.get("tabs") or [{}])[0]
            focus_tab = focus_tab if index else first_tab.get("surface", first_tab.get("id"))
        daemon.close()
        # The agent chat goes beside a terminal of the first seeded workspace.
        app = app_client(tag)
        steps = [("palette.goToTab", {"kind": "tab", "id": focus_tab}), ("splitRight", None), ("palette.newAgentChat", None)]
        agent = True
        for action, target in steps:
            reply = app.call("action.run", {"action": action, **({"target": target} if target else {})})
            if not reply.get("ok"):
                print(f"  {tag}: seeding without an agent chat ({action}: {reply.get('error')})", file=sys.stderr)
                agent = False
                break
        app.close()
        if agent and not prime.wait_for(AGENT_MARK, timeout):
            print(f"  {tag}: the seeded agent chat never loaded", file=sys.stderr)
            agent = False
    finally:
        prime.quit()
    with open(seeded_marker(tag), "w") as out:
        out.write("agent\n" if agent else "terminals\n")


def seeded_agent(tag):
    try:
        with open(seeded_marker(tag)) as marker:
            return marker.read().strip() == "agent"
    except OSError:
        return False


def seeded_marker(tag):
    return os.path.join(state_directories(tag)[0], "bench-startup-realistic")


def one_run(tag, mode, timeout, profile=None):
    scratch = tempfile.mkdtemp(prefix=f"bench-startup-{tag}-")
    with open(os.path.join(scratch, "cmux.json"), "w") as out:
        out.write("{}\n")
    if app_pids(tag):
        raise SystemExit(f"tag {tag} has an app running; quit it first (this bench only stops what it starts)")
    # A first launch shows the agent New Tab page, not a terminal: other
    # profiles end at whichever content draws first.
    final = [FINAL_MARK, AGENT_MARK]
    any_of = profile != "realistic"
    if profile == "empty":
        reset_state(tag)
    elif profile == "realistic" and not os.path.exists(seeded_marker(tag)):
        seed_realistic(tag, scratch, timeout)
    if profile == "realistic" and not seeded_agent(tag):
        final = [FINAL_MARK]
    if mode == "cold":
        # Builds of one tag (a before and an after copy) share its daemon.
        for other in RUN_TAGS or [tag]:
            stop(tag_pids(other))
        if tag_pids(tag):
            raise SystemExit(f"tag {tag}: daemon processes did not exit")
    elif mode == "restart":
        if not owner_pids(f"cmux-app-{tag}"):
            prime = Launch(tag, scratch)
            prime.wait_for([FINAL_MARK, AGENT_MARK], timeout, any_of=True)
            prime.quit()
        stop(owner_pids(f"cmux-app-{tag}"))
    elif not [p for p in tag_pids(tag) if p not in app_pids(tag)]:
        prime = Launch(tag, scratch)
        prime.wait_for([FINAL_MARK, AGENT_MARK], timeout, any_of=True)
        prime.quit()
    launch = Launch(tag, scratch)
    try:
        reached = launch.wait_for(final, timeout, any_of=any_of)
        if HANG_THRESHOLD_MS:
            launch.stalls = launch_stalls(tag)
    finally:
        launch.quit()
    if not reached:
        missing = [mark for mark in final if mark not in launch.marks]
        print(f"  {tag} {mode}: {', '.join(missing)} not reached within {timeout} s", file=sys.stderr)
    if getattr(launch, "stalls", None) is not None:
        return {**launch.marks, "stalls": launch.stalls}
    return launch.marks


def launch_stalls(tag):
    """The launch's main-thread stalls, longest first, with their top frames."""
    client = app_client(tag)
    try:
        hangs = client.call("debug.hangs").get("result") or {}
    finally:
        client.close()
    stalls = [{"ms": round(record.get("duration_ms", 0), 1), "cpu_ms": round(record.get("cpu_ms", 0), 1),
               "frames": [f for f in record.get("frames", []) if "cmux" in f or "CmuxNext" in f][:8]
               or record.get("frames", [])[:8]}
              for record in hangs.get("records", [])]
    return sorted(stalls, key=lambda stall: -stall["ms"])


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


def stall_site(stall):
    """The first app frame of a stall, without its module and offset."""
    frames = stall["frames"]
    for frame in [f for f in frames if "CmuxNext" in f] + [f for f in frames if "cmux DEV" in f]:
        if "cmux DEV" in frame:
            return frame.split(" + ")[0].replace("cmux DEV.debug.dylib ", "").replace("cmux DEV ", "")[:100]
    return (stall["frames"] or ["?"])[0].split(" + ")[0][:100]


def print_stalls(runs):
    """Main-thread stall time per run, and the sites that stalled in most runs."""
    totals = [sum(s["ms"] for s in run.get("stalls", [])) for run in runs]
    print(f"  main-thread stalls: median total {statistics.median(totals):.0f} ms per launch (max {max(totals):.0f})")
    sites = {}
    for run in runs:
        for stall in run.get("stalls", []):
            sites.setdefault(stall_site(stall), []).append(stall["ms"])
    for site, values in sorted(sites.items(), key=lambda item: -sum(item[1]))[:8]:
        print(f"    {len(values)}/{len(runs)} runs, median {statistics.median(values):>4.0f} ms  {site}")


def table(runs):
    """Rows in the order the marks landed (by median), each with its gap
    from the row before."""
    medians = []
    for mark, label in MARKS:
        values = [run[mark] for run in runs if mark in run]
        if values:
            medians.append((statistics.median(values), label, mark, max(values), len(values)))
    rows = []
    previous = 0.0
    for median, label, mark, worst, count in sorted(medians, key=lambda row: row[0]):
        rows.append((label, mark, median, worst, median - previous, count))
        previous = median
    return rows


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--tag", action="append", default=[])
    parser.add_argument("--app", action="append", default=[], help="a staged `cmux DEV <tag>.app` (fleet artifact)")
    parser.add_argument("--profile", choices=["empty", "realistic"],
                        help="empty: no saved state before each run; realistic: a seeded day's work "
                             "(default: whatever state the tag has)")
    parser.add_argument("--runs", type=int, default=5)
    parser.add_argument("--mode", action="append", choices=["cold", "restart", "warm", "daemon"])
    parser.add_argument("--timeout", type=float, default=30.0, help="seconds per launch to reach the first frame")
    parser.add_argument("--json", help="write every run's marks here")
    parser.add_argument("--budget", action="append", default=[], metavar="MARK=MS",
                        help="exit 1 when a mark's median (any tag, mode) is over MS or never arrives")
    parser.add_argument("--hangs", type=int, metavar="MS",
                        help="record main-thread stalls over MS during each launch (debug.hangs) and print the worst")
    args = parser.parse_args()
    global HANG_THRESHOLD_MS
    HANG_THRESHOLD_MS = args.hangs
    for path in args.app:
        APPS[app_tag(path)] = os.path.abspath(path)
        args.tag.append(app_tag(path))
    if not args.tag:
        parser.error("give at least one --tag or --app")
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
                    marks = one_run(tag, mode, args.timeout, args.profile)
                    results[tag][mode].append(marks)

                    def shown(mark):
                        return "%.0f ms" % marks[mark] if mark in marks else "missing"
                    print(f"  {tag} {mode} run {index + 1}: first live terminal frame {shown(FINAL_MARK)}, "
                          f"agent pane {shown(AGENT_MARK)}", flush=True)
                    for stall in marks.get("stalls", [])[:3]:
                        print(f"    stall {stall['ms']:.0f} ms (cpu {stall['cpu_ms']:.0f}): "
                              + " < ".join(stall["frames"][:4]), flush=True)
    finally:
        for tag in args.tag:
            stop(tag_pids(tag))
    print(f"load average: {' '.join(f'{x:.0f}' for x in os.getloadavg())}")
    for tag in args.tag:
        for mode in modes:
            runs = results[tag][mode]
            print(f"\n{tag} {mode} {args.profile or 'kept'} profile ({len(runs)} runs), ms since process start")
            print(f"  {'phase':<46} {'median':>8} {'max':>8} {'gap':>8}  n")
            for label, mark, median, worst, gap, count in table(runs):
                print(f"  {label:<46} {median:>8.0f} {worst:>8.0f} {gap:>+8.0f}  {count}")
            if args.hangs:
                print_stalls(runs)
    if args.json:
        with open(args.json, "w") as out:
            json.dump(results, out, indent=1)
    over = check_budgets(results, args.budget)
    for line in over:
        print(f"over budget: {line}", file=sys.stderr)
    if over:
        sys.exit(1)


def check_budgets(results, budgets):
    """Every `MARK=MS` whose median is over MS (or missing) in some tag and mode."""
    over = []
    for budget in budgets:
        mark, _, limit = budget.partition("=")
        for tag, modes in results.items():
            for mode, runs in modes.items():
                values = [run[mark] for run in runs if mark in run]
                if len(values) < len(runs):
                    over.append(f"{tag} {mode}: {mark} missing in {len(runs) - len(values)} of {len(runs)} runs")
                elif values and statistics.median(values) > float(limit):
                    over.append(f"{tag} {mode}: {mark} median {statistics.median(values):.0f} ms > {limit} ms")
    return over


if __name__ == "__main__":
    main()
