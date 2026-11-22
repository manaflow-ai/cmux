#!/usr/bin/env python3
"""Live check that every surface shows the one window background (Lawrence
R48, plans/cmux-next/windows.md "One backdrop rule"): terminal, new tab page,
agent chat, Settings, browser page, titlebar strip, sidebar and rail, at
window opacity 1.0, 0.8 and 0.5 with blur off and on.

The sidebar is compared too (R55: with no override it follows R48). The
override phase (Lawrence R55) sets one `appearance.surfaces.<surface>.color`
at a time and checks that the surface's region changes and every other
sampled region stays as it was. Launches the tagged app itself (no-activate, scratch cmux.json and an empty
Ghostty config), opens each surface as the user would (debug.key, origin
user), captures the composited window (debug.window_snapshot) and compares
pixels in blank regions of each surface with the titlebar strip of the same
capture. The app reads its own windows, so no Screen Recording grant is
needed; what is behind the window does not show in the capture (alpha only).
Kills the app it started at the end.

Usage: background-match-e2e.py --tag <tag> [--out DIR] [--tolerance 3] [--phases match,override]
Exit 1 when a surface differs from the strip by more than the tolerance
(per channel, 0-255, premultiplied RGBA), or an override does not change
its own surface alone.
"""
import argparse, glob, json, os, signal, socket, struct, subprocess, sys, tempfile, time, zlib

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS", "/tmp"))
parser.add_argument("--tolerance", type=int, default=3)
parser.add_argument("--opacities", default="1.0,0.8,0.5")
parser.add_argument("--blurs", default="0,20")
parser.add_argument("--phases", default="match,override")
parser.add_argument("--override-opacities", default="1.0,0.8")
opts = parser.parse_args()

APP = next(iter(sorted(glob.glob(os.path.expanduser(
    f"~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/cmux DEV {opts.tag}.app")))), None)
if not APP:
    sys.exit(f"no tagged app for {opts.tag}")
BINARY = os.path.join(APP, "Contents/MacOS/cmux DEV")
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
SCRATCH = tempfile.mkdtemp(prefix=f"bgmatch-{opts.tag}-")
CONFIG = os.path.join(SCRATCH, "cmux.json")
GHOSTTY = os.path.join(SCRATCH, "ghostty")
open(GHOSTTY, "w").write("")
WIDTH, HEIGHT = 1100, 720


def write_config(opacity, blur, surfaces=None):
    appearance = {"backgroundOpacity": opacity, "backgroundBlur": blur}
    if surfaces:
        appearance["surfaces"] = surfaces
    with open(CONFIG, "w") as f:
        json.dump({"appearance": appearance}, f)


def rpc(method, params=None):
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(30)
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


def wait(predicate, seconds, step=0.25):
    end = time.time() + seconds
    while time.time() < end:
        value = predicate()
        if value:
            return value
        time.sleep(step)
    return None


