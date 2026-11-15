#!/usr/bin/env python3
"""Behavior check: chrome text draws at a stock AppKit label's weight (cx-8w027.12).

ChromeLabel and ChromeTextLayer draw their glyphs once as a mask (GlyphMask) so their color
blends on the render server. Core Graphics darkens glyph stems by the ink's luminance, so a mask
drawn in the wrong ink is lighter or heavier than an NSTextField next to it (black ink: 13% light
on a dark theme). This launches the tagged app and asks `debug.text_weight` for the coverage of
both classes next to a stock NSTextField (same text, font, color; 4 inks x 3 fonts) in a dark
and a light theme, as the window server shows them. Each value must be within 1% of stock.

appearance.fontSmoothing (ProcessFontSmoothing): the app launches twice, with the default
("antialiased") and with "system". Both launches hold the 1% parity, and the stock label itself
must draw thinner under the default than under "system" (the AppleFontSmoothing default reached
AppKit before its first text draw), unless the Mac turned smoothing off for every app.

Usage (nx-remote --needs gui --app-from-fleet cmux --tag T --ref SHA):
  text-weight-e2e.py --app "$NX_APP" --tag "$NX_APP_TAG" --out "$NX_ARTIFACTS" [--tolerance 0.01]
Stop the app afterwards with "$NX_APP_STOP". Exit 1 on any failed check.
"""
import argparse, json, os, socket, subprocess, sys, tempfile, time

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


def launch(mode):
    """Starts the tagged app with appearance.fontSmoothing `mode` (None: unset); returns the process."""
    config, ghostty = os.path.join(SCRATCH, f"cmux-{mode}.json"), os.path.join(SCRATCH, "ghostty")
    open(config, "w").write(json.dumps({"appearance": {"fontSmoothing": mode}} if mode else {}))
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
    print(f"launched pid {app.pid} (fontSmoothing {mode or 'unset'})", flush=True)

    def answers():
        reply = rpc("debug.themes") if os.path.exists(SOCKET) else None
        return reply is not None and not (isinstance(reply, dict) and "error" in reply)

    if not wait(answers, 180):
        sys.exit("the tagged app did not come up")
    return app


def stop(app):
    app.terminate()
    try:
        app.wait(30)
    except subprocess.TimeoutExpired:
        app.kill()
        app.wait(10)


def weights(label):
    """debug.text_weight in both themes; checks the 1% parity; returns {theme: values}."""
    out = {}
    for theme, dark in (("dark", True), ("light", False)):
        values = rpc("debug.text_weight", {"dark": dark})
        report[f"{label}.{theme}"] = values
        if not isinstance(values, dict) or "error" in values or len(values) < 2:
            check(False, f"{label} {theme}: debug.text_weight answered ({values})")
            continue
        out[theme] = values
        print(f"{label} {theme}: backing scale {values.get('scale')}, smoothsStems {values.get('smoothsStems')}", flush=True)
        for key in sorted(k for k in values if k not in ("scale", "smoothsStems") and not k.startswith("stock.")):
            ratio = values[key]
            check(abs(ratio - 1) <= opts.tolerance, f"{label} {theme} {key}: {ratio * 100 - 100:+.2f}% vs stock NSTextField")
    return out


try:
    app = launch(None)
    try:
        thin = weights("antialiased")
        # ChromeLabel is its own view (cx-8w027.26): it must lay out, draw (cacheDisplay and layer
        # render, the drag image paths) and read to VoiceOver as the stock label it replaced.
        parity = rpc("debug.label_parity", {"dir": opts.out}, timeout=300)
        report["label_parity"] = parity
        if not isinstance(parity, dict) or "error" in parity:
            check(False, f"debug.label_parity answered ({parity})")
        else:
            mismatches = parity.get("mismatches", [])
            for line in mismatches:
                print("  mismatch:", line, flush=True)
            count = parity.get("mismatch_count", 1)
            check(parity.get("checked", 0) > 0 and count == 0,
                  f"label parity: {count} mismatch(es) in {parity.get('checked')} checks vs stock NSTextField")
        # The real chrome (sidebar rows, tab titles) for a look: text upright and in place.
        shot = rpc("debug.window_snapshot", {"path": os.path.join(opts.out, "window.png")})
        check(isinstance(shot, dict) and "error" not in shot, f"debug.window_snapshot wrote window.png ({shot})")
    finally:
        stop(app)
    app = launch("system")
    try:
        system = weights("system")
        shot = rpc("debug.window_snapshot", {"path": os.path.join(opts.out, "window-system.png")})
        check(isinstance(shot, dict) and "error" not in shot, f"debug.window_snapshot wrote window-system.png ({shot})")
    finally:
        stop(app)
    for theme in ("dark", "light"):
        if theme not in thin or theme not in system:
            continue
        check(thin[theme].get("smoothsStems") == 0, f"{theme}: the default (antialiased) launch draws without smoothing")
        if system[theme].get("smoothsStems") != 1:
            print(f"{theme}: this Mac turned font smoothing off for every app; system draws thin too", flush=True)
            continue
        keys = sorted(k for k in thin[theme] if k.startswith("stock."))
        a, b = sum(thin[theme][k] for k in keys), sum(system[theme][k] for k in keys)
        report[f"stock_ratio.{theme}"] = a / b if b else None
        check(b > 0 and a < b * 0.97, f"{theme}: stock NSTextField ink, antialiased over system: {a / b * 100 if b else 0:.1f}%")
finally:
    with open(os.path.join(opts.out, "text-weight.json"), "w") as f:
        json.dump({"failures": failures, **report}, f, indent=1)
    print(f"{len(failures)} failure(s)", flush=True)
sys.exit(1 if failures else 0)
