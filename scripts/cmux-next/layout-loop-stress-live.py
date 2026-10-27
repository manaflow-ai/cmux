#!/usr/bin/env python3
"""Layout loop and pane ring stress on a tagged cmux DEV (behavior proof).

Launches the tagged app (no activation, bounded window, isolated config),
then over its debug socket: opens a browser split (Chromium pages move the
overlay plane into the overlay panel), makes 20 splits, columns and rows
(LAYOUT_STRESS_SPLITS), toggles the sidebar (moves the layout root without
a layout of the root), drives the command palette over the many-pane
window (typing, scrolling, Actions menu, scope chips, close and reopen,
parent resizes under it, the palette shown again on app activation),
steps the window size 50 times and walks the interface scale across its
range (every scale step lays the palette out again, hidden or not;
cx-wcej). After every step it reads `debug.layers` and fails when:

- one view was laid out more than its window's LayoutPassGuard limit
  (16, lower in a window of few views) in one window layout (`layout_passes.max_in_one_turn`), or the guard caught a loop;
- a plane is out of sync with its home (`planes[].in_sync`: the plane's
  frame vs the root's rect in window coordinates; this is the ring offset
  an ancestor move caused), a ring is off its rounded content rect, or the
  window counted ring lag passes;
- no step ran with a plane in the overlay panel, or an action failed.

The app crashing (AppKit layout-pass exception) fails the run too.

The app launches and stops through bench_launch.BenchApp (the bench env, an
empty cmux.json, a fresh saved session for the tag, the tag's daemons ended
at the stop). The run is also written as cmux-perf-result/v1 in OUT_DIR
(story layout-loop-stress: `layout_loop.max_in_one_turn` per step and
`layout_loop.failures`; drag_layout_bench_report.py).

Usage: layout-loop-stress-live.py TAG APP OUT_DIR
       layout-loop-stress-live.py --app APP --tag TAG --out OUT_DIR   (the perf-lab story runner)
Exit 0 = all steps clean. Writes OUT_DIR/layout-loop-stress.json.
"""
import argparse, json, os, socket, subprocess, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # its siblings, also under `python3 -I`
import drag_layout_bench_report as report  # noqa: E402
from bench_launch import BenchApp, LaunchError  # noqa: E402
from new_tab_bench_report import record_all  # noqa: E402

SOCKET = None  # the launched app's control socket (main)
RESIZE_STEPS = 50
# Panes: SPLITS actions cycle newColumn, splitRight, splitDown (columns,
# splits and rows); LAYOUT_STRESS_SPLITS raises it for a many-pane run.
SPLITS = int(os.environ.get("LAYOUT_STRESS_SPLITS", "20"))
# Palette steps typed into the open palette (the nightly crash,
# CMUXTERM-MACOS-40Q3, was a layout loop in the palette panel).
PALETTE_QUERY = "google.c"
# Down past the floor, up past the ceiling, back down, then reset.
SCALE_WALK = (("appearance.uiScale.decrease", 4), ("appearance.uiScale.increase", 14),
              ("appearance.uiScale.decrease", 14), ("appearance.uiScale.reset", 1))
LAST_PASSES = {}


def parse(argv=None):
    parser = argparse.ArgumentParser(usage="%(prog)s TAG APP OUT_DIR | --app APP [--tag TAG] --out OUT_DIR")
    parser.add_argument("positional", nargs="*", metavar="TAG APP OUT_DIR", help="the older positional form")
    parser.add_argument("--app", help="the tagged app bundle")
    parser.add_argument("--tag")  # the story runner passes it; the bundle carries the tag
    parser.add_argument("--out")
    parser.add_argument("--build-config", choices=["bench", "bench-checks", "release", "debug"],
                        help="result-v1 build config of a bench-hooks bundle that does not stamp it (BenchApp.record)")
    opts = parser.parse_args(argv)
    if opts.positional:
        if len(opts.positional) != 3 or opts.app or opts.out:
            parser.error("give TAG APP OUT_DIR, or --app and --out")
        opts.tag, opts.app, opts.out = opts.positional
    if not opts.app or not opts.out:
        parser.error("name the app and the output folder")
    return opts


def app_args(words):
    """LAYOUT_STRESS_APP_ARGS: `-Key Value` launch arguments for this process only (for example
    "-AppleShowScrollBars Always": legacy scrollers, as with a mouse), passed through BenchApp(args=...)."""
    if len(words) % 2 or not all(w.startswith("-") for w in words[::2]):
        sys.exit("LAYOUT_STRESS_APP_ARGS is `-Key Value` pairs, got %r" % " ".join(words))
    return words


