#!/usr/bin/env python3
"""Liquid Glass Parity: the web UI's glass laid over the native glass, pixel by pixel, in every scenario.

  scripts/cmux-next/glass-parity-shots.py --app APP --tag TAG --out DIR [--matrix full|quick] [--vdisplay VDISPLAY.app]
      [--only SUBSTRING]

GUI host only (cmux-lawrence-2); never on a laptop. Launches the tagged DEV or NIGHTLY app (no activation,
automation socket, isolated Chief) and opens the Liquid Glass Parity playground (`debug.glass_parity`): every
surface the web UI draws as glass (menu, popover, hover card, tooltip, dialog, toast, docked chrome glass) rendered natively, in a
see-through WebKit page and in a see-through Chromium page, ON TOP OF EACH OTHER at the same boxes over one
backdrop. For each scenario the App captures each renderer alone (`debug.window_snapshot`: the window
server's composite, no Screen Recording grant needed) in the same frame, and writes per surface:

  KIND-native-STEM.png, KIND-webkit-STEM.png, KIND-chromium-STEM.png   each renderer's crop
  KIND-ENGINE-onion-STEM.png    the web crop over the native one at half opacity (onion skin)
  KIND-ENGINE-diff-STEM.png     the per-pixel difference, x8 (black is equal, an error of 32 is white)
  window-STEM-RENDERER.png, window-STEM-ENGINE-onion.png, window-STEM-ENGINE-diff.png   the whole stage

STEM names the scenario: backdrop[-color|-oOPACITY][-sOFFSET]-mode-active|inactive[-hover|-pressed]-appearance[-rt][-ic]-Sx.

THE SCENARIO MATRIX IS THE REGRESSION GATE (SCENARIOS below): every host-mode cell (a surface in one engine in
one scenario) must match the native glass within GATE (mean and p99 of the per-pixel worst-channel error over
the whole surface box, text included). The script exits 1 when a cell is past it or a scenario could not be
measured, and writes results.json and summary.md (the matrix). `css` scenarios measure the page's own glass
without the App's (the path a web surface takes when no host glass is under it): reported, not gated.

1x needs a 1x screen: --vdisplay starts a 1x virtual display (scripts/ci/frame-pacing/vdisplay.m) for the run.
Reduce Transparency is the App's own override (`debug.reduce_transparency`). Increase Contrast has no override
the App could honour: the system's Liquid Glass and the pages' `prefers-contrast` read the Mac's setting, so an
`ic` scenario turns the Mac's setting on (`defaults write com.apple.universalaccess increaseContrast`, the test
Mac only), checks that the App sees it (`increase_contrast` in the playground's status), and puts it back after;
when the Mac refuses the write (the domain needs the runner's Full Disk Access) the scenario is skipped, with
the reason, and never passes.

The menu's row states (`row`: hover, pressed) draw the native row's highlight (PopupRowView's hover and pressed
fills) and the web menu's own highlighted row (ui.css, popupSurface.css) at the same box.

A backdrop that moves is measured frame by frame at fixed offsets (`offset`): each renderer is captured alone,
one after the other, so a capture mid-motion would compare two different frames of Liquid Glass's adaptive look.
"""
import argparse, json, os, plistlib, socket, subprocess, sys, tempfile, time

parser = argparse.ArgumentParser()
parser.add_argument("--app", required=True)
parser.add_argument("--tag", required=True)
parser.add_argument("--out", required=True)
parser.add_argument("--matrix", default="full", choices=["full", "quick"])
parser.add_argument("--vdisplay", default="")
parser.add_argument("--only", default="")
opts = parser.parse_args()
opts.out = os.path.abspath(os.path.expanduser(opts.out))
os.makedirs(opts.out, exist_ok=True)
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
SCRATCH = tempfile.mkdtemp(prefix=f"glass-parity-{opts.tag}-")

# The gate: per-pixel worst-channel error over a surface's box (8-bit steps), text included.
GATE = {"mean": 1.0, "p99": 8}

