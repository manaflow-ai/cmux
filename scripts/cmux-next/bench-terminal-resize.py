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
           in those columns resizes each frame.

Per layout it records display-frame intervals and main-thread busy time per frame (`debug.frames`,
missed = an interval over 1.5 refresh periods), main-thread time in Ghostty's display passes
(`debug.terminal_display`: before G1 each pass drew on main with the previous size's cells and waited
for the GPU), and the render counters of every resized terminal (`debug.surfaces`): frames drawn by
the main thread, fresh frames presented in the commit of their size, late passes (GhosttyNextKit with
G1; absent before), full rebuilds. After the drag every terminal's drawn, fitted and owner grids must
agree. Prints one JSON summary per layout and writes OUT/terminal-resize.json. Exit 0 always (a bench,
not a gate); the summary says what to compare.
"""
import argparse, glob, importlib.util, json, os, plistlib, signal, socket, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
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


def drag(x0, y0, refresh_s):
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


def measure(name):
    dividers = vertical_dividers()
    if not dividers:
        return {"layout": name, "error": "no vertical divider"}
    x0, y0, height = column_divider(dividers, middle=(name == "stress"))
    rpc("debug.frames", {"action": "start"})
    time.sleep(1.0)  # bench script: idle frames give the refresh period
    idle = rpc("debug.frames", {"action": "stop"}) or {}
    refresh_ms = idle.get("refresh_ms") or 16.67
    rounds = []
    for _ in range(opts.rounds):
        before = surfaces()
        rpc("debug.terminal_display", {"action": "start"})
        rpc("debug.frames", {"action": "start"})
        drag(x0, y0, refresh_ms / 1000)
        frames = rpc("debug.frames", {"action": "stop"}) or {}
        display = rpc("debug.terminal_display", {"action": "stop"}) or {}
        time.sleep(1.0)  # bench script: the drag's last grid lands at the owner
        after = surfaces()
        settled = [s for s in after if not (s["fit"] == s["drawn"] == s["grid"])]
        # Resized in the drag: a full rebuild for a new grid, or a fitted grid that differs midway (the
        # drag ends where it began, so start and end grids match).
        by_id = {b["id"]: b for b in before}
        resized = sum(1 for a in after if a["id"] in by_id and
                      int(a["counters"].get("full_resize", 0)) > int(by_id[a["id"]]["counters"].get("full_resize", 0)))
        rounds.append({
            "terminals": len(after),
            "resized_terminals": resized,
            "frames": {k: frames.get(k) for k in ("frames", "refresh_ms", "p50_ms", "p95_ms", "p99_ms", "max_ms", "missed",
                                                  "main_p50_ms", "main_p95_ms", "main_max_ms", "main_total_ms",
                                                  "main_over_8_3_ms")},
            "display": display,
            "counters": counter_delta(before, after),
            "unsettled_after": [{"fit": s["fit"], "drawn": s["drawn"], "grid": s["grid"]} for s in settled],
        })
    return {"layout": name, "refresh_ms": refresh_ms, "moves": 4 * opts.steps, "rounds": rounds,
            "divider": {"x": round(x0, 1), "height": round(height, 1), "vertical_dividers": len(dividers)}}


def light():
    before_ws = (rpc("debug.focus") or {}).get("workspace")
    rpc("action.run", {"action": "newTab", "focus": True})
    wait(lambda: surfaces(), 30)
    write(f"clear; seq 1 {opts.scrollback}; seq -s. 900\r")
    rpc("action.run", {"action": "splitRight", "focus": True})
    wait(lambda: len(surfaces()) >= 2 and vertical_dividers(), 30)
    write(f"clear; seq 1 {opts.scrollback}; seq -s. 900\r")
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


def stress():
    path = os.path.join(HERE, "perf-stress-session.py")
    spec = importlib.util.spec_from_file_location("perf_stress_session", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    summary = module.Stress(rpc).build()
    time.sleep(3.0)  # bench script: the session's pages and busy terminals start
    result = measure("stress")
    result["session"] = {k: summary.get(k) for k in ("workspaces", "measured_panes", "measured_tabs", "busy_terminals", "build_s")} \
        if isinstance(summary, dict) else None
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


def split_resize(stress_session=False):
    """Cmd-D, Cmd-W, Cmd-Shift-D, Cmd-W on a terminal that shows a full-screen program (less), light or in
    the STRESS session: when the resized terminals' final grids reach the PTY and the screen (Lawrence
    2026-10-23: before the animation ends, not after it)."""
    name = "split-resize-stress" if stress_session else "split-resize"
    summary = None
    if stress_session:
        path = os.path.join(HERE, "perf-stress-session.py")
        spec = importlib.util.spec_from_file_location("perf_stress_session", path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        summary = module.Stress(rpc).build()
        time.sleep(3.0)  # bench script: the session's pages and busy terminals start
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
        result["session"] = {k: summary.get(k) for k in ("workspaces", "measured_panes", "measured_tabs", "busy_terminals")}
    return result


if os.path.exists(SOCKET):
    os.unlink(SOCKET)
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
try:
    if not wait(lambda: os.path.exists(SOCKET) and (rpc("debug.windows") or {}).get("windows"), 120):
        log.flush()
        tail = open(os.path.join(opts.out, "app.log"), errors="replace").read()[-3000:]
        sys.exit(f"app did not come up: socket {SOCKET} exists={os.path.exists(SOCKET)}; app log tail:\n{tail}")
    for name in [n for n in opts.layouts.split(",") if n]:
        result = {"idle-cursor": idle_cursor, "light": light, "stress": stress, "split-resize": split_resize,
                  "split-resize-stress": lambda: split_resize(stress_session=True)}[name]()
        report["layouts"].append(result)
        print(f"TERMINAL-RESIZE {json.dumps(result)}", flush=True)
finally:
    if app.poll() is None:
        app.send_signal(signal.SIGTERM)
        try:
            app.wait(20)
        except subprocess.TimeoutExpired:
            app.kill()
            app.wait()
    teardown.end()
    for path in [os.path.join(opts.out, "terminal-resize.json")] + ([opts.json] if opts.json else []):
        with open(path, "w") as f:
            json.dump(report, f, indent=1)
