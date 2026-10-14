#!/usr/bin/env python3
"""Drag feel proof for the sidebar document (DESIGN.md "Drag feel"): records
each cross-section drag per display frame and checks it frame by frame.

  nx-remote --needs gui --app-from-fleet cmux --tag T --ref SHA \
    -- python3 scripts/cmux-next/sidebar-v2-drag-record.py --out "$NX_ARTIFACTS" [--real-pointer] [--stress 1000]

Each scenario starts `debug.sidebar_rows {"motion": "start"}` (every realized
row's, block item's and the lifted card's presented frame per display frame)
and `debug.window_record` (JPEG frames for the proof page), then drags as a
person does: press, 120 Hz moves along the path, a hold, release. Default
moves are `debug.mouse` events spaced in time; `--real-pointer` posts them at
the window server with `cliclick` (needs `nx-remote --needs input`).

Checks per scenario (CHECKS.json and stdout PASS/FAIL):
- jumps: no view other than the dragged one moves more than JUMP_PT in one
  frame (a gap spring's peak step is about 3 pt at 120 Hz);
- gap continuity: the same check over the frames where a gap opens or closes;
- settle: the card's last frame meets the dropped item's first frame within
  2 pt (no fly-back), and the item moves at most JUMP_PT per frame after it
  shows (no pop on the echo);
- work: the main-thread drag update stays under 4 ms (p95).
"""
import argparse, json, os, shutil, socket, subprocess, sys, tempfile, time

parser = argparse.ArgumentParser()
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS", "/tmp"))
parser.add_argument("--real-pointer", action="store_true")
parser.add_argument("--stress", type=int, default=0, help="extra workspaces before the drags (autoscroll, hitches)")
parser.add_argument("--hz", type=float, default=120)
opts = parser.parse_args()
APP, TAG, STOP = os.environ.get("NX_APP"), os.environ.get("NX_APP_TAG", ""), os.environ.get("NX_APP_STOP")
SOCKET = os.environ.get("NX_APP_SOCKET") or f"/tmp/cmux-debug-{TAG}.sock"
CLI = os.environ.get("NX_APP_CLI") or (APP and os.path.join(APP, "Contents/Resources/bin/cmux"))
if not APP or not STOP:
    sys.exit("run inside `nx-remote --needs gui --app-from-fleet cmux` (NX_APP, NX_APP_STOP)")
if opts.real_pointer and not shutil.which("cliclick"):
    # cmux-lawrence-2 has no cliclick; its real-input tool is ~/.local/bin/cua-driver (`call drag`, foreground,
    # window-local screenshot pixels, no hold before the release). Port `mouse()` to it before an input run.
    sys.exit("--real-pointer needs cliclick on PATH (or a cua-driver port of mouse())")
JUMP_PT = 12.0
SCRATCH = tempfile.mkdtemp(prefix=f"sbv2-rec-{TAG}-")
CONFIG, GHOSTTY = os.path.join(SCRATCH, "cmux.json"), os.path.join(SCRATCH, "ghostty")
open(GHOSTTY, "w").write("")
open(CONFIG, "w").write("{}")
os.makedirs(opts.out, exist_ok=True)
CHECKS = {}


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


def cli(*args):
    env = {"HOME": os.environ["HOME"], "PATH": "/usr/bin:/bin", "TMPDIR": os.environ.get("TMPDIR", "/tmp"), "CMUX_QUIET": "1"}
    try:
        out = subprocess.run([CLI, "--app-socket", SOCKET, *args], capture_output=True, text=True, timeout=60, env=env)
    except subprocess.TimeoutExpired:
        return "timeout"
    return (out.stdout + out.stderr).strip()


def wait(predicate, timeout):
    deadline = time.time() + timeout
    while time.time() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.2)  # test harness wait, not app code
    return None


def window():
    value = rpc("debug.sidebar_rows") or {}
    return ((value.get("windows") if isinstance(value, dict) else None) or [{}])[0]


def rows():
    return {r["title"]: r for r in window().get("rows", []) if r.get("title")}


def section_items(section):
    return [i for i in window().get("items", []) if i.get("section") == section]


def center(frame):
    return frame["x"] + frame["width"] / 2, frame["y"] + frame["height"] / 2


def row_id(row):
    key = str((row or {}).get("key", ""))
    return key[key.find("(") + 1:key.rfind(")")] if "(" in key else key


def window_origin():
    """The window's screen origin (top-left, points) for real pointer events."""
    frames = (rpc("debug.surfaces") or {}).get("windows") or [{}]
    frame = frames[0].get("frame") or {}
    return frame.get("x", 40), frame.get("y", 40)


