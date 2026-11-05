#!/usr/bin/env python3
"""Terminal live-resize cost, light and STRESS (ghostty-integration-DESIGN.md G1/G2, PL-ghostty).

  nx-remote --needs gui --app-from-fleet cmux --tag T --ref SHA -- \\
    python3 scripts/cmux-next/bench-terminal-resize.py --app "$NX_APP" --out "$NX_ARTIFACTS"

Launches the tagged app (no activation, automation socket, scratch config), then per layout drags a
vertical divider left and right, one `debug.mouse` move per display frame:

  split-resize  Cmd-D, Cmd-W, Cmd-Shift-D, Cmd-W on a terminal showing less (`debug.terminal_final_grid`):
           per resized terminal, ms from the action to the first and the final grid sent to the daemon, to
           the owner's final grid and to the first frame drawn at it. split-resize-stress: the same in the
           STRESS session.
  idle-cursor  a focused terminal at rest with a hidden cursor: Ghostty frames drawn in --idle-s
           seconds (0 expected: a blink tick of a hidden cursor changes no pixel).

  light    a workspace split right: 2 terminals, each with --scrollback lines of history and one long
           line, so every column change reflows real text.
  stress   the STRESS session (perf-stress-session.py: 60 workspaces, 4x3 panes + nested splits, 6
           tabs each, 10 busy terminals); the divider between its first two columns. Every terminal
           in those columns must change size with its pane in each frame. A build that holds terminals
           through a drag (`terminalDrag.holdSurface`, on by default from #32006 until cmux-ad m19, 2026-11-05) fails: they keep their
           size through the drag (each round reports `holds_terminals` as it ran, as data). Before its timed
           rounds each drag layout runs a probe (one drag that ends --probe-pt away, then one back) and prints
           it as its own TERMINAL-RESIZE-PROBE line: the divider moved, a terminal fits a new grid, and its
           render counters counted it (full_resize or full_swap, terminal_resize_verdict.resized) at the
           release, or the layout fails at once.
  keys     4 terminals in a 2x2 grid, each with history: Ctrl-Shift-L then Ctrl-Shift-H on the bottom-left
           one (`resizePaneRight`, `resizePaneLeft`; --key-repeat presses each, --key-gap-ms apart, the last
           one --key-settle-s before the next), so the divider between the columns moves and all 4 resize.
           keys-stress: the same in the STRESS session (its first pane). Per round: display-frame intervals
           and main-thread ms per frame (all frames, and the frames that laid out a view), missed refreshes,
           and per press the most grids one terminal got (`debug.terminal_final_grid`: at most one per press).

  --ab KEY runs every round of the drag and key layouts once with the boolean tunable KEY off and once on, in
           this one launch (`debug.tunables set`), the order alternating per round; each layout then reports
           `arms` (terminal_resize_arms.summaries: per arm, the rounds' frames pooled into p50/p95/p99/max)
           and the run resets KEY after each such layout. `--ab motion.frameOwner.terminals` was FRAME OWNER
           S4's A/B.

The rule for the drag and key layouts: a terminal changes size with its pane in every frame of the motion.
`debug.terminal_display` samples each terminal shown at the round's start once per display frame, after the frame's
commit: its pane's size, the size its host asked of it, and the size its layer shows. Each round reports `follow`:
per terminal, frames sampled, `held` frames (asked is not the pane's size, more than 0.5 pt off) and `lagging` frames
(shown is not the pane's size), with the first 3 of each, and the round's `held_frames` and `lagging_frames`. A round
with a held frame fails, and the message names the terminal, its held frames and the first sizes. Lagging frames are
data only: the frame owner (`motion.frameOwner.terminals`) keeps a frame for 1-4 refreshes by design.

Per layout it records display-frame intervals and main-thread busy time per frame (`debug.frames`,
missed = an interval over 1.5 refresh periods, each split by cause into main late, commit late or presented late),
main-thread time in Ghostty's display passes
(`debug.terminal_display`: before G1 each pass drew on main with the previous size's cells and waited
for the GPU), and the render counters of every resized terminal (`debug.surfaces`): frames drawn by
the main thread, fresh frames presented in the commit of their size, late passes (GhosttyNextKit with
G1; absent before), full rebuilds. A terminal resized when its full rebuilds for a new grid grew
(terminal_resize_verdict.resized: full_resize, or full_swap when the reflow preview drew the new size). After the drag every terminal's drawn, fitted and owner grids must
agree. Prints one JSON summary per layout and writes OUT/terminal-resize.json; the summary says what to
compare. Exits non-zero, after writing the report, when a drag or key round held a terminal at another size than its
pane's, or a layout measured nothing (terminal_resize_verdict.py: a layout error or a failed probe, a drag or key resize
in which no terminal resized, no frame was counted, no terminal drew or no terminal was checked against its pane, a
round whose arm could not be set, a split action that resized no terminal): such zeros are not a result.
"""
import argparse, glob, importlib.util, json, os, plistlib, signal, socket, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import bench_launch  # noqa: E402
import terminal_resize_arms as arms  # noqa: E402
import terminal_resize_verdict  # noqa: E402
import main_profile  # noqa: E402  SCRATCH (RESIZE MAIN BUDGET)
from tag_teardown import TagTeardown  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--app", default=os.environ.get("NX_APP"))
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or "/tmp/bench-terminal-resize")
parser.add_argument("--layouts", default="idle-cursor,light,stress")
parser.add_argument("--steps", type=int, default=60, help="moves each way")
parser.add_argument("--step-pt", type=float, default=4.0)
parser.add_argument("--scrollback", type=int, default=20000, help="history lines printed in each light terminal")
parser.add_argument("--rounds", type=int, default=2)
parser.add_argument("--idle-s", type=float, default=5.0)
parser.add_argument("--tag", help="the app's tag (split-spring.sh passes it)")
parser.add_argument("--json", help="also write the report here (split-spring.sh's artifact)")
parser.add_argument("--ab", help="a boolean tunable: each round of the drag and key layouts runs with it off and on")
parser.add_argument("--probe-pt", type=float, default=40.0, help="how far the drag layouts' probe moves the divider")
parser.add_argument("--key-repeat", type=int, default=1, help="presses of each key per round (keys layouts)")
parser.add_argument("--key-gap-ms", type=float, default=33.0, help="between repeated presses of one key")
parser.add_argument("--key-settle-s", type=float, default=0.6, help="after the last press of a key")
# SCRATCH (RESIZE MAIN BUDGET, never merge): tunables set after launch, held-key rows, a main-thread profile per round.
parser.add_argument("--set", action="append", default=[], help="KEY=true|false: a boolean tunable set after launch")
parser.add_argument("--held-repeat", type=int, default=0, help="keys layouts: also measure a held key (this many presses)")
parser.add_argument("--xctrace-rounds", type=int, default=0, help="Time Profiler (attached to the app pid) on this many rounds per layout")
parser.add_argument("--held-is-data", action="store_true",
                    help="SCRATCH (SMOOTH-PAGES-PROFILE): a terminal held through a key resize (S4 OFF arm) is data, not a failed layout")
