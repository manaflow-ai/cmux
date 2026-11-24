#!/usr/bin/env python3
"""Live proof for u9489 (Oct 21): an index.html tab's right-click rows in a tagged app.

  send   the tab menu's Send Message… (home.messageAbout on the tab): the Home chat opens with a
         link to the tab in its message box. Window snapshots at 0, 120, 300, 700 and 1500 ms
         after the run show whether the dimmed region follows the chat's layout.
  text   the tab menu's Open as Text (file.openAsText): the same file opens in the code editor
         page (Monaco), next to the rendered page; the tab menu's rows are listed.

Runs as an `nx-remote --needs gui --app-from-fleet cmux --tag TAG --ref SHA` job (reads NX_APP,
NX_APP_TAG, NX_APP_STOP, NX_ARTIFACTS). Writes PNGs and html-file-menu-live.json to --out.
Exit 0 all checks passed; 1 a check failed; 2 the app did not come up.
Usage: html-file-menu-live.py [--tag TAG] [--app APP] [--out DIR] [--only send,text] [--reduce-motion]
"""
import argparse, hashlib, json, os, socket, subprocess, sys, tempfile, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from state_wait import wait_until, wait_stable  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("--tag", default=os.environ.get("NX_APP_TAG"))
ap.add_argument("--app", default=os.environ.get("NX_APP"))
ap.add_argument("--out", default=os.environ.get("NX_ARTIFACTS", tempfile.mkdtemp(prefix="html-file-menu-")))
ap.add_argument("--only", default="menu,text")
ap.add_argument("--classic", action="store_true", help="CMUX_NEXT_CLASSIC_HOME=1 (Home as a top page, not the dock)")
opts = ap.parse_args()
if not opts.tag or not opts.app:
    sys.exit("html-file-menu-live.py: --tag and --app (or NX_APP_TAG and NX_APP) are required")
os.makedirs(opts.out, exist_ok=True)
ONLY = set(opts.only.split(","))
SOCK = f"/tmp/cmux-debug-{opts.tag}.sock"
macos = os.path.join(opts.app, "Contents/MacOS")
BINARY = next((os.path.join(macos, n) for n in sorted(os.listdir(macos)) if n.startswith("cmux")), os.path.join(macos, "cmux DEV"))
SCRATCH = tempfile.mkdtemp(prefix="hfm-", dir="/tmp")
FIXTURE = os.path.join(SCRATCH, "site")
INDEX = os.path.join(FIXTURE, "index.html")
CONFIG = os.path.join(SCRATCH, "cmux.json")
GHOSTTY = os.path.join(SCRATCH, "ghostty")
ROWS, launched = [], []
CUA = os.path.expanduser("~/.local/bin/cua-driver")


def say(*parts):
    print(*parts, flush=True)


def row(name, ok, observed):
    ROWS.append({"check": name, "ok": bool(ok), "observed": observed})
    say("PASS" if ok else "FAIL", name, json.dumps(observed)[:600])


def rpc(method, params=None, timeout=30):
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
        conn.connect(SOCK)
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


def wait(predicate, timeout):
    deadline = time.time() + timeout
    while time.time() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.2)  # test harness poll, not app code
    return None


def pixels():
    """A hash of a fresh window snapshot (scratch file), for changes no socket state reports (the menu's highlight)."""
    path = os.path.join(SCRATCH, "settle.png")
    if (rpc("debug.window_snapshot", {"path": path}) or {}).get("error"):
        return None
    with open(path, "rb") as handle:
        return hashlib.sha1(handle.read()).hexdigest()


# The captures are best effort: a wait that times out says what never happened and the run goes on.
def until(predicate, what, timeout=15):
    value = wait_until(predicate, what, timeout=timeout, interval=0.1, raise_on_timeout=False)
    if not value:
        say(f"wait: {what} did not happen in {timeout} s; going on")
    return value


