#!/usr/bin/env python3
"""Liquid Glass Parity shots: native glass vs the web UI's glass, pixel diffs, on a GUI fleet Mac.

  scripts/cmux-next/glass-parity-shots.py --app APP --tag TAG --out DIR [--scales 2,1] [--modes host,css]
      [--backdrops plain,wallpaper,terminal,terminal-translucent,image] [--appearances light,dark]

GUI host only (cmux-lawrence-2); never on a laptop. Launches the tagged DEV or NIGHTLY app (no activation,
automation socket, isolated Chief), opens the Liquid Glass Parity playground (`debug.glass_parity`) and, for
every appearance x backdrop x mode x scale, has the App capture its own window (`debug.window_snapshot`, the
window server's composite: no Screen Recording grant, so it works over SSH) and diff each web surface
(WebKit and Chromium columns) against its native neighbor. Writes into DIR:

  window-STEM.png           the whole playground window (STEM = backdrop-mode-appearance-Sx)
  KIND-COLUMN-STEM.png      one surface's cell (surface + 8pt margin) per column
  KIND-COLUMN-diff-STEM.png the per-pixel error heat map vs native (x8: error 32 is white)
  results.json              every reply
  summary.md                the table: material mean / p99 per surface, column, backdrop, appearance, scale

A scale with no screen at that backing scale is skipped (1x needs a 1x display: a virtual one, see
scripts/ci/frame-pacing/vdisplay.m). Exits 1 when a host-mode surface's material diff (text excluded) is past
the tolerance (GlassParityDiff.hostTolerance): the drift test.
"""
import argparse, json, os, plistlib, socket, subprocess, sys, tempfile, time

parser = argparse.ArgumentParser()
parser.add_argument("--app", required=True)
parser.add_argument("--tag", required=True)
parser.add_argument("--out", required=True)
parser.add_argument("--scales", default="2,1")
parser.add_argument("--modes", default="host,css")
parser.add_argument("--backdrops", default="plain,wallpaper,terminal,terminal-translucent,image")
parser.add_argument("--appearances", default="light,dark")
opts = parser.parse_args()
opts.out = os.path.abspath(os.path.expanduser(opts.out))
os.makedirs(opts.out, exist_ok=True)
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
SCRATCH = tempfile.mkdtemp(prefix=f"glass-parity-{opts.tag}-")


def rpc(method, params=None, timeout=90):
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


def wait(predicate, seconds):
    end = time.monotonic() + seconds
    while time.monotonic() < end:  # bounded wait for the live app's own state
        try:
            value = predicate()
        except Exception:  # the app may not answer yet
            value = None
        if value:
            return value
        time.sleep(0.25)
    return None


with open(os.path.join(opts.app, "Contents/Info.plist"), "rb") as f:
    BINARY = os.path.join(opts.app, "Contents/MacOS", plistlib.load(f)["CFBundleExecutable"])
if os.path.exists(SOCKET):
    os.unlink(SOCKET)
config = os.path.join(SCRATCH, "cmux.json")
open(config, "w").write("{}")
ghostty = os.path.join(SCRATCH, "ghostty")
open(ghostty, "w").write("")
app = subprocess.Popen([BINARY], env={
    "HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
    "CMUX_NEXT_CONFIG_FILE": config, "CMUX_NEXT_GHOSTTY_CONFIG": ghostty,
    "CMUX_NEXT_CHIEF_ISOLATED": "1", "CMUX_NEXT_CHIEF_HOME": os.path.join(SCRATCH, "chief"),
    "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,900,600", "ACPMUX_AGENT_LAUNCH": "deny", "NX_REMOTE": "1"},
    stdout=open(os.path.join(opts.out, "app.log"), "w"), stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
print(f"app pid {app.pid}, scratch {SCRATCH}, out {opts.out}", flush=True)

results, rows, failures = [], [], []
try:
    if not wait(lambda: os.path.exists(SOCKET) and not (rpc("debug.window_frame") or {}).get("error"), 180):
        sys.exit("the tagged app did not come up")
    time.sleep(3)  # capture harness: the first window settles
    for appearance in opts.appearances.split(","):
        rpc("debug.appearance", {"mode": appearance})
        time.sleep(1.0)  # capture harness: the theme repaints
        for scale in [float(s) for s in opts.scales.split(",")]:
            for backdrop in opts.backdrops.split(","):
                for mode in opts.modes.split(","):
                    reply = rpc("debug.glass_parity", {"backdrop": backdrop, "mode": mode, "scale": scale,
                                                       "measure": True, "dir": opts.out}) or {}
                    status = reply.get("status") or {}
                    got = status.get("scale")
                    if got is not None and abs(float(got) - scale) > 0.01:
                        print(f"skip {backdrop} {mode} {appearance} {scale}x: window is at {got}x", flush=True)
                        continue
                    results.append({"appearance": appearance, "scale": scale, "backdrop": backdrop, "mode": mode,
                                    "reply": reply})
                    if reply.get("error"):
                        print(f"error {backdrop} {mode} {appearance} {scale}x: {reply['error']}", flush=True)
                        failures.append(f"{backdrop}-{mode}-{appearance}-{scale}x: {reply['error']}")
                        continue
                    print(f"{reply.get('stem')}: worst material mean {reply.get('worst_material_mean')} "
                          f"within {reply.get('within_tolerance')} host_glass {status.get('host_glass')}", flush=True)
                    for kind, columns in (reply.get("cells") or {}).items():
                        for column, diff in columns.items():
                            material, full = diff.get("material") or {}, diff.get("full") or {}
                            rows.append((appearance, int(scale), backdrop, mode, kind, column, material.get("mean"),
                                         material.get("p99"), material.get("max"), full.get("mean")))
                    if mode == "host" and not reply.get("within_tolerance"):
                        failures.append(f"{reply.get('stem')}: host material past tolerance")
finally:
    rpc("debug.glass_parity", {"close": True})
    rpc("debug.appearance", {"mode": "system"})
    rpc("debug.quit", {"fixture_quit": "end-sessions"})
    try:
        app.wait(timeout=20)
    except subprocess.TimeoutExpired:
        app.kill()  # the exact PID this script started
        app.wait()

with open(os.path.join(opts.out, "results.json"), "w") as f:
    json.dump(results, f, indent=1)
with open(os.path.join(opts.out, "summary.md"), "w") as f:
    f.write("| appearance | scale | backdrop | mode | surface | column | material mean | p99 | max | full mean |\n")
    f.write("|---|---|---|---|---|---|---|---|---|---|\n")
    for row in rows:
        f.write("| " + " | ".join("" if v is None else (f"{v:.2f}" if isinstance(v, float) else str(v)) for v in row) + " |\n")
    if failures:
        f.write("\nPast tolerance:\n" + "".join(f"- {line}\n" for line in failures))
print(f"{len(rows)} diffs, {len(failures)} failures; {opts.out}/summary.md", flush=True)
sys.exit(1 if failures or not rows else 0)