def rpc(method, params=None, timeout=30):
    try:
        c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        c.settimeout(timeout)
        c.connect(SOCKET)
        c.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = c.recv(1 << 20)
            if not chunk:
                break
            buf += chunk
        c.close()
        r = json.loads(buf)
        return r.get("result") if r.get("ok") else {"error": r.get("error")}
    except (OSError, ValueError) as e:
        return {"error": str(e)}


def check(step, app, results):
    """Reads debug.layers after a step; returns a list of failures."""
    if app.poll() is not None:
        return ["app exited %s during %s" % (app.returncode, step)]
    layers = rpc("debug.layers") or {}
    if "error" in layers:
        return ["debug.layers failed after %s: %s" % (step, layers["error"])]
    failures = []
    passes = layers.get("layout_passes") or {}
    LAST_PASSES.clear()
    LAST_PASSES.update(passes)
    if not passes.get("installed"):
        failures.append("LayoutPassGuard not installed")
    # The limit of the window that had the busiest view (lower than
    # `bound` in a small window, LayoutPassGuard.limit(viewCount:)).
    bound = passes.get("max_window_limit") or passes.get("bound", 16)
    worst = passes.get("max_in_one_turn", 0)
    if worst > bound:
        failures.append("%s: a %s in %s was laid out %s times in one window layout (window limit %s)" % (
            step, passes.get("max_view_class"), passes.get("max_window_class"), worst, bound))
    for loop in passes.get("loops") or []:
        failures.append("%s: layout loop in %s (%s)" % (step, loop.get("view_class"), " < ".join(loop.get("ancestry") or [])))
    rings = 0
    for window in layers.get("windows") or []:
        if (window.get("ring_lag_passes") or 0) > 0:
            failures.append("%s: ring lag passes %s (%s)" % (step, window.get("ring_lag_passes"), window.get("last_ring_lag")))
        for plane in window.get("planes") or []:
            if not plane.get("in_sync"):
                failures.append("%s: plane (%s) out of sync with its home" % (step, plane.get("host")))
            for ring in plane.get("rings") or []:
                rings += 1
                if not ring.get("ring_in_sync"):
                    failures.append("%s: pane %s ring %s != content %s (plane in %s)" % (
                        step, ring.get("pane"), ring.get("ring_in_window"), ring.get("content_in_window"), plane.get("host")))
    results.append({"step": step, "max_in_one_turn": worst, "max_view_class": passes.get("max_view_class"),
                    "max_window_class": passes.get("max_window_class"), "rings": rings, "failures": failures,
                    "placement": [p.get("host") for w in layers.get("windows") or [] for p in w.get("planes") or []]})
    return failures


def key(name, modifiers=None):
    """One key-down into the open palette panel."""
    return rpc("debug.key", {"key": name, "modifiers": modifiers or [], "target": "palette"}, timeout=10)


