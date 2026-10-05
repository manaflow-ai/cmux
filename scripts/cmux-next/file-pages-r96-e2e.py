#!/usr/bin/env python3
"""The file pages' keys, grants and R96 quit hook on a tagged DEBUG build (diff-host S6, S7).

Checks, each through the app's own sockets:
  keys     Cmd-K, Cmd-[ and Cmd-] in a markdown tab (the trunk's PageCommandHandlers; Cmd-S is
           file-pages-e2e.py's): the link popover opens, back and forward move between two files.
  grants   openLink to a file outside the document's folder: refused with no sheet when no real
           AppKit event reached the page in the last second; with one, the native sheet names the
           resolved path, Cancel refuses, and a second request on the same event is refused.
  crash    an edit the page reported, then its WebContent process ends (debug.filepages
           crash_page, WebKit's own kill); the quit's Save writes the reported text, because the
           disk still matches the base.
  dontsave an edit, then the quit's Don't Save: the file keeps its bytes.
  restore  an edit, its draft, an app crash (debug.crash.app), a change on disk, a relaunch: the
           notice's Open opens the draft as unsaved changes with the conflict toast, and the file
           keeps the other writer's bytes.
  picker   the diff-open action from the socket without focus (an agent or the CLI): it refuses
           with the needsFocus text and no picker appears over the window.
Synthetic events: debug.key (and debug.mouse) post NSEvents that DO set the page's
lastUserEventUptime, so the gesture steps prove the host's gesture path only loosely (a
synthetic event stands in for the person's). Steps that use debug.key: the keys step (Cmd-K,
Cmd-[, Cmd-], Escape) and the grants step "with a gesture" (debug.key "right" right before the
openLink). The "without a gesture" step waits 1.5 s after the last debug.key, so no event is in
the 1 s window. Editor autosave is off in the test config, so edits stay unsaved until the quit. Apps quit
through debug.quit; the only signals go to the PIDs this script launched. Run on cmux-lawrence-2, never the laptop.

Usage: file-pages-r96-e2e.py --tag <tag> --app <path to cmux DEV <tag>.app> [--out DIR]
"""
import argparse, json, os, signal, socket, subprocess, sys, tempfile, time

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--app", required=True)
parser.add_argument("--out", default=tempfile.mkdtemp(prefix="file-pages-r96-"))
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
BINARY = os.path.join(opts.app, "Contents/MacOS/cmux DEV")
SCRATCH = tempfile.mkdtemp(prefix=f"file-pages-r96-{opts.tag}-")
FIXTURE = "/tmp/hq48fp-r96-fixture"
CONFIG = os.path.join(SCRATCH, "cmux.json")
GHOSTTY = os.path.join(SCRATCH, "ghostty")
open(GHOSTTY, "w").write("")
DOCS = os.path.join(FIXTURE, "docs")
README = os.path.join(DOCS, "README.md")
OTHER = os.path.join(DOCS, "other.md")
SECRET = os.path.join(FIXTURE, "outside", "secret.txt")
CODE = os.path.join(FIXTURE, "src", "main.ts")
CODE_BYTES = b"const a = 1;\n"
failures, launched = [], []


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


def expect(label, condition, detail=""):
    print(("ok   " if condition else "FAIL ") + label + (f": {detail}" if detail and not condition else ""), flush=True)
    if not condition:
        failures.append(label)


def key(name, modifiers=None):
    reply = rpc("debug.key", {"key": name, "modifiers": modifiers or []}) or {}
    time.sleep(0.15)  # test harness: let the key land
    return reply


def text_of(page):
    return ((rpc("debug.page", {"page": page, "action": "state"}) or {}).get("text") or "").replace(" ", " ")


def filepages(params=None):
    return rpc("debug.filepages", params or {}) or {}


def dialogs():
    return [d for d in (rpc("debug.dialog") or {}).get("dialogs", []) if d.get("visible")]


def snapshot(name, page=None):
    path = os.path.join(opts.out, f"{name}.png")
    reply = rpc("debug.page", {"page": page, "action": "snapshot", "path": path}) if page else rpc("debug.window_snapshot", {"path": path})
    print(f"snapshot {name}: {(reply or {}).get('path') or reply}", flush=True)


def tab_of(kind, path):
    return next((t for t in filepages().get("tabs", []) if t.get("kind") == kind and t.get("file") == path), None)


def palette_key(name):
    rpc("debug.key", {"key": name, "modifiers": [], "target": "palette"})
    time.sleep(0.12)  # test harness: let the key land