parser.add_argument("--pages-mix", action="store_true",
                    help="SCRATCH (SMOOTH-PAGES-PROFILE): in STRESS, every other pane of each column shows a Chromium page")
parser.add_argument("--devtools-docked", action="store_true",
                    help="SCRATCH (SMOOTH-PAGES-PROFILE): with --pages-mix, one page in column 2 (moved by keys and drag) docks DevTools")
parser.add_argument("--newtab-runs", type=int, default=0, help="keys layout: also Cmd-T this many times, each after a key resize of its pane")
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)
APP = (opts.app or "").rstrip("/")
if not APP or not os.path.isdir(APP):
    sys.exit("pass --app (or run under nx-remote --app-from-fleet)")
with open(os.path.join(APP, "Contents/Info.plist"), "rb") as f:
    info = plistlib.load(f)
BINARY = os.path.join(APP, "Contents/MacOS", info["CFBundleExecutable"])
TAG = opts.tag or os.environ.get("NX_APP_TAG") or os.path.basename(APP).removesuffix(".app").split(" ")[-1]
SOCKET = os.environ.get("NX_APP_SOCKET") or f"/tmp/cmux-debug-{TAG}.sock"
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")


def rpc(method, params=None, timeout=60):
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


def wait(predicate, seconds, step=0.25):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:  # bench script: bounded poll of the app's socket state
        value = predicate()
        if value:
            return value
        time.sleep(step)  # bench script: the poll interval
    return None


def window():
    result = rpc("debug.layers")
    return ((result or {}).get("windows") or [{}])[0] if isinstance(result, dict) else {}


def vertical_dividers():
    w = window()
    height = (w.get("frame") or [0, 0, 0, 1000])[3]
    return sorted((x + wd / 2, height - (y + h / 2), h) for x, y, wd, h in w.get("divider_areas_in_window") or [] if h > wd)


def surfaces():
    """Visible terminal panes: dicts with an id (pane + shown tab), frame x, fit/drawn/owner grid and render counters."""
    result = rpc("debug.surfaces") or {}
    rows = []
    for win in result.get("windows") or []:
        for pane in win.get("panes") or []:
            surface, grid = pane.get("surface") or {}, pane.get("grid") or {}
            if not surface.get("fit_grid") or surface.get("hidden") or not surface.get("drawing", True):
                continue
            ident = "%s/%s" % (pane.get("pane"), pane.get("shown_tab") or pane.get("selected_tab"))
            rows.append({"id": ident, "x": grid.get("frame_x", 0), "fit": surface.get("fit_grid"), "drawn": surface.get("drawn_grid"),
                         "grid": surface.get("grid"), "counters": surface.get("render_counters") or {}})
    return sorted(rows, key=lambda r: r["x"])


def write(text):
    env = {k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}
    subprocess.run([CLI, "--app-socket", SOCKET, "--json", "terminal", "current", "write", "--text", text],
                   capture_output=True, text=True, timeout=60, env=env, stdin=subprocess.DEVNULL)


def counter_delta(before, after):
    """Sums counter deltas of the terminals present before and after, paired by id (not by x order:
    a pane that appears, closes or moves between the two reads must not pair with another's counters).
    `unpaired` counts the terminals present in only one of the two reads."""
    keys = ("frames", "frame_updates", "full_resize", "full_swap", "host_display_passes", "host_present_calls", "host_main_draws", "host_fresh_presents",
            "host_late_presents")
    total = {k: 0 for k in keys}
    by_id = {b["id"]: b for b in before}
    paired = [(by_id[a["id"]], a) for a in after if a["id"] in by_id]
    total["unpaired"] = len(before) + len(after) - 2 * len(paired)
    for b, a in paired:
        for k in keys:
            if k in a.get("counters", {}):
                total[k] += int(a["counters"][k]) - int(b["counters"].get(k, 0))
    total["host_counters"] = any("host_main_draws" in a.get("counters", {}) for a in after)
    return total


def drag(x0, y0, refresh_s, path=None):
    """Presses at (x0, y0), moves by each of `path` (default: --steps moves left, twice that right, --steps left,
    so it ends where it began), one move per display frame, and releases where it ends."""
    if path is None:
        path = [-opts.step_pt] * opts.steps + [opts.step_pt] * (2 * opts.steps) + [-opts.step_pt] * opts.steps
    rpc("debug.mouse", {"action": "down", "x": x0, "y": y0})
    x = x0
    next_at = time.monotonic()
    for delta in path:
        rpc("debug.mouse", {"action": "drag", "x": x, "y": y0, "to_x": x + delta, "to_y": y0, "steps": 1,
                            "press": False, "release": False})
        x += delta
        next_at += refresh_s
        pause = next_at - time.monotonic()
        if pause > 0:
            time.sleep(pause)  # bench script: one pointer move per display frame
    rpc("debug.mouse", {"action": "up", "x": x, "y": y0})