def palette_phase(app, results):
    """Opens the palette over the many-pane window and drives every part
    of its surface that lays out: typing (rows reload), deleting, moving
    the selection past the visible rows (scroll), the Actions menu, scope
    prefixes (chips, breadcrumb), Tab drill, close and reopen during the
    close fade, other scopes, the parent window resizing under the open
    palette, and the sidebar toggling under it. Checks debug.layers after
    every step."""
    failures = []

    def step(label, reply=None):
        error = reply.get("error") if isinstance(reply, dict) else None
        if error and not (isinstance(error, dict) and error.get("code") == "unavailable"):
            failures.append("palette %s failed: %s" % (label, json.dumps(reply)[:200]))
        failures.extend(check("palette " + label, app, results))
        return app.poll() is None

    def open_palette(scope=None, query=""):
        args = {"query": query}
        if scope:
            args["scope"] = scope
        return rpc("action.run", {"action": "palette.open", "args": args, "focus": True}, timeout=20)

    if not step("open", open_palette()):
        return failures
    for ch in PALETTE_QUERY:
        if not step("type %r" % ch, key(ch)):
            return failures
    for _ in PALETTE_QUERY:
        if not step("delete", key("delete")):
            return failures
    for name in ["down"] * 14 + ["pagedown", "pagedown", "end", "home", "up"]:
        if not step(name, key(name)):
            return failures
    if not step("actions menu", key("k", ["command"])) or not step("actions menu down", key("down")):
        return failures
    if not step("actions menu close", key("k", ["command"])):
        return failures
    for prefix in ["@", "?", ">"]:
        if not step("prefix %s" % prefix, key(prefix)) or not step("prefix %s type" % prefix, key("a")):
            return failures
        if not step("prefix %s delete" % prefix, key("delete")) or not step("prefix %s pop" % prefix, key("delete")):
            return failures
    if not step("tab drill", key("tab")) or not step("drill pop", key("delete")):
        return failures
    frame = rpc("debug.window_frame", {}) or {}
    base = frame.get("frame") if isinstance(frame.get("frame"), list) else [40, 40, 1400, 900]
    x, y, w, h = [float(v) for v in base]
    for i in range(8):
        target = [x + (i % 3) * 20, y, max(800, w - 60 * (i % 4)), max(560, h - 40 * (i % 3))]
        if not step("parent resize %d %s" % (i, target), rpc("debug.window_frame", {"frame": target})):
            return failures
    rpc("debug.window_frame", {"frame": [x, y, w, h]})
    if not step("sidebar under palette", rpc("action.run", {"id": "toggleSidebar"})):
        return failures
    if not step("sidebar back", rpc("action.run", {"id": "toggleSidebar"})):
        return failures
    for i in range(6):
        # Close, then reopen while the close fade still runs.
        if not step("close %d" % i, key("escape")) or not step("reopen %d" % i, open_palette(query="split" if i % 2 else "")):
            return failures
    for scope in ["tabs", "workspaces", "settings", "commands"]:
        if not step("scope %s" % scope, open_palette(scope=scope)):
            return failures
        if not step("scope %s type" % scope, key("e")) or not step("scope %s down" % scope, key("down")):
            return failures
    step("close", key("escape"))
    # The palette shown again when the app becomes active (hidesOnDeactivate;
    # the nightly crash came 37 s after the app became active). The app
    # never activates for real (no-activate run): debug.app_activation posts
    # the app's resign and become-active notifications and orders the
    # panel out and back in as AppKit does.
    for i in range(4):
        if not step("activation %d open" % i, open_palette(query="" if i % 2 == 0 else "new")):
            return failures
        if i == 2 and not step("activation %d down" % i, key("down")):
            return failures
        if not step("activation %d resign" % i, rpc("debug.app_activation", {"active": False})):
            return failures
        if i == 1:
            target = [x + 30, y, max(800, w - 120), max(560, h - 80)]
            if not step("activation %d resize while inactive" % i, rpc("debug.window_frame", {"frame": target})):
                return failures
        if not step("activation %d become active" % i, rpc("debug.app_activation", {"active": True})):
            return failures
        for name in ["down", "down", "up"]:
            if not step("activation %d %s" % (i, name), key(name)):
                return failures
        if not step("activation %d type" % i, key("s")) or not step("activation %d close" % i, key("escape")):
            return failures
        rpc("debug.window_frame", {"frame": [x, y, w, h]})
        # Closed palette: resign and become active again, then open.
        if not step("activation %d closed resign" % i, rpc("debug.app_activation", {"active": False})):
            return failures
        if not step("activation %d closed become active" % i, rpc("debug.app_activation", {"active": True})):
            return failures
    # End inactive, as the app really is: the focus state that observers
    # set from the synthetic notifications matches NSApp again.
    if not step("activation end resign", rpc("debug.app_activation", {"active": False})):
        return failures
    # The opaque material (Reduce Transparency) swaps the glass views.
    rpc("debug.reduce_transparency", {"enabled": True})
    if step("reduce transparency open", open_palette(query="new")):
        for name in ["down", "down"]:
            step("reduce transparency %s" % name, key(name))
        step("reduce transparency actions", key("k", ["command"]))
        step("reduce transparency close", key("escape"))
        step("reduce transparency close palette", key("escape"))
    rpc("debug.reduce_transparency", {"enabled": None})
    return failures


