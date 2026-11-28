#!/usr/bin/env python3
"""Live check: Cmd-click on a file path in terminal output (cx-do47).

  scripts/cmux-next/terminal-path-links-live.py --tag <tag> [--out DIR] [--app PATH]

Launches the tagged app (no activation, automation socket, empty config) as a recording
build (`CMUX_NEXT_TEST_RECORD_EXTERNAL_OPENS=1`: a link for another app or Finder is
recorded, not opened). A terminal starts in `<repo>/sub` of a fixture git repo, and
`debug.terminal.links {open}` activates link texts in it as Ghostty's Cmd-click on the
matched text does (its `open_url` action). Checks:

  1. `build-fleet/ORG-BACKUP.md.` (relative to the git root, trailing period) opens the
     Markdown page, never a browser at https://build-fleet/...;
  2. a quoted absolute path with a trailing comma opens the Markdown page;
  3. `src/app.ts:3:5` opens the code editor page;
  4. a folder opens in Finder;
  5. a path that exists nowhere opens nothing;
  6. `localhost:3000/docs` is a web link (http://localhost:3000/docs), not a scheme.
  7. `notes/todo.md:2` (a Markdown file with a line) opens the Markdown page, not the
     code editor;
  8. Cmd-hover (cx-do47.1) over a printed path that names a file reports a link under the
     pointer; over one that names nothing it reports none (Ghostty's link filter).

GUI host only (a capture mini). The app quits and the tag's daemons stop at the end.
Exits 1 when a check fails.
"""
import argparse, glob, json, os, plistlib, socket, subprocess, sys, tempfile, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tag_teardown import TagTeardown  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or tempfile.mkdtemp(prefix="terminal-path-links-"))
parser.add_argument("--app", help="tagged .app (default: found in DerivedData)")
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
failures = []


def check(ok, what):
    print(("ok   " if ok else "FAIL ") + what, flush=True)
    if not ok:
        failures.append(what)
    return ok


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
    result = reply.get("result") if reply.get("ok") else {"error": reply.get("error")}
    return result if isinstance(result, dict) else {"value": result}


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
    check(bool(value), what)
    return value


def page_texts(page):
    """The text of every live (not parked) `page` (cmux.markdown, cmux.editor)."""
    texts = []
    for entry in rpc("debug.page", {"page": page, "action": "list"}).get("pages") or []:
        if entry.get("parked"):
            continue
        state = rpc("debug.page", {"page": page, "action": "state", "instance": entry.get("instance")})
        # The code editor draws spaces as no-break spaces.
        texts.append((state.get("text") or "").replace("\u00a0", " "))
    return "\n".join(texts)


TERMINAL = None


def click(text):
    """Activates `text` in the fixture terminal; the link opens recorded since the last click."""
    global TERMINAL
    rpc("debug.terminal.links", {"clear": True})
    reply = rpc("debug.terminal.links", {"open": text, **({"tab": TERMINAL} if TERMINAL else {})})
    print(f"click {text!r}: {reply}", flush=True)
    TERMINAL = TERMINAL or reply.get("tab")
    time.sleep(1.5)  # test harness: the open runs after the click returns, off the main thread
    return rpc("debug.terminal.links").get("opened") or []


def web(opened):
    return [entry for entry in opened if entry.startswith(("browser:", "system:"))]


REPO = os.path.realpath(tempfile.mkdtemp(prefix="cxdo47-repo-"))
for folder in (".git", "build-fleet", "notes", "src", "sub"):
    os.makedirs(os.path.join(REPO, folder), exist_ok=True)
with open(os.path.join(REPO, "build-fleet", "ORG-BACKUP.md"), "w") as f:
    f.write("# Org backup\n\norg backup marker\n")
with open(os.path.join(REPO, "notes", "plan.md"), "w") as f:
    f.write("# Plan\n\nplan marker\n")
with open(os.path.join(REPO, "notes", "todo.md"), "w") as f:
    f.write("# Todo\n\ntodo marker\n")
with open(os.path.join(REPO, "src", "app.ts"), "w") as f:
    f.write("const a = 1;\nconst b = 2;\nconst c = 3;\n")

