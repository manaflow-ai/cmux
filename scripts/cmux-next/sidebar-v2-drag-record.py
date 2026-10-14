#!/usr/bin/env python3
"""Drag feel proof for the sidebar document (DESIGN.md "Drag feel"): records
each cross-section drag per display frame and checks it frame by frame.

  nx-remote --needs input --app-from-fleet cmux --tag T --ref SHA \
    -- python3 scripts/cmux-next/sidebar-v2-drag-record.py --out "$NX_ARTIFACTS/rec" --real-pointer
  ... --stress 1000 --trace --scenarios 1,4   (Animation Hitches trace during the drags)

Each scenario starts `debug.sidebar_rows {"motion": "start"}` (every realized
row's, block item's and the lifted card's presented frame and opacity per
display frame, the model revision) and `debug.window_record` (JPEG frames for
the proof page), then drags. `--real-pointer` drives the window server's
pointer with ~/.local/bin/cua-driver `call drag` (foreground, a straight
press-move-release; needs `nx-remote --needs input`); without it the moves
are `debug.mouse` events spaced at --hz.

Scenarios: 1 row into Pinned, 2 tile into list, 3 group into Pinned,
4 long drag with autoscroll, 5 refusal (Escape mid-drag: the gap closes and
the card flies back to its source slot).

Checks per scenario (CHECKS.json and stdout PASS/FAIL):
- jumps: no view other than the dragged one moves more than JUMP_PT (8 pt) in
  x, y or height in one frame (a 26 pt gap spring's peak step is about 2 pt at 120 Hz);
- blocks: the same over the block rows' heights (the Pinned block grows and
  shrinks on the spring);
- settle: the card's last frame meets the dropped (or, refused, the source)
  item's first frame without the card within 1 pt (no fly-back, no miss);
- echo: at every model revision change after the drop no view kinks (second
  difference over 1 pt) and no visible view appears or vanishes outside the
  card (the echo changes nothing on screen);
- work: the main-thread drag update stays under 4 ms (p95).
"""
import argparse, json, os, shutil, socket, subprocess, sys, tempfile, threading, time, atexit

from sidebar_v2_motion_checks import analyse

parser = argparse.ArgumentParser()
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS", "/tmp"))
parser.add_argument("--real-pointer", action="store_true")
parser.add_argument("--stress", type=int, default=0, help="extra workspaces before the drags (autoscroll, hitches)")
parser.add_argument("--hz", type=float, default=120)
parser.add_argument("--scenarios", default="1,2,3,4,5")
parser.add_argument("--trace", action="store_true", help="record an Animation Hitches trace (xctrace) over the drags")
parser.add_argument("--setup-only", action="store_true", help="after the setup: window snapshot + debug.sidebar_rows dump, no drags")
opts = parser.parse_args()
WANTED = set(opts.scenarios.split(","))
CUA = os.path.expanduser("~/.local/bin/cua-driver")
# One cua-driver session for every call: each `cua-driver call` otherwise gets its own implicit session, and a pixel
# drag then has no screenshot context (job 1014-101119-0fef0c: drag replied {"code": "screenshot_context_missing"}).
# A fresh label per run, started explicitly: cua-driver refuses a label whose session has ended (hitch6
# 1014-122551-0acceb: "session has ended; tool call 'list_windows' was rejected").
CUA_SESSION = f"sbv2-rec-{os.getpid()}-{int(time.time())}"
APP, TAG, STOP = os.environ.get("NX_APP"), os.environ.get("NX_APP_TAG", ""), os.environ.get("NX_APP_STOP")
SOCKET = os.environ.get("NX_APP_SOCKET") or f"/tmp/cmux-debug-{TAG}.sock"
CLI = os.environ.get("NX_APP_CLI") or (APP and os.path.join(APP, "Contents/Resources/bin/cmux"))
if not APP or not STOP:
    sys.exit("run inside `nx-remote --needs gui --app-from-fleet cmux` (NX_APP, NX_APP_STOP)")
if opts.real_pointer and not os.access(CUA, os.X_OK):
    sys.exit("--real-pointer needs ~/.local/bin/cua-driver (run under nx-remote --needs input)")
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


def cua(tool, args, timeout=60):
    out = subprocess.run([CUA, "call", tool, json.dumps({"session": CUA_SESSION, **args})], capture_output=True, text=True, timeout=timeout)
    try:
        return json.loads(out.stdout)
    except ValueError:
        return {"error": (out.stdout + out.stderr)[-400:]}


