#!/usr/bin/env python3
"""Kill, quit or crash a tagged cmux-next app and check every restored terminal.

Dogfood nxdog11: "after killing and reopening, persisted sessions are kinda
frozen". The daemon keeps every terminal running while the app is gone; on
relaunch each view re-attaches from a replay. This script builds a session
that stresses that path, ends the app, relaunches it and checks each terminal
view in every workspace:

  - the attach machine is `live` (debug.surfaces `attach`);
  - the view renders new output: a token sent to the terminal appears in the
    Ghostty mirror (debug.surfaces `text`), or the screen of a program that
    redraws by itself (top, an output loop) changes;
  - the shell's `stty size` equals the grid the mirror renders.

Terminals: `top`, vim, an idle shell, a colored output loop, and a reader
that always waits inside an unfinished escape sequence (`ESC [ 1 ; 3`). The
app is ended with a different workspace selected each time, so the other
workspace's terminals attach at a provisional grid on first show and their
PTYs resize mid-sequence (terminal-pending-sequence-v1). Each launch also
alternates the test window frame, so the relaunch itself resizes them.

  scripts/cmux-next/relaunch-e2e.py --tag <tag> [--rounds 3] [--modes kill,quit,crash] [--disconnect]
  scripts/cmux-next/relaunch-e2e.py --tag <tag> --long-top 600

--disconnect drops a view with the daemon's detach-client and checks the
disconnected label rules (coordinator decision 1). --long-top runs a fresh
`top` for SECONDS and reports every stall (daemon moved, mirror did not for
6 s) with the view's attach phase, link and surface state.

Every launch goes through bench_launch.BenchApp (the bench env with its
no-activate switch, a scratch cmux.json, the window on the last screen, the
GUI-session check); the tag's app must not be running. Each relaunch keeps
the tag: the same BenchApp starts the app again on the tag's saved state, and
the daemon the earlier launch left is adopted (launch_journey_report.relaunch).
At the end BenchApp.stop quits the app and its tag teardown ends every
launch's daemon and terminals. Exit 1 on any failed check.

With --story (scripts/perf-lab/stories.d, engine none) a run that did every
round is written into --out as cmux-perf-result/v1 (BenchApp.record):
relaunch_e2e.<mode>.first_answer (ms from the relaunch's spawn to its first
answered system.ping, per end mode) and relaunch_e2e.failed_checks (count).
Failed checks still record; a run that stopped writes none and exits 1.

--matrix runs the launch correctness matrix instead (p08-startup done check 13, launch_matrix.py): first launch,
scale change, appearance flip, theme change, crash recovery, crash streak, incognito leftovers, 3 windows on 2
displays, full-screen window, translucent window, a workspace closed through the daemon while the app is closed,
daemon cold, daemon unavailable, no-window launch, launch by URL open, quit during launch, and with --f2 the
Chromium Host killed during launch. Each case runs on a fresh state of the tag and prints PASS, FAIL or SKIP with
its first frame's still; DIR/launch-matrix.json keeps every row. Exit 1 on any FAIL.

  scripts/cmux-next/relaunch-e2e.py --tag <tag> --matrix [all|CASE,CASE] [--picture off] [--f2] --out DIR

Before each quit (the quit mode and the final stop), `leaks` on the app
(scripts/fuzz/macos-matrix/leakcheck.py) records the leaked blocks, bytes and
top types in the scratch leaks.json, with each run's output beside it.
Report only: a leak is never a failed check. --no-leaks skips it.
"""
import argparse, glob, json, os, random, re, signal, socket, subprocess, sys, tempfile, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # its siblings, also under `python3 -I`
import launch_journey_report as journey  # noqa: E402
from bench_launch import BenchApp, tag_of  # noqa: E402
from bench_story import story_problem  # noqa: E402
import launch_matrix  # noqa: E402

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "fuzz", "macos-matrix"))
import leakcheck  # noqa: E402


