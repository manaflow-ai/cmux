#!/usr/bin/env python3
"""Behavior check of appearance.colorTransition (cx-3rf4z, Lawrence 2026-10-15: "ensure when
changing themes and colors, like switching between workspaces with different colors/bgs, there is
always smooth animation (that can be configured, fully ... or even just instant").

Launches the tagged app itself (no activation, a scratch cmux.json, an empty Ghostty config, an
isolated Chief home; it never opens Home or the Chief pane) and gives two workspaces different
themes over the control socket (workspace.setTheme: Rose Pine and Catppuccin Mocha). Then
it switches between them by id (goToWorkspace) and samples the window backdrop
color the render server shows (debug.themes windows[].backdrop.sheet, the presentation value)
as fast as the socket answers:

  blend      400 ms linear in OKLab: several distinct colors in between, each sample nearer the target
             in OKLab than the last (within one 8-bit step), the last sample is the target exactly.
  retarget   B to A, then back to B after about 250 ms: the first sample after the reversal is
             near the last one before it (no jump to an end color), and it ends on B exactly.
  instant    enabled false: the first sample after the switch is already the target, no blend.
  series     three times: the shown workspace's theme changes dark -> light -> dark within 300 ms (Mocha, Latte, Mocha): the backdrop
             samples and the recorded window pixels (OUT/series-N/, read through sips) never jump.
  terminal   the shown terminal draws rows of palette red; its theme changes Mocha -> Latte -> Mocha
             within 300 ms. The recorded terminal pixels (OUT/terminal/) blend and never jump, the
             Ghostty frame counters (debug.surfaces render_counters) show blend frames and 0 cell
             rebuilds for the two color-only changes (the cells keep color references; only the
             color table moves), and no frame is drawn once the blend ended. Then a font size
             change rebuilds every row once (full_font; the preview switch and the restore that
             follow keep rows whose content is the same).
  record     (--record) one debug.window_record of a blend, frames under OUT/record/.
  glass      (--material glass) a see-through Liquid Glass window instead: three switches between
             a dark and a light workspace, each recorded (OUT/glass-N/). The old tint's overlay
             starts at the old tint, nearly opaque, and fades; the recorded pixels never jump (the
             first frames included); the glass ends on the new tint with no overlay. Only this
             phase runs.

Usage (nx-remote --needs gui --app-from-fleet cmux --tag T --ref SHA):
  color-transition-e2e.py --app "$NX_APP" --tag "$NX_APP_TAG" --out "$NX_ARTIFACTS" [--record]
Stop the app afterwards with "$NX_APP_STOP". Exit 1 on any failed check.
"""
import argparse, glob, json, os, socket, struct, subprocess, sys, tempfile, threading, time

parser = argparse.ArgumentParser()
parser.add_argument("--app", required=True)
parser.add_argument("--tag", required=True)
parser.add_argument("--out", required=True)
parser.add_argument("--record", action="store_true")
parser.add_argument("--material", choices=["opaque", "glass"], default="opaque")
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
SCRATCH = tempfile.mkdtemp(prefix=f"colortx-{opts.tag}-")
CONFIG = os.path.join(SCRATCH, "cmux.json")
GHOSTTY = os.path.join(SCRATCH, "ghostty")
failures, report = [], {}


def check(ok, what):
    print(("ok   " if ok else "FAIL ") + what, flush=True)
    if not ok:
        failures.append(what)


def config(**transition):
    look = {"backgroundOpacity": 0.8, "backgroundBlur": "glass"} if opts.material == "glass" else {"backgroundOpacity": 1}
    with open(CONFIG, "w") as f:
        json.dump({"appearance": {**look, "colorTransition": transition}}, f)


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
    except (OSError, ValueError) as error:
        return {"error": str(error)}
    return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}


