#!/usr/bin/env python3
"""Frame strips of the structural gestures under each motion setting (motion redesign, hq-1d).

Runs on a GUI host through `nx-remote --needs gui --app-from-fleet cmux --tag TAG --ref SHA`,
never on a laptop. Launches the tagged app with a scratch config (no-activate), then for each
motion configuration (in memory through `debug.motion`: bounce, per-kind switches, Reduce Motion)
records `debug.new_tab` frame_strip around Cmd-T, the strip's +, closing a tab, Cmd-N, Cmd-D,
Cmd-Shift-D and the close of each split, with `debug.motion` spans and per-frame samples (clock dt,
travel left per animator) for each. Cmd-T and + start from a terminal tab (`newSurface`): on a New Tab
page Cmd-T only focuses the page, which is why the phase-1 run recorded no Cmd-T motion. Splits
exclude every pane's content from the chrome counts (`content: "panes"`), so a terminal painting its
prompt is not read as motion. It also saves the app's motion parity corpus (`trajectory`). After the last gesture it checks that no display link
is left (`display_links`) and samples the app's CPU while idle. Writes OUT/results.json and the
strips under OUT/<config>/<gesture>/. A build without the new `debug.motion` actions (the base)
ignores them; its results say which configurations it could not set.

Usage: motion-proof.py --app APP --tag TAG [--out DIR] [--configs default,bouncy,...]
"""
import argparse, json, os, plistlib, socket, subprocess, sys, tempfile, time

# Phase 3 (hq-1d 2026-10-14): every kind is off by default (instant, no spring); each opt-in alone,
# all of them bouncy, and all of them under Reduce Motion (which still moves nothing).
ALL_ON = [{"action": "kind", "name": k, "value": True} for k in ("paneAnimations", "newTab", "newWorkspace")]
CONFIGS = {
    "default": [],
    "panes-on": [{"action": "kind", "name": "paneAnimations", "value": True}],
    "newtab-on": [{"action": "kind", "name": "newTab", "value": True}],
    "newworkspace-on": [{"action": "kind", "name": "newWorkspace", "value": True}],
    "bouncy": ALL_ON + [{"action": "bounce", "value": "subtle"}],
    "reduce": ALL_ON + [{"action": "reduce", "value": True}],
}
RESET = [{"action": "bounce", "value": "none"}, {"action": "reduce", "value": None},
         {"action": "kind", "name": "paneAnimations", "value": False}, {"action": "kind", "name": "newTab", "value": False},
         {"action": "kind", "name": "newWorkspace", "value": False}, {"action": "speed", "value": "fast"}]

parser = argparse.ArgumentParser()
parser.add_argument("--app", required=True)
parser.add_argument("--tag", required=True)
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS", "/tmp/motion-proof"))
parser.add_argument("--configs", default=",".join(CONFIGS))
parser.add_argument("--size", default="1280x800")
parser.add_argument("--duration-ms", type=float, default=600)
# A build whose frame_strip sends only Command and knows no `gesture` (before hq-1d phase 2): its
# Cmd-Shift-D would be a Cmd-D and its + a Cmd-T, so those gestures are skipped, not mislabeled.
parser.add_argument("--base", action="store_true")
# hq-1d phase 3 step 7: only a Cmd-T loop (N opens and closes from a terminal tab) under one
# debug.motion recording, with every kind on; writes OUT/loop.json with the per-frame main-thread
# work of the clock and each animator (`work`), its spans and the sidebar's travel samples.
parser.add_argument("--loop", type=int, default=0)
# perf-tabs (cx-8w027.4): after the gestures, open this many terminal tabs (a crowded strip that
# scrolls) and record Move Tab Right/Left, Next Tab, Cmd-9/Cmd-1 (a reveal that scrolls the strip)
# and a close there.
parser.add_argument("--crowded", type=int, default=0)
# perf-tabs-polish (cx-8w027.18): frame strip scale (1 = full scale, for inner tab motion), and a fast
# selection burst in the crowded strip (several Next Tab keys inside one recording).
parser.add_argument("--strip-scale", type=float, default=0.25)
parser.add_argument("--burst", type=int, default=4)
# Record only the focused pane's tab strip (full-scale strips of the tabs' own motion stay cheap).
parser.add_argument("--crop-strip", action="store_true")
opts = parser.parse_args()
WIDTH, HEIGHT = (int(v) for v in opts.size.split("x"))
BINARY = os.path.join(opts.app, "Contents/MacOS",
                      plistlib.load(open(os.path.join(opts.app, "Contents/Info.plist"), "rb"))["CFBundleExecutable"])
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
SCRATCH = tempfile.mkdtemp(prefix=f"motion-{opts.tag}-")
CONFIG = os.path.join(SCRATCH, "cmux.json")
GHOSTTY = os.path.join(SCRATCH, "ghostty")
open(CONFIG, "w").write("{}")
open(GHOSTTY, "w").write("theme = light:Apple System Colors Light,dark:Apple System Colors\nfont-size = 12\n")


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
        return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}
    except (OSError, ValueError) as error:
        return {"error": str(error)}