def column_divider(dividers, middle):
    """The divider to drag. Light: the only one. STRESS (`middle`): the column divider between
    columns 2 and 3 of the 4x3 grid. Column dividers span the whole grid's height; a nested split's
    divider spans one row, so the tallest ones are the column dividers, and the middle of those (by x)
    resizes every pane of the first two columns."""
    if not middle:
        return dividers[0]
    tallest = max(h for _, _, h in dividers)
    columns = sorted(d for d in dividers if d[2] >= 0.9 * tallest)
    return columns[len(columns) // 2 - 1] if len(columns) >= 2 else columns[0]


# `missed_split`: each missed refresh's cause from cmux's own stamps (debug.frames, FrameMissSplit): main_late (the main
# work ran past the frame's target time), commit_late (the Core Animation commit did), presented_late (neither: the main
# thread was idle at the target and the frame still missed); `missed_frames`: the first misses with their stamps.
FRAME_KEYS = ("frames", "refresh_ms", "p50_ms", "p95_ms", "p99_ms", "max_ms", "missed", "main_p50_ms", "main_p95_ms",
              "main_max_ms", "main_total_ms", "main_over_8_3_ms", "view_layouts", "view_layouts_max", "missed_split",
              "missed_frames")


def pane_check(display):
    """The round's pane check (terminal_resize_verdict.follow), taken out of `debug.terminal_display`'s stop reply:
    `follow` and its totals for the round entry."""
    checked = terminal_resize_verdict.follow(display)
    if checked is None:
        return {"follow": None}
    return {"follow": checked, "held_frames": checked["held_frames"], "held_terminals": checked["held_terminals"],
            "lagging_frames": checked["lagging_frames"]}


def frame_numbers(frames):
    """A round's `debug.frames` numbers (with the main-thread p99 the reply lacks), and its raw per-frame arrays for
    the arms' pooled distributions (kept in the report as the round's `raw`)."""
    main_ms = frames.get("main_ms") or []
    raw = {"intervals_ms": frames.get("intervals_ms") or [], "main_ms": main_ms,
           "motion_main_ms": arms.motion(main_ms, frames.get("view_layouts_per_frame") or [])}
    numbers = {k: frames.get(k) for k in FRAME_KEYS}
    numbers["main_p99_ms"] = (arms.distribution(main_ms) or {}).get("p99")
    return numbers, raw


def unsettled(after):
    return [{"fit": s["fit"], "drawn": s["drawn"], "grid": s["grid"]} for s in after if not (s["fit"] == s["drawn"] == s["grid"])]


def drag_holds_terminals():
    """Whether this build keeps each terminal's size and text through a divider drag (`terminalDrag.holdSurface`, on
    by default since #32006), as data: such a drag holds its terminals, so its rounds fail the pane check. False for a
    build without that switch (`debug.tunables` answers an error)."""
    row = rpc("debug.tunables", {"action": "get", "key": "terminalDrag.holdSurface"}) or {}
    return row.get("value") is True


def set_arm(arm):
    """Sets --ab's tunable for one arm (None: the build as it is). Returns why it could not, else None."""
    if arm is None:
        return None
    rpc("debug.tunables", {"action": "activate"})  # a bench build's tunable store is off until asked (debug-settings.md)
    row = rpc("debug.tunables", {"action": "set", "key": opts.ab, "value": arm}) or {}
    if row.get("value") is not arm:
        return f"debug.tunables set {opts.ab}={arm} answered {json.dumps(row)[:200]}"
    time.sleep(0.5)  # bench script: the arm starts at rest; the switch is read at the next layout
    return None


def reset_arm():
    """--ab's tunable back to the build's default: the layouts after an A/B layout (idle-cursor, split-resize) and the
    next run measure the build as it is. A DEBUG build keeps a set value in the tag's Debug Settings file, so a run killed
    before this leaves it set; a bench build (--config=bench) keeps tunables in memory only."""
    if opts.ab:
        rpc("debug.tunables", {"action": "set", "key": opts.ab, "value": None}, timeout=10)


def finish(result):
    """Pools each arm's rounds (`arms`, with --ab) and resets --ab's tunable. Each round keeps its raw per-frame arrays
    (`raw`: intervals_ms, main_ms, motion_main_ms), so a reader can place the slow frames in the spring."""
    if opts.ab:
        result["ab"] = opts.ab
        result["arms"] = arms.summaries(result.get("rounds") or [])
        reset_arm()
    return result


def probe(name, x0, y0, refresh_s, middle):
    """One untimed drag that ends --probe-pt left of where it began, then one back. It proves that `debug.mouse`
    reaches the divider (it moved) and that the render counters count a new grid (a terminal beside it resized at
    the release, held through the drag or not). Printed at once as its own line; a failed probe fails its layout
    before any timed round."""
    steps = max(1, round(opts.probe_pt / opts.step_pt))
    before = surfaces()
    drag(x0, y0, refresh_s, [-opts.probe_pt / steps] * steps)
    time.sleep(1.0)  # bench script: the release's grids land
    after = surfaces()
    dividers = vertical_dividers()
    moved_to = column_divider(dividers, middle)[0] if dividers else None
    if moved_to is not None:
        drag(moved_to, y0, refresh_s, [(x0 - moved_to) / steps] * steps)
        time.sleep(1.0)  # bench script: the release's grids land
    moved = None if moved_to is None else round(moved_to - x0, 1)
    resized = terminal_resize_verdict.resized(before, after)
    # The fact the counters must match: a terminal beside the divider fits a new grid after the drag.
    by_id = {row["id"]: row for row in before}
    regridded = sum(1 for row in after if row["id"] in by_id and row["fit"] != by_id[row["id"]]["fit"])
    found = []
    if moved is None or moved > -opts.probe_pt / 2:
        found.append(f"the probe drag did not move the divider (moved {moved} pt of -{opts.probe_pt:g})")
    if not regridded:
        found.append("no terminal fits a new grid after the probe drag")
    elif not resized:
        found.append(f"{regridded} terminal(s) fit a new grid but no render counter counted it "
                     f"({' and '.join(terminal_resize_verdict.RESIZE_COUNTERS)} unchanged)")
    result = {"layout": name, "moved_pt": moved, "regridded_terminals": regridded, "resized_terminals": resized,
              "terminals": len(after), "ok": not found, "problems": found}
    print(f"TERMINAL-RESIZE-PROBE {json.dumps(result)}", flush=True)
    return result


def refresh_period():
    rpc("debug.frames", {"action": "start"})
    time.sleep(1.0)  # bench script: idle frames give the refresh period
    idle = rpc("debug.frames", {"action": "stop"}) or {}
    return idle.get("refresh_ms") or 16.67


APP_BINARIES = set()


def profile_start(name, index):
    """SCRATCH: a Time Profiler recording of the app pid for the first --xctrace-rounds rounds of a layout."""
    if index >= opts.xctrace_rounds or not report.get("pid"):
        return None
    return main_profile.start(report["pid"], f"{name}-{index}", opts.out)


def profile_stop(recording, entry):
    """SCRATCH: ends the recording; the round keeps the summary (`main_profile`) and the raw samples (`main_samples`)."""
    if not recording:
        return
    raw = main_profile.stop(recording)
    if not APP_BINARIES:
        APP_BINARIES.add(info["CFBundleExecutable"])
        for path in glob.glob(os.path.join(APP, "Contents/Frameworks/*")):
            APP_BINARIES.add(os.path.basename(path).split(".")[0])
    entry["main_profile"] = main_profile.summarize(raw, APP_BINARIES)
    entry["main_profile"]["mode"] = (raw or {}).get("mode")
    entry["main_profile"]["threads_ms"] = (raw or {}).get("threads_ms")
    entry["main_samples"] = {k: (raw or {}).get(k) for k in ("samples", "stacks", "frames")}


def apply_sets():
    """SCRATCH: --set KEY=true|false after launch (a bench build's tunable store is off until activated)."""
    applied = {}
    for item in opts.set:
        key, _, value = item.partition("=")
        rpc("debug.tunables", {"action": "activate"})
        row = rpc("debug.tunables", {"action": "set", "key": key, "value": value.lower() == "true"}) or {}
        applied[key] = row.get("value")
    return applied


def measure(name):
    dividers = vertical_dividers()
    if not dividers:
        return {"layout": name, "error": "no vertical divider"}
    middle = name == "stress"
    x0, y0, height = column_divider(dividers, middle)
    refresh_ms = refresh_period()
    checked = probe(name, x0, y0, refresh_ms / 1000, middle)
    if not checked["ok"]:
        return {"layout": name, "error": "probe: " + "; ".join(checked["problems"]), "probe": checked}
    x0, y0, height = column_divider(vertical_dividers() or dividers, middle)
    rounds = []
    for index in range(opts.rounds):
        for arm in arms.order(index, opts.ab):
            entry = {"arm": arm} if opts.ab else {}
            problem = set_arm(arm)
            if problem:
                rounds.append({**entry, "error": problem})
                continue
            before = surfaces()
            recording = profile_start(name, index)
            background = main_profile.background_cpu()
            rpc("debug.terminal_display", {"action": "start"})
            rpc("debug.frames", {"action": "start"})
            drag(x0, y0, refresh_ms / 1000)
            frames = rpc("debug.frames", {"action": "stop", "raw": True}) or {}
            display = rpc("debug.terminal_display", {"action": "stop"}) or {}
            entry["background_cpu"] = main_profile.background_delta(background)
            profile_stop(recording, entry)
            time.sleep(1.0)  # bench script: the drag's last grid lands at the owner
            after = surfaces()
            numbers, raw = frame_numbers(frames)
            # Resized in the drag: a full rebuild for a new grid, a resize or a reflow preview's swap (the drag ends
            # where it began, so start and end grids match; a build that holds terminals through the drag resizes none).
            entry.update(pane_check(display))
            entry.update({"terminals": len(after), "resized_terminals": terminal_resize_verdict.resized(before, after), "frames": numbers,
                          "main_ms": arms.distribution(raw["main_ms"]), "raw": raw, "display": display,
                          "counters": counter_delta(before, after), "unsettled_after": unsettled(after),
                          "holds_terminals": drag_holds_terminals()})
            rounds.append(entry)
    return finish({"layout": name, "refresh_ms": refresh_ms, "moves": 4 * opts.steps, "probe": checked,
                   "drag_holds_terminals": drag_holds_terminals(), "rounds": rounds,
                   "divider": {"x": round(x0, 1), "height": round(height, 1), "vertical_dividers": len(dividers)}})


def measure_keys(name, repeat=None):
    """Ctrl-Shift-L then Ctrl-Shift-H on the focused pane, per round and arm (see the module docstring)."""
    refresh_ms = refresh_period()
    plan = [action for action in ("resizePaneRight", "resizePaneLeft") for _ in range(max(1, repeat or opts.key_repeat))]
    rounds = []
    for index in range(opts.rounds):
        for arm in arms.order(index, opts.ab):
            entry = {"arm": arm} if opts.ab else {}
            problem = set_arm(arm)
            if problem:
                rounds.append({**entry, "error": problem})
                continue
            before = surfaces()
            recording = profile_start(name, index)
            background = main_profile.background_cpu()
            rpc("debug.terminal_display", {"action": "start"})
            rpc("debug.frames", {"action": "start"})
            presses = []
            for number, action in enumerate(plan):
                last = number + 1 == len(plan) or plan[number + 1] != action
                # The grids sent from here to the next press's start count as this press's: each press sends its final
                # grids by its first frame tick (FRAME OWNER S1B), within --key-gap-ms.
                traced = rpc("debug.terminal_final_grid", {"action": "start"}) or {}
                if not traced.get("started"):
                    entry["error"] = f"the grid trace did not start: {json.dumps(traced)[:200]}"
                    break
                reply = rpc("action.run", {"action": action, "focus": True})
                # bench script: a held key's repeat gap, or the spring lands before the other key
                time.sleep(opts.key_settle_s if last else opts.key_gap_ms / 1000)
                traced = (rpc("debug.terminal_final_grid", {"action": "stop"}) or {}).get("terminals") or {}
                sends = [len(t.get("sends") or []) for t in traced.values()]
                press = {"action": action, "terminals_sent": sum(1 for n in sends if n), "max_grids_per_terminal": max(sends, default=0)}
                if isinstance(reply, dict) and (reply.get("error") or reply.get("refused")):
                    press["refused"] = json.dumps(reply)[:200]
                presses.append(press)
            frames = rpc("debug.frames", {"action": "stop", "raw": True}) or {}
            display = rpc("debug.terminal_display", {"action": "stop"}) or {}
            entry["background_cpu"] = main_profile.background_delta(background)
            profile_stop(recording, entry)
            if entry.get("error"):
                rounds.append(entry)
                continue
            time.sleep(1.0)  # bench script: the last press's frames and grids land
            after = surfaces()
            numbers, raw = frame_numbers(frames)
            entry.update(pane_check(display))
            entry.update({"terminals": len(after), "resized_terminals": terminal_resize_verdict.resized(before, after), "frames": numbers,
                          "interval_ms": arms.distribution(raw["intervals_ms"]), "main_ms": arms.distribution(raw["main_ms"]),
                          "motion_main_ms": arms.distribution(raw["motion_main_ms"]), "raw": raw, "presses": presses,
                          "display": display, "counters": counter_delta(before, after), "unsettled_after": unsettled(after)})
            refused = [press["refused"] for press in presses if press.get("refused")]
            if refused:
                entry["error"] = f"{len(refused)} of {len(presses)} presses refused: {refused[0]}"
            rounds.append(entry)
    return finish({"layout": name, "refresh_ms": refresh_ms, "plan": plan, "key_gap_ms": opts.key_gap_ms,
                   "key_settle_s": opts.key_settle_s, "rounds": rounds})


def history():
    write(f"clear; seq 1 {opts.scrollback}; seq -s. 900\r")


def keys():
    """4 terminals in a 2x2 grid, each with history, the bottom-left one focused: its Ctrl-Shift-L and Ctrl-Shift-H
    move the divider between the two columns, so all 4 resize."""
    rpc("action.run", {"action": "newTab", "focus": True})
    wait(lambda: surfaces(), 30)
    history()
    for action, shown in (("splitRight", 2), ("splitDown", 3)):
        rpc("action.run", {"action": action, "focus": True})
        wait(lambda: len(surfaces()) >= shown, 30)
        history()
    rpc("action.run", {"action": "focusLeft", "focus": True})
    time.sleep(0.5)  # bench script: the focus moves before the split
    rpc("action.run", {"action": "splitDown", "focus": True})
    if not wait(lambda: len(surfaces()) >= 4, 30):
        return {"layout": "keys", "error": f"the 2x2 grid did not form ({len(surfaces())} terminals shown)"}
    history()
    time.sleep(2.0)  # bench script: the history prints before the presses
    results = [measure_keys("keys")]
    if opts.held_repeat:
        results.append(measure_keys("keys-held", opts.held_repeat))
    if opts.newtab_runs:
        results.append(newtab_after_resize())
    return results


def newtab_after_resize():
    """SCRATCH (RESIZE MAIN BUDGET fix 1): Cmd-T in the focused pane right after a key resize changed its size (the
    spring landed, past the spare's old 120 ms settle): key ms, first visible frame, the cover the page showed, and
    whether the spare was laid out at another size than its pane's (`refit`)."""
    runs = []
    for index in range(opts.newtab_runs):
        action = "resizePaneRight" if index % 2 == 0 else "resizePaneLeft"
        rpc("action.run", {"action": action, "focus": True})
        time.sleep(0.8)  # bench script: the spring lands, then 120 ms more than the old fit settle
        result = rpc("debug.new_tab", {"action": "bench_create", "command": "new_tab"}, timeout=20) or {}
        marks = sorted({s["name"] for s in result.get("spans") or [] if s.get("ms", 0) == 0 and s["name"].startswith("newTab.cover")})
        state = rpc("debug.new_tab", {}) or {}
        openings = state.get("openings") or []
        row = {"run": index, "after": action, "key_ms": result.get("key_ms"), "visible_ms": result.get("visible_ms"),
               "frames_to_visible": result.get("frames_to_visible"), "cover": marks, "error": result.get("error"),
               "last_opening": openings[-1] if openings else None}
        print(f"NEWTAB-AFTER-RESIZE {json.dumps(row)}", flush=True)
        runs.append(row)
        time.sleep(0.5)  # bench script: the page shows before its close
        rpc("action.run", {"action": "closeTab", "focus": True})
        time.sleep(0.8)  # bench script: the close lands and the next spare is made
    return {"layout": "newtab-after-resize", "runs": runs}


def keys_stress():
    """The STRESS session's measured workspace, its first pane focused (column 1, row 1)."""
    session, summary = stress_session()
    panes = Stress.panes(session.workspace(session.measured)) if getattr(session, "measured", None) else []
    if panes:
        session.focus_pane(panes[0]["id"])
        time.sleep(1.0)  # bench script: the focus lands before the presses
    result = measure_keys("keys-stress")
    result["session"] = session_fields(summary)
    results = [result]
    if opts.held_repeat:
        held = measure_keys("keys-stress-held", opts.held_repeat)
        held["session"] = result["session"]
        results.append(held)
    return results


def light():
    before_ws = (rpc("debug.focus") or {}).get("workspace")
    rpc("action.run", {"action": "newTab", "focus": True})
    wait(lambda: surfaces(), 30)
    history()
    rpc("action.run", {"action": "splitRight", "focus": True})
    wait(lambda: len(surfaces()) >= 2 and vertical_dividers(), 30)
    history()
    time.sleep(2.0)  # bench script: the history prints before the drag
    return measure("light")


def idle_cursor():
    """A focused terminal at rest with its cursor hidden (as agent TUIs keep it): Ghostty frames drawn in
    --idle-s seconds. Each blink tick used to update and draw a frame (about 1.7/s); none changes a pixel."""
    rpc("action.run", {"action": "newTab", "focus": True})
    wait(lambda: surfaces(), 30)
    write("clear; printf '\\033[?25l'; sleep 600\r")
    time.sleep(1.5)  # bench script: the command runs and the screen settles
    def focused_frames():
        rows = surfaces()
        # The phase's own new workspace shows one terminal: the one it wrote to.
        row = rows[0] if len(rows) == 1 else None
        return (int(row["counters"].get("frames", 0)) if row else None), len(rows)
    # At rest first: the counter unchanged for 3 s in a row (at most 20 s), so the frames of the command's
    # own output (clear, the cursor hide) are not counted as idle frames.
    settle_start, (last, _) = time.monotonic(), focused_frames()
    stable_since = time.monotonic()
    while time.monotonic() - settle_start < 20 and time.monotonic() - stable_since < 3:
        time.sleep(0.5)  # bench script: polls the counter for the settle, not an app synchronization
        now, _ = focused_frames()
        if now != last:
            last, stable_since = now, time.monotonic()
    settled_s = round(time.monotonic() - settle_start, 1)
    before, shown = focused_frames()
    time.sleep(opts.idle_s)  # bench script: the measured idle window
    after, shown_after = focused_frames()
    result = {"layout": "idle-cursor", "idle_s": opts.idle_s, "terminals_shown": [shown, shown_after],
              "settled_s": settled_s, "frames_before": before, "frames_after": after,
              "note": "the bench window is never key (no activation): Ghostty's blink timer runs only when focused"}
    # No count without exactly one shown terminal with render counters: an error, never a 0.
    if before is None or after is None or before == 0:
        result["error"] = "no render counter for one shown terminal (or it never drew): no idle count"
    else:
        result["frames"] = after - before
    return result


STRESS = {}
_spec = importlib.util.spec_from_file_location("perf_stress_session", os.path.join(HERE, "perf-stress-session.py"))
_stress_module = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_stress_module)
Stress = _stress_module.Stress


