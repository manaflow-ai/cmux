#!/usr/bin/env python3
"""Live check: a password manager extension's passkey flow in cmux matches Chrome (user report
2026-11-17: Bitwarden, GitHub sudo "Retry passkey" failed at once with "Authentication failed").

  scripts/cmux-next/passkeys-extension-fallback-live.py --tag TAG --app PATH.app --out DIR [--scenario S]

Launches the tagged DEV app (activated: page focus is part of the check) with the probe extension in
tests/passkeys/extension-fallback/extension, which works the way Bitwarden does: it wraps
navigator.credentials.get, opens a chrome.windows.create popout and falls back to the browser's own get
when chrome.windows.onRemoved fires for that window. The page (tests/passkeys/extension-fallback/
page.html, served on localhost) registers a credential on a DevTools virtual authenticator first
(`debug.cef.devtools`, Debug builds), so the get completes with no Touch ID.

--scenario popout: click "Use passkey" (a trusted DevTools click), wait for the popout panel, close it
through the app's own close path (`debug.popups {action: close}`), wait for the fallback sign-in.
--in-home opens the page beside Home's agent page (a cmux page, shown last): the popout must still open
over the web page. Red before the fix: the window closed at once, no panel.

--scenario sw-restart (with --freeze-hidden 5 --neighbors 0 --hidden-seconds 75 --cycles 2): hide the
tab until the worker stops, show it, sign in. It needs --extension with a password manager's own
scripts whose worker holds a port and injects them again on each start (2026-11-17: Bitwarden
2026.10.0's fido2 page and content scripts with a background that copies fido2.background.ts start-up;
Bitwarden's code is GPL and stays out of this repository). Red before the fix: the frozen page never
got its port disconnects, the old script copies stayed live beside the new ones, and the get failed
with "Something went wrong."; the page's dataset counters (copies, disconnects) are in result.json.

--scenario agent (no extension): an agent drives the tab (`browser.page.*` with `agent`) and registers a passkey
on the virtual authenticator, then clicks "Use passkey": the fork refuses each WebAuthn request of an agent-driven
tab (cmux_tab_set_webauthn_mode), so registration must fail with NotAllowedError. Every cmux control call marks
the tab agent-driven, so a person's ceremony cannot be driven here; the unit tests hold that a person's tab keeps
passkeys. Red before the fix: the agent registered and signed in (on a person's Mac, a real Touch ID sheet).

Writes result.json, the page's own pictures (DevTools Page.captureScreenshot) and window pictures to
--out. Exit 0 when the page signed in.
"""
import argparse
import base64, functools, http.server, json, os, plistlib, re, socket, subprocess, sys, tempfile, threading, time

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--app", required=True)
parser.add_argument("--out", required=True)
parser.add_argument("--keep", action="store_true", help="leave the app running at the end")
parser.add_argument("--scenario", choices=["popout", "sw-restart", "agent"], default="popout",
                    help="popout: close the extension's popout, expect the fallback sign-in; sw-restart: hide the tab "
                         "until the extension's worker stops, show it again (the worker restarts and injects its "
                         "scripts again), expect one live copy and a sign-in; agent: no extension, an agent's "
                         "register must get NotAllowedError")
parser.add_argument("--extension", help="the extension folder (default: the probe in tests/passkeys/extension-fallback)")
parser.add_argument("--freeze-hidden", default=None, help="browser.freezeHiddenTabs for the run: seconds or off")
parser.add_argument("--hidden-seconds", type=float, default=45, help="sw-restart: how long the tab stays hidden")
parser.add_argument("--neighbors", type=int, default=None, help="browser.keepNeighborTabsAwake for the run (0: the hidden tab may freeze)")
parser.add_argument("--in-home", action="store_true", help="open the page in Home, beside its agent page (a cmux page)")
parser.add_argument("--cycles", type=int, default=1, help="sw-restart: hide and show the tab this many times")
opts = parser.parse_args()
if opts.scenario == "sw-restart" and not opts.extension:
    parser.error("--scenario sw-restart needs --extension: the probe extension holds no port and injects nothing "
                 "again, so it cannot show a lost disconnect")
os.makedirs(opts.out, exist_ok=True)
ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "../../tests/passkeys/extension-fallback"))
APP = os.path.abspath(opts.app)
with open(os.path.join(APP, "Contents/Info.plist"), "rb") as f:
    INFO = plistlib.load(f)