def wait(predicate, seconds, step=0.25):
    end = time.time() + seconds
    while time.time() < end:  # bounded wait for the live app
        try:
            value = predicate()
        except Exception:  # the app may not answer yet
            value = None
        if value:
            return value
        time.sleep(step)
    return None


def action(name, args=None, target=None):
    params = {"action": name, "args": args or {}, "focus": True, "origin": "script"}
    if target:
        params["target"] = target
    reply = rpc("action.run", params)
    if isinstance(reply, dict) and reply.get("error"):
        print("action", name, "->", reply, flush=True)
    return reply


def fire(name, args=None, target=None):
    """Runs an action without waiting for its reply, so sampling starts at once."""
    thread = threading.Thread(target=action, args=(name, args, target), daemon=True)
    thread.start()
    return thread


def shown_workspace():
    return next((w for w in window().get("workspaces") or [] if w.get("shown")), {})


def themed(name):
    """Sets the shown workspace's theme and waits until debug.themes shows it there."""
    shown = shown_workspace().get("workspace")
    action("workspace.setTheme", {"theme": name}, target=f"workspace:{shown}" if shown else None)
    ok = wait(lambda: shown_workspace().get("effective_spec") == name, 10)
    with open(os.path.join(opts.out, f"themes-{name.replace(' ', '-')}.json"), "w") as f:
        json.dump(rpc("debug.themes"), f, indent=1)
    check(bool(ok), f"the shown workspace takes {name} ({shown_workspace().get('effective_spec')})")


def workspace_ids():
    snap = rpc("snapshot.get") or {}
    topology = snap.get("topology") or snap
    return [w.get("id") for w in topology.get("workspaces") or []]


def window():
    windows = (rpc("debug.themes") or {}).get("windows") or []
    return windows[0] if windows else {}


def sheet():
    return (window().get("backdrop") or {}).get("sheet") or ""


def backdrop():
    return window().get("backdrop") or {}


def jumps(directory, label, fx=0.12, fy=0.75, moved=0.1):
    """Checks the recorded pixels at (fx, fy) in `directory` (default a blank sidebar spot): per
    60 Hz frame no step is over a quarter of the whole change, the first moving one included.
    Returns the pixels."""
    pixels = frame_colors(directory, fx, fy)
    try:
        times = json.load(open(os.path.join(directory, "frames.json"))).get("times") or []
    except (OSError, ValueError):
        times = []
    if len(pixels) <= 10:
        check(False, f"{label} pixels: frames recorded ({len(pixels)})")
        return pixels
    gaps = [max((b - a) * 1000, 1000 / 60) for a, b in zip(times, times[1:])] if len(times) == len(pixels) else []
    steps = [distance(a, b) * ((1000 / 60) / gaps[i] if gaps else 1) for i, (a, b) in enumerate(zip(pixels, pixels[1:]))]
    total = max(distance(pixels[0], p) for p in pixels)
    first = next((x for x in steps if x > 0.002), 0)
    check(total > moved, f"{label} pixels: the window recolored on screen (moved {total:.3f})")
    check(first < 0.25 * total, f"{label} pixels: the first frames do not jump (first step {first:.3f} of {total:.3f})")
    check(max(steps) < 0.25 * total, f"{label} pixels: no frame jumps (largest step per 60 Hz frame {max(steps):.3f} of {total:.3f})")
    return pixels


def rgb(hexa):
    return tuple(int(hexa[i:i + 2], 16) / 255 for i in (1, 3, 5)) if len(hexa) >= 7 else None


def oklab(color):
    def lin(c):
        return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4
    r, g, b = (lin(c) for c in color)
    l = (0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b) ** (1 / 3)
    m = (0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b) ** (1 / 3)
    s = (0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b) ** (1 / 3)
    return (0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s,
            1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s,
            0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s)


def distance(a, b):
    """OKLab distance between two #RRGGBB colors."""
    return sum((x - y) ** 2 for x, y in zip(oklab(rgb(a)), oklab(rgb(b)))) ** 0.5