def mouse(action, x, y):
    if opts.real_pointer:
        ox, oy = window_origin.cached
        verb = {"down": "dd", "drag": "dm", "up": "du"}[action]
        subprocess.run(["cliclick", f"{verb}:{int(ox + x)},{int(oy + y)}"], check=False)
    elif action == "drag":
        rpc("debug.mouse", {"x": x, "y": y, "action": "drag", "to_x": x, "to_y": y, "steps": 1, "press": False, "release": False})
    else:
        rpc("debug.mouse", {"x": x, "y": y, "action": action})


def gesture(path, hold=0.35, seconds=1.2):
    """Press at path[0], move through the path's points in `seconds` at opts.hz, hold, release."""
    x0, y0 = path[0]
    mouse("down", x0, y0)
    points = []
    for (ax, ay), (bx, by) in zip(path, path[1:]):
        n = max(2, int(seconds * opts.hz / max(1, len(path) - 1)))
        points += [(ax + (bx - ax) * i / n, ay + (by - ay) * i / n) for i in range(1, n + 1)]
    period = 1.0 / opts.hz
    start = time.monotonic()
    for index, (x, y) in enumerate(points):
        mouse("drag", x, y)
        delay = start + (index + 1) * period - time.monotonic()
        if delay > 0:
            time.sleep(delay)  # test harness pacing: a person's 120 Hz pointer
    deadline = time.monotonic() + hold
    while time.monotonic() < deadline:  # a still pointer sends no moves; the display-link autoscroll keeps going
        time.sleep(period)
    x, y = points[-1]
    mouse("up", x, y)


def check(name, frames, dragged, dropped_key=None):
    """Frame checks over one scenario's motion samples."""
    worst, worst_at, jumps = 0.0, None, []
    for a, b in zip(frames, frames[1:]):
        for key, fb in b["views"].items():
            fa = a["views"].get(key)
            if fa is None or key in dragged:
                continue
            step = max(abs(fb[0] - fa[0]), abs(fb[1] - fa[1]), abs(fb[3] - fa[3]))
            if step > worst:
                worst, worst_at = step, (key, round(b["t"] - frames[0]["t"], 3))
            if step > JUMP_PT:
                jumps.append({"key": key, "t": round(b["t"] - frames[0]["t"], 3), "step": round(step, 1)})
    work = sorted(f["work_ms"] for f in frames if f["work_ms"] > 0)
    p95 = work[int(len(work) * 0.95)] if work else 0
    gaps = [b["t"] - a["t"] for a, b in zip(frames, frames[1:])]
    long_frames = sum(1 for g in gaps if g > 1.5 / opts.hz)
    settle = None
    lifted = [f for f in frames if f["lift"]]
    if lifted and not dropped_key:
        # The dropped item: a key that shows after the drop and not at the start, else the dragged row itself.
        new = [k for k in frames[-1]["views"] if k not in frames[0]["views"]]
        dropped_key = new[0] if len(new) == 1 else next(iter(dragged & set(frames[-1]["views"])), None)
    if lifted and dropped_key:
        last = lifted[-1]
        after = [f for f in frames if f["t"] > last["t"] and dropped_key in f["views"]]
        if after:
            card, item = last["lift"], after[0]["views"][dropped_key]
            meet = max(abs(card[0] - item[0]), abs(card[1] - item[1]))
            drift = max((max(abs(b["views"][dropped_key][1] - a["views"][dropped_key][1]), abs(b["views"][dropped_key][0] - a["views"][dropped_key][0]))
                         for a, b in zip(after, after[1:]) if dropped_key in a["views"] and dropped_key in b["views"]), default=0)
            settle = {"card_meets_item_pt": round(meet, 1), "item_max_step_after_pt": round(drift, 1), "ok": meet <= 2 and drift <= JUMP_PT}
    result = {"frames": len(frames), "max_step_pt": round(worst, 1), "max_step_at": worst_at, "jumps": jumps[:20], "jump_count": len(jumps),
              "drag_work_p95_ms": round(p95, 2), "frame_gaps_over_1_5x": long_frames, "settle": settle}
    # Nothing recorded, no lifted card or no dropped item to follow is a failed proof, not a pass.
    recorded = len(frames) >= 10 and bool(lifted)
    result["recorded"] = recorded
    ok = recorded and not jumps and p95 < 4 and settle is not None and settle["ok"]
    result["ok"] = ok
    CHECKS[name] = result
    print(f"{'PASS' if ok else 'FAIL'} {name}: {json.dumps(result)}", flush=True)


