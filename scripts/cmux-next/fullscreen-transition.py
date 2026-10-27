#!/usr/bin/env python3
"""Full screen enter/exit lag and layout, in a real window (fullscreen-lag).

Launches a tagged cmux-next app (scratch config, empty Ghostty config), builds a busy window (a workspace
with three terminals and a browser split, plus --parked more workspaces with two terminals each), then for
each trigger in --triggers (action: the Toggle Full Screen action; key: Ctrl-Cmd-F through the app's key
path; zoom: the green button's own click) enters and leaves full screen --rounds times and measures each
transition with `debug.window_transition` (notifications, resizes, layout passes and their main-thread ms,
terminal grid reports and daemon resizes), `debug.frames` (missed vsyncs) and `debug.hangs`:

  settle_ms      trigger -> the last resize or layout pass of the transition (the first settled frame)
  did_ms         trigger -> didEnter / didExit
  resizes        window resizes during the transition, and how many distinct sizes
  layout         outermost window layout passes, their total and longest main-thread ms
  grid_reports   terminal grid reports the views made; resizes_sent: grids sent to the daemon
  missed         display frames the main thread missed

Layout rows: after a round trip the top row (toolbar band, sidebar, main pane, the first tab of every strip)
is where it was before; in full screen and back, no strip's first tab sits under the traffic lights.
--spaces also switches Spaces (Ctrl-Right / Ctrl-Left through System Events) while in full screen.

The summary prints the median over rounds (perf_stats.pct). The app launches and stops through
bench_launch.BenchApp (the bench env, an empty cmux.json, a fresh saved session for the tag, the tag's daemons ended
at the stop). It may activate, as full screen needs, and stays an isolated launch (CMUX_NEXT_ISOLATED_LAUNCH=1: the
fixed test window frame, no `cmux` shim pointer, no global hot keys, no browser import offer; LaunchIsolation.swift). Every round and the failed rows are also written as
cmux-perf-result/v1 in --out (story fullscreen-transition: `fullscreen.<trigger>.<enter|exit>.<value>` and
`fullscreen.failed_rows`; drag_layout_bench_report.py). FULLSCREEN_KEEP=1 leaves the app running.

Usage: fullscreen-transition.py --tag <tag> --app PATH [--rounds 3] [--parked 10] [--triggers action,key,zoom]
       [--json PATH] [--out DIR] [--gate]
"""
import argparse, json, os, re, socket, subprocess, sys, tempfile, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # its siblings, also under `python3 -I`
import drag_layout_bench_report as results  # noqa: E402
from bench_launch import ISOLATED_LAUNCH_KEY, BenchApp, bundle_id  # noqa: E402
from new_tab_bench_report import record_all  # noqa: E402


def parse(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--tag")  # the story runner and fullscreen-transition.sh pass it; the bundle carries the tag
    parser.add_argument("--app", required=True)
    parser.add_argument("--rounds", type=int, default=3)
    parser.add_argument("--parked", type=int, default=10)
    parser.add_argument("--triggers", default="action,key,zoom")
    parser.add_argument("--spaces", action="store_true")
    parser.add_argument("--json")
    parser.add_argument("--out", default="/tmp")
    parser.add_argument("--gate", action="store_true", help="fail on the timing budget rows too, not only layout")
    parser.add_argument("--settle-budget-ms", type=float, default=150.0, help="settle_ms after didEnter/didExit")
    parser.add_argument("--story", default=results.FULLSCREEN_STORY, help="result-v1 story")
    parser.add_argument("--build-config", choices=["bench", "bench-checks", "release", "debug"],
                        help="result-v1 build config of a bench-hooks bundle that does not stamp it (BenchApp.record)")
    opts, _unknown = parser.parse_known_args(argv)
    return opts


# Set by main(): the options, the launched app (BenchApp), its tag, socket and CLI, and a scratch folder.
opts = LAUNCHER = TAG = SOCKET = CLI = SCRATCH = None
ROWS = []


def run(*args, timeout=30):
    env = {"HOME": os.environ["HOME"], "PATH": "/usr/bin:/bin", "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "CMUX_SOCKET_PATH": SOCKET, "CMUX_QUIET": "1", "CMUX_TAG": TAG,
           "CMUX_BUNDLE_ID": bundle_id(LAUNCHER.app), "CMUX_BUNDLED_CLI_PATH": CLI}
    return subprocess.run([CLI, *args], capture_output=True, text=True, timeout=timeout, env=env)


def rpc(method, params=None, timeout=30):
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
            conn.settimeout(timeout)
            conn.connect(SOCKET)
            conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
            buf = b""
            while not buf.endswith(b"\n"):
                chunk = conn.recv(1 << 20)
                if not chunk:
                    break
                buf += chunk
        reply = json.loads(buf)
        return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}
    except (OSError, ValueError) as error:
        return {"error": str(error)}