def wait(predicate, seconds, step=0.3):
    end = time.time() + seconds
    while time.time() < end:
        value = predicate()
        if value:
            return value
        time.sleep(step)  # test harness wait, not app code
    return None


def key(k, mods=None):
    return rpc("debug.key", {"key": k, "modifiers": mods or []})


def action(name):
    return rpc("action.run", {"id": name})


def tab_count():
    snap = rpc("snapshot.get") or {}
    topo = snap.get("topology") or snap
    focus = (topo.get("focus") or {}).get("workspace")
    for ws in topo.get("workspaces", []):
        if ws.get("id") == focus:
            return sum(len(p.get("tabs", [])) for s in ws.get("screens", []) for p in s.get("panes", []))
    return 0


def terminal_tab():
    """Opens a terminal tab in the focused pane (a script's newSurface is a terminal) and waits for it."""
    before = tab_count()
    action("newSurface")
    wait(lambda: tab_count() > before, 8)
    time.sleep(1.0)  # test harness wait: the terminal's first paint


def pane_count():
    snap = rpc("snapshot.get") or {}
    topo = snap.get("topology") or snap
    focus = (topo.get("focus") or {}).get("workspace")
    for ws in topo.get("workspaces", []):
        if ws.get("id") == focus:
            return sum(len(s.get("panes", [])) for s in ws.get("screens", []))
    return 0


def workspace_count():
    snap = rpc("snapshot.get") or {}
    topo = snap.get("topology") or snap
    return len(topo.get("workspaces", []))


def spare_state():
    """Whether a prewarmed New Tab spare was waiting (read before a gesture)."""
    state = rpc("debug.new_tab", {"action": "state"}) or {}
    spares = state.get("spares")
    return len(spares) > 0 if isinstance(spares, list) else None


def tab_order():
    """The focused workspace's pane with the most tabs (one pane here): its tabs in model order."""
    snap = rpc("snapshot.get") or {}
    topo = snap.get("topology") or snap
    focus = (topo.get("focus") or {}).get("workspace")
    panes = [p for ws in topo.get("workspaces", []) if ws.get("id") == focus for s in ws.get("screens", []) for p in s.get("panes", [])]
    if not panes:
        return []
    pane = max(panes, key=lambda p: len(p.get("tabs", [])))
    return [(t.get("id"), t.get("title"), t.get("kind") or t.get("type")) for t in pane.get("tabs", [])]


def set_config(values, settings):
    """Rewrites the scratch cmux.json (the app reloads it), waits for the reload, then sets the
    configuration's motion switches again: the reload applies the file's (default) kinds."""
    open(CONFIG, "w").write(json.dumps(values))
    time.sleep(1.5)  # test harness wait: the config watcher's reload
    for change in RESET + settings:
        rpc("debug.motion", change)


