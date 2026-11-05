#!/usr/bin/env python3
"""Tagged-app check: a link from another app while Chief's Home is shown (#27897, classic Home off).

With cmux the default browser, a web link clicked in another app reaches the app as a URL
(`debug.external_open`, the route `application(_:open:)` takes). Home is the home workspace with the
Chief chat in a pinned dock; its layout is Chief's, so a page from another app opens in a workspace
of the person's, never as a new column beside the dock. Through the app's control socket only:
- home.show shows Home and the keyboard is in the dock;
- debug.external_open https://example.com/... is accepted;
- the window then shows a workspace other than Home, with a browser tab;
- home.show again: Home's panes and tabs are the ones it had before the open.
Runs on cmux-lawrence-2 through
`nx-remote --needs gui --app-from-fleet cmux --tag <tag> --ref <sha> -- 'python3 scripts/cmux-next/home-external-open.py'`
with an isolated HOME and Chief home under /tmp; it launches the app itself and ends with
quitEndSessions, endAgents and the tag's acpmux daemon shutdown. Reads NX_APP, NX_APP_TAG, NX_APP_STOP,
NX_ARTIFACTS. `--socket PATH` checks an app already running (started with LaunchServices, as
`capture-host launch` or `open -g -n` does) instead, and leaves it running.
"""
import json, os, shutil, socket, subprocess, sys, tempfile, time

ATTACH = sys.argv[2] if len(sys.argv) == 3 and sys.argv[1] == "--socket" else None
APP, TAG = (None, None) if ATTACH else (os.environ["NX_APP"], os.environ["NX_APP_TAG"])
OUT, STOP = os.environ.get("NX_ARTIFACTS", "/tmp/home-external-open"), os.environ.get("NX_APP_STOP", "")
SOCK = ATTACH or "/tmp/cmux-debug-%s.sock" % TAG
os.makedirs(OUT, exist_ok=True)
SCRATCH = tempfile.mkdtemp(prefix="h27897-", dir="/tmp")
HOME, CHIEF = os.path.join(SCRATCH, "home"), os.path.join(SCRATCH, "chief")
URL = "https://example.com/?cmux-27897"
failures = []


def rpc(method, params=None, timeout=35):
    try:
        c = socket.socket(socket.AF_UNIX); c.settimeout(timeout); c.connect(SOCK)
        c.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = c.recv(1 << 22)
            if not chunk:
                break
            buf += chunk
        c.close()
        reply = json.loads(buf)
        return reply.get("result", reply)
    except (OSError, ValueError) as error:
        return {"ok": False, "error": "socket: %s" % error}


def check(name, ok, detail=""):
    print(("ok   " if ok else "FAIL ") + name + ("" if ok else "  " + json.dumps(detail)[:800]), flush=True)
    if not ok:
        failures.append(name)
    return ok


def poll(predicate, timeout=30):
    deadline = time.time() + timeout
    value = predicate()
    while not value and time.time() < deadline:
        time.sleep(0.25)  # test harness wait, not app code
        value = predicate()
    return value


def run(action, arguments=None):
    params = {"id": action, "focus": True}
    if arguments:
        params["arguments"] = arguments
    return rpc("action.run", params) or {}


def refused(reply):
    text = json.dumps(reply)
    return "error" in reply or "not ready" in text or '"refused"' in text or reply.get("ok") is False


def shot(name):
    rpc("debug.window_snapshot", {"kind": "main", "path": os.path.join(OUT, name + ".png")}, 60)


def window():
    windows = (rpc("debug.focus") or {}).get("windows") or [{}]
    return windows[0]


def layout():
    """The shown workspace's panes and their tabs, as the focus model has them."""
    return sorted((p.get("pane"), sorted(p.get("tabs") or [])) for p in window().get("topology") or [])


def dock_pane():
    windows = (rpc("debug.pane_chrome") or {}).get("windows") or []
    panes = sorted((windows[0] if windows else {}).get("panes") or [], key=lambda p: (p.get("cell") or [0])[0])
    return (panes or [{}])[0].get("pane")