def stress(app, results):
    """The steps after launch (actions, palette, resizes, scale walk); returns the failures."""
    failures = []
    rpc("debug.layers", {"reset_layout_passes": True})
    failures += check("launch", app, results)
    steps = [("splitBrowserRight", "action")] + [
        (("newColumn" if i % 3 == 0 else "splitRight" if i % 3 == 1 else "splitDown"), "action") for i in range(SPLITS)]
    steps.insert(8, ("toggleSidebar", "action"))
    steps.insert(15, ("toggleSidebar", "action"))
    for name, _ in steps:
        reply = rpc("action.run", {"id": name})
        error = reply.get("error") if isinstance(reply, dict) else None
        # "unavailable" is the product's own refusal (no room to split):
        # a normal outcome at small pane sizes, not a fault.
        if error and not (isinstance(error, dict) and error.get("code") == "unavailable"):
            failures.append("action %s failed: %s" % (name, json.dumps(reply)[:200]))
        failures += check("action %s -> %s" % (name, json.dumps(reply)[:80]), app, results)
        if app.poll() is not None:
            break
    failures += palette_phase(app, results)
    frame = rpc("debug.window_frame", {}) or {}
    base = frame.get("frame") or [40, 40, 1400, 900]
    x, y, w, h = [float(v) for v in (base if isinstance(base, list) else [40, 40, 1400, 900])]
    for i in range(RESIZE_STEPS):
        if app.poll() is not None:
            break
        dw = (i % 10) * 37 - 160
        dh = ((i * 7) % 10) * 23 - 100
        target = [x, y, max(700, w + dw), max(500, h + dh)]
        rpc("debug.window_frame", {"frame": target})
        failures += check("resize %d %s" % (i, target), app, results)
        if i == 25:
            rpc("action.run", {"id": "toggleSidebar"})
            failures += check("toggleSidebar mid-resize", app, results)
    for action, count in SCALE_WALK:
        for i in range(count):
            if app.poll() is not None:
                break
            reply = rpc("action.run", {"id": action})
            error = reply.get("error") if isinstance(reply, dict) else None
            if error and not (isinstance(error, dict) and error.get("code") == "unavailable"):
                failures.append("action %s failed: %s" % (action, json.dumps(reply)[:200]))
            failures += check("%s %d" % (action, i + 1), app, results)
    return failures


def main(argv=None):
    global SOCKET
    opts = parse(argv)
    os.makedirs(opts.out, exist_ok=True)
    launcher = BenchApp(opts.app, out=opts.out, config={}, window=(40, 40, 1400, 900), screen="last",
                        build_config=opts.build_config,
                        args=app_args(os.environ.get("LAYOUT_STRESS_APP_ARGS", "").split()))
    tag = launcher.tag
    results, failures = [], []
    try:
        try:
            launcher.launch(timeout=180)  # ready once debug.windows lists a window
        except LaunchError as error:  # its reason is printed; the run is a failure with a report
            failures.append("no window within 180 s: %s" % error)
        else:
            SOCKET = launcher.socket
            print("launched pid %d" % launcher.process.pid, flush=True)
            failures += stress(launcher.process, results)
            rpc("debug.window_snapshot", {"kind": "main", "path": os.path.join(opts.out, "after-stress.png")}, timeout=60)
    finally:
        launcher.stop()  # debug.quit end-sessions, then only this tag's processes and daemons (tag_teardown.py)

    # The browser split must have moved a plane into the overlay panel (the
    # path the deferral and the ancestor-move resync change); a run that never
    # left the root proves nothing about it.
    # The guard counts inside -[NSWindow layoutIfNeeded]; a run that counted
    # nothing means that bracket never fired (the proof would be empty).
    if results and not LAST_PASSES.get("max_in_one_turn"):
        failures.append("the guard counted no layout inside a window layout (layoutIfNeeded bracket never fired)")
    if results and not any("overlay_panel" in r["placement"] for r in results):
        failures.append("no step ran with the plane in the overlay panel (browser page window never showed)")
    summary = {"tag": tag, "steps": len(results), "failures": failures,
               "max_in_one_turn": max([r["max_in_one_turn"] for r in results] or [0]),
               "rings_checked": sum(r["rings"] for r in results), "layout_passes": LAST_PASSES, "results": results}
    with open(os.path.join(opts.out, "layout-loop-stress.json"), "w") as f:
        json.dump(summary, f, indent=1)
    print("steps=%d rings_checked=%d max_in_one_turn=%d (%s in %s) failures=%d" % (
        summary["steps"], summary["rings_checked"], summary["max_in_one_turn"], LAST_PASSES.get("max_view_class"),
        LAST_PASSES.get("max_window_class"), len(failures)), flush=True)
    for entry in (LAST_PASSES.get("top_classes") or [])[:12]:
        print("passes %6d %s" % (entry.get("passes", 0), entry.get("view_class")), flush=True)
    for f in failures[:40]:
        print("FAIL " + f, flush=True)
    for key, where in record_all(launcher, report.layout_loop_series(results, failures)).items():
        if not where.startswith("not recorded"):
            print("result-v1 %s: %s" % (key, where), flush=True)
    return 0 if not failures and results else 1


if __name__ == "__main__":
    sys.exit(main())
