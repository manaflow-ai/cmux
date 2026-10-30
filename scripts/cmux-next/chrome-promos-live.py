#!/usr/bin/env python3
"""Chrome promotions in a Chromium tab (cx-lqitn): a tagged cmux-next app must
not show Chrome's in-product help, first-run or default-browser bubbles.

Repro of the bubble Lawrence saw ("Split view makes it easier to multitask",
IPH_SideBySideTabSwitchFeature): Chromium shows it when the user switches
between the same two tabs of one browser three times
(split_view_iph_controller.cc). A fresh profile is in User Education's 7-day
new-profile grace and 10-minute session grace, so the run passes
`disable-user-education-rate-limiting` through CMUX_NEXT_CEF_EXTRA_SWITCHES
(Debug development bundles only) to make the old build show it at once.

Steps: launch the app (no activation, automation socket, empty config), open
two Chromium tabs in one pane, switch between them 8 times, then count the
app's on-screen windows above the main window (a help bubble is its own
window) and capture the window. Then read Chromium's ChromeFeatureState file,
which records the browser's feature overrides.

Usage (from an nx-remote --app-from-fleet job):
  chrome-promos-live.py TAG APP_PATH --expect bubble|none
Exit 0 when what the app shows matches --expect.
"""
import argparse, json, os, plistlib, socket, subprocess, sys, tempfile, time

parser = argparse.ArgumentParser()
parser.add_argument("tag")
parser.add_argument("app")
parser.add_argument("--expect", choices=["bubble", "none"], required=True)
parser.add_argument("--flips", type=int, default=8)
parser.add_argument("--activate", action="store_true",
                    help="let the app activate (Chromium shows a help bubble only in an active window); "
                         "run in an `nx-remote --needs input` job, which owns the front app")
args = parser.parse_args()

out = os.environ.get("NX_ARTIFACTS") or tempfile.mkdtemp(prefix="chrome-promos-")
SOCKET = f"/tmp/cmux-debug-{args.tag}.sock"
CAPTURE = os.environ.get("NX_CAPTURE")
failures = []
TAB = None


def check(ok, what):
    print(("ok   " if ok else "FAIL ") + what, flush=True)
    if not ok:
        failures.append(what)


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
        reply = json.loads(buf)
    except (OSError, ValueError) as e:
        return {"error": str(e)}
    r = reply.get("result") if reply.get("ok") else {"error": reply.get("error")}
    return r if isinstance(r, dict) else {"value": r}


def wait(pred, seconds):
    end = time.monotonic() + seconds
    while time.monotonic() < end:  # bounded wait for the app's own state
        v = pred()
        if v:
            return v
        time.sleep(0.25)
    return None


def windows():
    return rpc("debug.focus").get("windows") or []


def open_tab(url):
    """A tab a person opens (origin remote), not an agent-driven one."""
    created = rpc("action.run", {"action": "openBrowser.chromium", "args": {"url": url}, "focus": True,
                                 "origin": "remote"}).get("created")
    return (created or [None])[0]


def page_status(tab):
    reply = rpc("debug.browser.page_status", {"tab": tab} if tab else {})
    return reply if "certificate" in reply else {}


def focused_pane():
    panes = [p for w in rpc("debug.surfaces").get("windows", []) for p in w.get("panes", [])]
    for pane in panes:
        if pane.get("focused"):
            return pane
    return next((p for p in panes if p.get("visible")), {})


def snapshot(name):
    print("snapshot", name, rpc("debug.window_snapshot", {"kind": "main", "path": os.path.join(out, name)}), flush=True)


def app_windows(pid):
    """On-screen windows of the app from WindowServer (all layers)."""
    if not CAPTURE:
        return None
    r = subprocess.run(["bash", CAPTURE, "windows", "--all-layers", "--pid", str(pid)], capture_output=True, text=True)
    print("windows:", r.stdout.strip()[:4000], r.stderr.strip()[:500], flush=True)
    try:
        data = json.loads(r.stdout)
    except ValueError:
        return None
    return data.get("windows", data) if isinstance(data, dict) else data


def shot(pid, name):
    if not CAPTURE:
        return
    path = os.path.join(out, name)
    r = subprocess.run(["bash", CAPTURE, "shot", "--pid", str(pid), "--with-popups", "--out", path],
                       capture_output=True, text=True)
    print(f"shot {name}: exit {r.returncode} {r.stdout.strip()[:300]} {r.stderr.strip()[:300]}", flush=True)


with open(os.path.join(args.app, "Contents/Info.plist"), "rb") as f:
    info = plistlib.load(f)
binary = os.path.join(args.app, "Contents/MacOS", info["CFBundleExecutable"])
scratch = tempfile.mkdtemp(prefix=f"chrome-promos-{args.tag}-")
config = os.path.join(scratch, "cmux.json")
open(config, "w").write("{}\n")
if os.path.exists(SOCKET):
    os.unlink(SOCKET)
env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""),
       "TMPDIR": os.environ.get("TMPDIR", "/tmp"), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
       "CMUX_NEXT_SOCKET_MODE": "automation",
       "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": config,
       "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1200,800",
       "CMUX_NEXT_CEF_EXTRA_SWITCHES": "disable-user-education-rate-limiting"}
if not args.activate:
    env["CMUX_NEXT_NO_ACTIVATE"] = "1"
