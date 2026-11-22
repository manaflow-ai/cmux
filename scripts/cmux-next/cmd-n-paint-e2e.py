#!/usr/bin/env python3
"""Cmd-N and Cmd-T paint stable on a running tagged build (bd cx-8g3sn).

A new workspace (Cmd-N) or tab (Cmd-T) opens on the New Tab page, the prewarmed spare handed
over (no page loads for it), with no blank or intermediate frame: the window as the window
server composited it, read frame after frame around the key (`debug.new_tab` frame_strip),
changes outside the pane's content area and its tab strip (whose tabs slide) in one step (each frame equals the one before the key
or the settled one), the content area too (Leo 2026-10-13: the New Tab frame drawn under the
adopted page showed one frame on another background), and the content area never turns one flat
color it was not before the key.
Fails on any such frame and prints where the frame strips are.

`--split N` (Leo 2026-10-20: "the layout shifts" when a new workspace opens from a split one): the
workspace is split into N panes first (Cmd-D, then Cmd-Shift-D), so the prewarmed page waits at a
split pane's size and Cmd-N's new workspace, one pane over the whole area, must still show it in
one step: no frame of the page laid out at the old pane's size.

`--cold` (bd cx-ec99): the first Cmd-N goes the moment the app answers on its socket after launch,
with no wait for a ready spare, and its content area must never turn flat (the person sees the
New Tab page's frame, never an empty pane, while its page loads). Start this script before the app.

The app runs already (a capture slot: `capture-host launch`), with its debug socket; or `--app` and
`--tag` launch a tagged DEV build here (no activation, scratch config, as instant-new-surfaces-bench.py
does) and quit it at the end, for CI's GUI runners (cmux-next-frame-pacing.yml, `instant`).

Three arms per key (`--arms`, default all; bench_arms.py), each reported with p50/p95/p99/max of the frames per
opening that were blank or intermediate (`bad_frames`, the warm rule, applied to every arm alike), with each arm's
count of blank frames (`blank_frames`):

  warm   the openings above: each after a ready spare (up to 30 s) and 0.5 s more
  quick  two quick presses (`--quick-runs`, default 3, per key): Cmd-N (Cmd-T: Ctrl-`, Cmd-T, Ctrl-`) through
         `debug.key`, not recorded, then at once the recorded opening, with no wait for the spare to refill
  cold   cold, no wait (`--cold-runs`, default 3, per key): `debug.new_tab drop_spare`, then at once the recorded
         opening; with `--cold` the launch's first Cmd-N counts in this arm too

The bench's HEADLINE per key is the WORST arm: the arm with the most blank frames when any arm has one (the HEADLINE
names its `blank_frames` count), or a missed run, else the highest p95, then the highest max; printed as
`HEADLINE cmd-n-paint/cmd-<key> bad_frames = <arm> arm ... blank_frames=N`. The warm arm alone never stands for the
bench. The quick and cold openings are reported, not judged: the exit status is the warm openings' (and the
`--cold` launch opening's), as before.

`--screen` is another use of the same app and keys, with no judgement and none of the openings above: each key
alone, and each key a set time after another key, as the screen showed it frame by frame, in a session of
`--workspaces` workspaces (new_surface_screen.py has its arguments and its report). The recording is then
`--duration-ms` 2000 long unless that is given. With `w` in `--keys`, the mode also records the Close Tab key
(Command-W): alone, a set time after a New Tab key, the same time after key-downs of the New Tab key at a hold's
times with no repeat flag, and the same time after a hold of the New Tab key (`--close-cases`).

Usage: cmd-n-paint-e2e.py (--socket <path> | --app PATH --tag TAG) [--runs 3] [--keys n,t] [--out DIR] [--cold] [--split N]
       [--arms warm,quick,cold] [--quick-runs 3] [--cold-runs 3] [--json FILE]
       cmd-n-paint-e2e.py (--socket <path> | --app PATH --tag TAG) --screen [--runs 3] [--keys n,t[,w]] [--gaps 0,100]
       [--workspaces N] [--live-shells 8] [--duration-ms 2000] [--page-watch 3] [--json FILE] [--screen-tgz FILE]
       [--close-cases idle,key,downs,hold] [--close-gap-ms 100] [--hold-keys 6] [--hold-delay-ms 375] [--hold-repeat-ms 90]
       [--key-tabs 6,84]
"""
import argparse, atexit, glob, json, os, signal, socket, subprocess, sys, tempfile, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # bench_arms, also under `python3 -I`
import bench_arms  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--socket")
parser.add_argument("--app", help="a tagged DEV app to launch (with --tag) instead of one already running")
parser.add_argument("--tag")
parser.add_argument("--runs", type=int, default=3)
parser.add_argument("--keys", default="n,t", help="Command-<key> openings to check, comma separated")
parser.add_argument("--out", default="/tmp/cmd-n-paint", help="where the app writes each run's frames")
parser.add_argument("--duration-ms", type=float, help="ms recorded after the key (700; with --screen 2000)")
parser.add_argument("--cold", action="store_true", help="the first Cmd-N right after launch: no ready spare, no blank frame")
parser.add_argument("--split", type=int, default=1, help="split the workspace into this many panes before the openings")
parser.add_argument("--arms", default="warm,quick,cold", help="the arms to time (bench_arms.py)")
parser.add_argument("--quick-runs", type=int, default=3, help="quick arm: openings right after another press, per key")
parser.add_argument("--cold-runs", type=int, default=3, help="cold arm: openings right after the spare was dropped, per key")
parser.add_argument("--json", help="write the openings and the arms here")
parser.add_argument("--screen", action="store_true", help="report each key from the screen's frames (new_surface_screen.py); no judgement")
parser.add_argument("--window-screen", default="last", help="the screen of the launched app's window (an index, or last)")
if "--screen" in sys.argv:
    # Only this mode reads its module and its arguments: the openings below need no file that they did not need before.
    import new_surface_screen  # noqa: E402
    new_surface_screen.add_arguments(parser)
