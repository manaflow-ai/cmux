#!/usr/bin/env python3
"""App gestures, measured in a real window (app-efficiency, Leo 2026-10-21: "systemically why are things slow
how can they get faster / e.g. splitting, e.g. cmd shift d, e.g. adding stuff to sidebar, all that...").

Launches a tagged cmux-next app (scratch config, empty Ghostty config). For each --workspaces count the app
holds that many terminal workspaces (the first one, the bench workspace, has --scrollback lines), and each
scenario's gesture is timed from the press until the window rests (--settle seconds):

  split-right                Cmd-D in the bench workspace (`debug.key`, the real key path; --input action
                             runs splitRight instead), then the new pane closes (untimed)
  split-down                 Cmd-Shift-D (splitDown), then its close
  right-sidebar-open/-close  Cmd-Opt-B (toggleRightSidebar, the side pane) twice; which press opened it is read
                             from the main pane's width
  sidebar-hide/-show         Cmd-B (toggleSidebar) twice, read the same way
  new-top                    New Workspace at Top above the existing ones, then it closes (untimed)
  switch                     goToWorkspace between the bench workspace and the last one, both ways

Per gesture, from `debug.frames` (raw per-frame data): display frame intervals (p50/p95/p99/max), missed
vsyncs at the display's rate, dropped frames at 120 Hz (counted from the intervals on a 120 Hz display;
on a slower one estimated per frame from the interval and the main thread's work: work over 8.33 ms misses a
120 Hz vsync), the main thread's busy ms per frame (the main run loop's awake time between two frames), and
`NSView.layout()` calls and window layout passes per frame (`LayoutPassGuard`). Also: hangs and run-loop gaps
of 8.3 ms or more (`debug.hangs`), the busiest layout view classes (`debug.layers`), sidebar and layout work
counters (`debug.sidebar_perf`, `debug.layout_counters`), and the app's own press-to-commit ms for new-top
(`debug.new_workspace`) and switch (`debug.tab_switch`). The tag's daemon keeps workspaces across launches, so
the run first closes any an earlier run left and starts from the one it shows.

The summary pools every round's frames per scenario; totals are medians over rounds. It prints a Markdown
table (--markdown writes it to a file) and a REPORT-JSON line. Slow numbers are data, not failures. The run
fails (RESULT FAIL, with the reasons in `failures`) when the window draws no frames (an unlit or occluded
console), the app stops holding a requested workspace count, or any requested gesture did not do what it
names in every round: a split made no pane, a toggle press left the main pane's width unchanged or a round
lacks one of its two halves, new-top's workspace is not the sidebar's first workspace row, or a switch did
not land), a measured gesture drew no frames, `--input key` could not press the key (the action path runs only
with `--input action`), or an untimed restore (closing the new pane or workspace) did not bring the app back to
the requested count, which stops the run. A partial table is never a PASS.

Fleet (alone on an owned mini's console; the allowlisted entry builds the tagged app at the ref):
  cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/split-spring.sh \
    --ref <sha> --key <key> --arg=--suite=app-perf --artifact artifacts/split-spring/report.json \
    [--arg=--workspaces=10,50] [--arg=--rounds=5] [--arg=--scenarios=split-right,switch]

On a capture mini over ssh (outside the console's GUI session), --open starts the app through LaunchServices.

Usage: app-perf.py --tag <tag> --app PATH [--workspaces 10,50] [--scenarios ...] [--rounds 5] [--settle 1.0]
       [--scrollback 2000] [--input key|action] [--open] [--sha SHA] [--json PATH] [--markdown PATH] [--out DIR]
"""
import argparse, glob, json, math, os, signal, socket, subprocess, sys, tempfile, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bench_launch import LaunchError, launch_app  # noqa: E402

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bench_memory  # noqa: E402  (process lookups for --open)