def record(name, path, dragged, dropped_key=None, **kwargs):
    folder = os.path.join(opts.out, name)
    shutil.rmtree(folder, ignore_errors=True)
    rpc("debug.sidebar_rows", {"motion": "start"})
    rpc("debug.window_record", {"dir": folder, "seconds": min(8, kwargs.get("seconds", 1.2) + kwargs.get("hold", 0.35) + 1.4)})
    gesture(path, **kwargs)
    time.sleep(1.2)  # test harness: let the drop settle on screen
    frames = (rpc("debug.sidebar_rows", {"motion": "stop"}, timeout=60) or {}).get("frames") or []
    os.makedirs(folder, exist_ok=True)
    json.dump(frames, open(os.path.join(folder, "motion.json"), "w"))
    check(name, frames, dragged, dropped_key)


def launch():
    if os.path.exists(SOCKET):
        os.unlink(SOCKET)
    env = ["CMUX_NEXT_NO_ACTIVATE=1", "CMUX_NEXT_SOCKET_MODE=automation", "CMUX_NEXT_TEST_WINDOW_SCREEN=last",
           f"CMUX_NEXT_CONFIG_FILE={CONFIG}", f"CMUX_NEXT_GHOSTTY_CONFIG={GHOSTTY}", "CMUX_NEXT_TEST_WINDOW_FRAME=40,40,1100,820"]
    subprocess.run(["open", "-n", APP, *[arg for pair in env for arg in ("--env", pair)]], check=True)
    if not wait(lambda: os.path.exists(SOCKET) and (rpc("debug.surfaces") or {}).get("windows"), 120):
        sys.exit("FAIL the tagged app did not come up")
    time.sleep(1.5)  # test harness: let the window settle


launch()
window_origin.cached = window_origin()
try:
    for name in ("Alpha", "Beta", "Gamma", "Delta", "Echo", "Foxtrot"):
        cli("workspace", "create", "--name", name)
    wait(lambda: {"Alpha", "Foxtrot"} <= set(rows()), 20)
    for name in ("Beta", "Gamma"):
        rpc("debug.toast", {"perform": "palette.toggleWorkspacePin", "target_kind": "workspace", "target_id": row_id(rows().get(name))})
    time.sleep(1.0)  # test harness: let the pins land
    for index in range(opts.stress):
        cli("workspace", "create", "--name", f"S{index:04d}")
    if opts.stress:
        wait(lambda: f"S{opts.stress - 1:04d}" in json.dumps(window().get("rows", [])) or None, 600)

    # 1. A workspace row into Pinned tiles (between the two tiles).
    alpha, pinned = rows().get("Alpha"), section_items("sec_pinned")
    if alpha and len(pinned) >= 2:
        start, first = center(alpha["window_frame"]), pinned[0]["window_frame"]
        record("1-row-into-pinned", [start, (start[0], start[1] - 30), (first["x"] + first["width"] * 0.85, first["y"] + first["height"] / 2)],
               {f"workspace({row_id(alpha)})"})
    # 2. A tile back into the list (between Delta and Echo).
    pinned, delta, echo = section_items("sec_pinned"), rows().get("Delta"), rows().get("Echo")
    if pinned and delta and echo:
        tile = pinned[0]
        to = (center(delta["window_frame"])[0], (delta["window_frame"]["y"] + delta["window_frame"]["height"] + echo["window_frame"]["y"]) / 2)
        record("2-tile-into-list", [center(tile["window_frame"]), to], {f"item:{tile.get('id')}"})
    # 3. A group into Pinned (custom-section behavior: same section kind rules).
    cli("workspace", "group", "create", "--name", "Grp")
    cli("workspace", "group", "Grp", "add", "--workspace", "Foxtrot")
    time.sleep(1.0)  # test harness: let the group show
    group = next((r for r in window().get("rows", []) if str(r.get("key", "")).startswith("group")), None)
    pinned = section_items("sec_pinned")
    if group and pinned:
        last = pinned[-1]["window_frame"]
        record("3-group-into-pinned", [center(group["window_frame"]), (last["x"] + last["width"] * 0.85, last["y"] + last["height"] / 2)],
               {str(group.get("key"))})
    # 4. A long drag down into the list's bottom edge: autoscroll, then a drop.
    listed = [r for r in window().get("rows", []) if r.get("title") and r.get("in_list")]
    if listed:
        top = listed[0]
        bottom = max(r["window_frame"]["y"] + r["window_frame"]["height"] for r in listed)
        edge = min(bottom, 820 - 60)
        record("4-autoscroll-across", [center(top["window_frame"]), (center(top["window_frame"])[0], edge - 4)], {str(top.get("key"))},
               hold=2.0, seconds=1.0)
finally:
    json.dump(CHECKS, open(os.path.join(opts.out, "CHECKS.json"), "w"), indent=1)
    subprocess.run([STOP], check=False)
sys.exit(0 if CHECKS and all(c["ok"] for c in CHECKS.values()) else 1)
