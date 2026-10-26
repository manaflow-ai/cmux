#!/usr/bin/env python3
"""Cmd-N, Cmd-T, Ctrl-`, Cmd-D and Cmd-Shift-D: key to visible, idle and under load (instant-new-surfaces).

Launches the tagged app itself (no activation, scratch config), makes a terminal workspace, then
runs `debug.new_tab {action: bench_create, command}` for each command `--runs` times: the key goes
through the real key path (`debug.key`) and the app reports, per run, the key's main-thread ms,
the display frame at which the result shows (`visible_ms`, `frames_to_visible`), when the
daemon's object replaced the provisional one (`confirmed_ms`) and its BenchSpans marks.

Two phases: `idle`, then `load` (every core busy with `yes`, plus `--storm` workers looping the
tag's CLI against its daemon). With `--budget-frames N` the run fails when any command's p95
display frame of visibility (1 = the first frame drawn after the key) is above N or a key's main-thread time is above `--budget-key-ms`.

`--commands` picks the commands (default all); `--workspaces 10,100` runs every phase again at
each workspace count (the app holds that many terminal workspaces; the bench's is the shown one).

The close leg (Cmd-W): every Cmd-T run is undone by Cmd-W through `debug.key`, stamped with its send time
(CLOCK_UPTIME_RAW, the NSEvent clock). Its key to committed frame is the `closeTab` run's `action.commit`
(`debug.action_budget`: the key event's age at the run's start plus the run's start to the end of the Core
Animation commit that showed it, the `input_to_commit` of ChromeOS/Chrome's EventLatency); its frames are
`debug.frames` intervals over `--close-window-ms` after the key, with no socket request inside the window (a
request is main-thread work). Dropped = intervals over 1.5 refresh periods (`debug.frames` `missed`, the same
rule as the create runs' `frames.missed`). The report keeps every key it had (`summary`, `runs`; perf-budgets.py
reads `summary`) and adds `close` (per phase) and `results_v1`.

`--session light` (default) measures the bench's own terminal workspace; `--session stress` builds STRESS first
(perf-stress-session.py: 60 workspaces, the measured one with 14 panes of 6 tabs, 10 busy terminals) and measures
in its measured workspace. Every series is also written as one cmux-perf-result/v1 file into `--out` through
BenchApp.record (percentiles: scripts/perf-lab/perf_stats.py), named `<key>.<session>.<metric>` for the idle phase
at the launched workspace count (`cmd_t.light.dropped`, `cmd_w.stress.key_to_frame`) and
`<key>.<session>.<phase>.<metric>` for the others (`cmd_t.light.load.dropped`, `cmd_t.light.idle_10ws.dropped`).
Keys: cmd_n, cmd_t, ctrl_backtick, cmd_d, cmd_shift_d, cmd_shift_l (new_browser) and cmd_w; metrics key_to_frame
(ms, key to the frame that showed it), dropped (count per run), key_ms and confirmed (create runs), commit and frame
(Cmd-W: perform to commit, and every frame interval of the close window). Lab stories:
scripts/perf-lab/stories.d/new-surfaces.json and new-surfaces-stress.json.

Usage: instant-new-surfaces-bench.py --tag TAG --app PATH [--runs 12] [--commands new_terminal]
       [--workspaces 10,100] [--session light|stress] [--out DIR] [--json FILE]
"""
import argparse, collections, glob, json, os, signal, socket, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from bench_launch import PERF_LAB, BenchApp, RecordError, bundle_id, load_by_path  # noqa: E402

perf_stats = load_by_path("perf_stats", os.path.join(PERF_LAB, "perf_stats.py"))
perf_result = load_by_path("perf_result", os.path.join(PERF_LAB, "perf_result.py"))
pct = perf_stats.pct

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--app", required=True)
parser.add_argument("--runs", type=int, default=12)
parser.add_argument("--storm", type=int, default=8)
parser.add_argument("--phases", default="idle,load")
parser.add_argument("--commands", default="split_right,split_down,new_tab,new_terminal,new_workspace")
parser.add_argument("--workspaces", default="", help="comma-separated workspace counts to run every phase at (empty: as launched)")
parser.add_argument("--budget-frames", type=float, default=0, help="fail when a command's p95 display frame of visibility is above this (1: the first frame; 0: report only)")
parser.add_argument("--budget-key-ms", type=float, default=16.7)
parser.add_argument("--hang-stacks", action="store_true",
                    help="as the every-action sweep: hang watchdog at 8 ms, the agent pane mock (Cmd-N opens its New Tab page), "
                         "and each run's longest main-thread stall with its whole stack (64 frames) in the row and the log")
