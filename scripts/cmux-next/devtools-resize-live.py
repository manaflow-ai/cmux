#!/usr/bin/env python3
"""Live check: dragging the divider of docked Chrome DevTools resizes it, and the size stays
with the tab (cx-d0d.45, R118).

  scripts/cmux-next/devtools-resize-live.py --app APP|--tag <tag> [--out DIR] [--background]
    [--story devtools-resize-live]

Launches the tagged app through bench_launch.BenchApp (the bench env, an empty cmux.json, a fresh
saved session, the tag's daemons ended after), opens a Chromium tab on a local page and its DevTools
(docked) and drags the divider. By default the app may activate (still an isolated launch:
CMUX_NEXT_ISOLATED_LAUNCH) and the drag is a real mouse: cua-driver's, through the window server,
where the Chromium page and DevTools windows must leave the divider to cmux (after a click in
DevTools, as when using it). With --background the app is never
activated (CMUX_NEXT_NO_ACTIVATE), so its window is not key (a drag on a window behind another app's),
and the drag is delivered in the app (`debug.mouse`). Checks:

  1. the drag resizes DevTools by about the drag;
  2. a second tab's DevTools takes its own size and the first tab keeps its own;
  3. closing and reopening DevTools keeps the tab's size.

GUI host only (a capture mini). Exits 1 when a check fails. With --story (which needs --background, the
method its story measures) it also writes, as cmux-perf-result/v1 (resize_bench_report.py), how far each
drag's new size is from the drag and the failed checks.
"""
import argparse, base64, functools, http.server, json, os, struct, subprocess, sys, tempfile, threading, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # its siblings, also under `python3 -I`
from bench_launch import ISOLATED_LAUNCH_KEY, BenchApp, bundle_id  # noqa: E402
import resize_bench_report as results  # noqa: E402

CUA = os.path.expanduser("~/.local/bin/cua-driver")
DRAG = 120  # points
WINDOW = (40, 40, 1200, 800)
failures = []
drag_errors = []  # per drag: |new size - old size - drag| in points, for result-v1
# Set by main(): the options and the launched app (BenchApp).
opts = bench = None


def parse(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", default=os.environ.get("NX_APP"), help="the tagged app bundle (default $NX_APP)")
    parser.add_argument("--tag", help="find the app of this tag in DerivedData when --app is not given")
    parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or tempfile.mkdtemp(prefix="devtools-resize-"))
    parser.add_argument("--background", action="store_true", help="never activate the app; drag in the app")
    parser.add_argument("--story", help=f"write result-v1 under this story ({results.DEVTOOLS_STORY})")
    parser.add_argument("--build-config", choices=["bench", "bench-checks", "release", "debug"],
                        help="result-v1 build config of a bench-hooks bundle that does not stamp it (BenchApp.record)")
    parsed = parser.parse_args(argv)
    parsed.app = results.tagged_app(parsed.app, parsed.tag)
    if not parsed.app:
        parser.error("name the tagged app with --app (or $NX_APP), or a --tag a tagged reload built")
    problem = parsed.story and results.story_problem(parsed.story, "chromium", "light")
    if problem:
        parser.error(problem)
    if parsed.story and not parsed.background:
        parser.error(f"--story {parsed.story} measures the --background drag (debug.mouse); pass --background")
    if not parsed.background and not os.path.exists(CUA):
        parser.error(f"no {CUA}: run on a capture mini, or pass --background")
    return parsed


def launch_env(background):
    """BenchApp's `env`: --background keeps the bench env's CMUX_NEXT_NO_ACTIVATE=1; a real drag needs an app that
    may activate, still an isolated launch (bench_launch.shipping_env's pair): the test window frame and screen,
    no `cmux` shim pointer, no global hot keys, no relaunch at login, no browser import offer."""
    return None if background else {"CMUX_NEXT_NO_ACTIVATE": None, ISOLATED_LAUNCH_KEY: "1"}


def check(ok, what):
    print(("ok   " if ok else "FAIL ") + what, flush=True)
    if not ok:
        failures.append(what)


def rpc(method, params=None, timeout=30):
    return bench.rpc(method, params, timeout)