def stress_session():
    """The STRESS session (perf-stress-session.py), built once per launch and shown: stress, keys-stress and
    split-resize-stress share it (a second build refuses: the app would have more than STRESS's 60 workspaces)."""
    if "session" not in STRESS:
        session = Stress(rpc)
        STRESS["summary"] = session.build()
        STRESS["session"] = session
        time.sleep(3.0)  # bench script: the session's pages and busy terminals start
        if opts.pages_mix:
            STRESS["summary"]["pages_mix"] = pages_mix(session)
            print(f"SMOOTH-PAGES-MIX {json.dumps(STRESS['summary']['pages_mix'])}", flush=True)
    else:
        STRESS["session"].show(STRESS["session"].measured)
        time.sleep(1.0)  # bench script: the measured workspace shows again after another layout's
    return STRESS["session"], STRESS["summary"]


def pages_mix(session):
    """SCRATCH (SMOOTH-PAGES-PROFILE): every other pane of each column (rows 2, 4, ... from the top) shows its first
    Chromium page (tab.focus, no focus move); the first pane of each column stays a terminal, so keys-stress still
    starts from a terminal. With --devtools-docked, the first page pane of column 2 (moved by the keys, column 1|2, and
    by the drag, column 2|3) docks DevTools at the bottom (devtools.openDocked). Raises when a page or DevTools does
    not show: a mix that is not there is not measured."""
    workspace = session.measured
    frames = {}
    for plane in session.shown_window().get("planes") or []:
        for ring in plane.get("rings") or []:
            if ring.get("pane") and ring.get("frame_in_window"):
                frames[ring["pane"]] = ring["frame_in_window"]
    columns = {}
    for pane, (x, y, w, h) in frames.items():
        columns.setdefault(round(x), []).append((y, pane))
    # Rows by y: every other row shows a page, whichever way y runs (3 rows: the middle one; 4 rows: two of them).
    picked, devtools_tab = [], None
    for column_index, (_, cells) in enumerate(sorted(columns.items())):
        panes = [pane for _, pane in sorted(cells)]
        for row, pane in enumerate(panes):
            if row % 2 == 0:
                continue
            # The builder's own record (asked kind, daemon id): the first tab asked as Chromium, not a WebKit one.
            page = next((ident for kind, ident, _ in session.made.get(pane) or [] if kind == "chromium" and ident), None)
            if not page:
                raise RuntimeError(f"pages-mix: pane {pane} has no Chromium tab")
            session.action("tab.focus", target=f"tab:{page}", focus=False)
            picked.append({"pane": pane, "tab": page, "column": column_index + 1, "row": row + 1})
            if opts.devtools_docked and column_index == 1 and devtools_tab is None:
                devtools_tab = page
    time.sleep(2.0)  # bench script: the shown pages load and draw
    shown = wait(lambda: (lambda w: w if sum(1 for b in w.get("browsers") or [] if b.get("engine") == "cef")
                          >= len(picked) else None)(session.shown_window()), 20)
    engines = [b.get("engine") for b in (session.shown_window().get("browsers") or [])]
    if not shown:
        raise RuntimeError(f"pages-mix: {len(picked)} pages asked, shown browsers by engine {engines}")
    result = {"page_panes": len(picked), "panes": picked, "shown_browsers": engines}
    if devtools_tab:
        pane = next(p["pane"] for p in picked if p["tab"] == devtools_tab)
        # As cef-layer-verify: the page's pane focused, then the action on it (a tab target can name the daemon id while
        # the page is still keyed by its provisional id). A DevTools that does not open is recorded, not fatal: the rows
        # with pages still measure, and the table says DevTools was missing.
        session.focus_pane(pane)
        session.action("tab.focus", target=f"tab:{devtools_tab}", focus=True)
        time.sleep(0.5)  # bench script: the page is the pane's content before the action
        reply = session.action("devtools.openDocked", target=f"pane:{pane}", focus=True)
        def opened():
            return next((d for d in (rpc("debug.cef") or {}).get("devtools") or []
                         if d.get("open") and d.get("devtools_frame")), None)
        entry = wait(opened, 30)
        if not entry:
            reply2 = session.action("devtools.openDocked", focus=True)  # the focused web view, no target
            entry = wait(opened, 30)
            reply = {"pane_target": reply, "no_target": reply2}
        if entry:
            time.sleep(2.5)  # bench script: the DevTools front end loads and draws
        result["devtools"] = {"tab": devtools_tab, "pane": pane, "open": bool(entry), "reply": json.dumps(reply)[:300],
                              "entry": entry if entry else (rpc("debug.cef") or {}).get("devtools")}
        print(f"SMOOTH-PAGES-DEVTOOLS {json.dumps(result['devtools'])[:1500]}", flush=True)
    first = Stress.panes(session.workspace(workspace))
    if first:
        session.focus_pane(first[0]["id"])
    return result