def bmp_pixel(path, fx, fy):
    """RGB hex of the pixel at fractions (fx, fy) of an uncompressed 24/32-bit BMP (what sips writes)."""
    data = open(path, "rb").read()
    offset = struct.unpack("<I", data[10:14])[0]
    width, height = struct.unpack("<ii", data[18:26])
    bpp = struct.unpack("<H", data[28:30])[0] // 8
    compression = struct.unpack("<I", data[30:34])[0]
    masks = struct.unpack("<III", data[54:66]) if compression == 3 else (0xFF0000, 0xFF00, 0xFF)
    stride = (width * bpp + 3) & ~3
    x, y = int(fx * width), int(fy * abs(height))
    row = (abs(height) - 1 - y) if height > 0 else y
    i = offset + row * stride + x * bpp
    if compression not in (0, 3) or bpp not in (3, 4):
        raise ValueError(f"{path}: BMP compression {compression}, {bpp * 8} bpp")
    word = int.from_bytes(data[i:i + bpp], "little")

    def channel(mask):
        shift = (mask & -mask).bit_length() - 1
        return (word & mask) >> shift if mask else 0
    return "#%02X%02X%02X" % tuple(channel(m) for m in masks)


def frame_colors(directory, fx, fy):
    """The color at (fx, fy) in every recorded frame, in order (sips converts each JPEG to BMP)."""
    out = []
    for jpg in sorted(glob.glob(os.path.join(directory, "frame-*.jpg"))):
        bmp = jpg[:-4] + ".bmp"
        done = subprocess.run(["sips", "-s", "format", "bmp", jpg, "--out", bmp], capture_output=True, text=True, timeout=30)
        if done.returncode != 0:
            print("sips:", (done.stdout + done.stderr).strip()[-200:], flush=True)
        if os.path.exists(bmp):
            out.append(bmp_pixel(bmp, fx, fy))
    return out


def sample(seconds, trigger, retrigger=None):
    """Runs `trigger`, then samples the sheet color for `seconds`; `retrigger` (delay, fn) runs once mid-way."""
    samples, start = [], time.monotonic()
    trigger()
    fired = retrigger is None
    while time.monotonic() - start < seconds:  # bounded sampling window
        if not fired and time.monotonic() - start >= retrigger[0]:
            samples.append((round(time.monotonic() - start, 4), "RETARGET"))
            retrigger[1]()
            fired = True
        samples.append((round(time.monotonic() - start, 4), sheet()))
    return samples


def colors(samples):
    return [c for _, c in samples if c and c != "RETARGET"]


def settled():
    """The sheet color once no blend runs (bounded)."""
    def at_rest():
        backdrop = window().get("backdrop") or {}
        return backdrop.get("sheet") if backdrop.get("blending") == "false" and backdrop.get("sheet") else None
    time.sleep(0.1)
    return wait(at_rest, 5, 0.05)


def terminal_surface():
    """The shown terminal's surface diagnostics (debug.surfaces): render_counters, window_fraction, grid."""
    for win in (rpc("debug.surfaces") or {}).get("windows") or []:
        for pane in win.get("panes") or []:
            surface = pane.get("surface") or {}
            if pane.get("visible") and surface.get("render_counters") and surface.get("window_fraction"):
                return surface
    return {}


def counters():
    return terminal_surface().get("render_counters") or {}


def settle(target):
    return wait(lambda: (settled() or "")[:7] == target[:7], 5, 0.05)