PREFIX = "com.cmuxterm.app.debug."
if not INFO.get("CFBundleIdentifier", "").startswith(PREFIX):
    sys.exit(f"refusing {INFO.get('CFBundleIdentifier')}: not a tagged DEV bundle")
BINARY = os.path.join(APP, "Contents/MacOS", INFO["CFBundleExecutable"])
SOCKET = f"/tmp/cmux-debug-{re.sub(r'[^a-z0-9]+', '-', INFO['CFBundleIdentifier'][len(PREFIX):].lower()).strip('-')}.sock"
RESULT = {"tag": opts.tag, "steps": []}
AGENT = "PasskeyProbeAgent"


def step(name, **fields):
    RESULT["steps"].append({"step": name, **fields})
    print(name, json.dumps(fields)[:600], flush=True)


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
    except (OSError, ValueError) as error:
        return {"error": str(error)}
    return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}


def wait(predicate, seconds, every=0.25):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:  # bounded wait for the app's own state
        try:
            value = predicate()
        except Exception:  # noqa: BLE001 - a reply that is not there yet
            value = None
        if value:
            return value
        time.sleep(every)
    return None


def js(script):
    reply = rpc("browser.page.eval", {"script": script}) or {}
    return reply.get("value") if isinstance(reply, dict) and "error" not in reply else None


def devtools(method, params=None):
    reply = rpc("debug.cef.devtools", {"method": method, "params": params or {}}) or {}
    if reply.get("error"):
        return {"__error": reply["error"]}
    try:
        return json.loads(reply.get("result") or "{}")
    except ValueError:
        return {"raw": reply.get("result")}


def copies():
    """Live `message` listeners on window: each copy of a password manager's page script adds one."""
    reply = devtools("Runtime.evaluate", {"expression": "getEventListeners(window).message.length",
                                          "includeCommandLineAPI": True, "returnByValue": True})
    return ((reply.get("result") or {}).get("value")) if isinstance(reply, dict) else reply


def injected():
    """Counters a password manager's diagnostic copy writes on the page: script copies, port disconnects, worker starts."""
    value = js("JSON.stringify(Object.assign({}, document.documentElement.dataset))")
    return json.loads(value) if value else {}


def hibernation():
    report = rpc("debug.surfaces") or {}
    return report.get("hibernation") if isinstance(report, dict) else report


def click_sign_in():
    rect = json.loads(js("JSON.stringify(document.getElementById('signin').getBoundingClientRect())") or "{}")
    x, y = rect.get("x", 0) + rect.get("width", 0) / 2, rect.get("y", 0) + rect.get("height", 0) / 2
    for kind in ("mousePressed", "mouseReleased"):
        devtools("Input.dispatchMouseEvent", {"type": kind, "x": x, "y": y, "button": "left", "clickCount": 1})


def sign_in():
    js("window.__status = null")
    click_sign_in()
    return wait(lambda: (lambda s: s if s and s != "waiting" else None)(probe().get("status")), 30, 0.5)


def probe():
    value = js("JSON.stringify({log: window.__probe || [], status: window.__status || null, focus: document.hasFocus()})")
    return json.loads(value) if value else {}


def pictures(name):
    # The page's own pixels (its status line) through DevTools.
    shot = devtools("Page.captureScreenshot", {"format": "png"})
    if isinstance(shot, dict) and shot.get("data"):
        with open(os.path.join(opts.out, f"{name}-page.png"), "wb") as f:
            f.write(base64.b64decode(shot["data"]))
    main = rpc("debug.window_snapshot", {"path": os.path.join(opts.out, f"{name}-window.png")})
    popups = rpc("debug.popups", {"snapshot_dir": os.path.join(opts.out, f"{name}-popups")})
    return {"window": main, "popups": [p.get("snapshot") for p in (popups or {}).get("panels") or []]}


def serve():
    handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=ROOT)
    handler.log_message = lambda *args: None
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    # localhost (not 127.0.0.1): a secure context whose name is a valid RP ID.
    return f"http://localhost:{server.server_address[1]}/page.html"