opts = parser.parse_args()
if opts.screen and "--screen" not in sys.argv:
    parser.error("--screen: write the flag whole (the mode's module and arguments are read by that word)")
if opts.screen and new_surface_screen.openings(opts) > new_surface_screen.OPENINGS_LIMIT:
    parser.error(f"--screen: {new_surface_screen.openings(opts)} opening records can come in one recording (2 for each New Tab or "
                 f"New Workspace key of it: --gaps, --hold-keys); at most {new_surface_screen.OPENINGS_LIMIT}: the app keeps its "
                 "newest 64 opening records, and the tool counts a recording's new ones in that list")
if opts.duration_ms is None:
    opts.duration_ms = 2000 if opts.screen else 700
ARMS = [a for a in opts.arms.split(",") if a]
if set(ARMS) - set(bench_arms.ARMS):
    parser.error(f"--arms: one of {', '.join(bench_arms.ARMS)}")
if bool(opts.app) != bool(opts.tag) or bool(opts.socket) == bool(opts.app):
    parser.error("pass --socket, or --app with --tag")
if opts.app:
    opts.socket = f"/tmp/cmux-debug-{opts.tag}.sock"


def rpc(method, params=None, timeout=30):
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
        conn.connect(opts.socket)
        conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = conn.recv(1 << 20)
            if not chunk:
                break
            buf += chunk
        conn.close()
        reply = json.loads(buf)
        return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}
    except (OSError, ValueError) as error:
        return {"error": str(error)}


def wait(label, predicate, timeout):
    deadline = time.time() + timeout
    while time.time() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.2)  # test harness wait, not app code
    sys.exit(f"FAIL {label} (timed out after {timeout:.0f} s)")


def spare_ready():
    # No-activate slots have no key window: park the spare in window 0 as a key change does.
    rpc("debug.new_tab", {"action": "retarget"})
    state = rpc("debug.new_tab", {"action": "state"}) or {}
    return any(s.get("ready") for s in state.get("spares") or [])