def palette_open():
    windows = (rpc("debug.window_list") or {}).get("windows", [])
    return any(w.get("visible") and w.get("kind") in ("panel", "palette") for w in windows)


def open_file(path, kind):
    """`cmux file open` over the socket (the CLI entry point); when its tab gets no page, Open File...
    from the palette (the cmux picker in file mode, a typed path, Return)."""
    # Origin cli with focus requested on the run (file.open itself has no focus argument; without
    # it the tab opens in the background and its page is made when the tab shows:
    # ActionInvocation.allowsViewChange).
    reply = rpc("action.run", {"action": "file open", "args": {"path": path, "where": "tab"}, "focus": True, "origin": "cli"})
    tab = wait(lambda: (lambda t: t if t and t.get("has_page") else None)(tab_of(kind, path)), 15)
    print(f"file open {os.path.basename(path)} over the socket: ran={reply.get('ran')} page={bool(tab)} tab={tab_of(kind, path)}", flush=True)
    if tab:
        return tab
    print(f"after the socket open: focus={json.dumps(rpc('debug.focus'))[:400]}", flush=True)
    snapshot(f"socket-open-{os.path.basename(path)}")
    key("p", ["command", "shift"])
    if wait(palette_open, 10):
        for char in "Open File":
            palette_key(char)
        palette_key("return")
        time.sleep(0.6)  # test harness: the picker's first listing
        for char in path:
            palette_key(char)
        palette_key("return")
    else:
        print("the palette did not open", flush=True)
    return wait(lambda: (lambda t: t if t and t.get("has_page") else None)(tab_of(kind, path)), 30)


def make_fixture():
    subprocess.run(["rm", "-rf", FIXTURE], check=False)
    for folder in (DOCS, os.path.dirname(SECRET), os.path.dirname(CODE)):
        os.makedirs(folder, exist_ok=True)
    open(README, "w").write("# Docs home\n\nSee [the other page](other.md).\n")
    open(OTHER, "w").write("# Other page\n\nBack is Cmd-[.\n")
    open(SECRET, "w").write("outside the document's folder\n")
    open(CODE, "wb").write(CODE_BYTES)
    # The fixture is a user-chosen root, so the code file may be saved.
    open(CONFIG, "w").write(json.dumps({"files": {"roots": [FIXTURE]}, "editor": {"autoSave": "off"}}))


def launch():
    if os.path.exists(SOCKET):
        os.unlink(SOCKET)
    env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
           "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": CONFIG, "CMUX_NEXT_GHOSTTY_CONFIG": GHOSTTY,
           "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1300,850"}
    app = subprocess.Popen([BINARY], env=env, stdout=open(os.path.join(SCRATCH, "app.log"), "a"), stderr=subprocess.STDOUT,
                           stdin=subprocess.DEVNULL, cwd=FIXTURE)
    launched.append(app)
    print(f"launched pid {app.pid}", flush=True)
    if not wait(lambda: os.path.exists(SOCKET) and (rpc("debug.surfaces") or {}).get("windows"), 90):
        sys.exit("FAIL the tagged app did not come up")
    time.sleep(2)  # test harness: the window settles
    made = rpc("action.run", {"action": "workspace new", "args": {"cwd": FIXTURE, "focus": True}, "origin": "script"})
    print(f"workspace new in the fixture: {json.dumps(made)[:160]}", flush=True)
    wait(lambda: "terminal" in json.dumps(rpc("debug.focus") or {}), 20)
    time.sleep(2)  # test harness: the shell starts
    return app


def quit_app(app, unsaved_button):
    """debug.quit as Cmd-Q; the unsaved-changes dialog gets `unsaved_button`; the terminal sheet Quit."""
    print(f"debug.quit open: {rpc('debug.quit', {'open': True})}", flush=True)
    dialog = wait(lambda: next((d for d in dialogs() if any(b.get("id") == "dont-save" for b in d.get("buttons", []))), None), 10)
    expect(f"the quit asks about unsaved changes ({unsaved_button})", dialog is not None, json.dumps(rpc("debug.dialog"))[:400])
    if dialog:
        snapshot(f"quit-unsaved-{unsaved_button}")
        print(f"press {unsaved_button}: {rpc('debug.dialog', {'id': dialog['id'], 'press': unsaved_button})}", flush=True)
    if wait(lambda: (rpc("debug.quit") or {}).get("asking"), 5):
        rpc("debug.quit", {"press": "quit"})
    try:
        app.wait(timeout=30)
        print(f"quit {app.pid} exit {app.returncode}", flush=True)
    except subprocess.TimeoutExpired:
        app.send_signal(signal.SIGKILL)  # the PID launched here, never a pattern
        failures.append(f"quit {app.pid}")