def action(name, args=None, timeout=60):
    return rpc("action.run", {"action": name, "args": args or {}, "focus": True, "origin": "user"}, timeout=timeout)


def wait(check, seconds, step=0.1):
    deadline = time.time() + seconds
    while time.time() < deadline:
        try:
            value = check()
        except Exception:  # the app may not answer yet
            value = None
        if value:
            return value
        time.sleep(step)  # test harness polling a live app
    return None


def row(check, expected, observed, ok):
    ROWS.append((check, expected, observed, ok))
    print(f"{'PASS' if ok else 'FAIL'} | {check} | {expected} | {observed}", flush=True)


def geometry():
    g = rpc("debug.window_transition", {"action": "geometry"})
    return g[0] if isinstance(g, list) and g else {}


def first_tabs():
    """The first tab's window frame of every strip, keyed by the strip's window frame (rounded)."""
    out = {}
    for strip in (rpc("debug.tab_drag") or {}).get("strips") or []:
        tabs = strip.get("tabs") or []
        if not tabs:
            continue
        f = tabs[0]["frame"]
        f = [f["x"], f["y"], f["width"], f["height"]] if isinstance(f, dict) else list(f)
        s = strip.get("frame") or f
        s = [s["x"], s["y"], s["width"], s["height"]] if isinstance(s, dict) else list(s)
        out[f"{round(s[0])},{round(s[1])}"] = [round(v, 1) for v in f]
    return out


def is_full():
    return geometry().get("full_screen") is True


def trigger(kind):
    if kind == "action":
        return action("toggleFullScreen")
    if kind == "key":
        return rpc("debug.key", {"key": "f", "modifiers": ["control", "command"]})
    if kind == "zoom":
        return rpc("debug.window_transition", {"action": "click_zoom"})
    raise SystemExit(f"unknown trigger {kind}")


def transition(kind, entering, label):
    rpc("debug.frames", {"action": "start"})
    rpc("debug.hangs", {"clear": True})
    rpc("debug.window_transition", {"action": "start"})
    t0 = time.time()
    reply = trigger(kind)
    done = "didEnter" if entering else "didExit"
    trace = wait(lambda: (lambda t: t if any(e.get("e") == done for e in t.get("events", [])) else None)(
        rpc("debug.window_transition")), 15)
    # Settled: no new resize or layout pass for 600 ms after the did notification.
    last, quiet_since = None, time.time()
    while time.time() - quiet_since < 0.6 and time.time() - t0 < 20:
        time.sleep(0.1)  # test harness polling a live app
        t = rpc("debug.window_transition") or {}
        n = len(t.get("events", []))
        if n != last:
            last, quiet_since = n, time.time()
    trace = rpc("debug.window_transition", {"action": "stop"}) or {}
    frames = rpc("debug.frames", {"action": "stop"}) or {}
    hangs = rpc("debug.hangs") or {}
    events = trace.get("events") or []
    did = next((e["t"] for e in events if e.get("e") == done), None)
    busy = [e for e in events if e.get("e") in ("resize", "layout")]
    settle = max((e["t"] + (e.get("ms") or 0) for e in busy), default=None)
    sizes = {(round(e["w"]), round(e["h"])) for e in events if e.get("e") == "resize"}
    hang_list = hangs.get("hangs") if isinstance(hangs, dict) else None
    result = {
        "trigger": kind, "entering": entering, "reply_error": (reply or {}).get("error") if isinstance(reply, dict) else None,
        "did_ms": did, "settle_ms": settle, "after_did_ms": round(settle - did, 1) if settle is not None and did is not None else None,
        "resizes": sum(1 for e in events if e.get("e") == "resize"), "sizes": len(sizes),
        "layout_passes": trace.get("layout_passes"), "layout_total_ms": trace.get("layout_total_ms"),
        "layout_max_ms": trace.get("layout_max_ms"), "root_layouts": trace.get("root_layouts"),
        "grid_reports": trace.get("terminal_grid_reports"), "resizes_sent": trace.get("terminal_resizes_sent"),
        "missed": frames.get("missed"), "frames_max_ms": frames.get("max_ms"),
        "hangs": len(hang_list) if isinstance(hang_list, list) else hangs.get("count"),
        "events": events,
    }
    print(f"  {label}: did {did} settle {settle} (+{result['after_did_ms']} after did) resizes {result['resizes']}/{len(sizes)} "
          f"layout {result['layout_passes']} passes {result['layout_total_ms']} ms (max {result['layout_max_ms']}) "
          f"roots {result['root_layouts']} grids {result['grid_reports']}/{result['resizes_sent']} missed {result['missed']} "
          f"hangs {result['hangs']}", flush=True)
    return result


