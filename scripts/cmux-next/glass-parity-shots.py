#!/usr/bin/env python3
"""Liquid Glass Parity: the web UI's glass laid over the native glass, pixel by pixel, in every scenario.

  scripts/cmux-next/glass-parity-shots.py --app APP --tag TAG --out DIR [--matrix full|quick|none] [--vdisplay VDISPLAY.app]
      [--vdisplay-hidpi] [--hz HZ] [--activate] [--frames] [--only SUBSTRING]

GUI host only: a fleet Mac with a console session (scripts/measure/glass-parity.sh, `cmux-ci run --display`) or
cmux-lawrence-2; never a laptop. Launches the tagged DEV or NIGHTLY app (no activation,
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
one scenario) must match the native GLASS within GATE: mean and p99 of the per-pixel worst-channel error over the
surface's box with its margin (rim, shadow, the highlighted row), only its text box left out. The text is the
fixture's two lines, which AppKit, WebKit and Chromium each rasterize with their own text stack (Core Text in the
first two, Skia in Chromium; each snaps the baseline to the pixel grid its own way), so it never matches to the pixel
and is not glass: it is measured over the whole box too (TEXT_TOLERANCE, `text ok` in the summary), reported and
not gated. The script exits 1 when a cell is past it or a scenario could not be
measured, and writes results.json and summary.md (the matrix). `css` scenarios measure the page's own glass
without the App's (the path a web surface takes when no host glass is under it): reported, not gated.

1x needs a 1x screen and 2x a 2x one: --vdisplay starts a 1x virtual display (scripts/ci/frame-pacing/vdisplay.m) for
the run, --vdisplay-hidpi a 2x one instead (for a host whose own screen is 1x), at --hz.

ACTIVE AND INACTIVE ARE TWO REAL STATES: with --activate the app launches without the no-activate switch, an
`active` cell makes it the active app with the playground key, an `inactive` one gives activation away, and the
cell fails unless the playground's status says it is so (key true, or the app not active). Without --activate
(a person's Mac) macOS may refuse the activation and the active cells fail.

--frames measures frame time: the backdrop moves under the glass every frame (`animate`) with one renderer shown
at a time, in host mode (the App's glass under the page) and css mode (the page's own glass: the path before
host glass), and `debug.frames` gives each frame's interval and main-thread time; frames.json and the summary
hold p50, p95, p99 and missed frames per renderer and mode.
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
parser.add_argument("--matrix", default="full", choices=["full", "quick", "none"])
parser.add_argument("--vdisplay", default="")
parser.add_argument("--vdisplay-hidpi", nargs="?", const="hidpi", default="", choices=["hidpi", "hidpi-points"])
# The virtual display's size in points (the 900 x 600 test window fits any): a 2x display of 1920x1200 points
# is 3840x2400 pixels, over what some hosts' virtual displays take (scripts/measure/vdisplay-hidpi-probe.sh).
parser.add_argument("--vdisplay-size", default="1920x1200")
parser.add_argument("--hz", type=float, default=60)
parser.add_argument("--activate", action="store_true")
parser.add_argument("--frames", action="store_true")
parser.add_argument("--only", default="")
opts = parser.parse_args()
opts.out = os.path.abspath(os.path.expanduser(opts.out))
os.makedirs(opts.out, exist_ok=True)
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
SCRATCH = tempfile.mkdtemp(prefix=f"glass-parity-{opts.tag}-")

# The gate: per-pixel worst-channel error over a surface's box (8-bit steps), its text box left out.
GATE = {"mean": 0.25, "p99": 2}
# The whole box, text included: reported per cell, not gated (the text stacks differ; see above).
TEXT_TOLERANCE = {"mean": 1.0, "p99": 8}

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
    # The text axis (GlassParityPlayground.TextRendering): which rasterization pairing matches the text.
    {"backdrop": "plain", "text": "flat"},
    {"backdrop": "wallpaper", "text": "flat"},
    {"backdrop": "plain", "text": "smooth"},
    {"backdrop": "wallpaper", "text": "smooth"},
]
CSS = [{"backdrop": "plain", "mode": "css"}, {"backdrop": "wallpaper", "mode": "css"}]
QUICK = [{"backdrop": "plain"}, {"backdrop": "wallpaper"}, {"backdrop": "terminal", "opacity": 0.6}]


def scenarios():
    if opts.matrix == "none":
        return []
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


def passes(diff, gate=GATE):
    return bool(diff) and diff.get("mean", 1e9) <= gate["mean"] and diff.get("p99", 1e9) <= gate["p99"]


display = None
if opts.vdisplay:
    out_path = os.path.join(opts.out, "vdisplay.out")
    display = subprocess.Popen([os.path.join(opts.vdisplay, "Contents/MacOS/VDisplay"), f"{opts.hz:g}", "7200", "main",
                                opts.vdisplay_size] + ([opts.vdisplay_hidpi] if opts.vdisplay_hidpi else []),
                               stdout=open(out_path, "w"), stderr=subprocess.STDOUT)
    # A 2x display can take 20 s to list and 15 s more for its modes (vdisplay.m): wait for its "ready" line, not
    # for the first line, which is a diagnostic while it comes up (runs 4-10 printed an empty "vdisplay:").
    wait(lambda: any(line.startswith(("ready", "error")) for line in open(out_path).read().splitlines()),
         60 if opts.vdisplay_hidpi else 20)
    print("vdisplay:", open(out_path).read().strip(), flush=True)

with open(os.path.join(opts.app, "Contents/Info.plist"), "rb") as f:
    BINARY = os.path.join(opts.app, "Contents/MacOS", plistlib.load(f)["CFBundleExecutable"])
if os.path.exists(SOCKET):
    os.unlink(SOCKET)
config = os.path.join(SCRATCH, "cmux.json")
open(config, "w").write("{}")
ghostty = os.path.join(SCRATCH, "ghostty")
open(ghostty, "w").write("")
ENV = {
    "HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
    "CMUX_NEXT_CONFIG_FILE": config, "CMUX_NEXT_GHOSTTY_CONFIG": ghostty,
    "CMUX_NEXT_CHIEF_ISOLATED": "1", "CMUX_NEXT_CHIEF_HOME": os.path.join(SCRATCH, "chief"),
    "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,900,600", "ACPMUX_AGENT_LAUNCH": "deny", "NX_REMOTE": "1"}
if opts.activate:
    del ENV["CMUX_NEXT_NO_ACTIVATE"]
app = subprocess.Popen([BINARY], env=ENV,
    stdout=open(os.path.join(opts.out, "app.log"), "w"), stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
print(f"app pid {app.pid}, scratch {SCRATCH}, out {opts.out}", flush=True)

results, rows, failures, skipped, frames = [], [], [], [], []
app_inactive = True  # the app launches in the background until the first active cell opens it


def pct(values, q):
    values = sorted(values)
    return round(values[min(len(values) - 1, int(q * len(values)))], 2) if values else None


def measure_frames(appearance, scale):
    """The frame time of each renderer's glass over a moving backdrop, in host and css mode."""
    for mode in ("host", "css"):
        reply = rpc("debug.glass_parity", {"backdrop": "wallpaper", "mode": mode, "offset": 0, "active": True, "opacity": 1,
                                           "row": "rest", "scale": scale}) or {}
        if abs(float(reply.get("scale") or 0) - scale) > 0.01:
            skipped.append(f"frames {mode} {appearance} {scale:g}x: no {scale:g}x screen")
            return
        for column in ("native", "webkit", "chromium"):
            rpc("debug.frames", {"action": "start"})
            moved = rpc("debug.glass_parity", {"animate": 4, "column": column}) or {}
            stats = rpc("debug.frames", {"action": "stop", "raw": True}) or {}
            intervals, busy = stats.get("intervals_ms") or [], stats.get("main_ms") or []
            refresh = stats.get("refresh_ms") or 0
            missed = sum(max(0, round(i / refresh) - 1) for i in intervals) if refresh else None
            row = {"appearance": appearance, "scale": scale, "mode": mode, "renderer": column, "refresh_ms": refresh,
                   "frames": len(intervals), "missed": missed, "interval_p50": pct(intervals, 0.5),
                   "interval_p95": pct(intervals, 0.95), "interval_p99": pct(intervals, 0.99),
                   "interval_max": round(max(intervals), 2) if intervals else None, "main_p50": pct(busy, 0.5),
                   "main_p95": pct(busy, 0.95), "main_max": round(max(busy), 2) if busy else None,
                   "error": moved.get("error") or stats.get("error"), "animated_ms": moved.get("animated_ms")}
            frames.append(row)
            print(f"frames {appearance} {scale:g}x {mode:<4} {column:<8} n={row['frames']} missed={missed} "
                  f"p50={row['interval_p50']} p99={row['interval_p99']} main_p95={row['main_p95']}", flush=True)
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
                params.setdefault("text", "standard")
                params.update({"scale": scale, "measure": True, "dir": opts.out})
                if opts.activate:
                    # Activation is the system's to give: an app started by a process that is no app (this harness) is
                    # never made active by its own request (fleet run b44f5987: every active cell came back with the app
                    # inactive). LaunchServices activates the running app at this bundle path, as a Dock click would,
                    # and the playground then makes its window key; an inactive cell gives activation to the Finder
                    # (it opens no window).
                    # Only when activation is elsewhere: reopening an active app lets its main window take key.
                    if not params["active"] or app_inactive:
                        subprocess.run(["open", "-a", opts.app if params["active"] else "Finder"], capture_output=True)
                    app_inactive = not params["active"]
                reply = rpc("debug.glass_parity", params) or {}
                status = reply.get("status") or {}
                if status.get("scale") is not None and abs(float(status["scale"]) - scale) > 0.01:
                    skipped.append(f"{label}: no {scale:g}x screen (window at {status['scale']}x)")
                    print("skip", skipped[-1], flush=True)
                    continue
                active = params["active"]
                # Active: the window key at every capture of the cell (the measure's snapshots say so per renderer).
                shots_key = [v.get("key_at_capture") for v in (reply.get("snapshots") or {}).values()]
                real = (status.get("key") is True and all(k is not False for k in shots_key)) if active \
                    else status.get("app_active") is False
                if opts.activate and not real:
                    failures.append(f"{label}: the window is not {'key' if active else 'inactive'} (key={status.get('key')}, "
                                    f"app_active={status.get('app_active')})")
                    print("error", failures[-1], flush=True)
                if want_ic and status.get("increase_contrast") is not True:
                    # `defaults write` lands in the preferences, but no supported call tells the running system it
                    # changed (System Settings does that through a private path): the App and its Liquid Glass keep
                    # the old setting. Skipped with the reason, never passed; later Increase Contrast cells too.
                    ic_refused = "the Mac's setting changed, but the running App did not see it (no supported way to apply it from a script)"
                    skipped.append(f"{label}: Increase Contrast not applied ({ic_refused})")
                    print("skip", skipped[-1], flush=True)
                    continue
                results.append({"scenario": scenario, "appearance": appearance, "scale": scale, "reply": reply})
                if reply.get("error") or not reply.get("cells"):
                    failures.append(f"{label}: {reply.get('error') or 'no cells'}")
                    print("error", failures[-1], flush=True)
                    continue
                # The Chromium column's capture is the window server's composite alone (`chromium_pages: false`): it
                # must hold the page's child window, else that column shows only the App's glass and would pass blank.
                shot = (reply.get("snapshots") or {}).get("chromium") or {}
                if shot and (shot.get("method") != "composited" or (shot.get("child_windows") or 0) < 1):
                    failures.append(f"{label}: the Chromium page is not in its capture (method {shot.get('method')}, "
                                    f"child windows {shot.get('child_windows')})")
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
                        ok = passes(material)
                        worst = max(worst, material.get("mean", 0))
                        rows.append({"stem": reply["stem"], "kind": kind, "engine": engine, "gated": gated, "pass": ok,
                                     "exact": material.get("max") == 0, "text_ok": passes(full, TEXT_TOLERANCE),
                                     "full": full, "material": material})
                        if gated and not ok:
                            failures.append(f"{reply['stem']} {kind} {engine}: glass mean {material.get('mean')} "
                                            f"p99 {material.get('p99')} max {material.get('max')}")
                        # WebKit text is gated on every text axis: the pages draw with the native text's smoothing
                        # (appearance.fontSmoothing `auto`, WebTheme.pageSmoothing; `flat` and `smooth` pin both
                        # sides), which run c2c44e1f measured exact (mean 0.005, p99 0). Chromium shapes with
                        # HarfBuzz and rasterizes with Skia (other subpixel glyph positions, about 16% less ink),
                        # so its text stays reported, not gated.
                        if gated and engine == "webkit" and scenario.get("text", "standard") in ("standard", "flat", "smooth") \
                                and not passes(full, TEXT_TOLERANCE):
                            failures.append(f"{reply['stem']} {kind} {engine}: text mean {full.get('mean')} "
                                            f"p99 {full.get('p99')} (same smoothing on both sides)")
                print(f"{reply['stem']}: worst glass mean {worst:.3f} rt={status.get('reduce_transparency')} "
                      f"key={status.get('key')} host_glass={status.get('host_glass')}", flush=True)
            if opts.frames:
                rpc("debug.reduce_transparency", {"enabled": False})
                measure_frames(appearance, scale)
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
    json.dump({"gate": GATE, "text_tolerance": TEXT_TOLERANCE, "rows": rows, "failures": failures, "skipped": skipped, "results": results, "frames": frames}, f, indent=1)