def launch(app_path, tag, at_end=None):
    """Starts the tagged app on its debug socket with a scratch config; it quits at exit. Returns (the process, the
    quit). `at_end(pid, what the quit did)` is called after the quit at exit."""
    app_path = os.path.abspath(app_path.rstrip("/"))
    binary = next((p for p in sorted(glob.glob(os.path.join(app_path, "Contents/MacOS/*"))) if not p.endswith(".dylib")), None)
    if not binary:
        sys.exit(f"no executable in {app_path}")
    if os.path.exists(opts.socket):
        os.remove(opts.socket)
    scratch = tempfile.mkdtemp(prefix=f"cmd-n-paint-{tag}-")
    open(os.path.join(scratch, "ghostty"), "w").close()
    config = os.path.join(scratch, "cmux.json")
    open(config, "w").write("{}\n")
    env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
           "CMUX_NEXT_TEST_WINDOW_SCREEN": opts.window_screen, "CMUX_NEXT_CONFIG_FILE": config,
           "CMUX_NEXT_GHOSTTY_CONFIG": os.path.join(scratch, "ghostty"), "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1200,900"}
    if opts.screen:
        # --window-look: its keys go into this launch's 2 config files before the app starts (new_surface_look.py).
        unwritten = new_surface_screen.new_surface_look.write(opts.window_look, env)
        if unwritten:
            sys.exit(f"FAIL --window-look: {unwritten}")
        LAUNCHED.update(cli=os.path.join(app_path, "Contents/Resources/bin/cmux"), env=env)
    os.makedirs(opts.out, exist_ok=True)
    log = open(os.path.join(opts.out, f"app-{tag}.log"), "a")
    process = subprocess.Popen([binary], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)

    fact = {}

    def quit_app():
        """Quits the app, one time (the exit's call after the screen mode's own call does nothing). Returns what the
        quit did: the app's answer, whether the process ended in 20 s, whether KILL ended it, its return code."""
        if fact:
            return fact
        fact["ended_before_the_quit"] = process.poll() is not None
        fact["quit_reply"] = rpc("action.run", {"action": "quitEndSessions"}, timeout=10)
        try:
            process.wait(timeout=20)
            fact["ended_in_20_s"] = True
        except subprocess.TimeoutExpired:
            fact["ended_in_20_s"] = False
            os.kill(process.pid, signal.SIGKILL)
            fact["killed_by_the_driver"] = True
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                pass
        fact["returncode"] = process.returncode
        cli = os.path.join(app_path, "Contents/Resources/bin/cmux")
        subprocess.run([cli, "server", "stop", "--session", f"cmux-app-{tag}", "--end-terminals"],
                       env={k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}, capture_output=True, timeout=30)
        if os.path.exists(opts.socket):
            os.remove(opts.socket)
        return fact
    # `at_end` (the screen mode's): what the launch left is printed at each exit, also at a stop inside this launch.
    atexit.register(lambda: at_end(process.pid, quit_app()) if at_end else quit_app())
    wait("the tagged app's socket", lambda: os.path.exists(opts.socket) and (rpc("debug.windows") or {}).get("windows"), 120)
    time.sleep(2)  # test harness wait: the first workspace settles
    return process, quit_app


RUN_END = LAUNCH_FAULT = APP = None
LAUNCHED = {}  # --screen: the launch's environment and the bundle's CLI, for the report's settings lines
if opts.app:
    if opts.screen:
        # The record of the bundle's last run goes into the log whole before a thing of it moves (run_end_record.py).
        import run_end_record  # noqa: E402
        RUN_END = run_end_record.RunEnd(opts.app)
        RUN_END.last()
        new_surface_screen.fresh_session(opts.tag, opts.app)  # the tag's saved session of an earlier run is not this run's
        RUN_END.set_aside()  # after fresh_session: it stops the run when an app of the bundle runs now
    APP = launch(opts.app, opts.tag, RUN_END.own if RUN_END else None)
    if RUN_END:
        LAUNCH_FAULT = RUN_END.launch_fault(APP[0].pid)
failures = []
if opts.split > 1:
    wait("a ready spare before the splits", spare_ready, 60)
    for index in range(opts.split - 1):
        # Split Right, then Split Down: each opens a New Tab page in the new pane (NewTabPage.split).
        rpc("debug.key", {"key": "d", "modifiers": ["command"] + (["shift"] if index else [])})
        time.sleep(1.0)  # test harness wait: the split's pane shows
    # The spare draws the focused pane's context and takes its size once that settles and the layout is still (NewTabSparePool.fitSettle).
    time.sleep(1.0)  # test harness wait
OPENINGS = []