class Target:
    """The tagged app's main window for cua-driver: pid, window id and the
    screenshot pixels per point (cua-driver takes window-local screenshot pixels)."""
    pid = window_id = None
    scale = 1.0

    @classmethod
    def find(cls):
        pid = app_pid()
        started = cua("start_session", {})
        if isinstance(started, dict) and started.get("error"):
            fail_harness(f"cua-driver start_session failed: {json.dumps(started)[:300]}")
        # The window can still be ordering in after launch (hitch5 1014-112015-158e99 found none on screen): wait for it.
        listed = {}
        windows = wait(lambda: [w for w in (listed.update(cua("list_windows", {"pid": pid})) or listed.get("windows") or [])
                                if w.get("is_on_screen")], 30)
        if not windows:
            fail_harness(f"cua-driver lists no on-screen window for pid {pid} after 30 s: {json.dumps(listed)[:400]}")
        main = max(windows, key=lambda w: w["bounds"]["width"] * w["bounds"]["height"])
        shot = os.path.join(SCRATCH, "window.png")
        cua("get_window_state", {"pid": pid, "window_id": main["window_id"], "screenshot_out_file": shot}, timeout=120)
        width = int.from_bytes(open(shot, "rb").read()[16:20], "big") if os.path.exists(shot) else 0
        cls.pid, cls.window_id = pid, main["window_id"]
        cls.scale = width / main["bounds"]["width"] if width else 1.0
        print(f"cua target pid={pid} window={cls.window_id} bounds={main['bounds']} scale={cls.scale:.3f}", flush=True)


def ground():
    """A fresh screenshot context for the next pixel action (the drag's coordinates are in its pixels)."""
    shot = os.path.join(SCRATCH, "ground.png")
    reply = cua("get_window_state", {"pid": Target.pid, "window_id": Target.window_id, "screenshot_out_file": shot,
                                     "max_elements": 1}, timeout=120)
    if not isinstance(reply, dict) or reply.get("error") or reply.get("code"):
        fail_harness(f"cua-driver get_window_state before the drag failed: {json.dumps(reply)[:400]}")


def real_drag(a, b, seconds):
    """One straight press-move-release at the window server (cua-driver, foreground), `opts.hz` moves per second."""
    steps = max(2, min(200, int(seconds * opts.hz)))
    k = Target.scale
    return cua("drag", {"pid": Target.pid, "window_id": Target.window_id, "delivery_mode": "foreground",
                        "from_x": a[0] * k, "from_y": a[1] * k, "to_x": b[0] * k, "to_y": b[1] * k,
                        "duration_ms": int(seconds * 1000), "steps": steps}, timeout=seconds + 60)


def mouse(action, x, y):
    if action == "drag":
        rpc("debug.mouse", {"x": x, "y": y, "action": "drag", "to_x": x, "to_y": y, "steps": 1, "press": False, "release": False})
    else:
        rpc("debug.mouse", {"x": x, "y": y, "action": action})


def fail_harness(message):
    """Stops the run: a dead harness must not record a still sidebar as data (CHECKS.json says why)."""
    CHECKS["harness"] = {"ok": False, "error": message}
    sys.exit(f"FAIL real drag: {message}")


def gesture(path, hold=0.35, seconds=1.2, escape_at=None):
    """Press at path[0], move through the path in `seconds`, hold, release; `escape_at` (s): Escape mid-drag."""
    if opts.real_pointer:
        # cua-driver moves along one straight line and releases at its end (no hold). Its call can return
        # before the gesture runs, and fronting the window takes a while (job 1014-082101-bac11c: every scenario
        # recorded a still sidebar), so time the scenario from the drag the app reports, not from the call.
        if window().get("drag_active"):
            fail_harness("a drag from the previous scenario is still active before the cua-driver call")
        ground()
        reply = {}
        worker = threading.Thread(target=lambda: reply.update(value=real_drag(path[0], path[-1], seconds)))
        called = time.monotonic()
        worker.start()
        began = wait(lambda: window().get("drag_active"), 5)
        if not began:
            # A dead harness must not record a still sidebar as data: stop the run here.
            worker.join(seconds + 70)
            fail_harness(f"the app reported no drag within 5 s of the cua-driver call (reply: {json.dumps(reply.get('value'))[:500]})")
        print(f"real drag: began {time.monotonic() - called:.2f}s after the call", flush=True)
        if escape_at is not None:
            threading.Timer(max(0.0, escape_at - 0.2), lambda: rpc("debug.key", {"key": "escape"})).start()
        worker.join(seconds + 70)  # no polling while the pointer moves (it would add main-thread work to the trace)
        value = reply.get("value")
        failed = not isinstance(value, dict) or value.get("error") or value.get("isError") or value.get("code")
        print(f"cua drag {'FAILED' if failed else 'reply'}: {json.dumps(value)[:500]}", flush=True)
        if not wait(lambda: not window().get("drag_active"), 10):
            fail_harness("the drag was still active 10 s after the cua-driver gesture ended")
        return
    if escape_at is not None:
        threading.Timer(escape_at, lambda: rpc("debug.key", {"key": "escape"})).start()
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