# One scenario: what the playground sets (backdrop, color, opacity, offset, active, mode) and what the App sets
# (reduce transparency). Appearances and scales multiply every scenario.
BASE = [
    {"backdrop": "plain"},
    {"backdrop": "color", "color": "2d6cdf"},
    {"backdrop": "color", "color": "f4f1ea"},
    {"backdrop": "wallpaper"},
    {"backdrop": "wallpaper", "offset": 13},              # the backdrop moved under the glass
    {"backdrop": "wallpaper", "offset": 57},
    {"backdrop": "terminal", "opacity": 1},               # an opaque terminal
    {"backdrop": "terminal", "opacity": 0.6},             # a see-through terminal over a custom background
    {"backdrop": "terminal", "opacity": 0.2},
    {"backdrop": "image"},                                # a background image (the Mac's desktop picture)
    {"backdrop": "wallpaper", "active": False},           # an inactive window
    {"backdrop": "plain", "rt": True},                    # Reduce Transparency
    {"backdrop": "wallpaper", "rt": True},
    {"backdrop": "plain", "row": "hover"},                # the menu's row under the pointer
    {"backdrop": "wallpaper", "row": "hover"},
    {"backdrop": "wallpaper", "row": "pressed"},
    {"backdrop": "plain", "ic": True},                    # Increase Contrast (the Mac's setting)
    {"backdrop": "wallpaper", "ic": True},
]
CSS = [{"backdrop": "plain", "mode": "css"}, {"backdrop": "wallpaper", "mode": "css"}]
QUICK = [{"backdrop": "plain"}, {"backdrop": "wallpaper"}, {"backdrop": "terminal", "opacity": 0.6}]


def scenarios():
    if opts.matrix == "quick":
        return [dict(s, mode="host") for s in QUICK]
    return [dict({"mode": "host"}, **s) for s in BASE] + CSS


UA_DOMAIN = "com.apple.universalaccess"


def read_increase_contrast():
    out = subprocess.run(["defaults", "read", UA_DOMAIN, "increaseContrast"], capture_output=True, text=True)
    return out.stdout.strip() == "1" if out.returncode == 0 else None


def set_increase_contrast(on):
    """Sets the Mac's Increase Contrast (the test Mac only); answers the error text when the Mac refuses it."""
    out = subprocess.run(["defaults", "write", UA_DOMAIN, "increaseContrast", "-bool", "true" if on else "false"],
                         capture_output=True, text=True)
    if out.returncode != 0:
        return (out.stderr or out.stdout).strip() or f"defaults exited {out.returncode}"
    subprocess.run(["notifyutil", "-p", "com.apple.accessibility.cache.enhance.background.contrast"], capture_output=True)
    return None


IC_BEFORE = read_increase_contrast()
ic_refused = None


def rpc(method, params=None, timeout=180):
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


def passes(diff):
    return diff is not None and diff.get("mean", 1e9) <= GATE["mean"] and diff.get("p99", 1e9) <= GATE["p99"]


display = None
if opts.vdisplay:
    out_path = os.path.join(opts.out, "vdisplay.out")
    display = subprocess.Popen([os.path.join(opts.vdisplay, "Contents/MacOS/VDisplay"), "60", "7200", "", "1920x1200"],
                               stdout=open(out_path, "w"), stderr=subprocess.STDOUT)
    wait(lambda: open(out_path).read().startswith(("ready", "error")), 20)
    print("vdisplay:", open(out_path).read().strip(), flush=True)

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