app = None
try:
    config(duration=400, curve="linear", colorSpace="oklab")
    # No cursor blink: the terminal phase checks that no frame is drawn once a blend ends.
    open(GHOSTTY, "w").write("cursor-style-blink = false\n")
    if os.path.exists(SOCKET):
        os.unlink(SOCKET)
    env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
           "CMUX_NEXT_CONFIG_FILE": CONFIG, "CMUX_NEXT_GHOSTTY_CONFIG": GHOSTTY, "CMUX_NEXT_CHIEF_ISOLATED": "1",
           "CMUX_NEXT_CHIEF_HOME": os.path.join(SCRATCH, "chief"), "CMUX_NEXT_TEST_WINDOW_FRAME": "60,60,980,720"}
    log = open(os.path.join(opts.out, "app.log"), "a")
    app = subprocess.Popen([os.path.join(opts.app, "Contents/MacOS/cmux DEV")], env=env, stdout=log, stderr=log,
                           stdin=subprocess.DEVNULL)
    print("launched pid", app.pid, flush=True)
    if not wait(lambda: os.path.exists(SOCKET) and workspace_ids(), 180, 0.5):
        sys.exit("the tagged app did not come up")
    if opts.material == "glass":
        check(wait(lambda: backdrop().get("glassTint"), 30) is not None, "debug.themes reports the Liquid Glass tint")
    else:
        check(wait(lambda: sheet(), 30) is not None, "debug.themes reports the window backdrop sheet")

    check(bool(wait(lambda: shown_workspace().get("workspace"), 30)), "a workspace shows")
    themed("Rose Pine")
    first_ws = shown_workspace().get("workspace")
    action("workspace.newAtBottom")
    check(bool(wait(lambda: shown_workspace().get("workspace") not in (None, first_ws), 30)), "a second workspace opens and shows")
    themed("Catppuccin Latte" if opts.material == "glass" else "Catppuccin Mocha")
    second_ws = shown_workspace().get("workspace")
    report["workspaces"] = [first_ws, second_ws]
    if opts.material == "glass":
        def glass_at_rest():
            b = backdrop()
            return b.get("glassTint") if b.get("blending") == "false" and b.get("glassTint") else None
        for run in range(3):
            action("goToWorkspace", {"workspace": first_ws})
            time.sleep(0.2)
            old = wait(glass_at_rest, 5, 0.05)
            run_dir = os.path.join(opts.out, f"glass-{run}")
            os.makedirs(run_dir, exist_ok=True)
            rpc("debug.window_record", {"dir": run_dir, "seconds": 1.0})
            time.sleep(0.15)
            samples, start = [], time.monotonic()
            fire("goToWorkspace", {"workspace": second_ws})
            while time.monotonic() - start < 0.8:  # bounded sampling window
                b = backdrop()
                samples.append((round(time.monotonic() - start, 4), b.get("glassTint"), b.get("glassOverlay"), b.get("glassOverlayOpacity")))
            time.sleep(0.4)  # the recording stops by itself
            new = wait(glass_at_rest, 5, 0.05)
            report[f"glass-{run}"] = {"old": old, "new": new, "samples": samples}
            check(bool(old and new) and old[:7] != new[:7], f"glass {run}: the switch changes the glass tint ({old} -> {new})")
            blending = [x for x in samples if x[2]]
            if blending and old:
                _, _, color, opacity = blending[0]
                check(distance(color, old) < 0.02, f"glass {run}: the overlay starts at the old tint ({color} vs {old})")
                check(float(opacity or 0) > 0.8, f"glass {run}: the overlay starts nearly opaque ({opacity})")
                values = [float(x[3] or 0) for x in blending]
                check(all(b <= a + 0.01 for a, b in zip(values, values[1:])), f"glass {run}: the overlay only fades ({values[:6]}...)")
            else:
                check(False, f"glass {run}: the old tint's overlay shows during the blend ({len(samples)} samples)")
            check(not (backdrop().get("glassOverlay")), f"glass {run}: no overlay once the blend ends")
            report[f"glass-{run}-pixels"] = jumps(run_dir, f"glass {run}")
        sys.exit(1 if failures else 0)
    time.sleep(1)
    dark = settled()
    action("goToWorkspace", {"workspace": first_ws})
    time.sleep(1)
    light = settled()
    report["light"], report["dark"] = light, dark
    # Two dark themes for the blend checks (the series phase below crosses light/dark).
    span = distance(light, dark) if light and dark else 0
    check(span > 0.02, f"the two workspaces have different backgrounds ({light} vs {dark}, OKLab distance {span:.3f})")

    # blend: first -> second workspace, 400 ms linear, OKLab.
    blend = sample(0.8, lambda: fire("goToWorkspace", {"workspace": second_ws}))
    report["blend"] = blend
    seen = colors(blend)
    while len(seen) > 1 and seen[0][:7] == light[:7] and seen[1][:7] == light[:7]:
        seen = seen[1:]  # the switch had not landed yet
    distinct = list(dict.fromkeys(c[:7] for c in seen))
    remaining = [distance(c, dark) for c in distinct]
    check(len(distinct) >= 4, f"the blend shows {len(distinct)} distinct colors between the two (want >= 4)")
    steps = [b - a for a, b in zip(remaining, remaining[1:])]
    check(all(s <= 0.004 for s in steps), f"every sample is nearer the target than the last (OKLab steps {[round(s, 4) for s in steps]})")
    check(bool(seen) and seen[-1][:7] == (dark or "")[:7], f"the blend ends on the dark background exactly ({seen[-1] if seen else None})")

    # retarget: dark -> light, back to dark after 250 ms (the switch itself lands after ~130 ms).
    settle(dark)
    retarget = sample(1.1, lambda: fire("goToWorkspace", {"workspace": first_ws}), (0.25, lambda: fire("goToWorkspace", {"workspace": second_ws})))
    report["retarget"] = retarget
    marker = next((i for i, (_, c) in enumerate(retarget) if c == "RETARGET"), None)
    before_turn = colors(retarget[:marker]) if marker is not None else []
    after_turn = colors(retarget[marker + 1:]) if marker is not None else []
    if before_turn and after_turn:
        jump = distance(after_turn[0], before_turn[-1])
        span = distance(light, dark)
        check(jump < 0.35 * span, f"the reversal continues from the color on screen (jump {jump:.3f} of span {span:.3f})")
        check(before_turn[-1][:7] not in (light[:7], dark[:7]), f"the reversal came mid-blend ({before_turn[-1]})")
    else:
        check(False, "samples on both sides of the reversal")
    check(bool(after_turn) and after_turn[-1][:7] == dark[:7], f"the retarget ends on the dark background ({after_turn[-1] if after_turn else None})")

    if opts.record:
        settle(dark)
        rec = os.path.join(opts.out, "record")
        os.makedirs(rec, exist_ok=True)
        rpc("debug.window_record", {"dir": rec, "seconds": 1.2})
        time.sleep(0.1)
        action("goToWorkspace", {"workspace": first_ws})
        time.sleep(1.4)  # the recording stops by itself after 1.2 s
        check(os.path.exists(os.path.join(rec, "frames.json")), "a frame recording of one blend is written")

    for run in range(3):  # an intermittent one-frame flash needs more than one try
        # theme series: the shown workspace's theme changes twice in quick succession (dark -> light,
        # then back to the dark one before the first blend ends). The backdrop and the recorded window
        # pixels both continue from the color on screen; neither jumps to an end color.
        action("goToWorkspace", {"workspace": second_ws})
        settle(dark)
        series_dir = os.path.join(opts.out, f"series-{run}")
        os.makedirs(series_dir, exist_ok=True)
        rpc("debug.window_record", {"dir": series_dir, "seconds": 1.5})
        time.sleep(0.15)
        on_second = f"workspace:{second_ws}"
        series = sample(1.2, lambda: fire("workspace.setTheme", {"theme": "Catppuccin Latte"}, on_second),
                        (0.3, lambda: fire("workspace.setTheme", {"theme": "Catppuccin Mocha"}, on_second)))
        report[f"series-{run}"] = series
        time.sleep(0.6)  # the recording stops by itself
        marker = next((i for i, (_, c) in enumerate(series) if c == "RETARGET"), None)
        before_turn = colors(series[:marker]) if marker is not None else []
        after_turn = colors(series[marker + 1:]) if marker is not None else []
        final = settled()
        if before_turn and after_turn and final:
            latte_span = max(distance(dark, c) for c in before_turn)
            jump = distance(after_turn[0], before_turn[-1])
            check(latte_span > 0.1, f"series {run}: the light theme was blending in (moved {latte_span:.3f} from the dark one)")
            check(jump < 0.1, f"series {run}: the second change continues from the backdrop on screen (jump {jump:.3f})")
            check(after_turn[-1][:7] == final[:7], f"series {run}: the backdrop ends on the last theme ({after_turn[-1]} vs {final})")
        else:
            check(False, f"series {run}: samples on both sides of the second change")
        pixels = frame_colors(series_dir, 0.12, 0.75)  # a blank spot low in the sidebar
        report[f"series-{run}-pixels"] = pixels
        try:
            times = json.load(open(os.path.join(series_dir, "frames.json"))).get("times") or []
        except (OSError, ValueError):
            times = []
        if len(pixels) > 10:
            # Each step per one 60 Hz frame: the recorder captures on the main thread, which a theme
            # change keeps busy, so one recorded step can span several display frames (a 40 ms gap is
            # 2.4 frames of smooth motion). A jump changes the color within one displayed frame.
            gaps = [max((b - a) * 1000, 1000 / 60) for a, b in zip(times, times[1:])] if len(times) == len(pixels) else []
            steps = [distance(a, b) * ((1000 / 60) / gaps[i] if gaps else 1) for i, (a, b) in enumerate(zip(pixels, pixels[1:]))]
            total = max(distance(pixels[0], p) for p in pixels)
            check(total > 0.1, f"series {run} pixels: the window recolored on screen (moved {total:.3f})")
            check(max(steps) < 0.25 * total, f"series {run} pixels: no frame jumps (largest step per 60 Hz frame {max(steps):.3f} of {total:.3f})")
        else:
            check(False, f"series {run} pixels: frames recorded ({len(pixels)})")

    # terminal: palette red rows (SGR 41, erased to the line end) in the shown terminal; a theme
    # series (Mocha -> Latte -> Mocha within 300 ms) blends that red on the GPU.
    action("goToWorkspace", {"workspace": second_ws})
    settle(dark)
    action("terminal.sendText", {"text": "clear; for i in 1 2 3 4 5 6 7 8 9 10; do printf '\\033[41m\\033[K\\n'; done; printf '\\033[0m'\r"})
    term = wait(lambda: terminal_surface() or None, 15) or {}
    check(bool(term), f"debug.surfaces reports the shown terminal's render counters ({term.get('render_counters')})")
    time.sleep(1.5)  # the output lands and the prompt redraws
    term = terminal_surface()
    fraction = term.get("window_fraction") or [0.3, 0.1, 0.6, 0.8]
    try:
        rows = int(str(term.get("grid") or "80x24").split("x")[1])
    except (IndexError, ValueError):
        rows = 24
    fx, fy = fraction[0] + fraction[2] * 0.5, fraction[1] + fraction[3] * (4.5 / max(rows, 10))
    report["terminal-point"] = [fx, fy, rows]
    term_dir = os.path.join(opts.out, "terminal")
    os.makedirs(term_dir, exist_ok=True)
    before = counters()
    rpc("debug.window_record", {"dir": term_dir, "seconds": 1.5})
    time.sleep(0.15)
    on_second = f"workspace:{second_ws}"
    fire("workspace.setTheme", {"theme": "Catppuccin Latte"}, on_second)
    time.sleep(0.3)
    fire("workspace.setTheme", {"theme": "Catppuccin Mocha"}, on_second)
    time.sleep(1.3)  # the recording stops by itself; the last blend (400 ms) has ended
    after = counters()
    time.sleep(0.5)
    idle = counters()
    report["terminal-counters"] = {"before": before, "after": after, "idle": idle}
    if before and after and idle:
        blend_frames = after["blend_frames"] - before["blend_frames"]
        rebuilds = after["cell_rebuilds"] - before["cell_rebuilds"]
        check(blend_frames >= 10, f"terminal: Ghostty drew the blend frame by frame ({blend_frames} blend frames)")
        full = {k: after.get(k, 0) - before.get(k, 0)
                for k in ("full_palette", "full_config", "full_font", "full_other", "full_swap", "full_resize")}
        updates = after.get("frame_updates", 0) - before.get("frame_updates", 0)
        report["terminal-rebuilds"] = {"cell_rebuilds": rebuilds, "frame_updates": updates, **full}
        check(rebuilds == 0 and not any(full.values()),
              f"terminal: two color-only theme changes rebuild no cells ({rebuilds} cell rebuilds, full {full}, "
              f"{updates} frame updates, {blend_frames} blend frames)")
        check(idle["frames"] - after["frames"] <= 1,
              f"terminal: no frame is drawn once the blend ended ({idle['frames'] - after['frames']} frames in 0.5 s)")
    else:
        check(False, "terminal: render counters before, after and at rest")
    pixels = jumps(term_dir, "terminal", fx, fy, moved=0.03)
    report["terminal-pixels"] = pixels

    def reddish(hexa):
        color = rgb(hexa or "")
        return bool(color) and color[0] - color[1] > 0.2
    check(bool(pixels) and reddish(pixels[0]) and reddish(pixels[-1]),
          f"terminal: the sampled spot is the red rows at both ends ({pixels[:1]} ... {pixels[-1:]})")

    # font: a font size change (terminal.increaseFontSize) still rebuilds the cells, once for the
    # new font grid.
    before = counters()
    fire("terminal.increaseFontSize")
    trace, start = [], time.monotonic()
    while time.monotonic() - start < 1.5:  # bounded sampling window
        t = terminal_surface()
        c = t.get("render_counters") or {}
        trace.append((round(time.monotonic() - start, 3), t.get("grid"), t.get("fit_grid"), t.get("drawn_grid"),
                      {k: c.get(k, 0) - before.get(k, 0) for k in c if k.startswith("full_") or k == "cell_rebuilds"}))
    report["font-trace"] = trace
    after = counters()
    action("terminal.decreaseFontSize")
    if before and after:
        delta = {k: after.get(k, 0) - before.get(k, 0) for k in after}
        report["font-rebuilds"] = delta
        fulls = sum(v for k, v in delta.items() if k.startswith("full_"))
        check(delta.get("full_font") == 1 and fulls == 1,
              f"font: a font size change rebuilds every row once, for the new font ({delta})")
    else:
        check(False, "font: render counters before and after")
    time.sleep(1.0)

    # instant: enabled false.
    config(enabled=False, duration=400, curve="linear")
    check(bool(wait(lambda: (window().get("backdrop") or {}).get("seconds") == "0.0", 10)), "instant: the app took enabled false")
    action("goToWorkspace", {"workspace": first_ws})
    check(bool(settle(light)), "instant: the light workspace shows before the switch")
    instant = sample(0.4, lambda: fire("goToWorkspace", {"workspace": second_ws}))
    report["instant"] = instant
    seen = [c[:7] for c in colors(instant)]
    between = [c for c in dict.fromkeys(seen) if c not in (light[:7], dark[:7])]
    check(bool(seen) and seen[-1] == dark[:7] and not between,
          f"instant: one step from the light to the dark background, nothing in between ({list(dict.fromkeys(seen))})")
finally:
    with open(os.path.join(opts.out, "color-transition.json"), "w") as f:
        json.dump({"failures": failures, **report}, f, indent=1)
    print(f"{len(failures)} failure(s)", flush=True)
sys.exit(1 if failures else 0)