SCENARIOS = ["split-right", "split-down", "right-sidebar", "sidebar", "new-top", "switch"]
parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--app", required=True)
parser.add_argument("--workspaces", default="10,50", help="workspace counts the app holds while the scenarios run")
parser.add_argument("--scenarios", default=",".join(SCENARIOS))
parser.add_argument("--rounds", type=int, default=5)
parser.add_argument("--settle", type=float, default=1.0, help="seconds timed after each press")
parser.add_argument("--scrollback", type=int, default=2000)
parser.add_argument("--input", choices=["key", "action"], default="key")
parser.add_argument("--open", action="store_true",
                    help="launch through LaunchServices (`open -n -g`), for a shell outside the console's GUI session (ssh)")
parser.add_argument("--sha", default="", help="the measured commit, for the table header (default: git rev-parse HEAD here)")
parser.add_argument("--json")
parser.add_argument("--markdown")
parser.add_argument("--out", default="/tmp")
opts, _unknown = parser.parse_known_args()
# LaunchServices reports the real path (/private/tmp for /tmp), so match processes by it.
TAG, APP = opts.tag, os.path.realpath(opts.app.rstrip("/"))
SOCKET = f"/tmp/cmux-debug-{TAG}.sock"
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")
BINARY = next((p for p in sorted(glob.glob(os.path.join(APP, "Contents/MacOS/*"))) if not p.endswith(".dylib")), None)
SCRATCH = tempfile.mkdtemp(prefix=f"app-perf-{TAG}-")
open(os.path.join(SCRATCH, "ghostty"), "w").close()
CONFIG = os.path.join(SCRATCH, "cmux.json")
open(CONFIG, "w").write("{}\n")
WINDOW = (80, 80, 1600, 1000)
FRAME_120 = 1000 / 120
REPORT = {"tag": TAG, "runs": [], "summary": []}
app = None


def rpc(method, params=None, timeout=30):
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
        conn.connect(SOCKET)
        conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = conn.recv(1 << 22)
            if not chunk:
                break
            buf += chunk
        conn.close()
        reply = json.loads(buf)
        return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}
    except (OSError, ValueError) as error:
        return {"error": str(error)}


def error_of(reply):
    return str(reply.get("error")) if isinstance(reply, dict) and reply.get("error") else None


def action(name, args=None, settle=0.0):
    # A socket caller may name only a headless origin (ControlOrigin: `user` is in-process only).
    reply = rpc("action.run", {"action": name, "args": args or {}, "focus": True, "origin": "script"}, timeout=60)
    if settle:
        time.sleep(settle)  # test harness: the app settles before the next step
    return reply


class Broken(Exception):
    """The app is no longer in the state the next measurement needs (a restore failed); the run stops."""


def wait(check, seconds, step=0.1):
    deadline = time.time() + seconds
    while time.time() < deadline:
        try:
            value = check()
        except Exception:  # the app may not answer yet
            value = None
        if value:
            return value
        time.sleep(step)  # test harness polling a live app
    return None


def topology():
    snap = rpc("snapshot.get")
    return (snap.get("topology") or {}) if isinstance(snap, dict) else {}


def workspace_ids():
    return [w.get("id") for w in topology().get("workspaces") or [] if w.get("id")]


def shown_workspace():
    return (topology().get("focus") or {}).get("workspace")


def pane_count():
    topo = topology()
    focus = (topo.get("focus") or {}).get("workspace")
    return sum(len(screen.get("panes") or []) for w in topo.get("workspaces") or [] if w.get("id") == focus
               for screen in w.get("screens") or [])


def geometry():
    windows = rpc("debug.window_transition", {"action": "geometry"})
    return windows[0] if isinstance(windows, list) and windows else {}


def go(workspace, settle=0.6):
    action("goToWorkspace", {"workspace": workspace})
    wait(lambda: shown_workspace() == workspace, 10)
    time.sleep(settle)  # test harness: the switch lands before the next gesture