scratch = tempfile.mkdtemp(prefix=f"passkey-fallback-{opts.tag}-")
config = os.path.join(scratch, "cmux.json")
with open(config, "w") as f:
    browser = {}
    if opts.freeze_hidden:
        browser["freezeHiddenTabs"] = opts.freeze_hidden if opts.freeze_hidden == "off" else float(opts.freeze_hidden)
    if opts.neighbors is not None:
        browser["keepNeighborTabsAwake"] = opts.neighbors
    json.dump({"browser": browser} if browser else {}, f)
if os.path.exists(SOCKET):
    os.unlink(SOCKET)
app = subprocess.Popen([BINARY], env={
    "HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_CONFIG_FILE": config,
    "CMUX_NEXT_TEST_WINDOW_SCREEN": "main", "CMUX_NEXT_TEST_WINDOW_FRAME": "60,60,1200,800",
    **({} if opts.scenario == "agent" else {
        "CMUX_NEXT_CEF_LOAD_EXTENSIONS": os.path.abspath(opts.extension) if opts.extension else os.path.join(ROOT, "extension")})},
    stdout=open(os.path.join(opts.out, "app.log"), "w"), stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
signed_in = False
try:
    if not wait(lambda: os.path.exists(SOCKET) and "error" not in (rpc("debug.focus") or {"error": 1}), 180):
        raise SystemExit("the app socket never answered")

    def focused_pane():
        return any(p.get("focused") for w in (rpc("debug.surfaces") or {}).get("windows") or [] for p in w.get("panes") or [])

    # A workspace of its own (not Home, whose agent page is a Chromium page too): the page is the last tab shown,
    # as when a person clicks it. --in-home keeps Home's agent page shown beside it, the last pane shown: an
    # extension's popup window must still open over the web page, never over that cmux page.
    if not opts.in_home:
        rpc("action.run", {"action": "newTab", "origin": "script", "focus": True})
        wait(focused_pane, 60)
        time.sleep(1.0)  # test harness: the new workspace takes the window
    url = serve()
    step("open", reply=rpc("action.run", {"action": "openBrowser.chromium", "args": {"url": url}, "focus": True}))
    if not wait(lambda: js("document.title") == "passkey fallback", 90):
        raise SystemExit("the page did not load in a Chromium tab")
    # The extension's page script wraps navigator.credentials.get in the page (MAIN world) once it is installed.
    wrapped = "!String(navigator.credentials.get).includes('[native code]')"
    if opts.scenario != "agent" and not wait(lambda: js(wrapped), 30):
        js("location.reload()")
        if not wait(lambda: js(wrapped), 30):
            raise SystemExit("the extension's page script is not in the page")
    PAGE_TAB = (((RESULT["steps"][0].get("reply") or {}).get("created")) or [None])[0]
    # Page focus is part of the check: the app must be the active app (a person's click makes it so).
    subprocess.run(["/usr/bin/open", APP], check=False)
    step("activate", active=wait(lambda: (rpc("debug.focus") or {}).get("app_active"), 10))
    if opts.scenario == "agent":
        # Every cmux control call (browser.page.*, debug.cef.devtools) marks the tab agent-driven, so this
        # harness is the agent from its first call: a person's ceremony on the same page is not possible here
        # (the unit tests hold that a person's tab keeps passkeys). The agent registers and signs in.
        touched = rpc("browser.page.eval", {"tab": PAGE_TAB, "agent": AGENT, "script": "document.title"})
        step("agent takes the tab", reply=touched)
        wait(lambda: js("document.title") == "passkey fallback", 30)
        devtools("WebAuthn.enable", {"enableUI": False})
        added = devtools("WebAuthn.addVirtualAuthenticator", {"options": {
            "protocol": "ctap2", "transport": "internal", "hasResidentKey": True, "hasUserVerification": True,
            "isUserVerified": True, "automaticPresenceSimulation": True}})
        step("virtual authenticator", reply=added)
        js("window.__reg = null; register().then(id => window.__reg = 'ok ' + id, e => window.__reg = 'failed ' + e)")
        registered = wait(lambda: js("window.__reg"), 30)
        step("agent registers", result=registered, pictures=pictures("1-register"))
        outcome = None
        if str(registered).startswith("ok"):
            js("window.__status = null")
            clicked = rpc("browser.page.click", {"tab": PAGE_TAB, "agent": AGENT, "selector": "#signin"}, timeout=45)
            outcome = wait(lambda: (lambda v: v if v and v != "waiting" else None)(js("window.__status")), 30, 0.5)
            step("agent clicks Use passkey", reply=clicked, outcome=outcome, pictures=pictures("2-agent"))
        refused = str(registered).startswith("failed NotAllowedError") and outcome is None
        RESULT["outcome"] = {"register": registered, "sign_in": outcome}
        print("PASS the agent's passkey requests were refused" if refused
              else f"FAIL register={registered!r} sign_in={outcome!r}", flush=True)
        raise SystemExit(0 if refused else 1)
    devtools("WebAuthn.enable", {"enableUI": False})
    added = devtools("WebAuthn.addVirtualAuthenticator", {"options": {
        "protocol": "ctap2", "transport": "internal", "hasResidentKey": True, "hasUserVerification": True,
        "isUserVerified": True, "automaticPresenceSimulation": True}})
    step("virtual authenticator", reply=added)
    js("window.__reg = null; register().then(id => window.__reg = 'ok ' + id, e => window.__reg = 'failed ' + e)")
    registered = wait(lambda: js("window.__reg"), 30)
    step("register", result=registered)
    if not str(registered).startswith("ok"):
        raise SystemExit("could not register on the virtual authenticator")
    step("before click", focus=rpc("debug.focus"), page=probe(), copies=copies(), pictures=pictures("1-page"))
    if opts.scenario == "sw-restart":
        first = sign_in()
        step("sign-in, tab never hidden", outcome=first, copies=copies(), injected=injected())
        for cycle in range(opts.cycles):
            other = (rpc("action.run", {"action": "openBrowser.chromium", "args": {"url": "about:blank"}, "focus": True}) or {})
            step("hide the tab", cycle=cycle, reply=other)
            hidden_until = time.time() + opts.hidden_seconds
            while time.time() < hidden_until:
                time.sleep(min(10, max(0, hidden_until - time.time())))  # test harness: sample while the worker stops
                step("hidden", cycle=cycle, hibernation=hibernation())
            step("show the tab", cycle=cycle, reply=rpc("tab.focus", {"tab": PAGE_TAB}) if PAGE_TAB else "no tab id")
            wait(lambda: js("document.title") == "passkey fallback", 20)
            time.sleep(3)  # test harness: the restarted worker injects its scripts
            step("shown", cycle=cycle, copies=copies(), injected=injected(), hibernation=hibernation())
        live = copies()
        second = sign_in()
        signed_in = str(first).startswith("signed in") and str(second).startswith("signed in")
        step("sign-in after the worker restarted", outcome=second, copies=live, injected=injected(), signed_in=signed_in, page=probe(),
             pictures=pictures("3-after-restart"))
        raise SystemExit(0 if signed_in else 1)
    click_sign_in()
    # The panel's own URL can lag (about:blank) while its extension page loads: any new popup panel is the popout.
    panel = wait(lambda: (rpc("debug.popups") or {}).get("panels"), 20)
    cef = rpc("debug.cef") or {}
    step("popout", shown=bool(panel), panels=panel, popups_reply=rpc("debug.popups"), page=probe(),
         popup_windows=cef.get("popup_windows"), window_requests=cef.get("window_requests"), pictures=pictures("2-popout"))
    if not panel:
        raise SystemExit("the extension's popout did not show")
    time.sleep(1.0)  # test harness: the popout page settles, as a person reads it
    step("close popout", reply=rpc("debug.popups", {"action": "close"}))
    outcome = wait(lambda: (lambda s: s if s and s != "waiting" else None)(probe().get("status")), 30, 0.5)
    after = probe()
    signed_in = str(outcome).startswith("signed in")
    step("after close", outcome=outcome, signed_in=signed_in, page=after, focus=rpc("debug.focus"),
         panels=(rpc("debug.popups") or {}).get("panels"), pictures=pictures("3-after-close"))
finally:
    RESULT["signed_in"] = signed_in
    with open(os.path.join(opts.out, "result.json"), "w") as f:
        json.dump(RESULT, f, indent=1)
    if not opts.keep:
        rpc("action.run", {"action": "app quit"})
        try:
            app.wait(timeout=20)
        except subprocess.TimeoutExpired:
            app.terminate()
print("PASS" if signed_in else "FAIL", "signed in after the popout closed" if signed_in else "no sign-in after the popout closed")
sys.exit(0 if signed_in else 1)