def lights_clear(geo, tabs):
    lights = geo.get("lights")
    if not lights:
        return True, "no lights"
    lx, ly, lw, lh = lights
    bad = [t for t in tabs.values() if t[0] < lx + lw and t[0] + t[2] > lx and t[1] < ly + lh and t[1] + t[3] > ly]
    return not bad, f"lights {lights} tabs under them {bad}"


def setup():
    for _ in range(opts.parked):
        made = run("workspace", "create", "--name", "parked")
        ws = re.search(r"value\.workspace_id\s+(\S+)", made.stdout)
        if ws:
            run("workspace", ws.group(1), "focus")
            time.sleep(0.5)  # test harness: the workspace's first terminal
            action("splitRight")
            time.sleep(0.3)  # test harness: the split lands
    made = run("workspace", "create", "--name", "busy")
    ws = re.search(r"value\.workspace_id\s+(\S+)", made.stdout)
    if ws:
        run("workspace", ws.group(1), "focus")
    time.sleep(1.0)  # test harness: shell prompt
    action("splitRight")
    time.sleep(0.5)  # test harness: the split lands
    action("splitDown")
    time.sleep(0.5)  # test harness: the split lands
    page = os.path.join(SCRATCH, "page.html")
    open(page, "w").write("<!doctype html><body style='margin:0;background:#2980b9;color:white;font:40px -apple-system'>"
                          + "<p>full screen row</p>" * 60)
    action("openBrowser.webkit", {"url": "file://" + page}, timeout=120)
    time.sleep(3.0)  # test harness: the page paints


def spaces_round():
    """In full screen, switch to the Space on the left and back (System Events: needs Accessibility)."""
    script = 'tell application "System Events" to key code {} using control down'
    out = {}
    for name, code in (("left", 123), ("right", 124)):
        rpc("debug.frames", {"action": "start"})
        rpc("debug.window_transition", {"action": "start"})
        done = subprocess.run(["osascript", "-e", script.format(code)], capture_output=True, text=True, timeout=10)
        time.sleep(2.0)  # test harness: the Space slide runs ~0.5-1 s
        trace = rpc("debug.window_transition", {"action": "stop"}) or {}
        frames = rpc("debug.frames", {"action": "stop"}) or {}
        out[name] = {"osascript": done.returncode, "error": done.stderr.strip()[:200],
                     "spaces": sum(1 for e in trace.get("events", []) if e.get("e") == "space"),
                     "resizes": sum(1 for e in trace.get("events", []) if e.get("e") == "resize"),
                     "layout_passes": trace.get("layout_passes"), "layout_total_ms": trace.get("layout_total_ms"),
                     "grid_reports": trace.get("terminal_grid_reports"), "missed": frames.get("missed")}
        print(f"  space {name}: {out[name]}", flush=True)
    return out


def cleanup():
    """Leaves full screen, then stops the app and the tag's daemons (BenchApp.stop); FULLSCREEN_KEEP=1 keeps it."""
    global SOCKET
    if os.environ.get("FULLSCREEN_KEEP") or LAUNCHER is None or LAUNCHER.process is None:
        return
    SOCKET = LAUNCHER.socket  # the path launch() probed last, also when it raised
    try:
        if LAUNCHER.process.poll() is None and is_full():
            action("toggleFullScreen")
            time.sleep(2)  # test harness: leave full screen before quitting
    finally:
        LAUNCHER.stop()


def bench_app(app, out, build_config=None):
    """The app this bench launches: it may activate (no CMUX_NEXT_NO_ACTIVATE) and stays isolated."""
    return BenchApp(app, out=out, config={}, env={"CMUX_NEXT_NO_ACTIVATE": None, ISOLATED_LAUNCH_KEY: "1"},
                    window=(80, 80, 1400, 900), screen=None, build_config=build_config)