def strip(name, folder, key_name, modifiers, content="focused", gesture=None, repeat=1):
    rpc("debug.motion", {"action": "start"})
    params = {"action": "frame_strip", "key": key_name, "modifiers": modifiers, "dir": folder, "scale": opts.strip_scale,
              "duration_ms": opts.duration_ms, "content": "none" if content == "panes" else content, "tolerance": 0.0005}
    if repeat > 1:
        params.update({"repeat": repeat, "repeat_interval_ms": 40})
    if opts.crop_strip:
        params["crop"] = "strip"
    if gesture:
        params["gesture"] = gesture
    reply = rpc("debug.new_tab", params) or {}
    time.sleep(0.4)  # test harness wait: late springs reach rest before the spans are read
    motion = rpc("debug.motion", {"action": "stop"}) or {}
    frames = reply.get("frames") or []
    result = {k: reply.get(k) for k in ("frame_count", "mean_interval_ms", "intermediate", "moving", "reversals", "jumps",
                                       "max_step", "content_intermediate", "blank", "error")}
    for k in ("tabs_moving_frames", "tabs_restarts", "tabs_peak_travel"):
        result[k] = reply.get(k)
    result.update({"gesture": name, "dir": folder, "spans": motion.get("spans") or [], "samples": motion.get("samples") or [],
                   "notes": motion.get("notes") or [], "spare": spare_state(),
                   "progress": [[f.get("ms"), f.get("progress", None), f.get("intermediate")] for f in frames]})
    print(json.dumps({k: result.get(k) for k in ("gesture", "frame_count", "moving", "reversals", "jumps", "max_step",
                                              "content_intermediate", "blank", "tabs_moving_frames", "tabs_restarts",
                                              "tabs_peak_travel", "error")}), flush=True)
    return result


def run_config(name, settings):
    for change in RESET + settings:
        rpc("debug.motion", change)
    state = rpc("debug.motion", {"action": "read"}) or {}
    out = os.path.join(opts.out, name)
    results = {"settings": settings, "state": {k: state.get(k) for k in ("speed", "reduce_motion", "bounce", "enabled_kinds", "pane_animations")},
               "gestures": []}
    # Cmd-T from a terminal tab (Cmd-T on a New Tab page only focuses it), then its close.
    terminal_tab()
    results["gestures"].append(strip("cmd-t", os.path.join(out, "cmd-t"), "t", ["command"]))
    time.sleep(0.6)  # test harness wait: the page settles
    results["gestures"].append(strip("close-tab", os.path.join(out, "close-tab"), "w", ["command"]))
    time.sleep(0.6)  # test harness wait
    # The strip's + (the same path as Cmd-T, P7), from a terminal tab again; close what it opened.
    if not opts.base:
        terminal_tab()
        results["gestures"].append(strip("plus", os.path.join(out, "plus"), "t", ["command"], gesture="plus"))
        time.sleep(0.6)  # test harness wait
        key("w", ["command"])
        time.sleep(0.8)  # test harness wait
    # The + bug (phase 3 step 4): + and Cmd-T again, each with a cold spare (right after an open,
    # before the pool rewarms) and a warm one; with ui.animations.newTab off both must be instant.
    if not opts.base:
        for warm in (False, True):
            for gesture in ("plus", "cmd-t"):
                terminal_tab()
                if warm:
                    time.sleep(3)  # test harness wait: the New Tab spare rewarms
                label = f"{gesture}-{'warm' if warm else 'cold'}"
                results["gestures"].append(strip(label, os.path.join(out, label), "t", ["command"],
                                                 gesture="plus" if gesture == "plus" else None))
                time.sleep(0.6)  # test harness wait
                key("w", ["command"])
                time.sleep(0.6)  # test harness wait
    # hq-4e review item 1: a tab drag while a CLI new tab lands keeps the drag's springs.
    if not opts.base:
        terminal_tab()
        results["gestures"].append(strip("drag-new", os.path.join(out, "drag-new"), "t", ["command"], gesture="drag_new"))
        time.sleep(0.8)  # test harness wait
        key("w", ["command"])
        time.sleep(0.6)  # test harness wait
    # After current (tabs.newTabPosition afterCurrent): Cmd-T on tab 1 of three shows the page in
    # slot 2 from its first frame; submitting it (`!ls`, Return) puts the terminal in that slot.
    if not opts.base:
        set_config({"tabs": {"newTabPosition": "afterCurrent"}}, settings)
        terminal_tab()
        terminal_tab()
        # A terminal tab with tabs after it (Cmd-T on the window's first tab, a New Tab page, only focuses it).
        order = tab_order()
        anchor = next((i for i, t in enumerate(order[:-1]) if "terminal" in str(t[2]).lower() and i < 8), 1)
        rpc("tab.focus", {"tab": order[anchor][0], "focus": True})  # Cmd-1..9 switch workspaces, not tabs
        time.sleep(0.6)  # test harness wait
        before = tab_order()
        results["gestures"].append(strip("after-current", os.path.join(out, "after-current"), "t", ["command"]))
        time.sleep(0.8)  # test harness wait: the page's field takes keys
        page_order = tab_order()
        for char in "!ls":
            key(char)
        time.sleep(0.3)  # test harness wait
        results["gestures"].append(strip("page-submit", os.path.join(out, "page-submit"), "return", []))
        time.sleep(1.5)  # test harness wait: NewTabSlot's move lands
        after = tab_order()
        slot = anchor + 1
        results["slots"] = {"before": before, "page": page_order, "after": after, "anchor": anchor,
                            "page_after_anchor": len(page_order) > slot and page_order[slot][0] not in [t[0] for t in before],
                            "submit_after_anchor": len(after) > slot and after[slot][0] not in [t[0] for t in page_order]
                            and "terminal" in str(after[slot][2]).lower()}
        print("slots", json.dumps(results["slots"])[:400], flush=True)
        for _ in range(len(after) - 1):
            key("w", ["command"])
            time.sleep(0.4)  # test harness wait
        set_config({}, settings)
    # Cmd-N: a new workspace row; Cmd-W closes its only tab (and the workspace).
    before = workspace_count()
    results["gestures"].append(strip("cmd-n", os.path.join(out, "cmd-n"), "n", ["command"]))
    if workspace_count() > before:
        key("w", ["command"])
    time.sleep(0.8)  # test harness wait
    terminal_tab()
    # Cmd-D, its close, Cmd-Shift-D, its close: pane content is out of the counts (pane chrome only).
    for gesture, mods in (("cmd-d", ["command"]), ("cmd-shift-d", ["command", "shift"]))[: 1 if opts.base else 2]:
        panes = pane_count()
        results["gestures"].append(strip(gesture, os.path.join(out, gesture), "d", mods, content="panes"))
        wait(lambda: pane_count() > panes, 5)
        time.sleep(0.6)  # test harness wait: the split's terminal starts
        results["gestures"].append(strip(f"close-{gesture}", os.path.join(out, f"close-{gesture}"), "w", ["command"], content="panes"))
        wait(lambda: pane_count() <= panes, 5)
        time.sleep(0.6)  # test harness wait
    if opts.crowded:
        results["gestures"] += crowded_strip(out)
    return results