def counters():
    """Every numeric work counter the app keeps (sidebar and layout), for a before/after delta."""
    out = {}
    for method in ("debug.sidebar_perf", "debug.layout_counters"):
        reply = rpc(method)
        if isinstance(reply, dict):
            out.update({k: v for k, v in reply.items() if isinstance(v, (int, float)) and not isinstance(v, bool)})
    return out


def missed(intervals, refresh):
    return sum(1 for i in intervals if refresh and i > refresh * 1.5)


def drop120(intervals, busy, refresh):
    """120 Hz vsyncs missed. On a 120 Hz display, counted from the intervals; on a slower one, per frame the
    larger of the 120 Hz frames its interval lost beyond the display's own and the 120 Hz frames its main-thread
    work overran (work over 8.33 ms misses a 120 Hz vsync)."""
    if refresh and refresh <= FRAME_120 * 1.05:
        return sum(max(0, round(i / refresh) - 1) for i in intervals)
    base = round(refresh / FRAME_120) if refresh else 2
    return sum(max(max(0, round(i / FRAME_120) - base), max(0, math.ceil(b / FRAME_120) - 1)) for i, b in zip(intervals, busy))


def measure(label, gesture, timer=None):
    """Times one gesture from the press until the window rests; returns its row."""
    rpc("debug.hangs", {"clear": True})
    rpc("debug.layers", {"reset_layout_passes": True})
    before = counters()
    start_error = error_of(rpc(timer, {"action": "start"})) if timer else None
    start_error = error_of(rpc("debug.frames", {"action": "start"})) or start_error
    time.sleep(0.1)  # test harness: a few frames at rest before the press
    started = time.monotonic()
    error = gesture()
    reply_ms = (time.monotonic() - started) * 1000
    time.sleep(opts.settle)  # test harness: the gesture's motion lands and the window rests
    frames = rpc("debug.frames", {"action": "stop", "raw": True}) or {}
    timed = (rpc(timer, {"action": "stop"}) or {}) if timer else {}
    hangs = rpc("debug.hangs") or {}
    after = counters()
    layers = (rpc("debug.layers") or {}).get("layout_passes") or {}
    intervals, busy = frames.get("intervals_ms") or [], frames.get("main_ms") or []
    views, windows = frames.get("view_layouts_per_frame") or [], frames.get("window_layouts_per_frame") or []
    refresh = frames.get("refresh_ms") or 0
    samples = next((v for k, v in timed.items() if isinstance(v, list) and k != "confirms_ms"), []) if isinstance(timed, dict) else []
    commits = [s.get("commit_ms") for s in samples if isinstance(s, dict) and s.get("commit_ms") is not None]
    return {
        "label": label, "error": error or start_error or error_of(frames), "reply_ms": round(reply_ms, 1), "refresh_ms": refresh,
        "frames": len(intervals), "missed": missed(intervals, refresh), "drop120": drop120(intervals, busy, refresh),
        "main_total_ms": round(sum(busy), 2), "view_layouts_total": sum(views), "window_layouts_total": sum(windows),
        "app_commit_ms": round(commits[0], 1) if commits else None,
        "hangs": hangs.get("count") if isinstance(hangs, dict) else None,
        "gaps_over_8_3ms": hangs.get("frames_over_8_3ms") if isinstance(hangs, dict) else None,
        "max_gap_ms": hangs.get("max_gap_ms") if isinstance(hangs, dict) else None,
        "work": {k: round(after[k] - before.get(k, 0), 2) for k in after if after[k] != before.get(k, 0)},
        "top_layout_classes": (layers.get("top_classes") or [])[:10],
        "intervals_ms": intervals, "main_ms": busy, "view_layouts": views, "window_layouts": windows,
    }


