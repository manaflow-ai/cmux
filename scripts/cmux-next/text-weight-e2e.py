#!/usr/bin/env python3
"""Behavior check: chrome text draws at a stock AppKit label's weight (cx-8w027.12).

ChromeLabel and ChromeTextLayer draw their glyphs once as a mask (GlyphMask) so their color
blends on the render server. Core Graphics darkens glyph stems by the ink's luminance, so a mask
drawn in the wrong ink is lighter or heavier than an NSTextField next to it (black ink: 13% light
on a dark theme). This launches the tagged app and asks `debug.text_weight` for the coverage of
both classes next to a stock NSTextField (same text, font, color; 4 inks x 3 fonts) in a dark
and a light theme, as the window server shows them. Each value must be within 1% of stock.

Usage (nx-remote --needs gui --app-from-fleet cmux --tag T --ref SHA):
  text-weight-e2e.py --app "$NX_APP" --tag "$NX_APP_TAG" --out "$NX_ARTIFACTS" [--tolerance 0.01]
Stop the app afterwards with "$NX_APP_STOP". Exit 1 on any failed check.
"""
import argparse, json, os, re, socket, subprocess, sys, tempfile, time

parser = argparse.ArgumentParser()
parser.add_argument("--app", required=True)
parser.add_argument("--tag", required=True)
parser.add_argument("--out", required=True)
parser.add_argument("--tolerance", type=float, default=0.01)
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
SCRATCH = tempfile.mkdtemp(prefix=f"textweight-{opts.tag}-")
failures, report = [], {}


def check(ok, what):
    print(("ok   " if ok else "FAIL ") + what, flush=True)
    if not ok:
        failures.append(what)


def rpc(method, params=None, timeout=60):
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


def wait(predicate, seconds, step=0.5):
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


# The one ChromeLabel difference left, and only in some runs (cx-8w027.26.1): a wrapping label
# limited to 2 lines at a preferred width, 10.5 pt, measures 2 pt wider than a stock field
# (intrinsic, fitting, Auto Layout hug). Remove this when the bead is fixed.
KNOWN_PARITY_ROWS = 21
KNOWN_PARITY = re.compile(r"^(label|wrapping|font) 10\.5r t2 lines=2 lb=(-|0|5) pmlw=140 (intrinsic\.w|fitting\.w|auto220hug\.w): ")

try:
    config, ghostty = os.path.join(SCRATCH, "cmux.json"), os.path.join(SCRATCH, "ghostty")
    open(config, "w").write("{}")
    open(ghostty, "w").write("")
    if os.path.exists(SOCKET):
        os.unlink(SOCKET)
    env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
           "CMUX_NEXT_CONFIG_FILE": config, "CMUX_NEXT_GHOSTTY_CONFIG": ghostty, "CMUX_NEXT_CHIEF_ISOLATED": "1",
           "CMUX_NEXT_CHIEF_HOME": os.path.join(SCRATCH, "chief"), "CMUX_NEXT_TEST_WINDOW_FRAME": "460,60,900,640"}
    log = open(os.path.join(opts.out, "app.log"), "a")
    app = subprocess.Popen([os.path.join(opts.app, "Contents/MacOS/cmux DEV")], env=env, stdout=log, stderr=log,
                           stdin=subprocess.DEVNULL)
    print("launched pid", app.pid, flush=True)
    def answers():
        reply = rpc("debug.themes") if os.path.exists(SOCKET) else None
        return reply is not None and not (isinstance(reply, dict) and "error" in reply)

    if not wait(answers, 180):
        sys.exit("the tagged app did not come up")
    for theme, dark in (("dark", True), ("light", False)):
        values = rpc("debug.text_weight", {"dark": dark})
        report[theme] = values
        if not isinstance(values, dict) or "error" in values or len(values) < 2:
            check(False, f"{theme}: debug.text_weight answered ({values})")
            continue
        print(f"{theme}: backing scale {values.get('scale')}", flush=True)
        for key in sorted(k for k in values if k != "scale"):
            ratio = values[key]
            check(abs(ratio - 1) <= opts.tolerance, f"{theme} {key}: {ratio * 100 - 100:+.2f}% vs stock NSTextField")
    # ChromeLabel is its own view (cx-8w027.26): it must lay out, draw (cacheDisplay and layer
    # render, the drag image paths) and read to VoiceOver as the stock label it replaced.
    parity = rpc("debug.label_parity", {"dir": opts.out}, timeout=180)
    report["label_parity"] = parity
    if not isinstance(parity, dict) or "error" in parity:
        check(False, f"debug.label_parity answered ({parity})")
    else:
        mismatches = parity.get("mismatches", [])
        known = [m for m in mismatches if KNOWN_PARITY.match(m)]
        for line in mismatches:
            print("  known (cx-8w027.26.1):" if line in known else "  mismatch:", line, flush=True)
        # The known difference shows all its rows or none (a ratchet on its size).
        check(len(known) in (0, KNOWN_PARITY_ROWS), f"label parity: {len(known)} known row(s), expected 0 or {KNOWN_PARITY_ROWS} (cx-8w027.26.1)")
        unknown = parity.get("mismatch_count", 1) - len(known)
        check(parity.get("checked", 0) > 0 and unknown == 0 and len(mismatches) == parity.get("mismatch_count", -1),
              f"label parity: {unknown} mismatch(es) in {parity.get('checked')} checks vs stock NSTextField"
              f" ({len(known)} known, cx-8w027.26.1)")
    # The real chrome (sidebar rows, tab titles) for a look: text upright and in place.
    shot = rpc("debug.window_snapshot", {"path": os.path.join(opts.out, "window.png")})
    check(isinstance(shot, dict) and "error" not in shot, f"debug.window_snapshot wrote window.png ({shot})")
finally:
    with open(os.path.join(opts.out, "text-weight.json"), "w") as f:
        json.dump({"failures": failures, **report}, f, indent=1)
    print(f"{len(failures)} failure(s)", flush=True)
sys.exit(1 if failures else 0)