def session_fields(summary):
    return {k: summary.get(k) for k in ("workspaces", "measured_panes", "measured_tabs", "busy_terminals", "build_s",
                                         "pages_mix")} \
        if isinstance(summary, dict) else None


def stress():
    _, summary = stress_session()
    result = measure("stress")
    result["session"] = session_fields(summary)
    return result


def final_grid_round(action):
    """Runs `action` (splitRight, splitDown, closeTab: Cmd-D, Cmd-Shift-D, Cmd-W) inside a
    `debug.terminal_final_grid` window. Per terminal shown before it whose grid changed: grids sent to the
    daemon, ms from the action to the first one and to the final one, to the owner's final grid (the PTY
    has it, the program got SIGWINCH), and to the first frame drawn at it."""
    def first(entries, grid, skip_first=True):
        return next((e["ms"] for e in entries[1 if skip_first else 0:] if e["grid"] == grid), None)
    before = rpc("debug.terminal_final_grid", {"action": "stop"}) or {}
    shown = set((before.get("terminals") or {}).keys())
    rpc("debug.frames", {"action": "start"})
    started = rpc("debug.terminal_final_grid", {"action": "start"}) or {}
    ran = rpc("action.run", {"action": action, "focus": True})
    time.sleep(1.5)  # bench script: the spring lands and the last echo comes
    report = (rpc("debug.terminal_final_grid", {"action": "stop"}) or {}).get("terminals") or {}
    problems = [p for p in (
        None if started.get("started") else f"trace start replied {str(started)[:200]}",
        None if shown else f"no terminal shown before the action (trace replied {str(before)[:200]})",
        None if not (isinstance(ran, dict) and ran.get("error")) else f"{action} replied {str(ran)[:200]}",
    ) if p]
    frames = rpc("debug.frames", {"action": "stop"}) or {}
    rows = []
    for key in sorted(shown & set(report)):
        t = report[key]
        final, sends, owner, drawn = t.get("fitted"), t.get("sends") or [], t.get("owner") or [], t.get("drawn") or []
        if not sends and not (owner and owner[0]["grid"] != final):
            continue
        rows.append({"final": final, "sends": len(sends), "send_grids": [e["grid"] for e in sends],
                     "first_send_ms": sends[0]["ms"] if sends else None, "final_send_ms": first(sends, final, False),
                     "owner_final_ms": first(owner, final), "drawn_final_ms": first(drawn, final)})
    def worst(field):
        values = [r[field] for r in rows if r[field] is not None]
        return max(values) if values else None
    return {"action": action, "shown_before": len(shown), "problems": problems,
            "resized_terminals": len(rows), "max_first_send_ms": worst("first_send_ms"),
            "max_final_send_ms": worst("final_send_ms"), "max_owner_final_ms": worst("owner_final_ms"),
            "max_drawn_final_ms": worst("drawn_final_ms"), "sends_total": sum(r["sends"] for r in rows),
            "frames": {k: frames.get(k) for k in ("frames", "p95_ms", "max_ms", "missed", "main_p95_ms", "main_max_ms")},
            "terminals": rows}