def edit_code(letter):
    rpc("debug.page", {"page": "cmux.editor", "action": "click", "selector": ".monaco-editor .view-lines"})
    reply = rpc("debug.page", {"page": "cmux.editor", "action": "type", "text": letter, "selector": ".monaco-editor textarea"}) or {}
    time.sleep(1)  # test harness: the page reports the edit (500 ms trailing)
    return reply.get("inserted") is True


try:
    make_fixture()

    # Run 1: keys, grants, then a page crash and the quit's Save.
    app = launch()
    expect("README.md opens in a markdown tab", open_file(README, "cmux.markdown") is not None)
    expect("the markdown page shows README.md", wait(lambda: "Docs home" in text_of("cmux.markdown"), 20) is not None)
    rpc("debug.page", {"page": "cmux.markdown", "action": "click", "selector": ".ProseMirror"})
    key("k", ["command"])
    # The link popover takes the keyboard: its URL field is the active element.
    popover = wait(lambda: (lambda a: a if a and a.get("tag") == "input" else None)(
        (rpc("debug.page", {"page": "cmux.markdown", "action": "state"}) or {}).get("active")), 5)
    expect("Cmd-K opens the link popover", popover is not None,
           json.dumps((rpc("debug.page", {"page": "cmux.markdown", "action": "state"}) or {}).get("active")))
    snapshot("markdown-cmd-k", page="cmux.markdown")
    key("escape")
    key("escape")
    # A link follows on Cmd-click while editing (the page's link router).
    clicked = rpc("debug.page", {"page": "cmux.markdown", "action": "click", "selector": "a[href='other.md']", "meta": True})
    moved = wait(lambda: "Other page" in text_of("cmux.markdown"), 5)
    print(f"followed other.md: {bool(moved)} click={clicked} text={text_of('cmux.markdown')[:200]!r}", flush=True)
    if moved:
        key("[", ["command"])
        expect("Cmd-[ goes back to README.md", wait(lambda: "Docs home" in text_of("cmux.markdown"), 5) is not None)
        key("]", ["command"])
        expect("Cmd-] goes forward to other.md", wait(lambda: "Other page" in text_of("cmux.markdown"), 5) is not None)
        key("[", ["command"])
        wait(lambda: "Docs home" in text_of("cmux.markdown"), 5)
    else:
        expect("a link click follows other.md (needed for Cmd-[ and Cmd-])", False, "UNVERIFIED: the click did not follow")

    # The cmux pickers open only when the run may change the view (React UIs lead review).
    for action in ("palette.openDirectoryDiffViewer", "openDiffViewer"):
        reply = rpc("action.run", {"action": action, "origin": "cli"})
        text = json.dumps(reply)
        print(f"{action} without focus: {text[:240]}", flush=True)
        expect(f"{action} without focus refuses with the needsFocus text",
               "The picker opens only when focus is requested." in text, text[:300])
        time.sleep(0.8)  # test harness: a picker would be on screen by now
        focus = rpc("debug.focus") or {}
        expect(f"{action} without focus shows no picker", (focus.get("context") or {}).get("palette_open") is False,
               json.dumps(focus.get("context")))

    tab = tab_of("cmux.markdown", README)
    link = {"key": tab["key"], "href": "../outside/secret.txt", "target": SECRET} if tab else None
    time.sleep(1.5)  # test harness: the last real key event is older than the 1 s gesture window
    reply = filepages({"open_link": link}) if link else {}
    expect("without a gesture there is no gesture", reply.get("gesture") is False, json.dumps(reply)[:300])
    time.sleep(1)  # test harness: the refusal lands
    expect("without a gesture no sheet shows", not dialogs(), json.dumps(dialogs())[:300])
    expect("without a gesture the link is refused", (filepages().get("last_open_link") or "").endswith("cancelled"),
           str(filepages().get("last_open_link")))
    key("right")  # a real key event to the page: the gesture
    reply = filepages({"open_link": link}) if link else {}
    gesture = reply.get("gesture") is True
    print(f"gesture after debug.key: {gesture}", flush=True)
    if gesture:
        sheet = wait(lambda: next(iter(dialogs()), None), 5)
        expect("with a gesture the sheet names the resolved path", sheet is not None and any(SECRET in line for line in sheet.get("lines", []) + [sheet.get("title", "")]),
               json.dumps(sheet)[:400])
        snapshot("open-outside-sheet")
        again = filepages({"open_link": link})
        time.sleep(0.5)  # test harness: the second request's refusal
        expect("a second request while the sheet shows is refused", len(dialogs()) == 1, json.dumps(dialogs())[:300])
        if sheet:
            cancel = next((b["id"] for b in sheet.get("buttons", []) if b.get("role") == "cancel"), "cancel")
            rpc("debug.dialog", {"id": sheet["id"], "press": cancel})
        expect("Cancel refuses the link", wait(lambda: (filepages().get("last_open_link") or "").endswith("cancelled"), 5) is not None,
               str(filepages().get("last_open_link")))
        expect("the outside file did not open", tab_of("cmux.editor", SECRET) is None)
    else:
        expect("debug.key gives the page a real gesture", False, "UNVERIFIED: the sheet path with a gesture")

    expect("main.ts opens in the editor", open_file(CODE, "cmux.editor") is not None)
    wait(lambda: "const a" in text_of("cmux.editor"), 30)
    expect("an edit reaches the editor", edit_code("Z"))
    tab = tab_of("cmux.editor", CODE)
    crashed = filepages({"crash_page": tab["key"]}) if tab else {}
    expect("the editor page's WebContent process ends", crashed.get("crashed") is True, json.dumps(crashed)[:300])
    time.sleep(1)  # test harness: the page is gone
    quit_app(app, "save")
    expect("after a page crash the quit writes the reported text", open(CODE, "rb").read() == b"Zconst a = 1;\n",
           repr(open(CODE, "rb").read()))

    # Run 2: Don't Save writes nothing.
    before = open(CODE, "rb").read()
    app = launch()
    open_file(CODE, "cmux.editor")
    wait(lambda: "const a" in text_of("cmux.editor"), 30)
    edit_code("D")
    quit_app(app, "dont-save")
    expect("Don't Save keeps the file's bytes", open(CODE, "rb").read() == before, repr(open(CODE, "rb").read()))

    # Run 3: a draft, an app crash, a change on disk, a relaunch, the notice's Open.
    app = launch()
    open_file(CODE, "cmux.editor")
    wait(lambda: "const a" in text_of("cmux.editor"), 30)
    edit_code("R")
    draft = wait(lambda: next((d for d in filepages().get("drafts", []) if d.get("id", "").endswith(CODE)), None), 10)
    expect("the edit has a recovery draft with its base hash", draft is not None and bool(draft.get("base")), json.dumps(filepages().get("drafts"))[:300])
    rpc("debug.crash.app", {"signal": "abort"}, timeout=5)
    try:
        app.wait(timeout=20)
    except subprocess.TimeoutExpired:
        app.send_signal(signal.SIGKILL)  # the PID launched here
    print(f"crashed {app.pid} exit {app.returncode}", flush=True)
    open(CODE, "wb").write(b"changed by another writer\n")
    app = launch()
    restored = filepages({"restore": draft["id"]}) if draft else {}
    expect("the notice's Open runs", restored.get("restored") is True, json.dumps(restored)[:300])
    # The draft is the file as it was at the edit, with the "R" typed in front.
    expect("the draft opens as unsaved changes", wait(lambda: "RZconst" in text_of("cmux.editor") or "Rconst" in text_of("cmux.editor"), 20) is not None,
           text_of("cmux.editor")[:200])
    toast = wait(lambda: next((t for t in filepages().get("toasts", []) if "changed on disk" in t), None), 10)
    expect("the conflict notice shows", toast is not None, json.dumps(filepages().get("toasts")))
    snapshot("restore-conflict")
    expect("opening the draft never writes the file", open(CODE, "rb").read() == b"changed by another writer\n", repr(open(CODE, "rb").read()))
    quit_app(app, "dont-save")
    expect("the other writer's bytes stay", open(CODE, "rb").read() == b"changed by another writer\n", repr(open(CODE, "rb").read()))

    print("FAILURES: " + ", ".join(failures) if failures else "ok: every step passed", flush=True)
finally:
    for app in launched:
        if app.poll() is None:
            rpc("debug.quit", {"open": True})
            time.sleep(1)  # test harness: the quit sheet, if any
            for dialog in dialogs():
                rpc("debug.dialog", {"id": dialog["id"], "press": "dont-save"})
            rpc("debug.quit", {"press": "quit"})
            try:
                app.wait(timeout=20)
            except subprocess.TimeoutExpired:
                app.send_signal(signal.SIGKILL)  # the PID launched here, never a pattern
sys.exit(1 if failures else 0)
