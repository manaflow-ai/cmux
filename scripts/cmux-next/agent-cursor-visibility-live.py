#!/usr/bin/env python3
"""Live check of the agent cursor visibility rules (CURSOR-HIDDEN, CURSOR-SHOW, CURSOR-SCREENS).

  scripts/cmux-next/agent-cursor-visibility-live.py --tag <tag> [--out DIR] [--publish-verb VERB]

GUI host only (cmux-lawrence-2); never on the laptop. Launches the tagged app
(no activation, automation socket), builds two windows with Chromium tabs on a
local page, then puts the target tab in each state and reads
`debug.agent_cursor {target}` (the live resolver) plus a `debug.window_snapshot`
of each window:

  visible          the target is the selected tab of a shown column   -> visible
  background_tab   another tab selected in the target's pane           -> hidden tabChip
  column_scrolled  focus moves right until the target column leaves    -> hidden columnEdge.leading
  other_workspace  the window shows another workspace                  -> hidden workspaceRow
  other_window     the other workspace moves to window 2               -> window 2 elsewhere
  minimized        window 2 minimized                                  -> notDrawn minimized
  other_space      only when --space-step is given (needs a manual Space switch on the host;
                   no automation may change Spaces)                    -> notDrawn otherSpace

When --publish-verb names a socket verb that publishes an automation.input
event (the input producer, not landed on 2026-10-04), each step also publishes
a click on the target and saves a second snapshot, so the overlay cursor or
indicator shows in the evidence. Without a producer the snapshots show the
page only and the resolver JSON is the evidence.

Exit 0 when every step's resolver answer matches; evidence in OUT/report.json.
Every step first checks that its setup took effect, from the resolver's own
input (`debug.agent_cursor` snapshot_json): a setup that did not happen reports
SETUP FAILED, never a resolver miss. Tabs are selected with the `tab.focus
{tab}` socket verb (the `tab.focus` action takes the tab as its target, not as
an argument); `newBrowserWorkspace` takes no arguments (an unknown `url`
argument refuses the whole run).
"""
import argparse, glob, http.server, json, os, plistlib, signal, socket, subprocess, sys, tempfile, threading, time

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or tempfile.mkdtemp(prefix="agent-cursor-vis-"))
parser.add_argument("--publish-verb", default=None, help="socket verb that publishes one automation.input event")
parser.add_argument("--space-step", action="store_true", help="pause for a manual Space switch and check otherSpace")
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)
APP = next(iter(glob.glob(os.path.expanduser(
    f"~/Library/Developer/Xcode/DerivedData/cmux-{opts.tag}/Build/Products/Debug/cmux DEV {opts.tag}.app"))), None)
if not APP:
    sys.exit(f"no tagged app for {opts.tag}")
with open(os.path.join(APP, "Contents/Info.plist"), "rb") as f:
    BINARY = os.path.join(APP, "Contents/MacOS", plistlib.load(f)["CFBundleExecutable"])
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"


class Page(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        name = self.path.strip("/") or "page"
        body = (f"<html><head><title>{name}</title></head><body style='margin:0;background:#2a2a2a;color:#ddd'>"
                f"<button id=b style='position:absolute;left:200px;top:150px;width:160px;height:60px'>{name}</button>"
                "</body></html>").encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Page)
threading.Thread(target=server.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{server.server_address[1]}/"


def rpc(method, params=None):
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(60)
        conn.connect(SOCKET)
        conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = conn.recv(1 << 22)
            if not chunk:
                break
            buf += chunk
        conn.close()
        reply = json.loads(buf)
        return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}
    except (OSError, ValueError) as error:
        return {"error": str(error)}


def wait(predicate, seconds, step=0.5):
    deadline = time.time() + seconds
    while time.time() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(step)
    return None


def focus_tab(tab):
    # The socket verb `tab.focus {tab}` runs the tab.focus action on that tab (it focuses by purpose).
    return rpc("tab.focus", {"tab": tab})


def snapshot(target):
    try:
        return json.loads(visibility(target).get("snapshot_json") or "{}")
    except ValueError:
        return {}