with open(os.path.join(opts.out, "frames.json"), "w") as f:
    json.dump(frames, f, indent=1)
gated = [r for r in rows if r["gated"]]
with open(os.path.join(opts.out, "summary.md"), "w") as f:
    f.write(f"Gate (glass: the box and its margin, text box left out): mean <= {GATE['mean']}, p99 <= {GATE['p99']} "
            f"(8-bit worst-channel error). {sum(r['pass'] for r in gated)}/{len(gated)} gated cells pass, "
            f"{sum(r['exact'] for r in gated)} exact (max 0). Text included (not gated; mean <= {TEXT_TOLERANCE['mean']}, "
            f"p99 <= {TEXT_TOLERANCE['p99']}): {sum(r['text_ok'] for r in gated)}/{len(gated)}.\n")
    # Text, per rasterization pairing and engine: the mean of the cells' with-text mean and p99.
    by = {}
    for r in gated:
        after = r["stem"].split("-text-")
        axis = after[1].split("-")[0] if len(after) > 1 else "standard"
        by.setdefault((axis, r["engine"]), []).append(r["full"])
    for (axis, engine), fulls in sorted(by.items()):
        mean = sum(full.get("mean") or 0 for full in fulls) / len(fulls)
        p99 = sum(full.get("p99") or 0 for full in fulls) / len(fulls)
        f.write(f"Text {axis} {engine}: {len(fulls)} cells, with-text mean {mean:.3f}, p99 {p99:.1f}.\n")
    f.write("\n")
    f.write("| scenario | surface | engine | glass pass | glass mean | glass p99 | glass max | text ok | with text mean | with text p99 |\n"
            "|---|---|---|---|---|---|---|---|---|---|\n")
    for r in rows:
        f.write(f"| {r['stem']} | {r['kind']} | {r['engine']} | {'yes' if r['pass'] else ('NO' if r['gated'] else 'n/a (css)')} | "
                f"{r['material'].get('mean')} | {r['material'].get('p99')} | {r['material'].get('max')} | "
                f"{'yes' if r['text_ok'] else 'no'} | {r['full'].get('mean')} | {r['full'].get('p99')} |\n")
    if frames:
        f.write("\nFrame time over a moving backdrop (ms; host: the App's glass under the page, css: the page's own glass):\n\n"
                "| appearance | scale | mode | renderer | frames | missed | interval p50 | p95 | p99 | max | main p95 |\n"
                "|---|---|---|---|---|---|---|---|---|---|---|\n")
        for r in frames:
            f.write(f"| {r['appearance']} | {r['scale']:g}x | {r['mode']} | {r['renderer']} | {r['frames']} | {r['missed']} | "
                    f"{r['interval_p50']} | {r['interval_p95']} | {r['interval_p99']} | {r['interval_max']} | {r['main_p95']} |\n")
    for title, items in (("Failures", failures), ("Skipped", skipped)):
        if items:
            f.write(f"\n{title}:\n" + "".join(f"- {line}\n" for line in items))
print(f"{len(gated)} gated cells, {len(failures)} failures, {len(skipped)} skipped; {opts.out}/summary.md", flush=True)
sys.exit(1 if failures or (not gated and opts.matrix != "none") else 0)
