#!/usr/bin/env python3
"""Live check: bookmark rows in an incognito omnibar (plans/cmux-next/bookmarks.md 2 and 3, cx-d0d.37).

  scripts/cmux-next/bookmarks-incognito-omnibar-live.py --tag <tag> [--out DIR] [--app PATH]
  scripts/cmux-next/bookmarks-incognito-omnibar-live.py --socket PATH   (an app already running, e.g. a capture slot)

Launches the tagged app (no activation, automation socket, empty config),
adds a bookmark to the default profile through `bookmark.add`, then types a
word of its title into the omnibar:

  1. of a normal window: a bookmark row offers it (the baseline);
  2. of an incognito window: a bookmark row offers it too, since incognito
     windows read the default profile's bookmarks.

GUI host only (a capture mini or the M1 Max through nx-remote). An app it
launched is quit and the tag's daemons stopped at the end; one it attached to
with --socket keeps running. Exits 1 when a check fails.
"""
import argparse, glob, json, os, plistlib, socket, subprocess, sys, tempfile, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tag_teardown import TagTeardown  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--tag")
parser.add_argument("--socket", help="attach to the app serving this automation socket instead of launching one")
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or tempfile.mkdtemp(prefix="bookmarks-incognito-"))
parser.add_argument("--app", help="tagged .app (default: found in DerivedData)")
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)

if not opts.socket and not opts.tag:
    parser.error("--tag or --socket is required")
SOCKET = opts.socket or f"/tmp/cmux-debug-{opts.tag}.sock"
# A word no history or search suggestion offers, so only the bookmark can match it.
WORD = f"zebracrumb{os.getpid()}"
URL = f"https://example.com/{WORD}"
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


def quiet_wait(predicate, seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:  # bounded wait for the app's own state
        value = predicate()
        if value:
            return value
        time.sleep(0.25)
    return None


def wait_for(predicate, what, seconds=20):
    value = quiet_wait(predicate, seconds)
    if not value:
        check(False, f"timed out: {what}")
    return value


def windows():
    """Window controllers as debug.focus reports them: [{id, model: {pane, ...}}]."""
    report = rpc("debug.focus") or {}
    return report.get("windows") or [] if isinstance(report, dict) else []


def focused_pane(window):
    entry = next((w for w in windows() if w.get("id") == window), None)
    return ((entry or {}).get("model") or {}).get("pane")


def omnibar(window):
    reply = rpc("debug.omnibar", {"window": window}) or {}
    return reply if isinstance(reply, dict) else {}


def browser_omnibar(window):
    """An omnibar in `window`'s focused pane: the one shown, else a Chromium tab opened in the
    active window (the one just opened)."""
    if "error" not in omnibar(window):
        return True
    print("omnibar", window, omnibar(window).get("error"))
    print("open a Chromium tab for", window, focused_pane(window),
          rpc("action.run", {"action": "tab new-chromium", "args": {"url": "about:blank"}, "focus": True}), flush=True)
    return quiet_wait(lambda: "error" not in omnibar(window), 60)


def bookmark_rows(window):
    """Type WORD (no Return) and wait for a bookmark row naming it; the row kinds seen last."""
    typed = rpc("debug.omnibar_type", {"window": window, "text": WORD, "commit": False}) or {}
    if not typed.get("typed"):
        print(f"note: the omnibar of {window} did not start editing: {typed}", flush=True)

    def found():
        report = omnibar(window)
        kinds = (report.get("card") or {}).get("row_kinds") or []
        rows = report.get("rows") or []
        return [row for kind, row in zip(kinds, rows) if kind == "bookmark" and WORD in row]
    rows = quiet_wait(found, 10)
    report = omnibar(window)
    print(f"{window}: rows {report.get('rows')} kinds {(report.get('card') or {}).get('row_kinds')}", flush=True)
    for _ in range(4):  # Escape closes the popup, then reverts the text
        if omnibar(window).get("phase") in ("idle", "focused"):
            break
        rpc("debug.key", {"key": "escape"})
    return rows


app = teardown = None
if not opts.socket:
    APP = opts.app or next(iter(sorted(glob.glob(os.path.expanduser(
        f"~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/cmux DEV {opts.tag}.app")))), None)
    if not APP:
        sys.exit(f"no tagged app for {opts.tag}")
    with open(os.path.join(APP, "Contents/Info.plist"), "rb") as f:
        BINARY = os.path.join(APP, "Contents/MacOS", plistlib.load(f)["CFBundleExecutable"])
    SCRATCH = tempfile.mkdtemp(prefix=f"bookmarks-incognito-{opts.tag}-")
    CONFIG = os.path.join(SCRATCH, "cmux.json")
    with open(CONFIG, "w") as f:
        f.write("{}\n")
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
bookmark = None
try:
    wait_for(lambda: os.path.exists(SOCKET) and "error" not in (rpc("debug.focus") or {"error": 1}), "app socket", 180)
    if not windows():
        rpc("action.run", {"action": "newWindow", "origin": "script"})
    normal = (wait_for(lambda: windows(), "a window", 60) or [{}])[0].get("id")
    if not quiet_wait(lambda: focused_pane(normal), 15):
        print("run newTab", rpc("action.run", {"action": "newTab", "origin": "script", "focus": True}), flush=True)
    wait_for(lambda: focused_pane(normal), "a focused pane", 60)

    added = rpc("action.run", {"action": "bookmark.add", "args": {"url": URL, "title": f"Test {WORD} page", "profile": "default"}})
    bookmark = wait_for(lambda: next((b for b in (rpc("bookmark.list", {"profile": "default", "text": WORD}) or {}).get("bookmarks") or []
                                      if b.get("url") == URL), None), f"the bookmark is listed ({added})", 20)

    # 1. A normal window (the baseline).
    if wait_for(lambda: browser_omnibar(normal), "an omnibar in the normal window", 90):
        rows = bookmark_rows(normal)
        check(bool(rows), f"normal omnibar offers the bookmark: {rows}")

    # 2. An incognito window.
    before = {w.get("id") for w in windows()}
    print("newIncognitoWindow", rpc("action.run", {"action": "newIncognitoWindow", "origin": "script"}), flush=True)
    incognito = (wait_for(lambda: [w.get("id") for w in windows() if w.get("id") not in before],
                          "the incognito window", 60) or [None])[0]
    if incognito and wait_for(lambda: browser_omnibar(incognito), "an omnibar in the incognito window", 90):
        rows = bookmark_rows(incognito)
        check(bool(rows), f"incognito omnibar offers the default profile's bookmark: {rows}")
finally:
    if bookmark:
        rpc("action.run", {"action": "bookmark.remove", "args": {"bookmark": URL, "profile": "default"}})
    if app:
        rpc("action.run", {"action": "quitEndSessions"})
        try:
            app.wait(timeout=20)
        except subprocess.TimeoutExpired:
            app.kill()  # the exact PID this script started
            app.wait()
        teardown.end()

print(f"{len(failures)} failure(s); artifacts in {opts.out}")
sys.exit(1 if failures else 0)
