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

Usage: fullscreen-transition.py --tag <tag> --app PATH [--rounds 3] [--parked 10] [--triggers action,key,zoom]
       [--json PATH] [--out DIR] [--gate]
"""
import argparse, glob, json, os, re, signal, socket, subprocess, sys, tempfile, time
# perfx/close-no-flash A/B (scratch overlay, never lands): --close-flash runs the close-flash bench on this tagged build.
if "--close-flash" in sys.argv[1:]:
    import importlib.util as _ilu
    _spec = _ilu.spec_from_file_location("close_flash_bench", os.path.join(os.path.dirname(os.path.abspath(__file__)), "close-flash-bench.py"))
    _mod = _ilu.module_from_spec(_spec)
    _spec.loader.exec_module(_mod)
    sys.exit(_mod.main(sys.argv[1:]))

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--app", required=True)
parser.add_argument("--rounds", type=int, default=3)
parser.add_argument("--parked", type=int, default=10)
parser.add_argument("--triggers", default="action,key,zoom")
parser.add_argument("--spaces", action="store_true")
parser.add_argument("--json")
parser.add_argument("--out", default="/tmp")
parser.add_argument("--gate", action="store_true", help="fail on the timing budget rows too, not only layout")
parser.add_argument("--settle-budget-ms", type=float, default=150.0, help="settle_ms after didEnter/didExit")
opts, _unknown = parser.parse_known_args()
TAG, APP = opts.tag, os.path.abspath(opts.app.rstrip("/"))
SOCKET = f"/tmp/cmux-debug-{TAG}.sock"
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")
BINARY = next((p for p in sorted(glob.glob(os.path.join(APP, "Contents/MacOS/*"))) if not p.endswith(".dylib")), None)
SCRATCH = tempfile.mkdtemp(prefix=f"fullscreen-{TAG}-")
open(os.path.join(SCRATCH, "ghostty"), "w").close()
CONFIG = os.path.join(SCRATCH, "cmux.json")
open(CONFIG, "w").write("{}\n")
ROWS, LAUNCHED = [], []
app = None


def run(*args, timeout=30):
    env = {"HOME": os.environ["HOME"], "PATH": "/usr/bin:/bin", "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "CMUX_SOCKET_PATH": SOCKET, "CMUX_QUIET": "1", "CMUX_TAG": TAG,
           "CMUX_BUNDLE_ID": f"com.cmuxterm.app.debug.{TAG}", "CMUX_BUNDLED_CLI_PATH": CLI}
    return subprocess.run([CLI, *args], capture_output=True, text=True, timeout=timeout, env=env)


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
    if os.environ.get("FULLSCREEN_KEEP") or not LAUNCHED:
        return
    if is_full():
        action("toggleFullScreen")
        time.sleep(2)  # test harness: leave full screen before quitting
    rpc("action.run", {"action": "quitEndSessions"}, timeout=10)
    if app:
        try:
            app.wait(timeout=20)
        except subprocess.TimeoutExpired:
            os.kill(app.pid, signal.SIGKILL)
    subprocess.run([CLI, "server", "stop", "--session", f"cmux-app-{TAG}", "--end-terminals"],
                   env={k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}, capture_output=True, timeout=30)
    if os.path.exists(SOCKET):
        os.remove(SOCKET)


def main():
    global app
    if os.path.exists(SOCKET):
        os.remove(SOCKET)
    env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_CONFIG_FILE": CONFIG,
           "CMUX_NEXT_GHOSTTY_CONFIG": os.path.join(SCRATCH, "ghostty"), "CMUX_NEXT_TEST_WINDOW_FRAME": "80,80,1400,900"}
    log = open(os.path.join(opts.out, f"app-{TAG}.log"), "a")
    app = subprocess.Popen([BINARY], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
    LAUNCHED.append(app.pid)
    print(f"launched pid {app.pid}", flush=True)
    if not wait(lambda: os.path.exists(SOCKET) and (rpc("debug.windows") or {}).get("windows"), 120):
        sys.exit("the tagged app did not come up")
    time.sleep(5)  # test harness: launch work settles
    setup()
    report = {"tag": TAG, "transitions": [], "geometry": {}}
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
            def med(key):
                values = sorted(v for v in (t.get(key) for t in ts) if v is not None)
                return values[len(values) // 2] if values else None
            print(f"  {kind:<6} {'enter' if entering else 'exit ':<5} did {med('did_ms')} settle {med('settle_ms')} "
                  f"after-did {med('after_did_ms')} resizes {med('resizes')} layout {med('layout_passes')}x "
                  f"{med('layout_total_ms')} ms max {med('layout_max_ms')} grids {med('grid_reports')}/{med('resizes_sent')} "
                  f"missed {med('missed')}", flush=True)
    if opts.json:
        json.dump(report, open(opts.json, "w"), indent=1)


try:
    main()
finally:
    cleanup()
    print("\nRESULT", "PASS" if ROWS and all(r[3] for r in ROWS) else "FAIL", f"({sum(r[3] for r in ROWS)}/{len(ROWS)})")
    sys.exit(0 if ROWS and all(r[3] for r in ROWS) else 1)