def split_resize(in_stress=False):
    """Cmd-D, Cmd-W, Cmd-Shift-D, Cmd-W on a terminal that shows a full-screen program (less), light or in
    the STRESS session: when the resized terminals' final grids reach the PTY and the screen (Lawrence
    2026-10-23: before the animation ends, not after it)."""
    name = "split-resize-stress" if in_stress else "split-resize"
    summary = None
    if in_stress:
        _, summary = stress_session()
    else:
        rpc("action.run", {"action": "newTab", "focus": True})
        wait(lambda: surfaces(), 30)
    write("clear; seq 1 5000 | less\r")
    time.sleep(1.5)  # bench script: less draws its first page
    rounds = []
    for _ in range(opts.rounds):
        for action in ("splitRight", "closeTab", "splitDown", "closeTab"):
            rounds.append(final_grid_round(action))
            time.sleep(0.5)  # bench script: the next press starts at rest
    def stats(field):
        values = sorted(t[field] for r in rounds for t in r["terminals"] if t[field] is not None)
        if not values:
            return None
        pick = lambda q: values[min(len(values) - 1, int(q * (len(values) - 1) + 0.5))]
        return {"n": len(values), "p50": pick(0.5), "p95": pick(0.95), "max": values[-1]}
    result = {"layout": name, "summary": {
        "key_to_first_grid_sent_ms": stats("first_send_ms"),
        "key_to_final_grid_sent_ms": stats("final_send_ms"),
        "key_to_owner_final_grid_ms": stats("owner_final_ms"),
        "key_to_first_frame_at_final_grid_ms": stats("drawn_final_ms"),
        "note": "grid sent: exact (the send itself, TIOCSWINSZ follows in the daemon). owner grid and first "
                "frame: sampled once per display frame, so <= 1 frame late.",
    }, "rounds": rounds}
    if isinstance(summary, dict):
        result["session"] = session_fields(summary)
    return result


