#!/usr/bin/env python3
"""Live check: Chromium internal pages on a tagged build (spec decision CHROME-INTERNAL-PAGES, cx-ldj).

  scripts/cmux-next/chrome-internal-pages-live.py --tag <tag> [--out DIR] [--app PATH]

Launches the tagged app (no activation, automation socket, empty config) and
drives the person's paths through the debug socket only, then the agent path:

  1. New Tab field: `chrome://extensions` (no trailing slash) + Return opens a
     Chromium tab on Chromium's canonical `chrome://extensions/`;
  2. omnibar: `chrome://ver` offers a `chrome://version` row;
  3. omnibar: `CHROME://Version` loads `chrome://version/`, and the omnibar
     then shows `chrome://version` with its scheme;
  4. omnibar: `about:history` shows cmux's History page, not Chromium's;
  5. omnibar: `chrome://settings` opens Settings > Browser;
  6. agent path (browser.page.*): navigate to `chrome://flags` is refused
     (`forbidden`), and the tab, now agent-driven, leaves `chrome://version`.

Saves a window snapshot (debug.window_snapshot, Chromium pages composited)
after steps 1, 3, 4, 5 and 6. GUI host only (cmux-lawrence-2 or the M1 Max
through nx-remote). Quits the app and stops the tag's daemons at the end.
Exits 1 when a check fails.
"""
import argparse, glob, json, os, plistlib, socket, subprocess, sys, tempfile, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tag_teardown import TagTeardown  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or tempfile.mkdtemp(prefix="chrome-internal-pages-"))
parser.add_argument("--app", help="tagged .app (default: found in DerivedData)")
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)

APP = opts.app or next(iter(sorted(glob.glob(os.path.expanduser(
    f"~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/cmux DEV {opts.tag}.app")))), None)
if not APP:
    sys.exit(f"no tagged app for {opts.tag}")
with open(os.path.join(APP, "Contents/Info.plist"), "rb") as f:
    BINARY = os.path.join(APP, "Contents/MacOS", plistlib.load(f)["CFBundleExecutable"])
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
SCRATCH = tempfile.mkdtemp(prefix=f"chrome-internal-{opts.tag}-")
CONFIG = os.path.join(SCRATCH, "cmux.json")
with open(CONFIG, "w") as f:
    f.write("{}\n")
failures = []


def check(ok, what):
    print(("ok   " if ok else "FAIL ") + what, flush=True)
    if not ok:
        failures.append(what)


def call(method, params=None, timeout=30):
    """The raw reply: {"ok": true, "result": ...} or {"ok": false, "error": {...}}."""
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
        return json.loads(buf)
    except (OSError, ValueError) as error:
        return {"ok": False, "error": {"code": "socket", "message": str(error)}}


def rpc(method, params=None):
    reply = call(method, params)
    return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}


def wait_for(predicate, what, seconds=20):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:  # bounded wait for the app's own state
        value = predicate()
        if value:
            return value
        time.sleep(0.25)
    check(False, f"timed out: {what}")
    return None


def chromium_tabs():
    """Shown Chromium tabs: [{tab, pane, url, title}]."""
    report = rpc("debug.cef") or {}
    return report.get("devtools") or [] if isinstance(report, dict) else []


def focused_pane():
    for window in (rpc("debug.surfaces") or {}).get("windows") or []:
        for pane in window.get("panes") or []:
            if pane.get("focused"):
                return pane
    return None


def chromium_url():
    """The URL of the Chromium page in the focused pane, or None."""
    pane = focused_pane()
    for tab in chromium_tabs():
        if pane and tab.get("pane") == pane.get("pane"):
            return tab.get("url")
    return None


def omnibar(params=None):
    return rpc("debug.omnibar", params) or {}


def snapshot(name):
    reply = rpc("debug.window_snapshot", {"path": os.path.join(opts.out, f"{name}.png")})
    keys = ("method", "chromium_pages", "chromium_pages_composited", "refusal_hud", "path")
    print("snapshot", name, {k: reply.get(k) for k in keys} if isinstance(reply, dict) else reply, flush=True)