def strip(key, run, arm, cold, label, judged=False):
    """One recorded opening: `debug.new_tab frame_strip` presses Cmd-<key> and reads the frames around it. Its row
    has the warm rule's bad frames (blank or intermediate), the blank frames, the spare, and the arm. A `judged`
    opening (the warm ones and the --cold launch opening, which the exit status reads) stops the script on a
    frame_strip error, as before; the quick and cold arms' openings record it as a missed run."""
    openings = len((rpc("debug.new_tab", {"action": "state"}) or {}).get("openings") or [])
    out = f"{opts.out}/cmd-{key}-{label}"
    reply = rpc("debug.new_tab", {"action": "frame_strip", "key": key, "dir": out, "duration_ms": opts.duration_ms}) or {}
    if "error" in reply:
        if judged:
            sys.exit(f"FAIL frame_strip Cmd-{key.upper()}: {reply}")
        print(f"Cmd-{key.upper()} {label}: frame_strip failed: {reply}", flush=True)
        row = {"key": key, "arm": arm, "label": label, "bad_frames": None, "blank_frames": None, "spare": None}
        OPENINGS.append(row)
        return row, None, []
    # Right after launch the sidebar may lead the content by a frame; the pane must never be empty.
    bad = [f for f in reply["frames"] if f["blank"] or ((f["intermediate"] or f.get("content_intermediate")) and not cold)]
    strict = [f for f in reply["frames"] if f["blank"] or f["intermediate"] or f.get("content_intermediate")]
    # The page is the prewarmed spare, handed over, not a page loaded for this opening.
    recorded = (rpc("debug.new_tab", {"action": "state"}) or {}).get("openings") or []
    opening = recorded[-1] if len(recorded) > openings else {}
    print(f"Cmd-{key.upper()} {label} ({arm}): spare={bool(opening.get('spare'))} {reply['frame_count']} frames every {reply['mean_interval_ms']:.1f} ms, "
          f"intermediate={reply['intermediate']:.0f} content_intermediate={reply.get('content_intermediate', 0):.0f} "
          f"strip_motion={reply.get('strip_intermediate', 0):.0f} "
          f"blank={reply['blank']:.0f} first_change_ms={reply.get('first_change_ms')} settled_ms={reply.get('settled_ms')} strip={out}/strip.png", flush=True)
    if reply.get("spans"):
        print("  marks: " + ", ".join(f"{span['name']} {span['ms']:+.0f} ms" for span in reply["spans"]), flush=True)
    for frame in bad:
        print(f"  {frame['file']} at {frame['ms']:+.0f} ms: outside differs {frame['outside_vs_before']:.3f} from before, "
              f"{frame['outside_vs_final']:.3f} from final, content between={frame.get('content_intermediate')}, blank={frame['blank']}", flush=True)
    row = {"key": key, "arm": arm, "label": label, "bad_frames": len(strict),
           "blank_frames": sum(1 for f in reply["frames"] if f["blank"]), "spare": bool(opening.get("spare")),
           # The content area: the first frame unlike before the key, and the first equal to the settled one for good (the page drawn).
           "first_change_ms": reply.get("first_change_ms"), "settled_ms": reply.get("settled_ms")}
    OPENINGS.append(row)
    return row, opening, bad


def close_new(count):
    """Back to one workspace and tab: Cmd-W closes each new tab (and with it a new workspace)."""
    for _ in range(count):
        rpc("debug.key", {"key": "w", "modifiers": ["command"]})
        time.sleep(0.5)  # test harness wait


def ready_spare(label):
    """The new arms' wait for a ready spare before their first press: never stops the script (a missed run)."""
    deadline = time.time() + 30
    while time.time() < deadline:
        if spare_ready():
            return True
        time.sleep(0.2)  # test harness wait, not app code
    print(f"{label}: no ready spare in 30 s; the opening is a missed run", flush=True)
    return False


def missed(key, arm, label):
    OPENINGS.append({"key": key, "arm": arm, "label": label, "bad_frames": None, "blank_frames": None, "spare": None})


def terminal_tab():
    # Cmd-T on a New Tab page only focuses it: open from a terminal tab (Control-`).
    rpc("debug.key", {"key": "`", "modifiers": ["control"]})
    time.sleep(1.0)  # test harness wait: the terminal tab shows


if opts.screen:
    # Each key as the screen showed it: a report, with no judgement; the openings below do not run.
    # The exit code says only whether the run went to its last case (a stopped run is not 0): no row is judged.
    # A launch of the driver's own that crashed is the exit code 1, after the report is written.
    screen = new_surface_screen.Screen(opts, rpc, {"spare_ready": spare_ready, "terminal_tab": terminal_tab, "close_new": close_new})
    screen.launch_fault, screen.launched = LAUNCH_FAULT, LAUNCHED or None
    screen.launch = None if not RUN_END else {"pid": APP[0].pid, "bundle": RUN_END.bundle, "fault": LAUNCH_FAULT}
    stop = None
    try:
        code = screen.run()["exit_code"]
    except BaseException as error:  # the run's own stop: the app's end record is still printed, then the stop goes on
        stop = error
    if RUN_END and RUN_END.own(APP[0].pid, APP[1]()):
        sys.exit(1)
    if stop:
        raise stop
    sys.exit(code)