def quiet_wait(predicate, seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:  # bounded wait for the app's own state
        value = predicate()
        if value:
            return value
        time.sleep(0.25)
    return None


def wait_for(predicate, what, seconds=20):
    value = quiet_wait(predicate, seconds)
    check(bool(value), what)
    return value


def windows():
    report = rpc("debug.focus") or {}
    return report.get("windows") or [] if isinstance(report, dict) else []


def focused_pane(window):
    entry = next((w for w in windows() if w.get("id") == window), None)
    return ((entry or {}).get("model") or {}).get("pane")


def layout():
    report = rpc("debug.cef.devtools_layout") or {}
    return report if isinstance(report, dict) else {}


def docked():
    now = layout()
    return now if now.get("open") and now.get("grab") and now.get("devtools_frame") else None


def extent(now):
    """DevTools' size along its dock axis, in points."""
    frame = now["devtools_frame"]
    return frame[2] if now.get("dock") in ("left", "right") else frame[3]


def cua(tool, params):
    try:
        out = subprocess.run([CUA, "call", tool, json.dumps(params)], capture_output=True, text=True, timeout=60).stdout
        return json.loads(out)
    except (OSError, subprocess.TimeoutExpired, ValueError) as error:
        return {"error": str(error)}


def png_width(b64):
    data = base64.b64decode(b64[:200] + "=" * (-len(b64[:200]) % 4))
    return struct.unpack(">I", data[16:20])[0] if data[:8] == b"\x89PNG\r\n\x1a\n" else None


def target(now, grow):
    """The divider's grab center and where the drag ends (DevTools `grow` points larger), in
    window points from the top left."""
    x, y, w, h = now["grab"]
    start = (x + w / 2, y + h / 2)
    end = {"bottom": (start[0], start[1] - grow), "right": (start[0] - grow, start[1]),
           "left": (start[0] + grow, start[1])}[now["dock"]]
    return start, end


def real_drag(now, grow):
    """cua-driver's drag (window-local screenshot pixels)."""
    found = [w for w in (cua("list_windows", {"pid": bench.process.pid}).get("windows") or []) if w.get("title") == "cmux"]
    if not found:
        return print("cua-driver lists no cmux window", flush=True)
    window_id = found[0]["window_id"]
    state = cua("get_window_state", {"pid": bench.process.pid, "window_id": window_id, "include_accessibility_tree": False})
    width = png_width(state.get("screenshot_png_b64") or "")
    scale = (width / now["window_frame"][2]) if width else 1.0
    titlebar = now["window_frame"][3] - now["content_height"]
    (sx, sy), (ex, ey) = target(now, grow)
    params = {"pid": bench.process.pid, "window_id": window_id, "from_x": round(sx * scale), "from_y": round((sy + titlebar) * scale),
              "to_x": round(ex * scale), "to_y": round((ey + titlebar) * scale), "delivery_mode": "foreground"}
    # A click in DevTools first, as when using it: its window takes key from cmux's.
    tools = now["devtools_frame"]
    click = {"pid": bench.process.pid, "window_id": window_id, "x": round((tools[0] + tools[2] / 2) * scale),
             "y": round((tools[1] + tools[3] / 2 + titlebar) * scale), "delivery_mode": "foreground"}
    cua("click", click)
    time.sleep(1)
    print("after a click in DevTools: cmux window key", layout().get("window_key"), flush=True)
    print("cua drag", params, json.dumps(cua("drag", params))[:300], flush=True)


def synthesized_drag(now, grow, window):
    (sx, sy), (ex, ey) = target(now, grow)
    for action, extra in (("down", {"x": sx, "y": sy}), ("drag", {"x": sx, "y": sy, "to_x": ex, "to_y": ey, "press": False, "release": False}),
                          ("up", {"x": ex, "y": ey})):
        print("synthesized", action, rpc("debug.mouse", {"window": window, "action": action, **extra}), flush=True)


def serve():
    root = tempfile.mkdtemp(prefix="devtools-page-")
    with open(os.path.join(root, "index.html"), "w") as f:
        f.write("<!doctype html><title>devtools resize</title><h1>DevTools resize</h1>")
    handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=root)
    handler.log_message = lambda *args: None
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return f"http://127.0.0.1:{server.server_address[1]}/index.html"