def launch():
    """Starts the tagged app with an isolated HOME and Chief home; returns its process."""
    os.makedirs(os.path.join(CHIEF, "optchat"), exist_ok=True)
    os.makedirs(HOME, exist_ok=True)
    open(os.path.join(CHIEF, "optchat", "settings.json"), "w").write('{"backup": {"remote": false}}\n')
    open(os.path.join(CHIEF, "migration.json"), "w").write('{"status": "test home: nothing to import"}\n')
    open(os.path.join(SCRATCH, "cmux.json"), "w").write("{}")
    open(os.path.join(SCRATCH, "ghostty"), "w").write("")
    global ENV
    ENV = env = {k: v for k, v in os.environ.items() if k in ("USER", "LOGNAME", "TMPDIR", "SHELL", "LANG")}
    env.update({"HOME": HOME, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1",
                "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_DEV_BACKEND_MODE": "local",
                "CMUX_NEXT_CONFIG_FILE": os.path.join(SCRATCH, "cmux.json"), "CMUX_NEXT_GHOSTTY_CONFIG": os.path.join(SCRATCH, "ghostty"),
                "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1500,940", "CMUX_NEXT_ONBOARDING_COMPUTER_USE": "mock",
                "CMUX_NEXT_CHIEF_HOME": CHIEF, "ACPMUX_AGENT_LAUNCH": "deny", "NX_REMOTE": "1"})
    env.pop("CMUX_NEXT_CLASSIC_HOME", None)
    if os.path.exists(SOCK):
        os.unlink(SOCK)
    app = subprocess.Popen([os.path.join(APP, "Contents/MacOS/cmux DEV")], env=env, cwd=OUT, stdin=subprocess.DEVNULL,
                           stdout=open(os.path.join(OUT, "app.log"), "a"), stderr=subprocess.STDOUT, start_new_session=True)
    print("launched pid %d" % app.pid, flush=True)
    return app


def stop(app):
    rpc("action.run", {"id": "quitEndSessions"}, timeout=10)
    try:
        app.wait(timeout=60)
    except subprocess.TimeoutExpired:
        print("app pid %d did not quit within 60 s" % app.pid, flush=True)
    rpc("action.run", {"id": "endAgents"}, timeout=10)
    acpmux = os.path.join(APP, "Contents/Resources/bin/acpmux")
    for acp in (os.path.join(CHIEF, "acpmux"), os.path.join(HOME, ".acpmux")):
        if os.path.isdir(acp):
            subprocess.run([acpmux, "daemon", "shutdown", "--end-agents"], env=dict(ENV, ACPMUX_HOME=acp), capture_output=True, timeout=30)
    if STOP:
        subprocess.run([STOP], capture_output=True, timeout=180)


app = None if ATTACH else launch()
try:
    poll(lambda: os.path.exists(SOCK) and (rpc("debug.windows") or {}).get("windows"), 240)
    shown = poll(lambda: (lambda r: None if refused(r) else r)(run("home.show")), 120)
    check("home.show is not refused", bool(shown), run("home.show"))
    home = poll(lambda: window().get("workspace"), 30)
    dock = poll(dock_pane, 60)
    rpc("debug.mouse", {"pane": dock, "action": "click"})
    in_dock = poll(lambda: (window().get("model") or {}).get("resolved_pane") == dock, 20)
    check("the keyboard is in Home's dock before the open", bool(dock) and bool(in_dock), window().get("model"))
    before = poll(layout, 20)
    shot("1-home-before")

    opened = rpc("debug.external_open", {"url": URL})
    check("debug.external_open accepts the link", opened is True or opened == {"value": True}, opened)
    browser = lambda w: sum(t.endswith(":browser") for p in w.get("topology") or [] for t in p.get("tabs") or [])
    moved = poll(lambda: (lambda w: w if w.get("workspace") not in (None, home) and browser(w) else None)(window()), 60)
    check("the link opens in a browser tab of a workspace other than Home", bool(moved), {"home": home, "window": window()})
    if moved:
        time.sleep(2)  # test harness wait: a second delivery would land by now
        check("the link opens once", window().get("workspace") == moved.get("workspace") and browser(window()) == browser(moved),
              window().get("topology"))
    shot("2-after-open")

    run("home.show")
    back = poll(lambda: window().get("workspace") == home and layout(), 30)
    check("Home's panes and tabs are unchanged by the open", back == before, {"before": before, "after": back})
    shot("3-home-after")
finally:
    if app:
        stop(app)
    shutil.rmtree(SCRATCH, ignore_errors=True)

print("%d failed: %s" % (len(failures), failures) if failures else "all checks passed", flush=True)
sys.exit(1 if failures else 0)