if os.path.exists(SOCKET):
    os.unlink(SOCKET)
# The run measures a session it builds: the tag's saved session from earlier runs on this host would be restored
# (cmux22, 2026-11-04: STRESS refused "the app already has 61 workspaces", and the light layout's terminals sat behind
# what the restored session showed). Only with no process of the bundle running: its state must not be in use.
# BENCH_LAUNCH_KEEP_STATE=1 keeps it.
running = bench_launch.bundle_pids(APP)
if running:
    print(f"bench-terminal-resize: {APP} already runs (pid {', '.join(map(str, running))}): its saved session stays",
          file=sys.stderr, flush=True)
elif not os.environ.get("BENCH_LAUNCH_KEEP_STATE"):
    bench_launch.start_fresh_state(TAG)
# An empty session is a first run: the app would put its Bring your history page in front of the first window
# (OnboardingService.showHistoryAtFirstRun, once per app channel). This tag's own defaults domain says it showed.
if sys.platform == "darwin" and info.get("CFBundleIdentifier") and not bench_launch.is_shipped_state_tag(TAG):
    subprocess.run(["defaults", "write", info["CFBundleIdentifier"], "home.firstRun.historyImportShown", "-bool", "YES"],
                   capture_output=True, timeout=30, stdin=subprocess.DEVNULL)