def target_window(snap):
    tab = snap.get("tab") or {}
    wins = snap.get("windows") or []
    return next((w for w in wins if w.get("shownWorkspace") == tab.get("workspace")), None) \
        or next((w for w in wins if tab.get("workspace") in (w.get("listedWorkspaces") or [])), None)


def target_pane(snap):
    window = target_window(snap) or {}
    pane_id = (snap.get("tab") or {}).get("pane")
    return next((p for p in window.get("panes") or [] if p.get("id") == pane_id), None)


def setup(name, target, predicate, seconds=15):
    """Waits until `predicate(snapshot)` holds; records SETUP FAILED otherwise."""
    if wait(lambda: predicate(snapshot(target)), seconds):
        return True
    snap = snapshot(target)
    report["steps"].append({"step": name, "target": target, "setup_failed": True, "snapshot": snap, "ok": False})
    failures.append(f"{name}: SETUP FAILED (the app did not reach the state; resolver not judged)")
    with open(os.path.join(opts.out, f"{name}-setup-failed.json"), "w") as f:
        json.dump(snap, f, indent=1)
    return False


def selected(tab):
    return lambda snap: (target_pane(snap) or {}).get("selectedTab") == tab


def scrolled_left(snap):
    pane = target_pane(snap) or {}
    frame, clip = pane.get("frame"), pane.get("clip")
    return bool(frame and clip and frame["x"] + frame["w"] <= clip["x"] + 0.5)


def shows_other_workspace(snap):
    window = target_window(snap)
    return bool(window and window.get("shownWorkspace") not in (None, (snap.get("tab") or {}).get("workspace")))


def action(name, args=None):
    # focus: true, so the user-origin view changes these steps need are allowed.
    return rpc("action.run", {"action": name, "args": args or {}, "focus": True})


def browser_tabs():
    report = rpc("debug.agent_cursor")
    return [entry["target"] for entry in (report.get("targets") or [])] if isinstance(report, dict) else []


def open_tab(name):
    before = set(browser_tabs())
    action("openBrowser.chromium", {"url": BASE + name})
    found = wait(lambda: [t for t in browser_tabs() if t not in before], 45)
    return found[0] if found else None


def visibility(target):
    report = rpc("debug.agent_cursor", {"target": target})
    entries = report.get("targets") if isinstance(report, dict) else None
    return entries[0] if entries else {"error": report}


def windows():
    listing = rpc("debug.window_list")
    return [w for w in (listing.get("windows") or []) if w.get("kind") == "main"] if isinstance(listing, dict) else []


report = {"steps": [], "base": BASE}
failures = []


def step(name, target, expect_kind, expect_anchor=None, expect_reason=None, ask_window=None):
    time.sleep(1.0)  # let springs settle (scroll, workspace swap)
    entry = visibility(target)
    result = entry.get("visibility") or {}
    record = {"step": name, "target": target, "visibility": result, "placements": entry.get("placements")}
    ok = result.get("kind") == expect_kind
    if expect_anchor:
        ok = ok and result.get("anchor") == expect_anchor
    if expect_reason:
        ok = ok and result.get("reason") == expect_reason
    if ask_window:
        # Placements are keyed by the app's window state ids (not NSWindow numbers): every
        # window other than the resolver's answer must draw nothing.
        others = [p for p in entry.get("placements") or [] if p.get("window") != result.get("window")]
        record["other_windows"] = others
        ok = ok and len(others) >= 1 and all((p.get("placement") or {}).get("kind") == "elsewhere" for p in others)
    if opts.publish_verb:
        record["publish"] = rpc(opts.publish_verb, {"target": target, "kind": "click", "point": {"x": 280, "y": 180}})
    for index, window in enumerate(windows()):
        path = os.path.join(opts.out, f"{name}-w{index}.png")
        record.setdefault("snapshots", []).append(
            {"window": window.get("id"), "result": rpc("debug.window_snapshot", {"window": window.get("id"), "path": path})})
    with open(os.path.join(opts.out, f"{name}-snapshot.json"), "w") as f:
        f.write(entry.get("snapshot_json") or "{}")
    with open(os.path.join(opts.out, f"{name}-sidebar-rows.json"), "w") as f:
        json.dump(rpc("debug.sidebar_rows"), f, indent=1)
    record["ok"] = ok
    report["steps"].append(record)
    if not ok:
        failures.append(f"{name}: expected {expect_kind} {expect_anchor or expect_reason or ''}, got {json.dumps(result)}")


