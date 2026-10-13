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

CONFIGS = {
    "default": [],
    "bouncy": [{"action": "bounce", "value": "subtle"}],
    "reduce": [{"action": "reduce", "value": True}],
    "splits-off": [{"action": "kind", "name": "splits", "value": False}],
    "newtab-off": [{"action": "kind", "name": "newTab", "value": False}],
    "newworkspace-off": [{"action": "kind", "name": "newWorkspace", "value": False}],
}
RESET = [{"action": "bounce", "value": "none"}, {"action": "reduce", "value": None},
         {"action": "kind", "name": "splits", "value": True}, {"action": "kind", "name": "newTab", "value": True},
         {"action": "kind", "name": "newWorkspace", "value": True}, {"action": "speed", "value": "fast"}]

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


def strip(name, folder, key_name, modifiers, content="focused", gesture=None):
    rpc("debug.motion", {"action": "start"})
    params = {"action": "frame_strip", "key": key_name, "modifiers": modifiers, "dir": folder,
              "duration_ms": opts.duration_ms, "content": content}
    if gesture:
        params["gesture"] = gesture
    reply = rpc("debug.new_tab", params) or {}
    time.sleep(0.4)  # test harness wait: late springs reach rest before the spans are read
    motion = rpc("debug.motion", {"action": "stop"}) or {}
    frames = reply.get("frames") or []
    result = {k: reply.get(k) for k in ("frame_count", "mean_interval_ms", "intermediate", "moving", "reversals", "jumps",
                                       "max_step", "content_intermediate", "blank", "error")}
    result.update({"gesture": name, "dir": folder, "spans": motion.get("spans") or [], "samples": motion.get("samples") or [],
                   "progress": [[f.get("ms"), f.get("progress", None), f.get("intermediate")] for f in frames]})
    print(json.dumps({k: result[k] for k in ("gesture", "frame_count", "moving", "reversals", "jumps", "max_step",
                                              "content_intermediate", "blank", "error")}), flush=True)
    return result


def run_config(name, settings):
    for change in RESET + settings:
        rpc("debug.motion", change)
    state = rpc("debug.motion", {"action": "read"}) or {}
    out = os.path.join(opts.out, name)
    results = {"settings": settings, "state": {k: state.get(k) for k in ("speed", "reduce_motion", "bounce", "disabled_kinds")},
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
    return results


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
    for name in opts.configs.split(","):
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
            app.kill()  # the exact PID this script started
    acpmux = os.path.join(opts.app, "Contents/Resources/bin/acpmux")
    cli = os.path.join(opts.app, "Contents/Resources/bin/cmux")
    acpmux_home = os.path.join(os.path.expanduser("~"), ".cmux/chief/isolated", opts.tag, "acpmux")
    if os.path.exists(acpmux):
        subprocess.run([acpmux, "daemon", "shutdown"], env={**os.environ, "ACPMUX_HOME": acpmux_home,
                       "ACPMUX_SOCKET": os.path.join(acpmux_home, "acpmux.sock")}, capture_output=True, timeout=30)
    if os.path.exists(cli):
        subprocess.run([cli, "server", "stop", "--session", f"cmux-app-{opts.tag}", "--end-terminals"],
                       env={k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}, capture_output=True, timeout=30)
    ps = subprocess.run(["ps", "-axo", "pid=,ppid=,command="], capture_output=True, text=True).stdout
    left = [line for line in ps.splitlines() if (opts.app + "/") in line]
    print(f"leftovers of this bundle: {len(left)}", flush=True)