def check(name, frames, dragged, dropped_key=None, refused=False):
    """Frame checks over one scenario's motion samples (also run offline: python3 -c 'import ...; check(...)')."""
    result = analyse(frames, dragged, dropped_key, refused, hz=opts.hz)
    CHECKS[name] = result
    print(f"{'PASS' if result['ok'] else 'FAIL'} {name}: {json.dumps(result)}", flush=True)


TRACE = {}


TRACE_TMP = []


TRACE_STARTED = []


def drop_trace_tmp():
    """Deletes the recorder's Instruments intermediates (the exported .trace and XML stay). If Instruments ignored TMPDIR,
    it also deletes instruments*.ktrace files in the user's temp dir that appeared after this run's trace started and that
    no process has open (another run's file is older, or open)."""
    while TRACE_TMP:
        shutil.rmtree(TRACE_TMP.pop(), ignore_errors=True)
    if not TRACE_STARTED:
        return
    since = TRACE_STARTED[0]
    tmp = subprocess.run(["getconf", "DARWIN_USER_TEMP_DIR"], capture_output=True, text=True).stdout.strip()
    import glob
    for name in glob.glob(os.path.join(tmp, "instruments*.ktrace")):
        try:
            born = os.stat(name).st_birthtime
        except OSError:
            continue
        if born >= since and not subprocess.run(["lsof", "-t", name], capture_output=True, text=True).stdout.strip():
            try:
                os.remove(name)
            except OSError:
                pass


atexit.register(drop_trace_tmp)


def trace_start():
    if not opts.trace:
        return None
    path = os.path.join(opts.out, "hitches.trace")
    shutil.rmtree(path, ignore_errors=True)
    # Instruments writes its instruments*.ktrace intermediates (1-12 GB each) to TMPDIR and leaves them when a recording is
    # interrupted: give it its own directory and delete it once the .trace is exported (TRACE_TMP, trace_stop, atexit).
    TRACE_STARTED.append(time.time())
    scratch = tempfile.mkdtemp(prefix="sbv2-xctrace-")
    TRACE_TMP.append(scratch)
    proc = subprocess.Popen(["xcrun", "xctrace", "record", "--template", "Animation Hitches", "--attach", str(Target.pid or app_pid()),
                             "--output", path, "--time-limit", "120s"], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                            env={**os.environ, "TMPDIR": scratch + "/"})
    time.sleep(4)  # test harness: xctrace attaches before the first drag
    return proc, path


def trace_stop(handle):
    if not handle:
        return
    proc, path = handle
    proc.send_signal(2)
    try:
        log = proc.communicate(timeout=180)[0]
    except subprocess.TimeoutExpired:
        proc.kill()
        log = "timeout"
    open(os.path.join(opts.out, "xctrace.log"), "w").write(log or "")
    drop_trace_tmp()  # the recording is finalized into hitches.trace (or failed): its intermediates are no longer needed
    try:
        toc = subprocess.run(["xcrun", "xctrace", "export", "--input", path, "--toc"], capture_output=True, text=True, timeout=300).stdout
    except subprocess.TimeoutExpired:
        TRACE["error"] = "xctrace export --toc timed out"
        return
    open(os.path.join(opts.out, "hitches-toc.xml"), "w").write(toc)
    import re, xml.etree.ElementTree as ET
    schemas = sorted(set(re.findall(r'schema="([^"]*hitch[^"]*)"', toc)))
    summary = {"schemas": schemas}
    duration = re.search(r"<duration>([0-9.]+)</duration>", toc)
    summary["trace_seconds"] = float(duration.group(1)) if duration else None
    for schema in schemas:
        try:
            xml = subprocess.run(["xcrun", "xctrace", "export", "--input", path, "--xpath", f'/trace-toc/run[@number="1"]/data/table[@schema="{schema}"]'],
                                 capture_output=True, text=True, timeout=300).stdout
        except subprocess.TimeoutExpired:
            summary[schema] = {"error": "export timed out"}
            continue
        open(os.path.join(opts.out, f"{schema}.xml"), "w").write(xml)
        rows = xml.count("<row")
        total_ns = 0
        try:
            root = ET.fromstring(xml)
            ids = {}
            for el in root.iter():
                if el.get("id") and el.text and el.tag in ("duration", "duration-on-core"):
                    ids[el.get("id")] = int(el.text)
            for row in root.iter("row"):
                for el in row:
                    if el.tag == "duration":
                        total_ns += int(el.text) if el.text else ids.get(el.get("ref"), 0)
                        break
        except (ET.ParseError, ValueError):
            pass
        entry = {"rows": rows, "hitch_ms": round(total_ns / 1e6, 1)}
        if summary["trace_seconds"]:
            entry["ratio_ms_per_s"] = round(total_ns / 1e6 / summary["trace_seconds"], 2)
        summary[schema] = entry
    TRACE.update(summary)
    print(f"TRACE {json.dumps(summary)}", flush=True)