def keep(count, scenario, index, run, ok, **extra):
    # A row without frame samples measured nothing (an occluded window, a probe that did not start).
    run.update(workspaces=count, scenario=scenario, round=index, ok=bool(ok and not run["error"] and run["frames"]), **extra)
    REPORT["runs"].append(run)
    print(f"  {count:>3} ws {scenario:<20} #{index} {'ok ' if run['ok'] else 'BAD'} frames {run['frames']:>3} "
          f"missed {run['missed']} drop120 {run['drop120']} main {run['main_total_ms']:.1f} ms "
          f"layouts {run['view_layouts_total']}/{run['window_layouts_total']} app {run['app_commit_ms']} "
          f"gaps {run['gaps_over_8_3ms']} err {run['error']}", flush=True)
    if opts.json:
        json.dump(REPORT, open(opts.json, "w"), indent=1)


def press(key, modifiers, verb):
    """The gesture by the path --input names; a failed key press is the row's error, never an action run instead."""
    if opts.input == "key":
        return error_of(rpc("debug.key", {"key": key, "modifiers": modifiers}))
    return error_of(action(verb))


def holds(count, what):
    """Stops the run unless the app holds exactly `count` workspaces (after `what`)."""
    have = len(workspace_ids())
    if have != count:
        raise Broken(f"{count} ws: the app holds {have} workspaces after {what}")


def split(count, scenario, modifiers, verb):
    for index in range(opts.rounds):
        before = pane_count()
        run = measure(scenario, lambda: press("d", modifiers, verb))
        made = wait(lambda: pane_count() == before + 1, 5)
        keep(count, scenario, index, run, made)
        if pane_count() != before:
            reply = action("closePane")
            if not wait(lambda: pane_count() == before, 10):
                raise Broken(f"{count} ws {scenario}: closing the new pane left {pane_count()} panes, not {before} "
                             f"({error_of(reply)})")
        time.sleep(0.6)  # test harness: the close lands before the next press


def toggle(count, name, key, modifiers, verb, labels):
    """Two presses per round. A press that narrowed the main pane showed the panel (labels[0]), one that
    widened it hid it (labels[1])."""
    for index in range(opts.rounds):
        for _ in range(2):
            before = main_width()
            run = measure(name, lambda: press(key, modifiers, verb))
            after = main_width()
            shown = None if before is None or after is None or before == after else after < before
            keep(count, f"{name}-{labels[0] if shown else labels[1] if shown is False else 'unchanged'}", index, run,
                 shown is not None, main_width=[before, after])
            time.sleep(0.3)  # test harness: idle between presses


def main_width():
    rect = geometry().get("main_pane")
    return rect[2] if isinstance(rect, list) and len(rect) == 4 else None


def sidebar_workspace_keys():
    """The first window's sidebar workspace rows, top to bottom, as workspace keys (row key `workspace(<key>)`)."""
    windows = (rpc("debug.sidebar_rows") or {}).get("windows") or [{}]
    keys = [str(r.get("key", "")) for r in windows[0].get("rows") or []]
    return [k[len("workspace("):-1] for k in keys if k.startswith("workspace(") and k.endswith(")")]


def workspace_key(public_id):
    return next((w.get("key") for w in topology().get("workspaces") or [] if w.get("id") == public_id), None)


def new_top(count, bench):
    """New Workspace at Top: ok only when it made exactly one workspace and the sidebar lists it first."""
    for index in range(opts.rounds):
        ids = workspace_ids()
        run = measure("new-top", lambda: error_of(action("workspace.newAtTop")), timer="debug.new_workspace")
        now = wait(lambda: (lambda w: w if len(w) > len(ids) else None)(workspace_ids()), 10) or workspace_ids()
        made = [i for i in now if i not in ids]
        key = workspace_key(made[0]) if len(made) == 1 else None
        # The app places a new row once the daemon lists it; the row must reach the top, not merely exist.
        rows = (wait(lambda: (lambda k: k if k and k[0] == key else None)(sidebar_workspace_keys()), 5)
                if key else None) or sidebar_workspace_keys()
        at_top = bool(key) and bool(rows) and rows[0] == key
        keep(count, "new-top", index, run, len(made) == 1 and at_top, made=len(made),
             row_index=rows.index(key) if key in rows else None)
        for workspace in made:
            go(workspace, settle=0.2)
            reply = action("closeWorkspace", {"confirm": True})  # destructive: a script caller confirms
            if not wait(lambda: workspace not in workspace_ids(), 10):
                raise Broken(f"{count} ws new-top: closing the new workspace failed ({error_of(reply)})")
        holds(count, "new-top's close")
        go(bench)