def crowded_strip(out):
    """Strip gestures in a crowded strip; the tabs it opened are closed again."""
    opened = 0
    for _ in range(opts.crowded):
        before = tab_count()
        action("newSurface")
        if wait(lambda: tab_count() > before, 8):
            opened += 1
    time.sleep(1.5)  # test harness wait: the new terminals' first paint
    gestures = []
    for name, key_name, mods in (("move-right", "]", ["shift", "option", "command"]), ("move-left", "[", ["shift", "option", "command"]),
                                 ("next-tab", "tab", ["control"]), ("select-first", "1", ["command"]), ("select-last", "9", ["command"]),
                                 ("close-crowded", "w", ["command"])):
        gestures.append(strip(f"crowded-{name}", os.path.join(out, f"crowded-{name}"), key_name, mods))
        time.sleep(0.5)  # test harness wait: the strip settles before the next gesture
    if opts.burst > 1:
        # A selection burst: each key retargets the reveal and the occlusion masks in flight.
        for name, key_name, mods in (("next-burst", "tab", ["control"]), ("prev-burst", "tab", ["control", "shift"])):
            gestures.append(strip(f"crowded-{name}", os.path.join(out, f"crowded-{name}"), key_name, mods, repeat=opts.burst))
            time.sleep(0.5)  # test harness wait
    for _ in range(max(0, opened - 1)):
        key("w", ["command"])
        time.sleep(0.15)  # test harness wait
    return gestures


def idle_cpu(pid):
    sample = subprocess.run(["top", "-l", "4", "-s", "2", "-pid", str(pid), "-stats", "pid,cpu"], capture_output=True, text=True).stdout
    values = [float(line.split()[1]) for line in sample.splitlines() if line.strip().startswith(str(pid))]
    # The first sample has no interval; the rest are 2 s each.
    return values[1:]