def settle(get, what, timeout=10, reads=4):
    return wait_stable(get, what, timeout=timeout, interval=0.1, reads=reads, raise_on_timeout=False)


def changed_then_settled(before, get, what, timeout=15):
    """Until `get()` moved off `before`, then until it holds still."""
    until(lambda: get() != before, what, timeout)
    return settle(get, what)


def surfaces_json(text=False):
    return json.dumps((rpc("debug.surfaces", {"text": True} if text else {}) or {}).get("windows"), sort_keys=True)


def snapshot(name, desktop=True):
    path = os.path.join(opts.out, f"{name}.png")
    reply = rpc("debug.window_snapshot", {"path": path})
    say(f"snapshot {name}: {(reply or {}).get('path') or reply}")
    if desktop and os.path.exists(CUA):
        cua("get_desktop_state", {"screenshot_out_file": os.path.join(opts.out, f"{name}-desktop.png")})
    return path


def tabs():
    found = []
    def walk(node):
        if isinstance(node, dict):
            if node.get("tab_id") or (node.get("id", "").startswith("tab_") if isinstance(node.get("id"), str) else False):
                found.append(node)
            for value in node.values():
                walk(value)
        elif isinstance(node, list):
            for value in node:
                walk(value)
    walk(rpc("debug.surfaces") or {})
    return found


def tab_showing(fragment):
    for t in tabs():
        text = json.dumps(t)
        if fragment in text:
            return t
    return None


def tab_id(t):
    return t.get("tab_id") or t.get("id")


def make_fixture():
    os.makedirs(FIXTURE, exist_ok=True)
    open(INDEX, "w").write("<!doctype html><html><head><title>Gallery index</title>"
                           "<style>body{font:15px -apple-system;margin:24px;background:#f4f1ea}"
                           "h1{font-size:22px}</style></head><body><h1>Gallery index</h1>"
                           "<p>A rendered HTML page. Its source is plain text.</p></body></html>\n")
    open(GHOSTTY, "w").write("")
    open(CONFIG, "w").write(json.dumps({"files": {"roots": [FIXTURE]}, "editor": {"autoSave": "off"}}))


def launch():
    if os.path.exists(SOCK):
        os.unlink(SOCK)
    env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
           "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": CONFIG, "CMUX_NEXT_GHOSTTY_CONFIG": GHOSTTY,
           "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1400,880", "ACPMUX_AGENT_LAUNCH": "deny", "NX_REMOTE": "1",
           "CMUX_NEXT_CHIEF_HOME": os.path.join(SCRATCH, "chief")}
    if opts.classic:
        env["CMUX_NEXT_CLASSIC_HOME"] = "1"
    app = subprocess.Popen([BINARY], env=env, stdout=open(os.path.join(SCRATCH, "app.log"), "a"), stderr=subprocess.STDOUT,
                           stdin=subprocess.DEVNULL, cwd=FIXTURE)
    launched.append(app)
    say(f"launched pid {app.pid}")
    if not wait(lambda: os.path.exists(SOCK) and (rpc("debug.surfaces") or {}).get("windows"), 120):
        say("FAIL the tagged app did not come up")
        finish(2)
    settle(surfaces_json, "the first window's surfaces")
    before = surfaces_json(text=True)
    say("workspace new:", json.dumps(rpc("action.run", {"action": "workspace new", "args": {"cwd": FIXTURE, "focus": True}, "origin": "script"}))[:200])
    # The new workspace shows, then its terminal's text holds still (the shell's prompt drew).
    changed_then_settled(before, lambda: surfaces_json(text=True), "the new workspace's shell")


def open_index():
    # origin user: the person's own open, so the page renders in a browser tab (FilePageOpener).
    reply = rpc("action.run", {"action": "file open", "args": {"path": INDEX, "where": "tab"}, "focus": True, "origin": "user"})
    say("file open:", json.dumps(reply)[:300])
    return wait(lambda: tab_showing("index.html"), 20)