def parse_args(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--tag", required=True)
    parser.add_argument("--rounds", type=int, default=3)
    parser.add_argument("--modes", default="kill,quit,crash", help="comma list of kill (SIGKILL), quit (Quit action), crash (debug.crash.app)")
    parser.add_argument("--settle", type=float, default=2.0, help="seconds after a workspace switch before checking")
    parser.add_argument("--attach-deadline", type=float, default=20.0, help="seconds a view may take to reach live")
    parser.add_argument("--disconnect", action="store_true", help="also drop views with detach-client and check each re-attaches on a key press and on being shown")
    parser.add_argument("--long-top", type=float, default=0, metavar="SECONDS",
                        help="instead of relaunch rounds: a fresh top in its own workspace, compared with the daemon every 2 s for SECONDS")
    parser.add_argument("--app", help="tagged .app (default: found in DerivedData)")
    parser.add_argument("--out", help="BenchApp's folder: the app log, evidence and result-v1 (default a scratch folder)")
    parser.add_argument("--story", help="write a run that did every round as cmux-perf-result/v1 under this story")
    parser.add_argument("--session", choices=["light"], default="light", help="result-v1 session (the story runner's)")
    parser.add_argument("--launch-timeout", type=float, default=120.0, help="seconds a launch may take to show its window")
    parser.add_argument("--matrix", metavar="CASES",
                        help=f"the launch correctness matrix: `all` or a comma list of {', '.join(launch_matrix.CASE)}")
    parser.add_argument("--picture", choices=["on", "off"], default="on",
                        help=f"--matrix: the {launch_matrix.PICTURE_FEATURE} feature (on: the saved picture is the first frame)")
    parser.add_argument("--f2", action="store_true", help="--matrix: run cef-host-kill with the Chromium Host app on")
    parser.add_argument("--no-leaks", action="store_true", help="skip the leaks report before each quit")
    args = parser.parse_args(argv)
    if args.matrix:
        if args.story or args.long_top:
            parser.error("--matrix does not go with --story or --long-top")
        try:
            launch_matrix.select(args.matrix)
        except ValueError as error:
            parser.error(str(error))
    if args.story:
        if args.long_top:
            parser.error("--story does not go with --long-top: it relaunches nothing")
        problem = story_problem(args.story, "none")
        if problem:
            parser.error(problem)
    return args


opts = None
APP = CLI = SCRATCH = None
bench = None  # the BenchApp of every launch of the run
TMP = os.environ.get("TMPDIR", "/tmp")
BASE_ENV = {"HOME": os.environ.get("HOME", ""), "USER": os.environ.get("USER", ""), "TMPDIR": TMP,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"}
TOKENS = random.SystemRandom()
failures = []
slow = []
relaunches = []  # (end mode, ms from the relaunch's spawn to its first answered system.ping)
leak_rows = []  # leakcheck rows, one per quit, each with its label


def configure(args, bench_app=BenchApp):
    """Sets the run's globals from the parsed `args`: the app, its CLI, the scratch folder and the BenchApp."""
    global opts, APP, CLI, SCRATCH, bench
    opts = args
    APP = tagged_app(opts)
    CLI = os.path.join(APP, "Contents/Resources/bin/cmux")
    SCRATCH = opts.out or tempfile.mkdtemp(prefix=f"relaunch-e2e-{opts.tag}-")
    os.makedirs(SCRATCH, exist_ok=True)
    bench = bench_app(APP, out=SCRATCH, config={}, window=FRAMES[0], screen="last", log_name="app.log",
                      perf_session=opts.session)
    if bench.tag != opts.tag:
        sys.exit(f"--tag {opts.tag} is not the tag of {APP} ({bench.tag})")
    return bench


def tagged_app(args):
    """--app, else the tag's Debug build in DerivedData; exits when there is none."""
    app = args.app or next(iter(sorted(glob.glob(os.path.expanduser(
        f"~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/cmux DEV {args.tag}.app")))), None)
    if not app:
        sys.exit(f"no tagged app for {args.tag}; pass --app")
    return app


def matrix(args, bench_app=BenchApp):
    """--matrix: every selected case on its own fresh state of the tag; 1 on any FAIL."""
    app = tagged_app(args)
    if tag_of(app) != args.tag:
        sys.exit(f"--tag {args.tag} is not the tag of {app} ({tag_of(app)})")
    out = args.out or tempfile.mkdtemp(prefix=f"launch-matrix-{args.tag}-")
    os.makedirs(out, exist_ok=True)
    rows = launch_matrix.run_matrix(app, args.matrix, out, picture=args.picture == "on", f2=args.f2,
                                    session=args.session, bench_app=bench_app)
    return 1 if any(row["result"] == launch_matrix.FAIL for row in rows) else 0


def cli(*args, timeout=30):
    env = {**BASE_ENV, "CMUX_SOCKET_PATH": bench.socket, "CMUX_QUIET": "1"}
    return subprocess.run([CLI, "--socket", bench.socket, *args], capture_output=True, text=True, timeout=timeout, env=env)


def rpc(method, params=None):
    r = cli("rpc", method, json.dumps(params or {}))
    try:
        return json.loads(r.stdout)
    except ValueError:
        return {"error": (r.stdout + r.stderr).strip()}


def wait(predicate, seconds, step=0.25):
    deadline = time.time() + seconds
    while time.time() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(step)
    return None


# Window frames the launches alternate between (points from the top-left of
# the screen's visible frame): a relaunch restores at another size, as after
# a display or window change, so every restored PTY resizes on attach.
FRAMES = [(40, 40, 1100, 720), (40, 40, 980, 640)]
launches = 0


def launch(mode=None):
    """The first launch (`mode` None), or the relaunch after the app was ended by `mode` on the same tag: its
    spawn-to-first-answer time is kept for result-v1. BenchApp raises LaunchError (a SystemExit) with the reason when
    the app does not come up."""
    global launches
    bench.window = FRAMES[launches % len(FRAMES)]
    launches += 1
    if mode is None:
        bench.launch(timeout=opts.launch_timeout)
        journey.remember(bench)
    else:
        journey.relaunch(bench, timeout=opts.launch_timeout, probe_first_answer=True)
        relaunches.append((mode, bench.first_answer_ms))
    ready = wait(lambda: rpc("debug.surfaces").get("windows"), 60, 0.5)
    if not ready:
        sys.exit(f"tagged app lists no window in debug.surfaces (log {bench.log_path})")
    focus = rpc("debug.focus")
    if focus.get("app_active") or focus.get("key_window"):
        # Evidence first: a user click shows as a system mouse event in the journal.
        evidence = os.path.join(SCRATCH, "focus-violation.json")
        with open(evidence, "w") as out:
            json.dump({"focus": focus, "journal": rpc("debug.journal")}, out, indent=1)
        print(f"  focus evidence: {evidence}")
        stop(signal.SIGKILL)
        sys.exit("the no-activate app took the keyboard; stopped it (report this as a bug): "
                 f"app_active={focus.get('app_active')} key_window={focus.get('key_window')}")
    given = (focus.get("keyboard_given_back") or {}).get("count") or 0
    print(f"launched pid {bench.process.pid}" + (f" (no-activate guard gave the keyboard back {given}x)" if given else ""))


def stop(sig):
    """Signals the app process this run started (its own PID); the daemon keeps running."""
    app = bench.process if bench else None
    if app and app.poll() is None:
        app.send_signal(sig)
        try:
            app.wait(20)
        except subprocess.TimeoutExpired:
            app.kill()
            app.wait()


def check_leaks(label):
    """Report only: `leaks` on the running app into the scratch leaks.json."""
    app = bench.process if bench else None
    if opts.no_leaks or not app or app.poll() is not None:
        return
    row = {"label": label, **leakcheck.run_local(app.pid, os.path.join(SCRATCH, f"leaks-{len(leak_rows) + 1}.txt"))}
    leak_rows.append(row)
    with open(os.path.join(SCRATCH, "leaks.json"), "w") as out:
        json.dump(leak_rows, out, indent=1)
    print(f"  {label} {leakcheck.summary_line(row)}")


def end(mode):
    """End the app the way the mode says; the daemon keeps running."""
    app = bench.process
    if mode == "kill":
        stop(signal.SIGKILL)
    elif mode == "crash":
        rpc("debug.crash.app", {"kind": "segv"})
        try:
            app.wait(20)
        except subprocess.TimeoutExpired:
            stop(signal.SIGKILL)
    else:
        check_leaks(f"before quit {launches}")
        rpc("action.run", {"id": "quit"})
        try:
            app.wait(20)
        except subprocess.TimeoutExpired:
            print("  quit action did not end the app; SIGTERM (also a normal quit)")
            stop(signal.SIGTERM)
    print(f"ended app ({mode}), exit {app.returncode}")


def workspaces():
    refs = []
    for line in cli("list-workspaces").stdout.splitlines():
        m = re.search(r"(workspace:\d+)", line)
        if m:
            refs.append(m.group(1))
    return refs


def surfaces(workspace):
    """[(surface ref, title)] of the workspace's selected terminal tabs."""
    out = []
    for line in cli("tree", "--workspace", workspace).stdout.splitlines():
        m = re.search(r"surface (surface:\d+) \[terminal\] \"(.*)\" \[selected\]", line)
        if m:
            out.append((m.group(1), m.group(2)))
    return out


LOOP = r"""echo relaunch-loop; while :; do printf '\033[3%dmrelaunch-loop %s\033[0m\n' $((RANDOM%8)) $RANDOM; sleep 0.002; done"""
READER = r"""stty -echo; while :; do printf '\033[1;3'; read x; printf 'm got-%s\n' "$x"; done"""


def setup():
    """Two workspaces, six terminals, the first workspace on two screens. The first launch starts from an empty
    session (BenchApp refuses a tag whose daemon an earlier run left), so workspaces of an earlier run here are
    another run's: refused, never measured."""
    if "relaunch-2" in cli("list-workspaces").stdout:
        sys.exit("the first launch restored workspace relaunch-2 of an earlier run (BENCH_LAUNCH_KEEP_STATE?); "
                 "run on an empty session or a fresh tag")
    first = workspaces()[0]
    top = wait(lambda: surfaces(first), 20)[0][0]
    vim_ref = cli("new-split", "right", "--workspace", first, "--surface", top, "--focus", "false").stdout.split()[1]
    idle = cli("new-split", "down", "--workspace", first, "--surface", top, "--focus", "false").stdout.split()[1]
    second = cli("new-workspace", "--name", "relaunch-2", "--focus", "false").stdout.split()[1]
    found = wait(lambda: surfaces(second), 20)
    if not found:
        sys.exit(f"workspace {second} never showed a terminal")
    loop = found[0][0]
    reader = cli("new-split", "right", "--workspace", second, "--surface", loop, "--focus", "false").stdout.split()[1]
    cli("send", "--surface", top, "top -s 1\n")
    cli("send", "--surface", vim_ref, f"vim -u NONE {SCRATCH}/vim.txt\n")
    cli("send", "--surface", idle, "echo relaunch-idle\n")
    cli("send", "--surface", loop, LOOP + "\n")
    cli("send", "--surface", reader, "echo relaunch-reader; " + READER + "\n")
    # A second screen in the first workspace with another reader waiting
    # inside an escape sequence: panes on a screen that is not shown have no
    # view, and a relaunch shows them later.
    cli("select-workspace", "--workspace", first)
    time.sleep(opts.settle)
    before = {ref for ref, _ in surfaces(first)}
    rpc("action.run", {"id": "screen.new"})
    added = wait(lambda: [ref for ref, _ in surfaces(first) if ref not in before], 20)
    if not added:
        sys.exit("screen.new made no terminal")
    cli("send", "--surface", added[0], "echo relaunch-reader-screen2; " + READER + "\n")
    time.sleep(1)
    rpc("action.run", {"id": "screen.previous"})
    time.sleep(3)


def view_rows(workspace_key=None):
    rows = []
    for window in rpc("debug.surfaces", {"text": True}).get("windows", []):
        for pane in window["panes"]:
            if pane.get("kind") == "terminal" and pane.get("presence") == "visible":
                rows.append(pane)
    return rows


def pane_for(surface):
    """The visible pane showing `surface` (matched through the CLI pane list)."""
    for line in cli("list-panes", "--id-format", "both").stdout.splitlines():
        m = re.search(r"(pane:\d+)\s+([0-9A-F-]{36})", line)
        if not m:
            continue
        if re.search(rf"\*\s+{surface}\b", cli("list-pane-surfaces", "--pane", m.group(1)).stdout):
            return "pane_" + m.group(2).replace("-", "").lower()
    return None


def mirror(pane_key):
    return next((p for p in view_rows() if p["pane"] == pane_key), None)


def check_surface(label, surface, title):
    pane_key = pane_for(surface)
    view = pane_key and mirror(pane_key)
    if not view:
        return f"{surface} has no visible view"
    if view.get("attach") != "live":
        # A terminal with a large scrollback takes seconds to decode its
        # replay on a loaded machine; slow is reported, stuck fails.
        started = time.time()
        live = wait(lambda: (mirror(pane_key) or {}).get("attach") == "live" and mirror(pane_key), opts.attach_deadline)
        if not live:
            return f"{surface} attach phase {(mirror(pane_key) or {}).get('attach')} after {opts.attach_deadline:.0f} s"
        slow.append(f"{label} {surface} reached live {time.time() - started + opts.settle:.1f} s after its workspace was shown")
        view = live
    token = f"tok{TOKENS.randrange(1 << 30)}"
    text = view.get("text") or ""
    if "relaunch-reader" in title:
        cli("send", "--surface", surface, token + "\n")
        expect = f"got-{token}"
    elif title.startswith("vim"):
        cli("send", "--surface", surface, f"o{token}\x1b")
        expect = token
    elif title.startswith("top") or "relaunch-loop" in title:
        daemon_before = cli("read-screen", "--surface", surface).stdout
        changed = wait(lambda: (mirror(pane_key) or {}).get("text") not in (None, text), 10)
        if changed:
            return None
        if cli("read-screen", "--surface", surface).stdout == daemon_before:
            print(f"  note: {surface} ({title}) did not redraw in the daemon either (machine busy); not counted")
            return None
        return f"{surface} ({title}) daemon screen changed but the mirror did not in 10 s"
    else:
        cli("send", "--surface", surface, f"echo {token} $(stty size)\n")
        expect = token
    seen = wait(lambda: expect in ((mirror(pane_key) or {}).get("text") or "").replace("\n", ""), 6)
    if not seen:
        return f"{surface} ({title}) mirror never showed {expect}"
    if expect == token and not title.startswith("vim"):
        grid = (mirror(pane_key) or {}).get("surface", {}).get("grid")
        m = re.search(rf"{token} (\d+) (\d+)", ((mirror(pane_key) or {}).get("text") or "").replace("\n", ""))
        if m and grid and grid != f"{m.group(2)}x{m.group(1)}":
            return f"{surface} shell size {m.group(2)}x{m.group(1)} but mirror grid {grid}"
    return None


def pane_screens():
    """Daemon pane resource id -> screen resource id, over every workspace."""
    screens = {}
    for workspace in daemon("list-workspaces").get("data", {}).get("workspaces", []):
        for screen in workspace.get("screens", []):
            for pane in screen.get("panes", []):
                screens[pane.get("resource_id")] = screen.get("resource_id")
    return screens


def shown_screen():
    """(active screen, screen count) of the window's shown workspace (debug.screens)."""
    window = next(iter(rpc("debug.screens").get("windows", [])), {})
    return window.get("active_screen"), len(window.get("screens", []))


def pane_keys():
    """CLI surface ref -> daemon pane resource id, for the current workspace."""
    keys = {}
    for line in cli("list-panes", "--id-format", "both").stdout.splitlines():
        m = re.search(r"(pane:\d+)\s+([0-9A-F-]{36})", line)
        if not m:
            continue
        found = re.search(r"\*\s+(surface:\d+)", cli("list-pane-surfaces", "--pane", m.group(1)).stdout)
        if found:
            keys[found.group(1)] = "pane_" + m.group(2).replace("-", "").lower()
    return keys


def check_hidden(label, surface, title):
    """A pane on a screen that is not shown has no visible view: the
    terminal must still be alive and accept input (daemon read-screen), and
    any view the app keeps for it must not be closed."""
    token = f"tok{TOKENS.randrange(1 << 30)}"
    if "relaunch-reader" in title:
        cli("send", "--surface", surface, token + "\n")
        expect = f"got-{token}"
    elif title.startswith(("top", "vim")) or "relaunch-loop" in title:
        return None if cli("read-screen", "--surface", surface).stdout.strip() else f"{surface} (hidden) daemon screen empty"
    else:
        cli("send", "--surface", surface, f"echo {token}\n")
        expect = token
    if not wait(lambda: expect in cli("read-screen", "--surface", surface).stdout.replace("\n", ""), 6):
        return f"{surface} ({title}, hidden screen) daemon never showed {expect}"
    return None


def check_all(label):
    """Every workspace, every screen: panes on the shown screen get the view
    checks; panes on other screens get the daemon checks first, then each
    screen is shown in turn and its panes get the view checks too."""
    bad = 0

    def report(where, surface, title, problem):
        nonlocal bad
        print(f"  {'BAD' if problem else 'ok '} {label} {where} {surface} {title[:30]!r}{': ' + problem if problem else ''}")
        if problem:
            bad += 1
            failures.append(f"{label}: {problem}")

    for workspace in workspaces():
        cli("select-workspace", "--workspace", workspace)
        time.sleep(opts.settle)
        titles = dict(surfaces(workspace))
        keys = pane_keys()
        screens = pane_screens()
        active, count = shown_screen()
        for surface, title in titles.items():
            if screens.get(keys.get(surface)) not in (None, active):
                report(f"{workspace} hidden-screen", surface, title, check_hidden(label, surface, title))
        for index in range(max(1, count)):
            if index:
                rpc("action.run", {"id": "screen.next"})
                time.sleep(opts.settle)
                active, _ = shown_screen()
            for surface, title in titles.items():
                if screens.get(keys.get(surface)) in (None, active):
                    report(f"{workspace} screen {index + 1}/{count}", surface, title, check_surface(label, surface, title))
        if count > 1:
            rpc("action.run", {"id": "screen.next"})  # back to the first screen
    return bad


def daemon(cmd, **fields):
    """One request on the tag's daemon socket (a separate client)."""
    path = next(iter(glob.glob(os.path.join(TMP, "cmux-tui-*", f"cmux-app-{opts.tag}.sock"))), None)
    if not path:
        return {}
    with socket.socket(socket.AF_UNIX) as sock:
        sock.connect(path)
        stream = sock.makefile("rwb")
        stream.write((json.dumps({"id": 1, "cmd": cmd, **fields}) + "\n").encode())
        stream.flush()
        for line in stream:
            reply = json.loads(line)
            if reply.get("id") == 1:
                return reply
    return {}


def detach_view(pane_key):
    """Drops the app's attach connection for the pane's terminal (detach-client)."""
    surface = None
    for workspace in daemon("list-workspaces").get("data", {}).get("workspaces", []):
        for screen in workspace.get("screens", []):
            for pane in screen.get("panes", []):
                if pane.get("resource_id") == pane_key and pane.get("tabs"):
                    surface = pane["tabs"][pane.get("active_tab", 0)]["surface"]
    clients = [c["client"] for c in daemon("list-clients").get("data", [])
               if c.get("name") == "cmux-next-terminal" and surface in c.get("attached", [])]
    for client in clients:
        daemon("detach-client", client=client)
    return bool(clients)


def link(pane_key):
    return (mirror(pane_key) or {}).get("link") or ""


def check_disconnect(label):
    """A view dropped by the daemon shows disconnected, stays so without an
    event, and re-attaches on a key press and on being shown again."""
    refs = workspaces()
    first = refs[0]
    cli("select-workspace", "--workspace", first)
    time.sleep(opts.settle)
    idle = next((s for s, title in surfaces(first) if not title.startswith(("top", "vim"))), None)
    pane_key = idle and pane_for(idle)
    problems = []
    if not pane_key:
        return [f"{label}: no idle shell to drop"]
    for line in cli("list-panes", "--id-format", "both").stdout.splitlines():
        m = re.search(r"(pane:\d+)\s+([0-9A-F-]{36})", line)
        if m and "pane_" + m.group(2).replace("-", "").lower() == pane_key:
            cli("focus-pane", "--pane", m.group(1), "--workspace", first)
    # 1. Key press.
    if not detach_view(pane_key) or not wait(lambda: link(pane_key).startswith("disconnected"), 5):
        problems.append(f"{label}: {idle} did not show disconnected after detach-client (link {link(pane_key)!r})")
    else:
        time.sleep(3)
        if not link(pane_key).startswith("disconnected"):
            problems.append(f"{label}: {idle} re-attached without an event ({link(pane_key)!r})")
        token = f"tok{TOKENS.randrange(1 << 30)}"
        cli("send", "--surface", idle, f"echo {token}\n")
        rpc("debug.key", {"key": "z"})
        if not wait(lambda: link(pane_key) == "connected" and token in ((mirror(pane_key) or {}).get("text") or ""), 10):
            problems.append(f"{label}: a key press did not re-attach {idle} with the missed output (link {link(pane_key)!r})")
        cli("send", "--surface", idle, "\x15")
    # 2. Shown again.
    if not detach_view(pane_key) or not wait(lambda: link(pane_key).startswith("disconnected"), 5):
        problems.append(f"{label}: second detach-client not seen")
    elif len(refs) > 1:
        cli("select-workspace", "--workspace", refs[1])
        time.sleep(opts.settle)
        cli("select-workspace", "--workspace", first)
        if not wait(lambda: link(pane_key) == "connected", 10):
            problems.append(f"{label}: showing {idle} again did not re-attach it (link {link(pane_key)!r})")
    focus = rpc("debug.focus")
    if focus.get("app_active") or focus.get("key_window"):
        problems.append(f"{label}: the no-activate app took the keyboard during the disconnect check")
    for problem in problems:
        print(f"  BAD {problem}")
    if not problems:
        print(f"  ok  {label} disconnect: key press and show re-attach, nothing without an event")
    failures.extend(problems)
    return problems


def long_top(seconds):
    """A fresh top compared with the daemon every 2 s. Reports each stall:
    the daemon screen moved but the mirror did not for 6 s or more, with the
    view's attach phase, link and surface state at that moment."""
    name = f"relaunch-top-{TOKENS.randrange(1 << 20)}"
    ref = cli("new-workspace", "--name", name).stdout.split()[1]
    surface = wait(lambda: surfaces(ref), 20)[0][0]
    cli("send", "--surface", surface, "top -s 1\n")
    cli("select-workspace", "--workspace", ref)
    time.sleep(3)
    pane_key = wait(lambda: pane_for(surface), 20)
    if not pane_key or not wait(lambda: mirror(pane_key), 20):
        failures.append(f"long top: {surface} never showed a view")
        print(f"  BAD long top: {surface} never showed a view")
        return
    started = time.time()
    last_mirror, last_daemon = None, None
    mirror_since, stalls, samples = time.time(), [], 0
    while time.time() - started < seconds:
        view = mirror(pane_key) or {}
        text = view.get("text")
        screen = cli("read-screen", "--surface", surface).stdout
        samples += 1
        if text != last_mirror:
            last_mirror, mirror_since = text, time.time()
        elif screen != last_daemon and time.time() - mirror_since >= 6:
            state = {k: view.get(k) for k in ("attach", "link", "phase", "presence")}
            state.update({k: (view.get("surface") or {}).get(k) for k in ("rendering_suspended", "drawing", "grid", "replay_applied")})
            stalls.append((round(time.time() - started), round(time.time() - mirror_since), state))
            print(f"  STALL at {stalls[-1][0]} s: mirror unchanged {stalls[-1][1]} s while the daemon moved; {state}")
        last_daemon = screen
        time.sleep(2)
    print(f"long top: {samples} samples over {seconds:.0f} s, {len(stalls)} stall samples")
    if stalls:
        failures.append(f"long top: {len(stalls)} stall samples, first {stalls[0]}")


def record(story, finished, log=print):
    """A run that did every round, under `story`: {metric: path or `not recorded: why`}, or why none was written."""
    if not finished:
        return "none: the run stopped before its last round"
    if any(ms is None for _, ms in relaunches):
        return "none: a relaunch never answered system.ping"
    series = journey.relaunch_e2e_series(relaunches, len(failures))
    return journey.record_all(bench, story, "none", series, log=log)


def run():
    """The checks; returns whether every round ran."""
    launch()
    if opts.long_top:
        long_top(opts.long_top)
        check_leaks("before the final quit")
        return True
    setup()
    check_all("before")
    if opts.disconnect:
        check_disconnect("before")
    modes = [m.strip() for m in opts.modes.split(",") if m.strip()]
    step = 0
    for round_index in range(opts.rounds):
        for mode in modes:
            # Alternate the selected workspace: a terminal in a workspace that
            # is not selected at relaunch attaches at a provisional grid on
            # first show and resizes right after its replay.
            refs = workspaces()
            cli("select-workspace", "--workspace", refs[step % len(refs)])
            if step % 3 == 2:
                rpc("action.run", {"id": "screen.next"})  # relaunch on the second screen
            step += 1
            time.sleep(opts.settle)
            end(mode)
            launch(mode)
            check_all(f"round {round_index + 1} after {mode}")
            if opts.disconnect:
                check_disconnect(f"round {round_index + 1} after {mode}")
    check_leaks("before the final quit")
    return True


def main(argv=None, bench_app=BenchApp):
    args = parse_args(argv)
    if args.matrix:
        return matrix(args, bench_app)
    configure(args, bench_app)
    finished = False
    try:
        finished = run()
    finally:
        bench.stop()  # quits the app, then the tag teardown ends every launch's daemon and terminals
    for note in slow:
        print(f"  slow: {note}")
    for row in leak_rows:
        print(f"  {row['label']} {leakcheck.summary_line(row)}")
    code = 1 if failures else 0
    if opts.story:
        results = record(opts.story, finished)
        print(f"result-v1: {results}")
        if not journey.any_written(results):
            print(f"RESULT-V1 FAIL: no series was written ({results})")
            code = 1
    print(f"{len(failures)} failed checks; scratch {SCRATCH}")
    for failure in failures:
        print(f"  {failure}")
    return code


if __name__ == "__main__":
    sys.exit(main())