scratch = tempfile.mkdtemp(prefix=f"bench-terminal-resize-{TAG}-")
config = os.path.join(scratch, "cmux.json")
with open(config, "w") as f:
    f.write("{}\n")
ghostty = os.path.join(scratch, "ghostty")
open(ghostty, "w").close()
env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
       "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_CONFIG_FILE": config,
       "CMUX_NEXT_GHOSTTY_CONFIG": ghostty, "CMUX_NEXT_TEST_WINDOW_FRAME": "80,80,1600,1000"}
# The measure entry (split-spring.sh) runs on an exclusive worker: same environment as its own bench.
teardown = TagTeardown(APP)
teardown.install()
log = open(os.path.join(opts.out, "app.log"), "a")
app = subprocess.Popen([BINARY], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
report = {"pid": app.pid, "app": APP, "layouts": []}
unmeasured = []
try:
    if not wait(lambda: os.path.exists(SOCKET) and (rpc("debug.windows") or {}).get("windows"), 120):
        log.flush()
        tail = open(os.path.join(opts.out, "app.log"), errors="replace").read()[-3000:]
        sys.exit(f"app did not come up: socket {SOCKET} exists={os.path.exists(SOCKET)}; app log tail:\n{tail}")
    if opts.set:
        report["set"] = apply_sets()
        print(f"MAIN-BUDGET set {json.dumps(report['set'])}", flush=True)
    for name in [n for n in opts.layouts.split(",") if n]:
        produced = {"idle-cursor": idle_cursor, "light": light, "stress": stress, "split-resize": split_resize,
                    "split-resize-stress": lambda: split_resize(in_stress=True), "keys": keys, "keys-stress": keys_stress}[name]()
        for result in (produced if isinstance(produced, list) else [produced]):
            found = terminal_resize_verdict.problems(result)
            if opts.held_is_data:
                result["held_as_data"] = [p for p in found if "did not change size with their pane" in p]
                found = [p for p in found if "did not change size with their pane" not in p]
            if found:
                # A layout that measured nothing fails the run (its zeros are not a result).
                result["problems"] = found
                unmeasured.extend(found)
            report["layouts"].append(result)
            printed = dict(result, rounds=[{k: v for k, v in r.items() if k not in ("main_samples", "raw")}
                                           for r in result.get("rounds") or []])
            print(f"TERMINAL-RESIZE {json.dumps(printed)}", flush=True)
finally:
    if app.poll() is None:
        reset_arm()  # a layout that stopped early (an exception) did not reset it
    if app.poll() is None:
        app.send_signal(signal.SIGTERM)
        try:
            app.wait(20)
        except subprocess.TimeoutExpired:
            app.kill()
            app.wait()
    teardown.end()
    if unmeasured:
        report["problems"] = unmeasured
    for path in [os.path.join(opts.out, "terminal-resize.json")] + ([opts.json] if opts.json else []):
        with open(path, "w") as f:
            json.dump(report, f, indent=1)
if unmeasured:
    sys.exit("bench-terminal-resize: a layout measured nothing:\n  " + "\n  ".join(unmeasured))