results, rows, failures, skipped = [], [], [], []
try:
    if not wait(lambda: os.path.exists(SOCKET) and not (rpc("debug.window_frame") or {}).get("error"), 180):
        sys.exit("the tagged app did not come up")
    time.sleep(3)  # capture harness: the first window settles
    for appearance in ("light", "dark"):
        rpc("debug.appearance", {"mode": appearance})
        time.sleep(1.0)  # capture harness: the theme repaints
        for scale in (2.0, 1.0):
            for scenario in scenarios():
                label = json.dumps(dict(scenario, appearance=appearance, scale=scale))
                if opts.only and opts.only not in label:
                    continue
                want_ic = bool(scenario.get("ic"))
                if want_ic and ic_refused:
                    skipped.append(f"{label}: Increase Contrast not settable ({ic_refused})")
                    continue
                if want_ic or read_increase_contrast():
                    refused = set_increase_contrast(want_ic)
                    if refused and want_ic:
                        ic_refused = refused
                        skipped.append(f"{label}: Increase Contrast not settable ({refused})")
                        print("skip", skipped[-1], flush=True)
                        continue
                    time.sleep(1.0)  # capture harness: the system glass and the pages repaint for the setting
                rpc("debug.reduce_transparency", {"enabled": bool(scenario.get("rt"))})
                params = {k: v for k, v in scenario.items() if k not in ("rt", "ic")}
                params.setdefault("offset", 0)
                params.setdefault("active", True)
                params.setdefault("opacity", 1)
                params.setdefault("row", "rest")
                params.update({"scale": scale, "measure": True, "dir": opts.out})
                reply = rpc("debug.glass_parity", params) or {}
                status = reply.get("status") or {}
                if status.get("scale") is not None and abs(float(status["scale"]) - scale) > 0.01:
                    skipped.append(f"{label}: no {scale:g}x screen (window at {status['scale']}x)")
                    print("skip", skipped[-1], flush=True)
                    continue
                if want_ic and status.get("increase_contrast") is not True:
                    failures.append(f"{label}: the App does not see Increase Contrast after the Mac's setting changed")
                    print("error", failures[-1], flush=True)
                    continue
                results.append({"scenario": scenario, "appearance": appearance, "scale": scale, "reply": reply})
                if reply.get("error") or not reply.get("cells"):
                    failures.append(f"{label}: {reply.get('error') or 'no cells'}")
                    print("error", failures[-1], flush=True)
                    continue
                gated = scenario.get("mode", "host") == "host"
                worst = 0.0
                for kind, engines in sorted(reply["cells"].items()):
                    for engine in ("webkit", "chromium"):
                        diff = engines.get(engine)
                        if diff is None:
                            if gated:
                                failures.append(f"{reply['stem']} {kind} {engine}: not measured")
                            continue
                        full, material = diff.get("full") or {}, diff.get("material") or {}
                        ok = passes(full)
                        worst = max(worst, full.get("mean", 0))
                        rows.append({"stem": reply["stem"], "kind": kind, "engine": engine, "gated": gated, "pass": ok,
                                     "exact": full.get("max") == 0, "full": full, "material": material})
                        if gated and not ok:
                            failures.append(f"{reply['stem']} {kind} {engine}: mean {full.get('mean')} p99 {full.get('p99')}")
                print(f"{reply['stem']}: worst mean {worst:.3f} rt={status.get('reduce_transparency')} "
                      f"key={status.get('key')} host_glass={status.get('host_glass')}", flush=True)
finally:
    if IC_BEFORE is not None and read_increase_contrast() != IC_BEFORE:
        set_increase_contrast(IC_BEFORE)
    elif IC_BEFORE is None and read_increase_contrast():
        set_increase_contrast(False)
    rpc("debug.reduce_transparency", {"enabled": None})
    rpc("debug.glass_parity", {"close": True})
    rpc("debug.appearance", {"mode": "system"})
    rpc("debug.quit", {"fixture_quit": "end-sessions"})
    try:
        app.wait(timeout=20)
    except subprocess.TimeoutExpired:
        app.kill()  # the exact PID this script started
        app.wait()
    if display:
        display.terminate()  # the helper this script started
        display.wait()

with open(os.path.join(opts.out, "results.json"), "w") as f:
    json.dump({"gate": GATE, "rows": rows, "failures": failures, "skipped": skipped, "results": results}, f, indent=1)
gated = [r for r in rows if r["gated"]]
with open(os.path.join(opts.out, "summary.md"), "w") as f:
    f.write(f"Gate: mean <= {GATE['mean']}, p99 <= {GATE['p99']} (8-bit worst-channel error, text included). "
            f"{sum(r['pass'] for r in gated)}/{len(gated)} gated cells pass, {sum(r['exact'] for r in gated)} exact.\n\n")
    f.write("| scenario | surface | engine | pass | mean | p99 | max | material mean |\n|---|---|---|---|---|---|---|---|\n")
    for r in rows:
        f.write(f"| {r['stem']} | {r['kind']} | {r['engine']} | {'yes' if r['pass'] else ('NO' if r['gated'] else 'n/a (css)')} | "
                f"{r['full'].get('mean')} | {r['full'].get('p99')} | {r['full'].get('max')} | {r['material'].get('mean')} |\n")
    for title, items in (("Failures", failures), ("Skipped", skipped)):
        if items:
            f.write(f"\n{title}:\n" + "".join(f"- {line}\n" for line in items))
print(f"{len(gated)} gated cells, {len(failures)} failures, {len(skipped)} skipped; {opts.out}/summary.md", flush=True)
sys.exit(1 if failures or not gated else 0)