def switch(count, bench):
    last = workspace_ids()[-1]
    go(last)
    go(bench)  # untimed: both workspaces have shown once
    for index in range(opts.rounds):
        for target in (last, bench):
            run = measure("switch", lambda: error_of(action("goToWorkspace", {"workspace": target})), timer="debug.tab_switch")
            keep(count, "switch", index, run, wait(lambda: shown_workspace() == target, 5), to=target)
            time.sleep(0.3)  # test harness: idle between switches


def reset(bench):
    """The tag's daemon keeps its workspaces across launches: an earlier run's leave the app holding more than
    the bench workspace. Closes them (untimed) so the fill starts from one; False when one will not close."""
    extra = [w for w in workspace_ids() if w != bench]
    if extra:
        print(f"closing {len(extra)} workspaces an earlier run left", flush=True)
    for workspace in extra:
        go(workspace, settle=0.1)
        reply = action("closeWorkspace", {"confirm": True})
        if not wait(lambda: workspace not in workspace_ids(), 10):
            print(f"workspace {workspace} did not close ({error_of(reply)})", flush=True)
            return False
    go(bench, settle=0.5)
    return workspace_ids() == [bench]


def fill(count, bench):
    """The app holds `count` workspaces and the bench workspace shows; False when the app stops making them."""
    for _ in range(count * 2):  # bounded: a create that never lands must not hang the step
        have = len(workspace_ids())
        if have >= count:
            break
        reply = action("workspace.newAtBottom")
        if not wait(lambda: len(workspace_ids()) > have, 10):
            print(f"workspace {have + 1} of {count} never showed ({error_of(reply)})", flush=True)
            return False
    if len(workspace_ids()) != count:  # more than asked (counts only grow) is not the requested set either
        return False
    go(bench, settle=3.0)
    return True


def expected_rows(scenario):
    """The rows each round of a scenario must keep, by row label: both halves of a toggle, both switches."""
    if scenario == "right-sidebar":
        return {"right-sidebar-open": 1, "right-sidebar-close": 1}
    if scenario == "sidebar":
        return {"sidebar-show": 1, "sidebar-hide": 1}
    return {scenario: 2 if scenario == "switch" else 1}


def incomplete(count, scenarios):
    """Why `count`'s measurements are not a full set: a round that failed, a missing or extra row."""
    problems = []
    for scenario in scenarios:
        expected = expected_rows(scenario)
        runs = [r for r in REPORT["runs"] if r["workspaces"] == count and
                (r["scenario"] == scenario or r["scenario"].startswith(scenario + "-"))]
        bad = [r for r in runs if not r["ok"]]
        if bad:
            problems.append(f"{count} ws {scenario}: {len(bad)} of {len(runs)} rows failed "
                            f"({', '.join(sorted({r['scenario'] for r in bad}))})")
        for index in range(opts.rounds):  # per round: open/open then close/close is not two full rounds
            labels = [r["scenario"] for r in runs if r["round"] == index]
            got = {label: labels.count(label) for label in labels}
            if got != expected:
                problems.append(f"{count} ws {scenario} round {index}: rows {got}, expected {expected}")
    return problems


def pct(values, p):
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(round((len(ordered) - 1) * p)))] if ordered else None