def read_png(path):
    """RGBA pixels of a non-interlaced 8-bit PNG (what CGImage writes)."""
    data = open(path, "rb").read()
    pos, chunks = 8, []
    width = height = color = 0
    while pos < len(data):
        length, kind = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + length]
        if kind == b"IHDR":
            width, height, depth, color = struct.unpack(">IIBB", body[:10])
            if depth != 8:
                raise ValueError(f"{path}: bit depth {depth}")
        elif kind == b"IDAT":
            chunks.append(body)
        pos += 12 + length
    channels = {6: 4, 2: 3}[color]
    raw = zlib.decompress(b"".join(chunks))
    stride = width * channels
    rows, prev = [], bytearray(stride)
    for y in range(height):
        kind = raw[y * (stride + 1)]
        line = bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for i in range(stride):
            a = line[i - channels] if i >= channels else 0
            b = prev[i]
            c = prev[i - channels] if i >= channels else 0
            if kind == 1:
                line[i] = (line[i] + a) & 255
            elif kind == 2:
                line[i] = (line[i] + b) & 255
            elif kind == 3:
                line[i] = (line[i] + (a + b) // 2) & 255
            elif kind == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        rows.append(bytes(line))
        prev = line
    return width, height, channels, rows


def sample(png, x, y):
    """Mean RGBA of a 5x5 point block around window point (x, y)."""
    width, height, channels, rows = png
    scale = width / WIDTH
    cx, cy = int(x * scale), int(y * scale)
    total = [0, 0, 0, 0]
    for dy in range(-2, 3):
        row = rows[min(max(cy + dy, 0), height - 1)]
        for dx in range(-2, 3):
            i = min(max(cx + dx, 0), width - 1) * channels
            px = list(row[i:i + channels]) + ([255] if channels == 3 else [])
            total = [t + p for t, p in zip(total, px)]
    return tuple(round(t / 25) for t in total)


# Blank points per surface, in window points from the top-left (window
# 1100x720, sidebar on). Each is a region the surface leaves empty. A
# "card" point may carry a subtle tint of the same token at the same
# opacity (Settings groups): its alpha stays within CARD_ALPHA of the strip
# and its color within CARD_TINT; every other point must equal the strip.
SURFACES = [
    # (name, keys that open it, {region: point}, cards)
    ("home", None, {"transcript": (1000, 600)}, {}),
    ("terminal", ("t", ["ctrl", "shift", "cmd"]), {"content": (900, 560)}, {}),
    ("newtabpage", ("l", ["cmd"]), {"content": (1050, 110)}, {}),
    ("agent", ("i", ["cmd", "shift"]), {"transcript": (800, 400), "session-list": (420, 450), "rail": (282, 400)}, {}),
    ("settings", (",", ["cmd"]), {"nav": (340, 690), "content": (447, 400)}, {"card": (930, 152)}),
    ("browser", ("l", ["cmd", "shift"]), {"page": (800, 500)}, {}),
]
CHROME = {"strip": (1060, 15), "sidebar": (150, 500), "rail": (24, 500)}
CARD_ALPHA, CARD_TINT = 10, 16
PHASES = set(opts.phases.split(","))

# Override phase (R55): per opened surface, the override keys whose region
# shows there, with that region's point. Sidebar and tab bar are checked
# over the terminal only. The docks need a docked column (not exercised).
OVERRIDE_COLOR = "#C83232"
COMMON = {"sidebar": (150, 500), "tabBar": (1060, 15)}
OVERRIDES = {
    "home": {"home": (1000, 600)},
    "terminal": {"terminal": (900, 560), "sidebar": COMMON["sidebar"], "tabBar": COMMON["tabBar"]},
    "newtabpage": {"newTabPage": (1050, 110)},
    "agent": {"agentPane": (800, 400)},
    "settings": {"settings": (447, 400)},
    "browser": {"browserChrome": (281, 45)},
}
CHANGED = 24


def snapshot_points(label, points):
    path = os.path.join(opts.out, f"ov-{label}.png")
    shot = rpc("debug.window_snapshot", {"path": path})
    if not isinstance(shot, dict) or "error" in shot:
        return None, shot
    png = read_png(path)
    return {region: sample(png, *point) for region, point in points.items()}, shot


def run_override_phase():
    for opacity in [float(v) for v in opts.override_opacities.split(",")]:
        for name, key, _points, _cards in SURFACES:
            cases = OVERRIDES.get(name, {})
            points = dict(COMMON, **cases)
            write_config(opacity, 0)
            time.sleep(1.5)
            if key:
                rpc("debug.key", {"key": key[0], "modifiers": key[1]})
                time.sleep(3.0)
            base, shot = snapshot_points(f"{opacity}-{name}-base", points)
            if base is None:
                failures.append(f"override {opacity} {name}: base snapshot failed {shot}")
                continue
            for surface, _point in cases.items():
                write_config(opacity, 0, {surface: {"color": OVERRIDE_COLOR}})
                time.sleep(1.5)
                now, shot = snapshot_points(f"{opacity}-{name}-{surface}", points)
                if now is None:
                    failures.append(f"override {opacity} {name}/{surface}: snapshot failed {shot}")
                    continue
                for region in points:
                    delta = max(abs(a - b) for a, b in zip(now[region], base[region]))
                    want_change = region == surface
                    good = delta >= CHANGED if want_change else delta <= opts.tolerance
                    report.append({"phase": "override", "opacity": opacity, "surface": name, "override": surface,
                                   "region": region, "px": now[region], "base": base[region], "ok": good})
                    print(f"{'ok' if good else 'WRONG'} override opacity={opacity} {name} set={surface} {region}: "
                          f"{now[region]} base {base[region]} ({'must change' if want_change else 'must stay'})", flush=True)
                    if not good:
                        failures.append(f"override {opacity} {name} set={surface}: {region} {now[region]} vs base {base[region]}")
            write_config(opacity, 0)
            time.sleep(1.0)
            if key:
                rpc("debug.key", {"key": "w", "modifiers": ["cmd"]})
                time.sleep(1.0)

app = None
failures, report = [], []
write_config(1.0, 0)
try:
    if os.path.exists(SOCKET):
        os.unlink(SOCKET)
    env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
           "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": CONFIG, "CMUX_NEXT_GHOSTTY_CONFIG": GHOSTTY,
           "CMUX_NEXT_TEST_WINDOW_FRAME": f"40,40,{WIDTH},{HEIGHT}"}
    log = open(os.path.join(SCRATCH, "app.log"), "a")
    app = subprocess.Popen([BINARY], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
    print(f"launched pid {app.pid}", flush=True)
    if not wait(lambda: os.path.exists(SOCKET) and (rpc("debug.surfaces") or {}).get("windows"), 90, 0.5):
        sys.exit("the tagged app did not come up")
    time.sleep(2)
    for opacity in ([float(v) for v in opts.opacities.split(",")] if "match" in PHASES else []):
        for blur in [int(v) for v in opts.blurs.split(",")]:
            write_config(opacity, blur)
            time.sleep(1.5)
            for name, key, points, cards in SURFACES:
                if key:
                    rpc("debug.key", {"key": key[0], "modifiers": key[1]})
                    time.sleep(3.0)
                path = os.path.join(opts.out, f"bg-{opacity}-{blur}-{name}.png")
                shot = rpc("debug.window_snapshot", {"path": path})
                if not isinstance(shot, dict) or "error" in shot:
                    failures.append(f"{opacity}/{blur} {name}: snapshot failed {shot}")
                    continue
                png = read_png(path)
                strip = sample(png, *CHROME["strip"])
                chrome = {region: sample(png, *point) for region, point in CHROME.items()}
                for region, point in list(points.items()) + [("sidebar", CHROME["sidebar"])] + list(cards.items()):
                    px = sample(png, *point)
                    card = region in cards
                    alpha_delta = abs(px[3] - strip[3])
                    if card:
                        # A tint: compare premultiplied, as it composites.
                        color_delta = max(abs(a * px[3] - b * strip[3]) / 255 for a, b in zip(px[:3], strip[:3]))
                    else:
                        color_delta = max(abs(a - b) for a, b in zip(px[:3], strip[:3]))
                    good = (alpha_delta <= CARD_ALPHA and color_delta <= CARD_TINT) if card \
                        else max(alpha_delta, color_delta) <= opts.tolerance
                    report.append({"opacity": opacity, "blur": blur, "surface": name, "region": region, "card": card,
                                   "px": px, "strip": strip, "chrome": chrome, "method": shot.get("method"), "ok": good})
                    print(f"{'ok' if good else 'DIFFERS'} opacity={opacity} blur={blur} {name}/{region}{' (card)' if card else ''}: "
                          f"{px} strip {strip} sidebar {chrome['sidebar']} rail {chrome['rail']}", flush=True)
                    if not good:
                        failures.append(f"{opacity}/{blur} {name}/{region} {px} != strip {strip}")
                if key:
                    rpc("debug.key", {"key": "w", "modifiers": ["cmd"]})
                    time.sleep(1.0)
    if "override" in PHASES:
        run_override_phase()
finally:
    if app and app.poll() is None:
        app.send_signal(signal.SIGKILL)
        print(f"killed {app.pid}", flush=True)
    with open(os.path.join(opts.out, "bg-report.json"), "w") as f:
        json.dump(report, f, indent=1)
print("RESULT", "all surfaces match" if not failures else f"{len(failures)} differ:\n  " + "\n  ".join(failures))
sys.exit(1 if failures else 0)