def cua(tool, args):
    r = subprocess.run([CUA, "call", tool, json.dumps(args)], capture_output=True, text=True, timeout=60)
    try:
        return json.loads(r.stdout)
    except ValueError:
        return {"raw": r.stdout[-400:], "err": r.stderr[-400:]}


def cua_window(pid):
    windows = cua("list_windows", {"pid": pid}).get("windows", [])
    size = lambda w: (w.get("bounds") or {}).get("width", 0) * (w.get("bounds") or {}).get("height", 0)
    return max(windows, key=size)["window_id"] if windows else None


def menu_items(state):
    """The open context menu's item titles (the first AXMenu outside the menu bar)."""
    import re
    lines = state.get("tree_markdown", "").split("\n")
    for i, line in enumerate(lines):
        if "] AXMenu " in line and "AXMenuBar" not in lines[max(0, i - 1)]:
            depth = len(line) - len(line.lstrip())
            items = []
            for r in lines[i + 1:]:
                indent = len(r) - len(r.lstrip())
                if indent <= depth:
                    break
                match = re.match(r'- (?:\[\d+\] )?AXMenuItem "([^"]*)"', r.strip())
                if indent == depth + 2 and match:
                    items.append(match.group(1))
            return items
    return []


def drive(action, **extra):
    return rpc("debug.home.drive", {"action": action, **extra}) or {}


def attachment_row():
    rows = drive("rows")
    found = [r for r in rows.get("rows", []) if r.get("outgoing") and r.get("kind") not in ("text", "status", "time")]
    return (found[-1] if found else None), rows


def run_menu():
    """u9489: right-click my index.html attachment in the Home chat, close the menu, send a message."""
    say("fixture:", json.dumps(rpc("debug.home_native_fixture.open", {"new": True}))[:300])
    wait(lambda: drive("geometry").get("ok"), 30)
    settle(lambda: drive("rows"), "the transcript's rows")
    before = drive("geometry")
    say("attach:", json.dumps(rpc("debug.home.attach", {"path": INDEX, "via": "drop"})))
    # The tile grows the field: the geometry changes, then holds.
    changed_then_settled(before, lambda: drive("geometry"), "the index.html tile in the field")
    say("send attachment:", json.dumps(drive("send")))
    row_, rows = wait(lambda: (lambda r: r if r[0] else None)(attachment_row()), 20) or (None, drive("rows"))
    say("rows:", json.dumps(rows)[:1500])
    row("index.html attachment shows in the transcript", row_ is not None, row_)
    if not row_:
        return
    pid = launched[0].pid
    snapshot("menu-0-before")
    b = row_["balloon"]
    # rows: window points, bottom-left origin; debug.mouse: window points, top-left origin.
    x, y = b["x"] + b["width"] / 2, rows["windowHeight"] - (b["y"] + b["height"] / 2)
    before = pixels()
    say("right click:", json.dumps(rpc("debug.mouse", {"x": x, "y": y, "action": "click", "button": "right"}, timeout=5)))
    open_pixels = changed_then_settled(before, pixels, "the menu's highlight to fade in")
    cap = os.environ.get("NX_CAPTURE")
    if cap:
        r = subprocess.run(["bash", cap, "shot", "--pid", str(pid), "--with-popups", "--out", os.path.join(opts.out, "menu-1-open.png")],
                           capture_output=True, text=True, timeout=60)
        say("capture menu-1-open:", r.returncode, r.stderr.strip()[:200])
    say("debug.menu:", json.dumps(drive("menu"))[:600])
    rpc("debug.key", {"key": "escape"}, timeout=5)
    changed_then_settled(open_pixels, pixels, "the menu and its highlight to close")
    snapshot("menu-2-closed")
    drive("focus")
    drive("type", text="Sending a message after the right-click.")
    say("send:", json.dumps(drive("send")))
    start = time.time()
    for ms in (100, 300, 700, 1500):
        delay = start + ms / 1000 - time.time()
        if delay > 0:
            time.sleep(delay)  # test harness: timed captures
        snapshot(f"menu-3-sent-{ms:04d}ms")
    say("rows after send:", json.dumps(drive("rows"))[:1500])