for key in ("NX_JOB_ID",):
    if key in os.environ:
        env[key] = os.environ[key]
app = subprocess.Popen([binary], env=env, stdout=open(os.path.join(out, "app.log"), "w"),
                       stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
print(f"app pid {app.pid}, out {out}", flush=True)
try:
    check(bool(wait(lambda: os.path.exists(SOCKET) and "error" not in rpc("debug.focus"), 180)), "app socket")
    if not windows():
        rpc("action.run", {"action": "newWindow", "origin": "script"})
    wait(windows, 60)
    # A fresh window has one tab (tab 1); A and B become tabs 2 and 3.
    a = open_tab("https://example.com/")
    check(bool(wait(lambda: page_status(a), 45)), "tab A (https://example.com) answers")
    b = open_tab("https://example.org/")
    check(bool(wait(lambda: page_status(b), 45)), "tab B (https://example.org) answers")
    time.sleep(3)  # test script: let both pages paint before the first capture
    print("tab B page status:", json.dumps(page_status(b))[:600], flush=True)
    before = app_windows(app.pid)
    snapshot("0-two-tabs.png")
    # Switch between tabs 2 and 3 (A and B): Chromium counts a switch back
    # to one of the two most recent tabs (split_view_iph_controller.cc).
    selected = []
    for i in range(args.flips):
        rpc("action.run", {"action": "selectSurfaceByNumber", "args": {"index": 2 if i % 2 == 0 else 3}})
        time.sleep(0.6)  # test script: a user-paced tab switch
        selected.append(focused_pane().get("selected_tab"))
    print("selected tab after each switch:", selected, flush=True)
    alternated = len(set(selected)) == 2 and all(x != y for x, y in zip(selected, selected[1:]))
    check(alternated, "the tab switches alternate between the two Chromium tabs")
    time.sleep(3)  # test script: the promo queue shows a bubble within about a second
    after = app_windows(app.pid)
    shot(app.pid, "1-after-tab-switches-capture.png")
    snapshot("1-after-tab-switches.png")
    extra = None
    if before is not None and after is not None:
        known = {w.get("window_id") for w in before}
        new = [w for w in after if w.get("window_id") not in known]
        # Chromium's status bubble (link URL, "Waiting for ...") comes and goes with loads and the
        # pointer; it is no promotion. WindowServer gives no class or role for it and debug.cef names
        # no window by id, so it is found by geometry: at most 30 pt high, its bottom-left corner on
        # the bottom-left corner of another app window (the Chromium page window).
        def at_bottom_left(w, of):
            b, o = w.get("bounds") or {}, of.get("bounds") or {}
            return (b.get("height", 99) <= 30 and abs(b.get("x", 0) - o.get("x", 0)) <= 8
                    and abs((b.get("y", 0) + b.get("height", 0)) - (o.get("y", 0) + o.get("height", 0))) <= 8)
        bubbles = [w for w in new if any(at_bottom_left(w, o) for o in before + after if o is not w)]
        for w in bubbles:
            print("ignored as Chromium's status bubble:", json.dumps(w), flush=True)
        if bubbles:
            print("debug.cef windows:", json.dumps((rpc("debug.cef") or {}).get("windows"))[:1500], flush=True)
        extra = len(new) - len(bubbles)  # windows that were not there before, less the status bubble
        print(f"app windows: {len(before)} before the switches, {len(after)} after; new:",
              json.dumps(new), flush=True)
    if args.expect == "bubble":
        check(extra is not None and extra > 0, f"a Chrome help bubble window appears after the tab switches (+{extra})")
    else:
        check(extra is not None and extra <= 0, f"no new window appears after the tab switches (+{extra})")
    # chrome://version does not render in a cmux tab, and helper processes
    # get the feature state through shared memory, not their command line.
    # Chromium writes the browser's feature overrides to ChromeFeatureState
    # in its user data directory at every launch: that file shows whether
    # the IPH demo-mode override is in effect.
    data_dir = os.path.join(os.environ["HOME"], "Library/Application Support", info["CFBundleIdentifier"], "Chromium")
    try:
        state = json.load(open(os.path.join(data_dir, "ChromeFeatureState")))
    except (OSError, ValueError) as e:
        state = {"error": str(e)}
    print("ChromeFeatureState:", json.dumps(state), flush=True)
    # A fresh profile only: the first-run sentinel and the tracker database
    # stay from any earlier run of an older build.
    print("first-run sentinel:", os.path.exists(os.path.join(data_dir, "First Run")),
          "| tracker database:", os.path.exists(os.path.join(data_dir, "Default", "Feature Engagement Tracker")), flush=True)
    if args.expect == "none":
        check("IPH_DemoMode" in state.get("enable-features", "")
              and "chosen_feature/IPH_Dummy" in state.get("force-fieldtrial-params", ""),
              "Chromium runs with IPH_DemoMode on IPH_Dummy (ChromeFeatureState)")
finally:
    stop = os.environ.get("NX_APP_STOP")
    if stop:
        subprocess.run([stop], timeout=120)
    else:
        rpc("action.run", {"action": "quitEndSessions"})
        try:
            app.wait(timeout=30)
        except subprocess.TimeoutExpired:
            print("app still running; stop it with the job's NX_APP_STOP", flush=True)
print(f"{len(failures)} failure(s); artifacts in {out}")
sys.exit(1 if failures else 0)