parser.add_argument("--session", choices=["light", "stress"], default="light",
                    help="light: the bench's own terminal workspace; stress: build STRESS (perf-stress-session.py) first")
parser.add_argument("--story", help="result-v1 story (default new-surfaces, or new-surfaces-stress with --session stress)")
parser.add_argument("--build-config", choices=["bench", "bench-checks", "release", "debug"],
                    help="result-v1 build config of a bench-hooks bundle that does not stamp it (BenchApp.record)")
parser.add_argument("--close-window-ms", type=float, default=600,
                    help="how long the Cmd-W leg records frames after its key (the close and its motion)")
parser.add_argument("--out", default="/tmp")
parser.add_argument("--json")
opts = parser.parse_args()
if opts.session == "stress" and opts.workspaces:
    parser.error("--session stress has its own 60 workspaces: drop --workspaces")
STORY = opts.story or ("new-surfaces" if opts.session == "light" else "new-surfaces-stress")
TAG, APP = opts.tag, os.path.abspath(opts.app.rstrip("/"))
BUNDLE_ID = bundle_id(APP) or f"com.cmuxterm.app.debug.{TAG}"
SOCKET = f"/tmp/cmux-debug-{TAG}.sock"
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")
BINARY = next((p for p in sorted(glob.glob(os.path.join(APP, "Contents/MacOS/*"))) if not p.endswith(".dylib")), None)
SCRATCH = tempfile.mkdtemp(prefix=f"instant-{TAG}-")
open(os.path.join(SCRATCH, "ghostty"), "w").close()
CONFIG = os.path.join(SCRATCH, "cmux.json")
open(CONFIG, "w").write("{}\n")
CLI_ENV = {"HOME": os.environ["HOME"], "PATH": "/usr/bin:/bin", "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "CMUX_SOCKET_PATH": SOCKET, "CMUX_QUIET": "1", "CMUX_TAG": TAG,
           "CMUX_BUNDLE_ID": BUNDLE_ID, "CMUX_BUNDLED_CLI_PATH": CLI}
LAUNCHED, LOAD = [], []
COMMANDS = [c for c in opts.commands.split(",") if c]


def run(*args, timeout=30):
    return subprocess.run([CLI, *args], capture_output=True, text=True, timeout=timeout, env=CLI_ENV)


def rpc(method, params=None, timeout=30):
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
        conn.connect(SOCKET)
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


def wait(check, seconds, step=0.25):
    deadline = time.time() + seconds
    while time.time() < deadline:
        try:
            value = check()
        except Exception:
            value = None
        if value:
            return value
        time.sleep(step)  # test harness polling a live app
    return None


def panes():
    return [p for w in (rpc("debug.surfaces").get("windows") or []) for p in w.get("panes", [])]


def window_key():
    return ((rpc("debug.windows") or {}).get("windows") or [{}])[0].get("id")


def uptime():
    """CLOCK_UPTIME_RAW seconds: the clock of NSEvent timestamps, so the app ages a stamped key from its send."""
    return time.clock_gettime(time.CLOCK_UPTIME_RAW) if hasattr(time, "CLOCK_UPTIME_RAW") else None