def median(values):
    values = sorted(v for v in values if v is not None)
    return values[len(values) // 2] if values else None


def top_classes(runs, limit=6):
    """The view classes laid out most in these runs (per run, median), busiest first."""
    names = {c.get("view_class") for r in runs for c in r["top_layout_classes"]}
    counts = {n: median(next((c.get("passes") for c in r["top_layout_classes"] if c.get("view_class") == n), 0) for r in runs)
              for n in names if n}
    return sorted(counts.items(), key=lambda item: -(item[1] or 0))[:limit]


def summarize():
    rows = []
    keys = []
    for run in REPORT["runs"]:
        key = (run["workspaces"], run["scenario"])
        if key not in keys:
            keys.append(key)
    for count, scenario in keys:
        runs = [r for r in REPORT["runs"] if (r["workspaces"], r["scenario"]) == (count, scenario)]
        intervals = [v for r in runs for v in r["intervals_ms"]]
        busy = [v for r in runs for v in r["main_ms"]]
        views = [v for r in runs for v in r["view_layouts"]]
        windows = [v for r in runs for v in r["window_layouts"]]
        rows.append({
            "workspaces": count, "scenario": scenario, "runs": len(runs), "ok": sum(r["ok"] for r in runs),
            "frames": len(intervals), "frame_p50_ms": pct(intervals, 0.5), "frame_p95_ms": pct(intervals, 0.95),
            "frame_p99_ms": pct(intervals, 0.99), "frame_max_ms": max(intervals) if intervals else None,
            "missed": median(r["missed"] for r in runs), "drop120": median(r["drop120"] for r in runs),
            "drop120_max": max((r["drop120"] for r in runs), default=None),
            "main_p50_ms": pct(busy, 0.5), "main_p95_ms": pct(busy, 0.95), "main_max_ms": max(busy) if busy else None,
            "main_total_ms": median(r["main_total_ms"] for r in runs),
            "view_layouts_per_frame_p95": pct(views, 0.95), "view_layouts_per_frame_max": max(views) if views else None,
            "view_layouts_total": median(r["view_layouts_total"] for r in runs),
            "window_layouts_total": median(r["window_layouts_total"] for r in runs),
            "gaps_over_8_3ms": median(r["gaps_over_8_3ms"] for r in runs),
            "app_commit_ms": median(r["app_commit_ms"] for r in runs), "hangs": sum(r["hangs"] or 0 for r in runs),
            "window_layouts_per_frame_max": max(windows) if windows else None,
            "work_median": {k: median(r["work"].get(k, 0) for r in runs) for k in sorted({k for r in runs for k in r["work"]})},
            "top_layout_classes": top_classes(runs),
        })
    REPORT["summary"] = rows
    return rows


def markdown(rows):
    def f(v, digits=1):
        return "-" if v is None else (f"{v:.{digits}f}" if isinstance(v, float) else str(v))
    refresh = median(r["refresh_ms"] for r in REPORT["runs"] if r["refresh_ms"])
    lines = [f"app-perf at `{REPORT.get('sha', '?')}` on `{REPORT.get('host', '?')}` (macOS {REPORT.get('macos', '?')}), "
             f"display {f(1000 / refresh if refresh else None, 0)} Hz, {opts.rounds} rounds, input {opts.input}. "
             "Frame and main-thread columns pool every round's frames; totals are medians per gesture.", "",
             "| ws | scenario | ok | frame p50 | p95 | p99 | max ms | missed | drop@120 | main ms/frame p50 | p95 | max "
             "| main ms total | view layouts/frame p95 | max | view layouts total | window passes/frame max | window passes total "
             "| gaps>8.3ms | hangs | app ms |",
             "|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|"]
    for r in rows:
        lines.append(f"| {r['workspaces']} | {r['scenario']} | {r['ok']}/{r['runs']} | {f(r['frame_p50_ms'])} | "
                     f"{f(r['frame_p95_ms'])} | {f(r['frame_p99_ms'])} | {f(r['frame_max_ms'])} | {f(r['missed'])} | "
                     f"{f(r['drop120'])} | {f(r['main_p50_ms'], 2)} | {f(r['main_p95_ms'], 2)} | {f(r['main_max_ms'], 2)} | "
                     f"{f(r['main_total_ms'])} | {f(r['view_layouts_per_frame_p95'])} | {f(r['view_layouts_per_frame_max'])} | "
                     f"{f(r['view_layouts_total'])} | {f(r['window_layouts_per_frame_max'])} | {f(r['window_layouts_total'])} | "
                     f"{f(r['gaps_over_8_3ms'])} | {f(r['hangs'])} | {f(r['app_commit_ms'])} |")
    lines += ["", "Busiest layout classes per gesture (median NSView.layout calls):"]
    for r in rows:
        lines.append(f"- {r['workspaces']} ws {r['scenario']}: " + ", ".join(f"{n} {f(c)}" for n, c in r["top_layout_classes"]))
    if REPORT.get("failures"):
        lines += ["", "Not a full set (RESULT FAIL):"] + [f"- {failure}" for failure in REPORT["failures"]]
    return "\n".join(lines)


class Launched:
    """An app LaunchServices started (`--open`): its pid, and a wait for it to exit."""

    def __init__(self, pid):
        self.pid = pid

    def wait(self, timeout):
        if not bench_memory.wait_gone(self.pid, timeout):
            raise subprocess.TimeoutExpired("open", timeout)


def launch(env, log_path):
    if not opts.open:
        log = open(log_path, "a")
        return subprocess.Popen([BINARY], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
    # LaunchServices starts the app in the console user's GUI session, which a process started over ssh is not
    # in; the app gets this environment on top of the session's.
    pairs = [arg for key, value in env.items() if key not in ("HOME", "USER", "TMPDIR", "PATH") for arg in ("--env", f"{key}={value}")]
    subprocess.run(["open", "-n", "-g", "--stdout", log_path, "--stderr", log_path, *pairs, APP], check=True, timeout=60)
    pid = wait(lambda: next((p for p, _, cmd in bench_memory.process_table() if bench_memory.is_binary(cmd, BINARY)), None), 60)
    return Launched(pid) if pid else None


def cleanup():
    if os.environ.get("APP_PERF_KEEP") or not app:
        return
    rpc("action.run", {"action": "quitEndSessions"}, timeout=10)
    try:
        app.wait(timeout=20)
    except subprocess.TimeoutExpired:
        os.kill(app.pid, signal.SIGKILL)
    subprocess.run([CLI, "server", "stop", "--session", f"cmux-app-{TAG}", "--end-terminals"],
                   env={k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}, capture_output=True, timeout=30)
    if opts.open:
        bench_memory.end_bundle(APP)
    if os.path.exists(SOCKET):
        os.remove(SOCKET)


def measure_count(count, wanted, bench):
    """Every wanted scenario at `count` workspaces; each starts from exactly `count` (raises Broken otherwise)."""
    for scenario in wanted:
        holds(count, "the previous scenario")
        if scenario == "split-right":
            split(count, scenario, ["command"], "splitRight")
        elif scenario == "split-down":
            split(count, scenario, ["command", "shift"], "splitDown")
        elif scenario == "right-sidebar":
            toggle(count, scenario, "b", ["option", "command"], "toggleRightSidebar", ("open", "close"))
        elif scenario == "sidebar":
            toggle(count, scenario, "b", ["command"], "toggleSidebar", ("show", "hide"))
        elif scenario == "new-top":
            new_top(count, bench)
        elif scenario == "switch":
            switch(count, bench)


def started(process):
    global app
    app = process


def main():
    global app, SOCKET
    if os.path.exists(SOCKET):
        os.remove(SOCKET)
    env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_CONFIG_FILE": CONFIG,
           "CMUX_NEXT_GHOSTTY_CONFIG": os.path.join(SCRATCH, "ghostty"), "CMUX_NEXT_CHIEF_ISOLATED": "1",
           "CMUX_NEXT_CHIEF_HOME": os.path.join(SCRATCH, "chief"), "CMUX_NEXT_NO_ACTIVATE": "1",
           "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_TEST_WINDOW_FRAME": ",".join(str(v) for v in WINDOW)}
    os.makedirs(opts.out, exist_ok=True)
    log_path = os.path.join(opts.out, f"app-{TAG}.log")
    if opts.open:
        app = launch(env, log_path)
        if app is None:
            print("the tagged app did not start (open -n found no process)", flush=True)
            return False
    else:
        # One launch path (bench_launch.py): socket in the state folder, bench env, the reason when it does not come up.
        try:
            app, SOCKET = launch_app(APP, env, log_path, timeout=120, on_start=started)
        except LaunchError:
            return False
    REPORT["macos"] = subprocess.run(["sw_vers", "-productVersion"], capture_output=True, text=True).stdout.strip()
    REPORT["host"] = subprocess.run(["hostname", "-s"], capture_output=True, text=True).stdout.strip()
    REPORT["sha"] = (opts.sha or subprocess.run(["git", "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip())[:12] or "?"
    print(f"launched pid {app.pid} macOS {REPORT['macos']} host {REPORT['host']} at {REPORT['sha']}", flush=True)
    if opts.open and not wait(lambda: os.path.exists(SOCKET) and (rpc("debug.windows") or {}).get("windows"), 120):
        print(f"the tagged app did not come up (socket {os.path.exists(SOCKET)})\n"
              + open(log_path, errors="replace").read()[-6000:], flush=True)
        return False
    time.sleep(5)  # test harness: launch work settles
    bench = wait(shown_workspace, 30)
    wanted = [s for s in opts.scenarios.split(",") if s]
    failures = REPORT.setdefault("failures", [])
    if not bench or not reset(bench):
        failures.append(f"the app does not start from one workspace (it holds {len(workspace_ids())})")
        return False
    if opts.scrollback:
        action("terminal.sendText", {"text": f"seq 1 {opts.scrollback}\r"}, settle=1.5)
    failures += [f"unknown scenario {s}" for s in wanted if s not in SCENARIOS]
    counts = sorted(int(v) for v in opts.workspaces.split(",") if v)
    for count in counts:
        if not fill(count, bench):
            failures.append(f"the app holds {len(workspace_ids())} workspaces, not {count}; "
                            f"{', '.join(str(c) for c in counts if c >= count)} not measured")
            print(f"stopped: {failures[-1]}", flush=True)
            break
        print(f"\n== {len(workspace_ids())} workspaces", flush=True)
        try:
            measure_count(count, wanted, bench)
        except Broken as error:
            failures.append(str(error))
            print(f"stopped: {error}", flush=True)
            break
        failures += incomplete(count, [s for s in wanted if s in SCENARIOS])
    if not any(r["frames"] for r in REPORT["runs"]):
        failures.append("the window drew no frames (an unlit or occluded console)")
    rows = summarize()
    table = markdown(rows)
    print("\n== summary\n" + table, flush=True)
    if opts.markdown:
        open(opts.markdown, "w").write(table + "\n")
    for failure in failures:
        print(f"FAIL {failure}", flush=True)
    return not failures


ok = False
try:
    ok = main()
except Exception:  # the step log is stdout only
    import traceback
    traceback.print_exc(file=sys.stdout)
finally:
    cleanup()
    if opts.json:
        json.dump(REPORT, open(opts.json, "w"), indent=1)
    # The step log keeps the numbers even when the step fails (no artifact comes back then).
    print("REPORT-JSON " + json.dumps(REPORT.get("summary") or []), flush=True)
    print("\nRESULT", "PASS" if ok else "FAIL")
    sys.exit(0 if ok else 1)