def run_held():
    """The bug's moment: the menu (and its darker area) is open while a message lands and moves the rows."""
    rows = drive("rows")
    row_ = next((r for r in reversed(rows.get("rows", [])) if r.get("outgoing") and r.get("kind") == "part"), None)
    if not row_:
        row("an attachment row for the held menu", False, rows)
        return
    b = row_["balloon"]
    x, y = b["x"] + b["width"] / 2, rows["windowHeight"] - (b["y"] + b["height"] / 2)
    before = pixels()
    rpc("debug.mouse", {"x": x, "y": y, "action": "click", "button": "right"}, timeout=5)
    changed_then_settled(before, pixels, "the held menu's highlight to fade in")
    # A reply from the Chief lands while the menu is open: the rows move up.
    before_rows = drive("rows")
    say("stream:", json.dumps(rpc("debug.home.drive", {"action": "stream", "text": "Got it, opening the page now.", "done": True})))
    changed_then_settled(before_rows, lambda: drive("rows"), "the reply's row to land")
    open_pixels = settle(pixels, "the transcript to stop moving")
    cap = os.environ.get("NX_CAPTURE")
    if cap:
        r = subprocess.run(["bash", cap, "shot", "--pid", str(launched[0].pid), "--with-popups", "--out",
                            os.path.join(opts.out, "held-1-menu-open-after-reply.png")], capture_output=True, text=True, timeout=60)
        say("capture held:", r.returncode, r.stderr.strip()[:200])
    cua("get_desktop_state", {"screenshot_out_file": os.path.join(opts.out, "held-1-menu-open-after-reply-desktop.png")})
    rpc("debug.key", {"key": "escape"}, timeout=5)
    changed_then_settled(open_pixels, pixels, "the held menu to close")
    snapshot("held-2-closed")


def editor_text():
    """The text of every live code editor page."""
    texts = []
    for entry in (rpc("debug.page", {"page": "cmux.editor", "action": "list"}) or {}).get("pages") or []:
        if not entry.get("parked"):
            texts.append((rpc("debug.page", {"page": "cmux.editor", "action": "state", "instance": entry.get("instance")}) or {}).get("text") or "")
    return "\n".join(texts).replace("\u00a0", " ")  # the code editor draws spaces as no-break spaces


def run_text():
    """The code editor page with index.html's source: the page Open as Text opens (FilePageOpener.route
    asText -> .editor). The socket's open of a web page by a script takes the same editor route."""
    reply = rpc("action.run", {"action": "file open", "args": {"path": INDEX, "where": "tab"}, "focus": True, "origin": "script"})
    say("file open (script, editor route):", json.dumps(reply)[:300])
    editor = wait(lambda: next((x for x in (rpc("debug.filepages") or {}).get("tabs", [])
                                if x.get("kind") == "editor" and x.get("file") == INDEX and x.get("has_page")), None), 30)
    row("index.html shows as text in the code editor", editor is not None, editor)
    # Monaco drew the file's source, then the window holds still.
    until(lambda: "Gallery index" in editor_text(), "the code editor to show index.html's source", 30)
    settle(pixels, "the code editor page")
    snapshot("text-editor")


def finish(code):
    with open(os.path.join(opts.out, "html-file-menu-live.json"), "w") as f:
        json.dump({"rows": ROWS}, f, indent=2)
    stop = os.environ.get("NX_APP_STOP")
    if stop:
        subprocess.run([stop], timeout=120)
    else:
        for app in launched:
            app.terminate()
    sys.exit(code)


make_fixture()
launch()
if "menu" in ONLY:
    run_menu()
if "held" in ONLY:
    run_held()
if "text" in ONLY:
    run_text()
finish(0 if all(r["ok"] for r in ROWS) else 1)