for run in range(opts.runs):
    for key in opts.keys.split(","):
        if key == "t":
            terminal_tab()
        cold = opts.cold and run == 0
        if cold:
            wait("the app's socket", lambda: "error" not in (rpc("debug.new_tab", {"action": "state"}, timeout=5) or {"error": "no reply"}), 60)
            rpc("debug.new_tab", {"action": "retarget"})
        else:
            wait(f"a ready spare before Cmd-{key.upper()}", spare_ready, 30)
            time.sleep(0.5)  # test harness wait: the window settles (caret, hover) before the strip
        # The --cold launch opening is the cold arm's launch press; the rest are the warm arm.
        _, opening, bad = strip(key, run, "cold" if cold else "warm", cold, str(run), judged=True)
        if opening is not None and not opening.get("spare") and not cold:
            failures.append(f"Cmd-{key.upper()} run {run} (no spare adopted: {opening or 'no opening'})")
        if bad:
            failures.append(f"Cmd-{key.upper()} run {run}")
        close_new(1)

for key in opts.keys.split(","):
    for index in range(opts.quick_runs if "quick" in ARMS else 0):
        if key == "t":
            terminal_tab()
        if not ready_spare(f"quick Cmd-{key.upper()} {index}"):
            missed(key, "quick", f"quick-{index}")
            continue
        # The first press takes the ready spare; the recorded one follows at once.
        rpc("debug.key", {"key": key, "modifiers": ["command"]})
        if key == "t":
            rpc("debug.key", {"key": "`", "modifiers": ["control"]})  # Cmd-T from a terminal tab again, at once
        strip(key, index, "quick", True, f"quick-{index}")
        close_new(3 if key == "t" else 2)
    for index in range(opts.cold_runs if "cold" in ARMS else 0):
        if key == "t":
            terminal_tab()
        if not ready_spare(f"cold Cmd-{key.upper()} {index}"):
            missed(key, "cold", f"cold-{index}")
            continue
        rpc("debug.new_tab", {"action": "drop_spare"})  # the spare is gone; nothing waits for its refill
        strip(key, index, "cold", True, f"cold-{index}")
        close_new(1)

ARM_REPORT = {}
print("", flush=True)
for key in opts.keys.split(","):
    # A blank frame is a defect a person sees (an empty pane): the arm with the most blank frames is the HEADLINE,
    # and the HEADLINE names the count, whatever the intermediate frames of the other arms.
    blank = {arm: sum(o["blank_frames"] or 0 for o in OPENINGS if o["key"] == key and o["arm"] == arm) for arm in ARMS}
    samples = {arm: [o["bad_frames"] for o in OPENINGS if o["key"] == key and o["arm"] == arm] for arm in ARMS}
    ARM_REPORT[f"cmd_{key}.bad_frames"] = bench_arms.report(f"cmd-n-paint/cmd-{key}", "bad_frames", "frames", samples,
                                                            out=lambda line: print(line, flush=True),
                                                            defects=blank, defect_name="blank_frames")
    # The key to the page drawn as it settles (its first frame equal to the last for good), per arm.
    ARM_REPORT[f"cmd_{key}.settled_ms"] = bench_arms.report(f"cmd-n-paint/cmd-{key}", "settled_ms", "ms",
                                                            {arm: [o.get("settled_ms") for o in OPENINGS if o["key"] == key and o["arm"] == arm] for arm in ARMS},
                                                            out=lambda line: print(line, flush=True))
    for arm in ARMS:
        rows = [o for o in OPENINGS if o["key"] == key and o["arm"] == arm]
        print(f"ARM cmd-n-paint/cmd-{key} spare_adopted {arm}: {sum(1 for o in rows if o['spare'])}/{len(rows)}", flush=True)
if opts.json:
    with open(opts.json, "w") as handle:
        json.dump({"openings": OPENINGS, "arms": ARM_REPORT, "headline_rule": bench_arms.RULE}, handle, indent=1)

if failures:
    sys.exit(f"FAIL blank or intermediate frames: {', '.join(failures)}")
print("PASS no blank or intermediate frame")