def measure(report):
    """Launches the app, builds the busy window and runs every trigger's rounds into `report`."""
    global SOCKET, CLI
    LAUNCHER.launch(timeout=120)  # ready once debug.windows lists a window; it may have moved to another candidate
    SOCKET, CLI = LAUNCHER.socket, LAUNCHER.cli
    print(f"launched pid {LAUNCHER.process.pid}", flush=True)
    time.sleep(5)  # test harness: launch work settles
    setup()
    before, tabs_before = geometry(), first_tabs()
    report["geometry"]["windowed"] = {"geo": before, "tabs": tabs_before}
    rpc("debug.window_snapshot", {"path": os.path.join(opts.out, "windowed.png")})
    ok, info = lights_clear(before, tabs_before)
    row("windowed: no tab under the traffic lights", "clear", info, ok)
    for kind in opts.triggers.split(","):
        for index in range(opts.rounds):
            enter = transition(kind, True, f"{kind} #{index} enter")
            report["transitions"].append(enter)
            row(f"{kind} #{index}: entered", "full screen", str(is_full()), is_full())
            full, tabs_full = geometry(), first_tabs()
            report["geometry"].setdefault(f"full-{kind}-{index}", {"geo": full, "tabs": tabs_full})
            if index == 0:
                rpc("debug.window_snapshot", {"path": os.path.join(opts.out, f"full-{kind}.png")})
            if opts.spaces and index == 0 and kind == opts.triggers.split(",")[0]:
                report["spaces"] = spaces_round()
            leave = transition(kind, False, f"{kind} #{index} exit")
            report["transitions"].append(leave)
            after, tabs_after = geometry(), first_tabs()
            if index == 0:
                rpc("debug.window_snapshot", {"path": os.path.join(opts.out, f"after-{kind}.png")})
            report["geometry"].setdefault(f"after-{kind}-{index}", {"geo": after, "tabs": tabs_after})
            row(f"{kind} #{index}: left", "windowed", str(not is_full()), not is_full())
            for key in ("frame", "toolbar_band", "sidebar", "main_pane", "lights"):
                row(f"{kind} #{index}: {key} back where it was", str(before.get(key)), str(after.get(key)),
                    before.get(key) == after.get(key))
            row(f"{kind} #{index}: first tabs back where they were", json.dumps(tabs_before), json.dumps(tabs_after),
                tabs_before == tabs_after)
            ok, info = lights_clear(after, tabs_after)
            row(f"{kind} #{index}: after, no tab under the traffic lights", "clear", info, ok)
            for t in (enter, leave):
                name = f"{kind} #{index} {'enter' if t['entering'] else 'exit'}"
                if t["after_did_ms"] is not None:
                    within = t["after_did_ms"] <= opts.settle_budget_ms
                    row(f"{name}: settles {opts.settle_budget_ms:.0f} ms after did{'Enter' if t['entering'] else 'Exit'}"
                        + ("" if opts.gate else " (info)"), f"<= {opts.settle_budget_ms}", str(t["after_did_ms"]),
                        within or not opts.gate)
            time.sleep(1.0)  # test harness: idle between rounds
            if opts.json:
                json.dump(report, open(opts.json, "w"), indent=1)
    print("\n== summary (per trigger and direction, median over rounds)")
    for kind in opts.triggers.split(","):
        for entering in (True, False):
            ts = [t for t in report["transitions"] if t["trigger"] == kind and t["entering"] == entering]
            print(f"  {kind:<6} {'enter' if entering else 'exit ':<5} {results.median_line(ts)}", flush=True)
    if opts.json:
        json.dump(report, open(opts.json, "w"), indent=1)


def main(argv=None):
    global opts, LAUNCHER, TAG, SOCKET, CLI, SCRATCH
    opts = parse(argv)
    os.makedirs(opts.out, exist_ok=True)
    LAUNCHER = bench_app(opts.app, opts.out, opts.build_config)
    TAG, SOCKET, CLI = LAUNCHER.tag, LAUNCHER.socket, LAUNCHER.cli  # cleanup() can reach a launch that failed
    SCRATCH = tempfile.mkdtemp(prefix=f"fullscreen-{TAG}-")
    report = {"tag": TAG, "transitions": [], "geometry": {}}
    try:
        measure(report)
    finally:
        cleanup()
        passed = bool(ROWS) and all(r[3] for r in ROWS)
        print("\nRESULT", "PASS" if passed else "FAIL", f"({sum(r[3] for r in ROWS)}/{len(ROWS)})")
    if report["transitions"]:  # a measured run (a launch that failed raised above)
        series = results.fullscreen_series(report["transitions"], ROWS, story=opts.story)
        for key, where in record_all(LAUNCHER, series).items():
            if not where.startswith("not recorded"):
                print(f"result-v1 {key}: {where}", flush=True)
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