def start_load():
    for _ in range(os.cpu_count() or 8):
        LOAD.append(subprocess.Popen(["yes"], stdout=subprocess.DEVNULL))
    loop = f'while :; do "{CLI}" workspace list >/dev/null 2>&1; "{CLI}" tree >/dev/null 2>&1; done'
    for _ in range(opts.storm):
        LOAD.append(subprocess.Popen(["/bin/sh", "-c", loop], env=CLI_ENV, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
    time.sleep(3)  # test harness: let the load ramp


def stop_load():
    for proc in LOAD:
        try:
            proc.terminate()
        except OSError:
            pass
    LOAD.clear()


def undo(command, window, before_panes):
    """Back to one terminal pane in the bench workspace. After Cmd-T it is the measured Cmd-W (`close_leg`)."""
    if command == "new_workspace":
        rpc("action.run", {"action": "closeWorkspace"})
        wait(lambda: (focused() or {}).get("kind") == "terminal", 10)
        return None
    if command == "new_tab":
        return close_leg(window, before_panes)
    rpc("debug.key", {"key": "w", "modifiers": ["command"], "window": window})
    wait(lambda: len(panes()) <= before_panes and (focused() or {}).get("kind") == "terminal", 10)
    return None


CLOSE_ACTION = "closeTab"  # Cmd-W's action (TabActionCatalog)


def newest_action_sequence():
    """The sequence of the newest action run the app recorded (-1 for none): the Cmd-W's run is the first
    `closeTab` after it."""
    recent = (rpc("debug.action_budget", {"limit": 1}) or {}).get("recent") or []
    return recent[0].get("sequence", -1) if recent else -1


def close_run(after):
    """The first `closeTab` run after sequence `after` (debug.action_budget's newest runs, newest first)."""
    reply = rpc("debug.action_budget", {"limit": 32}) or {}
    runs = [r for r in reply.get("recent") or [] if r.get("sequence", -1) > after]
    closes = sorted((r for r in runs if r.get("id") == CLOSE_ACTION), key=lambda r: r["sequence"])
    return (closes[0] if closes else None), [r.get("id") for r in runs], reply.get("error")


def close_leg(window, before_panes):
    """Cmd-W on the tab Cmd-T made, through the real key path: key to the committed frame of its `closeTab`
    run (the key's age at the run's start plus the run to its Core Animation commit) and the frame intervals
    of the close and its motion. No socket request runs inside the frame window: a request is main-thread work."""
    mark = newest_action_sequence()
    rpc("debug.frames", {"action": "start"})
    key = {"key": "w", "modifiers": ["command"], "window": window}
    stamp = uptime()
    if stamp is not None:
        key["timestamp"] = stamp
    sent = rpc("debug.key", key)
    time.sleep(opts.close_window_ms / 1000)  # test harness: the frame window, with no request in it
    frames = rpc("debug.frames", {"action": "stop", "raw": True}) or {}
    run, seen, error = close_run(mark)
    committed = bool(run) and run.get("outcome") == "committed"
    age, commit = (run or {}).get("input_age_ms"), (run or {}).get("commit_ms")
    out = {
        "key_error": sent.get("error") if isinstance(sent, dict) else None,
        "action": run, "actions_seen": seen if not run else None, "action_budget_error": error,
        "commit_ms": commit if committed else None,
        # The key's age is -1 when the run did not answer an input event: then there is no key-to-frame time.
        "key_to_frame_ms": round(age + commit, 3) if committed and age is not None and age >= 0 else None,
        "dropped": frames.get("missed") if not frames.get("error") else None,
        "refresh_ms": frames.get("refresh_ms"), "frames_error": frames.get("error"),
        "intervals_ms": frames.get("intervals_ms") or [],
    }
    wait(lambda: len(panes()) <= before_panes and (focused() or {}).get("kind") == "terminal", 10)
    return out


def focused():
    return next((p for p in panes() if p.get("focused")), None)


def ensure_terminal():
    """A shown terminal workspace: `newTab` from a script makes one terminal; focus: true shows it."""
    if (focused() or {}).get("kind") == "terminal":
        return True
    reply = rpc("action.run", {"action": "newTab", "args": {"focus": True, "name": "instant-bench"}, "wait": True})
    print("newTab:", json.dumps(reply)[:300], flush=True)
    ok = wait(lambda: (focused() or {}).get("kind") == "terminal", 30)
    time.sleep(1)  # test harness: shell prompt
    return ok


def bench(phase, window):
    rows = []
    if not ensure_terminal():
        sys.exit("no focused terminal: " + json.dumps(panes())[:800])
    for command in COMMANDS:
        for index in range(opts.runs):
            if command != "new_workspace" and not ensure_terminal():
                sys.exit("no focused terminal: " + json.dumps(panes())[:800])
            before = len(panes())
            rpc("debug.hangs", {"clear": True})
            result = rpc("debug.new_tab", {"action": "bench_create", "command": command}, timeout=20) or {}
            result.update({"phase": phase, "run": index})
            rows.append(result)
            marks = {s["name"]: round(s["at"], 1) for s in result.get("spans") or [] if s.get("ms", 0) == 0}
            print(f"{phase} {command} #{index}: key={result.get('key_ms')} visible={result.get('visible_ms')} "
                  f"frame={frame_of(result)} confirmed={result.get('confirmed_ms')} marks={marks} "
                  f"err={result.get('error')}", flush=True)
            time.sleep(0.4)  # test harness: let the creation's shell start before closing it
            hangs = rpc("debug.hangs", {"limit": 8 if opts.hang_stacks else 0}) or {}
            result["count250"] = hangs.get("count250") if isinstance(hangs, dict) else None  # stalls >= 250 ms (perf-cron)
            if opts.hang_stacks:
                result["hangs"] = longest_stall(hangs)
                stall = result["hangs"].get("stack") or {}
                print(f"  stalls={result['hangs'].get('count')} longest={stall.get('ms')} cpu={stall.get('cpu_ms')}", flush=True)
                for frame in stall.get("frames") or []:
                    print("    " + frame, flush=True)
            close = undo(command, window, before)
            if close is not None:
                result["close"] = close
                print(f"  cmd_w: key_to_frame={close['key_to_frame_ms']} commit={close['commit_ms']} "
                      f"dropped={close['dropped']} refresh={close['refresh_ms']} "
                      f"err={close['key_error'] or close['frames_error'] or close['action_budget_error']}"
                      + (f" no {CLOSE_ACTION} run (saw {close['actions_seen']})" if close["action"] is None else ""),
                      flush=True)
            time.sleep(0.3)
    return rows


def longest_stall(hangs):
    """debug.hangs: the stall count and the longest stall with its whole main-thread stack (bounded), as the
    every-action sweep's `hang_summary`: a window-server wait shows its AppKit and app callers only there."""
    records = [r for r in (hangs.get("records") or []) if r.get("kind", "stall") == "stall"] if isinstance(hangs, dict) else []
    longest = max(records, key=lambda r: r.get("duration_ms") or 0, default=None)
    out = {"count": hangs.get("count") if isinstance(hangs, dict) else None}
    if longest:
        out["stack"] = {"ms": round(longest.get("duration_ms") or 0, 2), "cpu_ms": round(longest.get("cpu_ms") or 0, 2),
                        "frames": (longest.get("frames") or [])[:64]}
    return out


def workspace_count():
    snap = rpc("snapshot.get") or {}
    topology = (snap.get("topology") or snap) if isinstance(snap, dict) else {}
    return len(topology.get("workspaces") or [])


def grow_workspaces(count):
    """At least `count` terminal workspaces, the bench's still shown (scripts make them unfocused)."""
    have = workspace_count()
    for index in range(have, count):
        rpc("action.run", {"action": "newTab", "args": {"name": f"bench-{index}"}, "wait": True})
    now = workspace_count()
    print(f"workspaces: {have} -> {now}", flush=True)
    if now < count:
        sys.exit(f"could not reach {count} workspaces (have {now})")
    return now


def frame_of(row, key="visible_ms"):
    """Which display frame after the key showed it (1 = the first frame the display link drew).
    The app's `frames_to_visible` divides by the refresh period, which counts a late first frame
    (main thread busy, display link start) as several; this walks the frames actually drawn."""
    frames = row.get("frames") or {}
    at, seen = frames.get("first_tick_ms"), row.get(key)
    if at is None or seen is None:
        return None
    index, intervals = 1, frames.get("intervals_ms") or []
    while seen > at + 0.5 and index - 1 < len(intervals):
        at += intervals[index - 1]
        index += 1
    return index


def summary(rows):
    out = {}
    for phase in sorted({r["phase"] for r in rows}):
        for command in COMMANDS:
            sel = [r for r in rows if r["phase"] == phase and r.get("command") == command]
            vis = [r.get("visible_ms") for r in sel]
            out[f"{phase}/{command}"] = {
                "n": len(sel), "missed": sum(v is None for v in vis),
                "key_p50": pct([r.get("key_ms") for r in sel], .5), "key_p95": pct([r.get("key_ms") for r in sel], .95),
                "key_p99": pct([r.get("key_ms") for r in sel], .99), "key_max": pct([r.get("key_ms") for r in sel], 1),
                "visible_p50": pct(vis, .5), "visible_p95": pct(vis, .95), "visible_p99": pct(vis, .99),
                "visible_max": pct(vis, 1),
                "frames_p50": pct([frame_of(r) for r in sel], .5),
                "frames_p95": pct([frame_of(r) for r in sel], .95),
                "frames_p99": pct([frame_of(r) for r in sel], .99),
                "frames_max": pct([frame_of(r) for r in sel], 1),
                "dropped_max": pct([dropped(r) for r in sel], 1),
                "dropped_total": sum(d for d in (dropped(r) for r in sel) if d is not None),
                "first_frame_ms_p50": pct([(r.get("frames") or {}).get("first_tick_ms") for r in sel], .5),
                "confirmed_p50": pct([r.get("confirmed_ms") for r in sel], .5),
                "confirmed_p95": pct([r.get("confirmed_ms") for r in sel], .95),
                "confirmed_p99": pct([r.get("confirmed_ms") for r in sel], .99),
            }
    return out


def dropped(row):
    """A create run's dropped frames: its frame intervals over 1.5 refresh periods (BenchFrames `missed`)."""
    return (row.get("frames") or {}).get("missed")


def close_summary(rows):
    """Per phase, the Cmd-W leg after each Cmd-T (`close_leg`)."""
    out = {}
    for phase in sorted({r["phase"] for r in rows if r.get("close")}):
        legs = [r["close"] for r in rows if r["phase"] == phase and r.get("close")]
        keyed = [c["key_to_frame_ms"] for c in legs]
        intervals = [i for c in legs for i in c["intervals_ms"]]
        out[f"{phase}/cmd_w"] = {
            "n": len(legs), "missed": sum(v is None for v in keyed),
            **{f"key_to_frame_{k}": v for k, v in perf_stats.summary(keyed).items() if k != "n"},
            **{f"commit_{k}": v for k, v in perf_stats.summary([c["commit_ms"] for c in legs]).items() if k != "n"},
            "dropped_max": pct([c["dropped"] for c in legs], 1),
            "dropped_total": sum(c["dropped"] for c in legs if c["dropped"] is not None),
            **{f"frame_{k}": v for k, v in perf_stats.summary(intervals).items()},
        }
    return out


# The result-v1 key of each command: the perf-budgets.json row prefix (perf-budgets.py rows_new_surfaces).
SERIES_KEYS = {"new_workspace": "cmd_n", "new_tab": "cmd_t", "new_terminal": "ctrl_backtick",
               "split_right": "cmd_d", "split_down": "cmd_shift_d", "new_browser": "cmd_shift_l"}
ENGINES = {"cef": "chromium", "webkit": "webkit"}


def series_name(key, phase):
    """`<key>.<session>` for the idle phase at the launched workspace count, else `<key>.<session>.<phase>`
    (`idle@10ws` -> `idle_10ws`): the lab stories claim only the first form."""
    base = f"{key}.{opts.session}"
    return base if phase == "idle" else f"{base}.{phase.replace('@', '_')}"


def result_series(rows):
    """{metric: (unit, engine, samples)} of every measured series, raw samples in run order."""
    out = {}
    for phase in sorted({r["phase"] for r in rows}):
        for command in COMMANDS:
            sel = [r for r in rows if r["phase"] == phase and r.get("command") == command]
            if not sel:
                continue
            name = series_name(SERIES_KEYS.get(command, command), phase)
            engines = collections.Counter(ENGINES.get(r.get("engine"), "none") for r in sel)
            engine = engines.most_common(1)[0][0] if command == "new_browser" else "none"
            out[f"{name}.key_to_frame"] = ("ms", engine, [r.get("visible_ms") for r in sel])
            out[f"{name}.dropped"] = ("count", engine, [dropped(r) for r in sel])
            out[f"{name}.key_ms"] = ("ms", engine, [r.get("key_ms") for r in sel])
            out[f"{name}.confirmed"] = ("ms", engine, [r.get("confirmed_ms") for r in sel])
        legs = [r["close"] for r in rows if r["phase"] == phase and r.get("close")]
        if legs:
            name = series_name("cmd_w", phase)
            out[f"{name}.key_to_frame"] = ("ms", "none", [c["key_to_frame_ms"] for c in legs])
            out[f"{name}.dropped"] = ("count", "none", [c["dropped"] for c in legs])
            out[f"{name}.commit"] = ("ms", "none", [c["commit_ms"] for c in legs])
            out[f"{name}.frame"] = ("ms", "none", [i for c in legs for i in c["intervals_ms"]])
    return out


def record_results(launcher, rows):
    """One cmux-perf-result/v1 file per series (BenchApp.record). A series with no sample, or one the bench cannot
    describe truthfully (no build sha, no features snapshot), is not written; its reason is returned instead."""
    written = {}
    for metric, (unit, engine, samples) in result_series(rows).items():
        samples = [s for s in samples if isinstance(s, (int, float))]
        if not samples:
            written[metric] = "not recorded: no samples"
            continue
        try:
            written[metric] = str(launcher.record(STORY, metric, unit, samples, better="lower", engine=engine))
        except (RecordError, perf_result.ResultError) as error:
            written[metric] = f"not recorded: {error}"
        if written[metric].startswith("not recorded"):
            print(f"result-v1 {STORY}/{metric}: {written[metric]}", flush=True)
    return written


app = None


def cleanup():
    stop_load()
    if not LAUNCHED:
        return
    rpc("action.run", {"action": "quitEndSessions"}, timeout=10)
    if app:
        try:
            app.wait(timeout=20)
        except subprocess.TimeoutExpired:
            os.kill(app.pid, signal.SIGKILL)
    subprocess.run([CLI, "server", "stop", "--session", f"cmux-app-{TAG}", "--end-terminals"],
                   env={k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}, capture_output=True, timeout=30)
    ps = subprocess.run(["ps", "-axo", "pid=,command="], capture_output=True, text=True).stdout
    for line in ps.splitlines():
        parts = line.split(None, 1)
        if len(parts) == 2 and parts[1].startswith(APP + "/") and int(parts[0]) != os.getpid():
            try:
                os.kill(int(parts[0]), signal.SIGTERM)
            except OSError:
                pass
    if os.path.exists(SOCKET):
        os.remove(SOCKET)


def main():
    global app, SOCKET
    # No socket check here: BenchApp.launch() refuses a live same-tag app (any bundle path) and unlinks only a
    # socket nothing accepts on.
    env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
           "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": CONFIG,
           "CMUX_NEXT_GHOSTTY_CONFIG": os.path.join(SCRATCH, "ghostty"), "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1200,900"}
    if opts.hang_stacks:
        env.update({"CMUX_NEXT_HANG_THRESHOLD_MS": "8", "CMUX_NEXT_AGENT_PANE_MOCK": "1", "ACPMUX_AGENT_LAUNCH": "deny"})
    # One launch path (bench_launch.py): socket in the state folder, bench env, a clear reason when it does not come up.
    launcher = BenchApp(APP, out=opts.out, log_name=f"app-{TAG}.log", window=None, screen=None, teardown=False, env=env,
                        perf_session=opts.session, build_config=opts.build_config)
    try:
        launcher.launch(timeout=120, on_start=lambda process: LAUNCHED.append(process.pid))
    finally:
        app = launcher.process
    SOCKET = launcher.socket
    CLI_ENV["CMUX_SOCKET_PATH"] = SOCKET
    time.sleep(2)  # test harness: shell prompt
    stress = None
    if opts.session == "stress":
        # STRESS's measured workspace ends shown and focused, its selected tabs terminals (perf-stress-session.py).
        module = load_by_path("perf_stress_session", os.path.join(HERE, "perf-stress-session.py"))
        stress = module.Stress(rpc).build()
        print("STRESS-SESSION " + json.dumps(stress), flush=True)
    window = window_key()
    rows = []
    counts = [int(c) for c in opts.workspaces.split(",") if c] or [None]
    for count in counts:
        suffix = ""
        if count is not None:
            ensure_terminal()
            suffix = f"@{grow_workspaces(count)}ws"
        for phase in opts.phases.split(","):
            if phase == "load":
                start_load()
            try:
                rows += bench(phase + suffix, window)
            finally:
                stop_load()
    result = {"tag": TAG, "host": os.uname().nodename, "cpus": os.cpu_count(), "summary": summary(rows), "runs": rows,
              "session": opts.session, "story": STORY, "close": close_summary(rows)}
    if stress is not None:
        result["stress_session"] = stress
    result["results_v1"] = record_results(launcher, rows)
    print("\nSUMMARY", json.dumps(result["summary"], indent=1), flush=True)
    print("CLOSE", json.dumps(result["close"], indent=1), flush=True)
    if opts.json:
        open(opts.json, "w").write(json.dumps(result, indent=1))
    if opts.budget_frames:
        bad = [k for k, v in result["summary"].items()
               if v["missed"] or (v["frames_p95"] or 99) > opts.budget_frames or (v["key_max"] or 0) > opts.budget_key_ms]
        print("BUDGET", "FAIL " + ", ".join(bad) if bad else "PASS", flush=True)
        return not bad
    return True


ok = False
try:
    ok = main()
finally:
    cleanup()
sys.exit(0 if ok else 1)