APP = opts.app or next(iter(sorted(glob.glob(os.path.expanduser(
    f"~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/cmux DEV {opts.tag}.app")))), None)
if not APP:
    sys.exit(f"no tagged app for {opts.tag}")
with open(os.path.join(APP, "Contents/Info.plist"), "rb") as f:
    INFO = plistlib.load(f)
BINARY = os.path.join(APP, "Contents/MacOS", INFO["CFBundleExecutable"])
SCRATCH = tempfile.mkdtemp(prefix=f"terminal-path-links-{opts.tag}-")
CONFIG = os.path.join(SCRATCH, "cmux.json")
# link-previews: Ghostty reports the regex link under the pointer (`hovered`).
GHOSTTY = os.path.join(SCRATCH, "ghostty")
with open(GHOSTTY, "w") as f:
    f.write("link-previews = true\n")
with open(CONFIG, "w") as f:
    f.write("{}\n")
teardown = TagTeardown(APP)
teardown.install()
if os.path.exists(SOCKET):
    os.unlink(SOCKET)
app = subprocess.Popen([BINARY], env={
    "HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_NO_ACTIVATE": "1",
    "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": CONFIG, "CMUX_NEXT_GHOSTTY_CONFIG": GHOSTTY,
    "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1200,800", "CMUX_NEXT_TEST_RECORD_EXTERNAL_OPENS": "1"},
    stdout=open(os.path.join(opts.out, "app.log"), "w"), stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
print(f"app pid {app.pid}, repo {REPO}, out {opts.out}", flush=True)
try:
    wait_for(lambda: os.path.exists(SOCKET) and "error" not in rpc("debug.focus"), "app socket", 180)
    check("error" not in rpc("debug.terminal.links"), "the build has debug.terminal.links")
    if not quiet_wait(lambda: rpc("debug.focus").get("windows"), 20):
        rpc("action.run", {"action": "newWindow", "origin": "script"})
    wait_for(lambda: rpc("debug.focus").get("windows"), "a window", 60)
    made = rpc("action.run", {"action": "workspace new", "args": {"cwd": os.path.join(REPO, "sub"), "focus": True}, "origin": "script"})
    print(f"workspace new: {json.dumps(made)[:300]}", flush=True)
    # The new workspace's terminal by tab id (`snapshot.get`), not by focus: a mini's restored
    # state can leave a chat page or a text field focused. Its view exists once its workspace
    # shows, so the workspaces are selected in turn until it answers.
    workspace = (made.get("created") or [None])[0]

    def fixture_terminal():
        global TERMINAL
        for listed in (rpc("snapshot.get").get("topology") or {}).get("workspaces") or []:
            if listed.get("id") != workspace:
                continue
            for screen in listed.get("screens") or []:
                for pane in screen.get("panes") or []:
                    for tab in pane.get("tabs") or []:
                        if tab.get("kind") in ("terminal", "pty") and "error" not in rpc("debug.terminal.links", {"open": "", "tab": tab["id"]}):
                            TERMINAL = tab["id"]
                            return TERMINAL
        return None

    if not quiet_wait(fixture_terminal, 10):
        for index in range(1, 10):
            rpc("action.run", {"action": "selectWorkspaceByNumber", "args": {"index": index}})
            if quiet_wait(fixture_terminal, 3):
                break
    if not wait_for(fixture_terminal, "the new workspace's terminal", 30):
        print(f"snapshot.get: {json.dumps(rpc('snapshot.get'))[:1500]}", flush=True)
    time.sleep(2)  # test harness: the shell starts and reports its cwd

    # 1. The reported case: a repo-relative path printed with a trailing period.
    opened = click("build-fleet/ORG-BACKUP.md.")
    check(not web(opened), f"build-fleet/ORG-BACKUP.md. opens no browser and no other app ({opened})")
    check(bool(quiet_wait(lambda: "org backup marker" in page_texts("cmux.markdown"), 15)),
          "build-fleet/ORG-BACKUP.md. resolves against the git root into the Markdown page")

    # 2. A quoted absolute path with a trailing comma.
    opened = click(f'"{REPO}/notes/plan.md",')
    check(not web(opened), f"the quoted path opens no other app ({opened})")
    check(bool(quiet_wait(lambda: "plan marker" in page_texts("cmux.markdown"), 15)), "the quoted path opens the Markdown page")

    # 3. A path with :line:col opens the code editor page.
    opened = click("../src/app.ts:3:5")
    check(not web(opened), f"../src/app.ts:3:5 opens no other app ({opened})")
    if not check(bool(quiet_wait(lambda: "const c" in page_texts("cmux.editor"), 30)), "../src/app.ts:3:5 opens the code editor page"):
        listed = rpc("debug.page", {"page": "cmux.editor", "action": "list"})
        state = rpc("debug.page", {"page": "cmux.editor", "action": "state"})
        print(f"editor pages: {json.dumps(listed)[:600]}\neditor state: {json.dumps(state)[:1500]}", flush=True)

    # 7. A Markdown file with a line opens the Markdown page, not the code editor.
    opened = click("notes/todo.md:2")
    check(not web(opened), f"notes/todo.md:2 opens no other app ({opened})")
    check(bool(quiet_wait(lambda: "todo marker" in page_texts("cmux.markdown"), 15)), "notes/todo.md:2 opens the Markdown page")
    check("todo marker" not in page_texts("cmux.editor"), "notes/todo.md:2 opens no code editor page")

    # 4. A folder opens in Finder.
    opened = click("build-fleet/")
    folder = os.path.join(REPO, "build-fleet")
    shown = [os.path.realpath(entry[len("finder:"):]) for entry in opened if entry.startswith("finder:")]
    check(shown == [folder] and len(opened) == 1, f"build-fleet/ opens in Finder ({opened})")

    # 5. A path that exists nowhere opens nothing.
    markdown_before = page_texts("cmux.markdown")
    opened = click("missing/nowhere.md")
    check(opened == [], f"missing/nowhere.md opens nothing ({opened})")
    check(page_texts("cmux.markdown") == markdown_before, "missing/nowhere.md opens no page")

    # 6. host:port is a web link, not a scheme.
    opened = click("localhost:3000/docs")
    check(opened == ["browser:http://localhost:3000/docs"], f"localhost:3000/docs opens the browser at http://localhost:3000/docs ({opened})")

    # 8. Cmd-hover (cx-do47.1): a path that names a file is a link; one that names nothing is
    # plain text, with no underline and no link under the pointer.
    rpc("action.run", {"action": "palette.goToTab", "target": {"kind": "tab", "id": TERMINAL}, "origin": "script"})
    rpc("action.run", {"action": "terminal.sendText", "target": {"kind": "tab", "id": TERMINAL}, "origin": "script",
                       "args": {"text": "clear && printf '%s\\n%s\\n' build-fleet/ORG-BACKUP.md missing/nowhere.md\n"}})
    time.sleep(2)  # test harness: the shell runs the command and the output draws

    def hovered(row):
        """The link Ghostty reports with Cmd held over column 4 of viewport row `row`."""
        for _ in range(2):  # the first hover starts the file check off the main thread
            rpc("debug.terminal.links", {"tab": TERMINAL, "hover": [4, row]})
            time.sleep(1)  # test harness: the check's answer and the pointer sent again
        return rpc("debug.terminal.links", {"tab": TERMINAL}).get("hovered")

    shown = hovered(0)
    check(shown == "build-fleet/ORG-BACKUP.md", f"Cmd-hover on a path that names a file is a link ({shown!r})")
    shown = hovered(1)
    check(not shown, f"Cmd-hover on a path that names nothing is no link ({shown!r})")
finally:
    rpc("action.run", {"action": "quitEndSessions"})
    try:
        app.wait(timeout=20)
    except subprocess.TimeoutExpired:
        app.kill()  # the exact PID this script started
        app.wait()
    teardown.end()

print(f"RESULT {'FAIL' if failures else 'PASS'} ({len(failures)} failed)", flush=True)
sys.exit(1 if failures else 0)