app = None
os.makedirs(opts.out, exist_ok=True)
report = {"tag": opts.tag, "configs": {}}
try:
    if os.path.exists(SOCKET):
        os.unlink(SOCKET)
    env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
           "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": CONFIG, "CMUX_NEXT_GHOSTTY_CONFIG": GHOSTTY,
           "CMUX_NEXT_TEST_WINDOW_FRAME": f"40,40,{WIDTH},{HEIGHT}"}
    log = open(os.path.join(opts.out, f"app-{opts.tag}.log"), "a")
    app = subprocess.Popen([BINARY], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
    print(f"launched pid {app.pid}", flush=True)
    if not wait(lambda: os.path.exists(SOCKET) and (rpc("debug.surfaces") or {}).get("windows"), 120):
        sys.exit("the tagged app did not come up")
    time.sleep(3)  # test harness wait: first frame and the New Tab spare settle
    corpus = rpc("debug.motion", {"action": "trajectory"}) or {}
    if corpus.get("tokens"):
        json.dump(corpus, open(os.path.join(opts.out, "swift-trajectory.json"), "w"))
    if opts.loop:
        for change in RESET + ALL_ON:
            rpc("debug.motion", change)
        terminal_tab()
        rpc("debug.motion", {"action": "start"})
        for _ in range(opts.loop):
            key("t", ["command"])
            time.sleep(0.5)  # test harness wait: the tab's springs and the page settle
            key("w", ["command"])
            time.sleep(0.5)  # test harness wait
        loop = rpc("debug.motion", {"action": "stop"}) or {}
        report["loop"] = {"opens": opts.loop, "work": loop.get("work"), "spans": len(loop.get("spans") or []),
                          "sidebar_frames": sum(1 for x in loop.get("samples") or [] if x.get("name") == "sidebar.travel"),
                          "state": {k: loop.get(k) for k in ("enabled_kinds", "pane_animations", "display_links")}}
        print("loop", json.dumps(report["loop"]), flush=True)
        json.dump(report["loop"], open(os.path.join(opts.out, "loop.json"), "w"), indent=1)
    for name in ([] if opts.loop else opts.configs.split(",")):
        report["configs"][name] = run_config(name, CONFIGS[name])
        json.dump(report, open(os.path.join(opts.out, "results.json"), "w"), indent=1)
    for change in RESET:
        rpc("debug.motion", change)
    time.sleep(2)  # test harness wait: every spring at rest
    state = rpc("debug.motion", {"action": "read"}) or {}
    report["idle"] = {"display_links": state.get("display_links"), "active_clients": state.get("active_clients"),
                      "cpu_percent_samples": idle_cpu(app.pid)}
    print("idle", report["idle"], flush=True)
    json.dump(report, open(os.path.join(opts.out, "results.json"), "w"), indent=1)
finally:
    if app and app.poll() is None:
        # The DEBUG quit fixture (a scripted quitEndSessions is user-only since cx-zk9t).
        reply = rpc("debug.quit", {"fixture_quit": "end-sessions"}, timeout=10)
        print("quit:", json.dumps(reply)[:200], flush=True)
        try:
            app.wait(30)
        except subprocess.TimeoutExpired:
            # nx-remote's stop for --app-from-fleet jobs (never a kill of the tagged app).
            if os.environ.get("NX_APP_STOP"):
                subprocess.run([os.environ["NX_APP_STOP"]], capture_output=True, timeout=60)
    acpmux = os.path.join(opts.app, "Contents/Resources/bin/acpmux")
    cli = os.path.join(opts.app, "Contents/Resources/bin/cmux")
    acpmux_home = os.path.join(os.path.expanduser("~"), ".cmux/chief/isolated", opts.tag, "acpmux")
    if os.path.exists(acpmux):
        subprocess.run([acpmux, "daemon", "shutdown", "--end-agents"], env={**os.environ, "ACPMUX_HOME": acpmux_home,
                       "ACPMUX_SOCKET": os.path.join(acpmux_home, "acpmux.sock")}, capture_output=True, timeout=30)
    if os.path.exists(cli):
        subprocess.run([cli, "server", "stop", "--session", f"cmux-app-{opts.tag}", "--end-terminals"],
                       env={k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}, capture_output=True, timeout=30)
    ps = subprocess.run(["ps", "-axo", "pid=,ppid=,command="], capture_output=True, text=True).stdout
    left = [line for line in ps.splitlines() if (opts.app + "/") in line]
    print(f"leftovers of this bundle: {len(left)}", flush=True)