def quiet_wait(predicate, seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:  # bounded wait for the app's own state
        value = predicate()
        if value:
            return value
        time.sleep(0.25)
    return None


def new_tab_submit(text):
    """The person's New Tab field: open the page, wait until its field has focus, type `text` key by
    key, and press Return once the field holds all of it. Test workaround for cx-9fl (keys typed into
    a New Tab page that is still starting are lost, even after its field has focus): retype, at most
    3 times, after deleting what arrived."""
    def field():
        f = rpc("debug.new_tab", {"action": "field"})
        return f if isinstance(f, dict) and "error" not in f else {}

    rpc("debug.new_tab", {"action": "open_and_type", "text": ""})
    if not quiet_wait(lambda: field() if field().get("focused") and field().get("text") == "" else None, 30):
        print(f"note: New Tab field not ready: {field()}", flush=True)
    for attempt in range(3):
        for character in text:
            rpc("debug.key", {"key": character})
        if quiet_wait(lambda: field().get("text") == text or None, 5):
            break
        arrived = field().get("text") or ""
        print(f"note: cx-9fl: New Tab field held {arrived!r} after typing {text!r} (attempt {attempt + 1})", flush=True)
        for _ in arrived:
            rpc("debug.key", {"key": "delete"})
        quiet_wait(lambda: field().get("text") == "" or None, 5)
    rpc("debug.key", {"key": "return"})


def type_in_omnibar(text, commit=True):
    return rpc("debug.omnibar_type", {"text": text, "commit": commit}) or {}


teardown = TagTeardown(APP)
teardown.install()
if os.path.exists(SOCKET):
    os.unlink(SOCKET)
app = subprocess.Popen([BINARY], env={
    "HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
    "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": CONFIG,
    "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1200,800"},
    stdout=open(os.path.join(opts.out, "app.log"), "w"), stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
print(f"app pid {app.pid}, scratch {SCRATCH}, out {opts.out}", flush=True)
try:
    wait_for(lambda: os.path.exists(SOCKET) and "error" not in (rpc("debug.focus") or {"error": 1}), "app socket", 180)
    if not (rpc("debug.surfaces") or {}).get("windows"):
        rpc("action.run", {"action": "newWindow", "origin": "script"})
    # A fresh launch can open on Home with no workspace: make one, so a pane exists for the New Tab page.
    if not quiet_wait(focused_pane, 15):
        print("run newTab", rpc("action.run", {"action": "newTab", "origin": "script", "focus": True}), flush=True)
    wait_for(focused_pane, "a focused pane", 60)

    # 1. The New Tab field, no trailing slash.
    new_tab_submit("chrome://extensions")
    url = wait_for(lambda: chromium_url() if (chromium_url() or "").startswith("chrome://extensions") else None,
                   "a Chromium tab on chrome://extensions", 90)
    check(url == "chrome://extensions/", f"New Tab chrome://extensions loads the canonical URL: {url}")
    if url is None:
        print(f"note: focused pane {focused_pane()}; chromium tabs {chromium_tabs()}", flush=True)
    wait_for(lambda: any((t.get("title") or "") for t in chromium_tabs()), "the extensions page title", 20)
    snapshot("1-extensions-no-slash")

    # 2. Completion and display (in a Chromium tab, also when step 1 failed).
    if not chromium_url():
        new_tab_submit("chrome://version")
        wait_for(lambda: chromium_url(), "a Chromium tab for the omnibar steps", 90)
    type_in_omnibar("chrome://ver", commit=False)
    # Rows arrive from the suggestion actor after the keystroke.
    rows = wait_for(lambda: [r for r in omnibar().get("rows") or [] if "chrome://version" in r], "a chrome://version row", 10)
    check(bool(rows), f"chrome://ver offers chrome://version: {omnibar().get('rows')}")
    # Escape closes the popup first, then reverts the text.
    for _ in range(4):
        if omnibar().get("phase") in ("idle", "focused"):
            break
        rpc("debug.key", {"key": "escape"})

    # 3. Case and canonical form.
    type_in_omnibar("CHROME://Version")
    url = wait_for(lambda: chromium_url() if (chromium_url() or "").startswith("chrome://version") else None,
                   "chrome://version", 30)
    check(url == "chrome://version/", f"CHROME://Version loads chrome://version/: {url}")
    # After a commit the field is not edited: it shows the display text, with the scheme.
    deadline = time.monotonic() + 10
    while omnibar().get("phase") not in ("idle", "committing") and time.monotonic() < deadline:
        time.sleep(0.25)  # bounded wait for the reducer to leave editing
    shown = omnibar().get("text")
    check(shown == "chrome://version", f"the omnibar shows chrome://version with its scheme: {shown!r}")
    time.sleep(1.0)  # paint before the snapshot (screenshot only)
    snapshot("2-version")

    # 6. The agent path (browser.page.*, the focused tab) on this Chromium page. It marks the tab
    #    agent-driven, so step 4 opens a new person tab.
    # The first agent op on a person's tab rebuilds it (`unavailable`, retry), and an agent-driven
    # tab leaves Chromium's own page (CEFAgentURLGuard).
    nav = call("browser.page.navigate", {"url": "chrome://flags"})
    if (nav.get("error") or {}).get("code") == "unavailable":
        wait_for(lambda: chromium_url() is not None or None, "the rebuilt page", 20)
        nav = call("browser.page.navigate", {"url": "chrome://flags"})
    code = (nav.get("error") or {}).get("code")
    check(not nav.get("ok") and code == "forbidden", f"agent navigate to chrome://flags is refused: {nav}")
    left = wait_for(lambda: not (chromium_url() or "").startswith("chrome://") or None, "the agent-driven tab leaves chrome://", 20)
    check(bool(left) and not (chromium_url() or "").startswith("chrome://flags"),
          f"the agent-driven tab shows no Chromium page: {chromium_url()}")
    snapshot("3-agent-refused")

    # 4. A page cmux shows itself: a new person tab, so the agent-driven tab above is not reused.
    new_tab_submit("chrome://extensions")
    wait_for(lambda: (chromium_url() or "").startswith("chrome://extensions"), "a second extensions tab", 60)
    type_in_omnibar("about:history")
    left = wait_for(lambda: chromium_url() is None or None, "the pane leaves Chromium for the History page", 20)
    check(bool(left) and not any((t.get("url") or "").startswith("chrome://history") for t in chromium_tabs()),
          f"about:history shows cmux's History page, not Chromium's: {chromium_tabs()}")
    shown = omnibar().get("text")
    check(shown in ("history", "cmux://history"), f"the omnibar names the History page: {shown!r}")
    time.sleep(1.0)
    snapshot("4-about-history")

    # 5. chrome://settings opens Settings > Browser.
    new_tab_submit("chrome://settings")
    page = wait_for(lambda: (lambda s: s if isinstance(s, dict) and s.get("painted") else None)(
        rpc("debug.page", {"page": "cmux.settings"})), "Settings painted", 40)
    check(bool(page), "chrome://settings opens Settings")
    check(not any((t.get("url") or "").startswith("chrome://settings") for t in chromium_tabs()),
          f"no Chromium settings tab: {chromium_tabs()}")
    time.sleep(1.0)
    snapshot("5-settings")
finally:
    rpc("action.run", {"action": "quitEndSessions"})
    try:
        app.wait(timeout=20)
    except subprocess.TimeoutExpired:
        app.kill()  # the exact PID this script started
        app.wait()
    teardown.end()

print(f"{len(failures)} failure(s); artifacts in {opts.out}")
sys.exit(1 if failures else 0)