def measure():
    """The three checks on the launched app (`check` records each failure)."""
    wait_for(lambda: "error" not in (rpc("debug.focus") or {"error": 1}), "app socket", 180)
    if not windows():
        rpc("action.run", {"action": "newWindow", "origin": "script"})
    window = (wait_for(lambda: windows(), "a window", 60) or [{}])[0].get("id")
    if not quiet_wait(lambda: focused_pane(window), 15):
        rpc("action.run", {"action": "newTab", "origin": "script", "focus": True})
    wait_for(lambda: focused_pane(window), "a focused pane", 60)
    url = serve()

    def open_tab():
        """A new Chromium tab with DevTools docked; its id and layout, or None."""
        reply = rpc("action.run", {"action": "openBrowser.chromium", "args": {"url": url}, "focus": True})
        tab = (reply.get("created") or [None])[0]
        wait_for(lambda: (rpc("browser.page.eval", {"script": "document.title", "tab": tab}) or {}).get("value") == "devtools resize",
                 "the page loads", 60)
        rpc("action.run", {"action": "toggleBrowserDeveloperTools", "origin": "script"})
        if not wait_for(docked, "DevTools opens docked", 30):
            return None, None
        time.sleep(2)  # live check: DevTools settles at its docked size
        return tab, layout()

    def drag(before, grow, what):
        """Drags the shown tab's divider; the layout after, or None when DevTools did not resize."""
        if opts.background:
            check(before.get("window_key") is False, "the window is not key")
            synthesized_drag(before, grow, window)
        else:
            real_drag(before, grow)
        after = quiet_wait(lambda: (lambda now: now if now.get("grab") and abs(extent(now) - extent(before)) >= abs(grow) / 2 else None)(layout()), 5)
        size = extent(after or layout())
        drag_errors.append(round(abs(size - extent(before) - grow), 1))
        check(abs(size - extent(before) - grow) <= 24, f"{what} resizes DevTools by about {grow} pt ({extent(before)} -> {size})")
        return after

    def fraction(now):
        return now["right_fraction" if now.get("dock") in ("left", "right") else "bottom_fraction"]

    # 1. A drag on the divider.
    first, before = open_tab()
    moved = before and drag(before, DRAG, "a drag on the divider" if opts.background else "a real drag on the divider")
    if moved:
        # 2. Sizes per tab.
        second, other = open_tab()
        if other:
            check(abs(extent(other) - extent(moved)) <= 2, f"a new tab's DevTools starts at the last size ({extent(other)})")
            resized = drag(other, -DRAG, "a drag in the second tab")
            kept = (rpc("debug.cef.devtools_layout", {"tab": first}) or {})
            check(resized and abs(fraction(kept) - fraction(moved)) < 0.005,
                  f"the first tab keeps its own size ({fraction(moved):.3f} -> {fraction(kept):.3f})")
            rpc("action.run", {"action": "closeTab", "origin": "script"})
            wait_for(lambda: (layout().get("grab") and layout()), "the first tab shows again", 20)
        # 3. The size stays with the tab when DevTools reopens.
        rpc("action.run", {"action": "toggleBrowserDeveloperTools", "origin": "script"})
        wait_for(lambda: not layout().get("open"), "DevTools closes", 20)
        rpc("action.run", {"action": "toggleBrowserDeveloperTools", "origin": "script"})
        if wait_for(docked, "DevTools reopens docked", 30):
            time.sleep(1)  # live check: the reopened DevTools lays out
            check(abs(extent(layout()) - extent(moved)) <= 2, f"reopened DevTools keeps its size ({extent(moved)} -> {extent(layout())})")


def main(argv=None):
    global opts, bench
    opts = parse(argv)
    os.makedirs(opts.out, exist_ok=True)
    # DevTools starts from the last size used (user defaults): start from the default.
    ident = bundle_id(opts.app)
    if ident:
        subprocess.run(["defaults", "delete", ident, "CmuxNextBrowser.devToolsLayout"], capture_output=True)
    bench = BenchApp(opts.app, out=opts.out, config={}, window=WINDOW, screen="last", log_name="app.log",
                     env=launch_env(opts.background), build_config=opts.build_config)
    try:
        bench.launch(timeout=180)  # ready once debug.windows lists a window
        print(f"app pid {bench.process.pid}, out {opts.out}", flush=True)
        measure()
    finally:
        bench.stop()
    print(f"{len(failures)} failure(s); artifacts in {opts.out}")
    problems = results.record(bench, results.devtools_resize_series(
        opts.story, "synthesized" if opts.background else "real", drag_errors, failures)) if opts.story else []
    for problem in problems:
        print(f"RESULT-V1 FAIL {problem}", flush=True)
    return 1 if failures or problems else 0


if __name__ == "__main__":
    sys.exit(main())
