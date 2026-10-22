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
import argparse, json, os, socket, subprocess, sys, tempfile, time

ap = argparse.ArgumentParser()
ap.add_argument("--tag", default=os.environ.get("NX_APP_TAG"))
ap.add_argument("--app", default=os.environ.get("NX_APP"))
ap.add_argument("--out", default=os.environ.get("NX_ARTIFACTS", tempfile.mkdtemp(prefix="html-file-menu-")))
ap.add_argument("--only", default="send,text")
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


def snapshot(name):
    path = os.path.join(opts.out, f"{name}.png")
    cap = os.environ.get("NX_CAPTURE")
    pid = launched[0].pid if launched else None
    if cap and pid:
        r = subprocess.run(["bash", cap, "shot", "--pid", str(pid), "--with-popups", "--out", path], capture_output=True, text=True, timeout=60)
        if r.returncode == 0 and os.path.exists(path):
            say(f"shot {name}: {path}")
            return path
    reply = rpc("debug.window_snapshot", {"path": path})
    say(f"snapshot {name}: {(reply or {}).get('path') or reply}")
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
    time.sleep(2)  # test harness: the window settles
    say("workspace new:", json.dumps(rpc("action.run", {"action": "workspace new", "args": {"cwd": FIXTURE, "focus": True}, "origin": "script"}))[:200])
    time.sleep(2)  # test harness: the shell starts


def open_index():
    # origin user: the person's own open, so the page renders in a browser tab (FilePageOpener).
    reply = rpc("action.run", {"action": "file open", "args": {"path": INDEX, "where": "tab"}, "focus": True, "origin": "user"})
    say("file open:", json.dumps(reply)[:300])
    return wait(lambda: tab_showing("index.html"), 20)


def run_send():
    t = open_index()
    row("index.html opens in a tab", t is not None, t)
    if not t:
        return
    time.sleep(1.5)  # test harness: the page paints
    snapshot("send-0-before")
    menu = rpc("debug.tab_menu", {"tab": tab_id(t)})
    say("tab menu:", json.dumps(menu)[:800])
    reply = rpc("action.run", {"action": "home.messageAbout", "target": f"tab:{tab_id(t)}", "focus": True, "origin": "user"})
    say("Send Message…:", json.dumps(reply)[:300])
    start = time.time()
    for ms in (0, 120, 300, 700, 1500, 3000):
        delay = start + ms / 1000 - time.time()
        if delay > 0:
            time.sleep(delay)  # test harness: timed captures
        snapshot(f"send-{ms:04d}ms")
    home = rpc("debug.home") or {}
    say("debug.home:", json.dumps(home)[:2500])
    row("Send Message… ran", "error" not in (reply or {}), reply)


def run_text():
    t = open_index()
    if not t:
        row("index.html opens in a tab", False, None)
        return
    reply = rpc("action.run", {"action": "file.openAsText", "target": f"tab:{tab_id(t)}", "focus": True, "origin": "user"})
    say("Open as Text:", json.dumps(reply)[:300])
    editor = wait(lambda: next((x for x in (rpc("debug.filepages") or {}).get("tabs", [])
                                if x.get("kind") == "editor" and x.get("file") == INDEX and x.get("has_page")), None), 20)
    row("Open as Text opens index.html in the code editor", editor is not None, editor)
    time.sleep(1.5)  # test harness: Monaco paints
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
if "send" in ONLY:
    run_send()
if "text" in ONLY:
    run_text()
finish(0 if all(r["ok"] for r in ROWS) else 1)