def app_pid():
    """The tagged app's pid: the process that holds its debug socket (an `open -n` launch's command line need
    not name the bundle path pgrep looks for), else the newest process running the bundle's binary."""
    for command in (["lsof", "-t", SOCKET], ["pgrep", "-n", "-f", os.path.join(os.path.realpath(APP), "Contents/MacOS")],
                    ["pgrep", "-n", "-f", os.path.join(APP, "Contents/MacOS")]):
        found = [int(pid) for pid in subprocess.run(command, capture_output=True, text=True).stdout.split() if int(pid) != os.getpid()]
        if found:
            return found[0]
    sys.exit(f"FAIL no process for the tagged app (socket {SOCKET}, bundle {APP})")


def record(name, path, dragged, dropped_key=None, refused=False, **kwargs):
    folder = os.path.join(opts.out, name)
    shutil.rmtree(folder, ignore_errors=True)
    rpc("debug.sidebar_rows", {"motion": "start"})
    # A real-pointer gesture starts late (the window is fronted first): record the longest window.
    seconds = 10 if opts.real_pointer else min(8, kwargs.get("seconds", 1.2) + kwargs.get("hold", 0.35) + 1.6)
    rpc("debug.window_record", {"dir": folder, "seconds": seconds})
    gesture(path, **kwargs)
    time.sleep(1.2)  # test harness: let the drop settle on screen
    frames = (rpc("debug.sidebar_rows", {"motion": "stop"}, timeout=60) or {}).get("frames") or []
    os.makedirs(folder, exist_ok=True)
    json.dump(frames, open(os.path.join(folder, "motion.json"), "w"))
    check(name, frames, dragged, dropped_key, refused)


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
trace = None
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
        # The new workspaces scrolled the list to its end, so Alpha and the Pinned tiles have no on-screen frame (hitch7
        # failed on a None tile frame): wheel the list back to its top before the drags.
        # New workspaces go to the list's top (newest first) and the Pinned tiles are a block at the very top of the
        # list, so at 1000 workspaces Alpha (near the end) and Pinned are never on screen together (setup1
        # 1014-155557-376478: Pinned block y -14440, Alpha y 1818). Wheel the list to its top until both Pinned tiles
        # have a frame; scenario 1 then drags the first workspace row under Pinned instead of Alpha.
        def pinned_block_y():
            block = next((r for r in window().get("rows", []) if str(r.get("key", "")) == 'block("sec_pinned")'), None)
            return ((block or {}).get("window_frame") or {}).get("y")
        def at_top():
            pinned, y = section_items("sec_pinned"), pinned_block_y()
            return bool(pinned and all(i.get("window_frame") for i in pinned) and y is not None and y >= 0)
        # debug.sidebar_wheel posts through the window's sendEvent like the window server does (hitch11: phased debug.mouse
        # scrolls moved the list once, 2400 pt, then never again). Positive dy moves the list toward its top.
        before, stuck = pinned_block_y(), 0
        for attempt in range(80):
            if at_top():
                break
            anchor = next((r for r in window().get("rows", []) if r.get("in_list") and r.get("window_frame")
                           and 0 <= r["window_frame"]["y"] < 760), None)
            if not anchor:
                print("no on-screen list row to wheel over", flush=True)
                break
            x, y = center(anchor["window_frame"])
            trackpad = stuck < 3
            reply = rpc("debug.sidebar_wheel", {"x": x, "y": y, "dy": 300 if trackpad else 40, "count": 20, "trackpad": trackpad})
            time.sleep(0.4)  # test harness: let the scroll (and any momentum) apply
            after = pinned_block_y()
            stuck = stuck + 1 if after == before else 0
            if attempt < 3 or attempt % 10 == 0 or stuck == 3:
                print("scroll", attempt, "trackpad", trackpad, "pinned block y", before, "->", after, "reply", json.dumps(reply)[:160], flush=True)
            if stuck >= 6:
                break
            before = after
        print("list at top:", at_top(), "pinned block y:", pinned_block_y(),
              "pinned frames:", [i.get("window_frame") for i in section_items("sec_pinned")], flush=True)
    if opts.setup_only:
        print("snapshot", json.dumps(rpc("debug.window_snapshot", {"path": os.path.join(opts.out, "setup.png"), "webviews": False}, timeout=60))[:300], flush=True)
        json.dump(rpc("debug.sidebar_rows"), open(os.path.join(opts.out, "setup-rows.json"), "w"), indent=1)
        sys.exit(0)
    # The cua-driver session starts after the setup: a 1000-workspace setup outlived its idle TTL (hitch10: "session has ended").
    if opts.real_pointer or opts.trace:
        Target.find()
    trace = trace_start()

    # 1. A workspace row into Pinned tiles (between the two tiles).
    alpha, pinned = rows().get("Alpha"), section_items("sec_pinned")
    if opts.stress:
        # The first workspace row under Pinned (Alpha is ~1000 rows down; see the setup note above).
        alpha = next((r for r in window().get("rows", []) if r.get("in_list") and str(r.get("key", "")).startswith("workspace")
                      and r.get("window_frame") and 0 <= r["window_frame"]["y"] < 760), None)
        print("scenario 1 source:", (alpha or {}).get("title"), (alpha or {}).get("window_frame"), flush=True)
    if "1" in WANTED and alpha and alpha.get("window_frame") and len(pinned) >= 2 and pinned[0].get("window_frame"):
        start, first = center(alpha["window_frame"]), pinned[0]["window_frame"]
        record("1-row-into-pinned", [start, (start[0], start[1] - 30), (first["x"] + first["width"] * 0.85, first["y"] + first["height"] / 2)],
               {f"workspace({row_id(alpha)})"})
    # 2. A tile back into the list (between Delta and Echo).
    pinned, delta, echo = section_items("sec_pinned"), rows().get("Delta"), rows().get("Echo")
    if "2" in WANTED and pinned and delta and echo:
        tile = pinned[0]
        to = (center(delta["window_frame"])[0], (delta["window_frame"]["y"] + delta["window_frame"]["height"] + echo["window_frame"]["y"]) / 2)
        record("2-tile-into-list", [center(tile["window_frame"]), to], {f"item:{tile.get('id')}"})
    # 3. A group into Pinned.
    if "3" in WANTED:
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
    def on_screen(r):
        return bool(r.get("window_frame")) and 0 <= r["window_frame"]["y"] < 760
    # Only rows on screen (hitch11: the first in_list row sat at y -455, so the drag started above the window).
    listed = [r for r in window().get("rows", []) if r.get("title") and r.get("in_list") and on_screen(r)]
    if "4" in WANTED and listed:
        top = listed[0]
        bottom = max(r["window_frame"]["y"] + r["window_frame"]["height"] for r in listed)
        edge = min(bottom, 820 - (12 if opts.real_pointer else 30))  # no hold with cua-driver: end inside the autoscroll band
        record("4-autoscroll-across", [center(top["window_frame"]), (center(top["window_frame"])[0], edge - 4)], {str(top.get("key"))},
               hold=2.0, seconds=1.6)
    # 5. A refusal: a row dragged down three rows, Escape before the release: the gap closes, the card flies home.
    listed = [r for r in window().get("rows", []) if r.get("title") and r.get("in_list") and on_screen(r) and str(r.get("key", "")).startswith("workspace")]
    if "5" in WANTED and len(listed) >= 4:
        row, below = listed[0], listed[3]
        record("5-refusal-springs-back", [center(row["window_frame"]), (center(row["window_frame"])[0], center(below["window_frame"])[1])],
               {str(row.get("key"))}, dropped_key=str(row.get("key")), refused=True, seconds=1.6, escape_at=1.1)
finally:
    try:
        trace_stop(trace)
    except Exception as error:  # the checks and the app stop still run
        TRACE["error"] = repr(error)
    json.dump({"checks": CHECKS, "trace": TRACE, "real_pointer": opts.real_pointer, "stress": opts.stress}, open(os.path.join(opts.out, "CHECKS.json"), "w"), indent=1)
    subprocess.run([STOP], check=False)
sys.exit(0 if CHECKS and all(c["ok"] for c in CHECKS.values()) else 1)