if os.path.exists(SOCKET):
    os.unlink(SOCKET)
config = os.path.join(opts.out, "cmux.json")
with open(config, "w") as f:
    f.write("{}\n")
env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
       "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
       "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": config, "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1100,720"}
log = open(os.path.join(opts.out, "app.log"), "a")
app = subprocess.Popen([BINARY], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
report["pid"] = app.pid
try:
    if not wait(lambda: os.path.exists(SOCKET) and "error" not in rpc("debug.focus"), 90):
        sys.exit("app did not come up")
    if "error" in rpc("debug.agent_cursor"):
        sys.exit("this build has no debug.agent_cursor (needs feat-cmux-next after the visibility resolver)")
    window1 = (windows() or [{}])[0].get("id")

    # Window 1: target tab plus a second tab in the same pane.
    target = open_tab("target")
    other = open_tab("other")
    report["tabs"] = {"target": target, "other": other}
    if not target or not other:
        raise RuntimeError("browser tabs did not open")
    focus_tab(target)
    if setup("visible", target, selected(target)):
        step("visible", target, "visible")
    focus_tab(other)
    if setup("background_tab", target, selected(other)):
        step("background_tab", target, "hidden", expect_anchor="tabChip")
    focus_tab(target)
    setup("reselect_target", target, selected(target))

    # Columns: three new columns to the right, then focus walks right until the target column scrolls out.
    for _ in range(3):
        action("newColumn")
    for _ in range(4):
        action("focusRight")
    if setup("column_scrolled", target, scrolled_left):
        step("column_scrolled", target, "hidden", expect_anchor="columnEdge.leading")

    # Another workspace in the same window.
    report["new_workspace"] = action("newBrowserWorkspace")
    if setup("other_workspace", target, shows_other_workspace, seconds=30):
        step("other_workspace", target, "hidden", expect_anchor="workspaceRow")

    # The other workspace moves to a new window 2; window 1 falls back to the target's workspace,
    # so window 1 keeps the target (column still scrolled) and window 2 must answer elsewhere.
    known = {w.get("id") for w in windows()}
    action("moveWorkspaceToNewWindow")
    window2 = (wait(lambda: [w.get("id") for w in windows() if w.get("id") not in known], 30) or [None])[0]
    report["windows"] = {"window1": window1, "window2": window2}
    if setup("other_window", target, lambda snap: len(snap.get("windows") or []) >= 2 and not shows_other_workspace(snap)):
        step("other_window", target, "hidden", expect_anchor="columnEdge.leading", ask_window=True)

    # Minimize window 1 (minimizeWindow acts on the key window: focus window 1 through the target tab first).
    focus_tab(target)
    action("minimizeWindow")
    if setup("minimized", target, lambda snap: (target_window(snap) or {}).get("minimized") is True):
        step("minimized", target, "notDrawn", expect_reason="minimized")

    if opts.space_step:
        input("Move the target window to another Space on this host, then press Return: ")
        if setup("other_space", target, lambda snap: (target_window(snap) or {}).get("onActiveSpace") is False):
            step("other_space", target, "notDrawn", expect_reason="otherSpace")
except RuntimeError as error:
    failures.append(str(error))
finally:
    if app.poll() is None:
        app.send_signal(signal.SIGTERM)
        try:
            app.wait(20)
        except subprocess.TimeoutExpired:
            app.kill()
            app.wait()
    server.shutdown()
report["failures"] = failures
with open(os.path.join(opts.out, "report.json"), "w") as f:
    json.dump(report, f, indent=1)
for record in report["steps"]:
    if record.get("setup_failed"):
        print("SETUP FAILED", record["step"])
    else:
        print("ok " if record["ok"] else "BAD", record["step"], json.dumps(record["visibility"])[:300])
for failure in failures:
    print("FAIL", failure)
print("PASS" if not failures else "FAIL", f"(evidence {opts.out}/report.json)")
sys.exit(0 if not failures else 1)
