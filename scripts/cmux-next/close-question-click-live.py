#!/usr/bin/env python3
"""Live proof that a person's real clicks answer the close question (Aziz 2026-11-12: "Close “IOS INTERNAL CI”?
Still running: 2.1.323." took no click on Close, Cancel or "Don't ask again").

Launches the tagged app (a scratch config, an isolated Chief home), makes a workspace named "IOS INTERNAL CI" whose
terminal runs `sleep`, optionally with a browser split beside it (a Chromium page window, as in the report), and
runs Close Workspace as a person's run, which asks. Then, with real pointer and key events at the HID tap
(CGEventPost, the window server's own pointer path; the job owns the GUI session, `--needs input`):

  check     a click on "Don't ask again" checks it, a second click unchecks it
  cancel    a click on Cancel answers: the question goes, the workspace stays
  escape    Escape answers as Cancel
  close     a click on Close answers: the question goes, the workspace closes

Each step records a still. Usage (nx-remote --needs input --app-from-fleet cmux --tag T --ref SHA):
  close-question-click-live.py --app "$NX_APP" --tag "$NX_APP_TAG" --out "$NX_ARTIFACTS/proof" [--browser]
Exit 0 only when every check passes.
"""
import argparse, json, os, socket, subprocess, sys, tempfile, time

parser = argparse.ArgumentParser()
parser.add_argument("--app", required=True)
parser.add_argument("--tag", required=True)
parser.add_argument("--out", required=True)
parser.add_argument("--browser", action="store_true", help="open a browser split beside the terminal first")
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
SCRATCH = tempfile.mkdtemp(prefix=f"closeq-{opts.tag}-")
CONFIG = os.path.join(SCRATCH, "cmux.json")
GHOSTTY = os.path.join(SCRATCH, "ghostty")
CLI = os.path.join(opts.app, "Contents/Resources/bin/cmux")
CUA = os.path.expanduser("~/.local/bin/cua-driver")
NAME = "IOS INTERNAL CI"
failures = []
steps = []


def check(ok, what, detail=None):
    print(("ok   " if ok else "FAIL ") + what + ("" if ok or detail is None else f"  ({json.dumps(detail)[:400]})"), flush=True)
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
    return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}


def cli_env():
    env = {k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}
    env["CMUX_NEXT_CONFIG_FILE"] = CONFIG
    return env


def cli(*args):
    done = subprocess.run([CLI, "--app-socket", SOCKET, *args], env=cli_env(), capture_output=True, text=True, timeout=60)
    print("cli", " ".join(args), "->", done.returncode, (done.stdout + done.stderr).strip()[-240:], flush=True)
    return done


def wait(predicate, seconds, step=0.2):
    """Test harness wait: polls a socket read until it holds or the bound ends."""
    end = time.time() + seconds
    while time.time() < end:
        try:
            value = predicate()
        except Exception:  # the app may not answer yet
            value = None
        if value:
            return value
        time.sleep(step)
    return None


def workspace_titles():
    return [r.get("title") for w in (rpc("debug.sidebar_rows") or {}).get("windows") or [] for r in w.get("rows") or []
            if str(r.get("key", "")).startswith("workspace(")]


def dialogs():
    return (rpc("debug.dialog") or {}).get("dialogs", [])


def question():
    return next((d for d in dialogs() if NAME in json.dumps(d)), None)


def shot(name, note):
    path = os.path.join(opts.out, f"{len(steps):02d}-{name}.png")
    done = subprocess.run(["bash", os.environ["NX_CAPTURE"], "shot", "--pid", str(app.pid), "--with-popups", "--out", path],
                          capture_output=True, text=True, timeout=120)
    print("shot", name, done.returncode, (done.stdout + done.stderr).strip()[-200:], flush=True)
    steps.append({"file": os.path.basename(path), "step": name, "note": note, "ok": done.returncode == 0})


def cua(tool, args):
    p = subprocess.run([CUA, "call", tool, json.dumps(args)], capture_output=True, text=True, timeout=90)
    try:
        return json.loads(p.stdout)
    except ValueError:
        return {"error": (p.stdout + p.stderr)[-600:]}


def find(obj, pred, out=None):
    out = [] if out is None else out
    if pred(obj):
        out.append(obj)
    if isinstance(obj, dict):
        for v in obj.values():
            find(v, pred, out)
    elif isinstance(obj, list):
        for v in obj:
            find(v, pred, out)
    return out


def element(label, role):
    """The screen frame center (top-left origin) of the app's element `label` of `role`, searched in every window of the
    app (the question's card is in the overlay panel, a child window of the main window)."""
    wins = cua("list_windows", {"pid": app.pid})
    rows = find(wins, lambda o: isinstance(o, dict) and "window_id" in o and o.get("pid") == app.pid)
    for win in sorted(rows, key=lambda w: -(w.get("z_index") or 0)):
        state = cua("get_window_state", {"pid": app.pid, "window_id": win["window_id"], "include_screenshot": False,
                                         "max_depth": 60, "max_elements": 4000})
        hits = [e for e in find(state, lambda o: isinstance(o, dict) and "frame" in o and "role" in o)
                if role in str(e.get("role", "")).lower() and label in (str(e.get("label", "")) + str(e.get("title", "")))]
        if hits:
            f, b = hits[-1]["frame"], win.get("bounds") or {}
            x, y = f["x"] + f["w"] / 2, f["y"] + f["h"] / 2
            if b and not (b["x"] <= x <= b["x"] + b["width"] and b["y"] <= y <= b["y"] + b["height"]):
                x, y = x + b["x"], y + b["y"]
            return {"point": [x, y], "frame": f, "window": win["window_id"], "role": hits[-1].get("role"), "label": hits[-1].get("label")}
    return None


def post_click(x, y):
    """One real left click at screen point (x, y) (top-left origin): CGEvents at the HID tap."""
    import ctypes, ctypes.util
    cg = ctypes.cdll.LoadLibrary(ctypes.util.find_library("CoreGraphics"))

    class P(ctypes.Structure):
        _fields_ = [("x", ctypes.c_double), ("y", ctypes.c_double)]
    cg.CGEventCreateMouseEvent.restype = ctypes.c_void_p
    cg.CGEventCreateMouseEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint32, P, ctypes.c_uint32]
    cg.CGEventPost.argtypes = [ctypes.c_uint32, ctypes.c_void_p]
    cg.CFRelease.argtypes = [ctypes.c_void_p]
    for kind, hold in ((5, 0.08), (1, 0.12), (2, 0.08)):  # mouseMoved, leftMouseDown, leftMouseUp
        e = cg.CGEventCreateMouseEvent(None, kind, P(x, y), 0)
        cg.CGEventPost(0, e)
        cg.CFRelease(e)
        time.sleep(hold)  # human-like press interval for the window server, not app synchronization


def post_key(code):
    import ctypes, ctypes.util
    cg = ctypes.cdll.LoadLibrary(ctypes.util.find_library("CoreGraphics"))
    cg.CGEventCreateKeyboardEvent.restype = ctypes.c_void_p
    cg.CGEventCreateKeyboardEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint16, ctypes.c_bool]
    cg.CGEventPost.argtypes = [ctypes.c_uint32, ctypes.c_void_p]
    cg.CFRelease.argtypes = [ctypes.c_void_p]
    for down in (True, False):
        e = cg.CGEventCreateKeyboardEvent(None, code, down)
        cg.CGEventPost(0, e)
        cg.CFRelease(e)
        time.sleep(0.05)  # human-like press interval for the window server, not app synchronization


def ask():
    """Close Workspace as a person's run on the active workspace: it asks while `sleep` runs."""
    reply = rpc("debug.toast", {"perform": "closeWorkspace"})
    print("perform closeWorkspace:", json.dumps(reply)[:200], flush=True)
    return wait(question, 10)


def click(label, role):
    found = element(label, role)
    print("element", label, json.dumps(found), flush=True)
    if not check(bool(found), f"the question's {label!r} {role} is on screen (accessibility)"):
        return None
    post_click(*found["point"])
    return found


app = None
try:
    with open(CONFIG, "w") as f:
        json.dump({}, f)
    open(GHOSTTY, "w").write("")
    if os.path.exists(SOCKET):
        os.unlink(SOCKET)
    env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_SOCKET_MODE": "automation",
           "CMUX_NEXT_CONFIG_FILE": CONFIG, "CMUX_NEXT_GHOSTTY_CONFIG": GHOSTTY, "CMUX_NEXT_CHIEF_ISOLATED": "1",
           "CMUX_NEXT_CHIEF_HOME": os.path.join(SCRATCH, "chief"), "CMUX_NEXT_TEST_WINDOW_FRAME": "60,60,1100,700"}
    log = open(os.path.join(opts.out, "app.log"), "a")
    app = subprocess.Popen([os.path.join(opts.app, "Contents/MacOS/cmux DEV")], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
    print("launched pid", app.pid, flush=True)
    if not wait(lambda: os.path.exists(SOCKET) and workspace_titles(), 180):
        sys.exit("the tagged app did not come up")
    done = cli("workspace", "create", "--name", NAME, "--json")
    terminal = None
    try:
        terminal = (json.loads(done.stdout).get("value") or {}).get("terminal_id")
    except ValueError:
        pass
    check(bool(wait(lambda: NAME in workspace_titles(), 15)), f"the workspace {NAME!r} is listed", workspace_titles())
    if terminal:
        cli("terminal", str(terminal), "write", "--text", "sleep 600\n")
        time.sleep(1.5)  # test harness: the shell starts sleep before the close asks process-info
    if opts.browser:
        cli("browser", "open", "https://example.com")
        time.sleep(4)  # test harness: the page window shows beside the terminal
    wins = cua("list_windows", {"pid": app.pid})
    main = max(find(wins, lambda o: isinstance(o, dict) and "window_id" in o and o.get("pid") == app.pid),
               key=lambda w: (w.get("bounds") or {}).get("width", 0), default=None)
    if main:
        cua("bring_to_front", {"pid": app.pid, "window_id": main["window_id"]})  # the job owns this GUI session
    shot("workspace", f"{NAME} runs sleep" + (" beside a browser split" if opts.browser else ""))

    # check: two clicks on the check box ------------------------------------------------------------------------
    asked = ask()
    check(bool(asked), "Close Workspace asks (sleep runs)", dialogs())
    json.dump(dialogs(), open(os.path.join(opts.out, "question.json"), "w"), indent=1)
    shot("asked", "the close question shows")
    if click("ask again", "checkbox"):
        checked = wait(lambda: (question() or {}).get("values", {}).get("dont-ask-again") is True, 3)
        check(bool(checked), "a click on Don't ask again checks it", question())
        shot("checked", "after a click on Don't ask again")
        click("ask again", "checkbox")
        check(bool(wait(lambda: (question() or {}).get("values", {}).get("dont-ask-again") is False, 3)),
              "a second click unchecks it", question())

    # cancel ---------------------------------------------------------------------------------------------------
    if click("Cancel", "button"):
        check(bool(wait(lambda: question() is None, 3)), "a click on Cancel answers the question", dialogs())
        time.sleep(0.5)  # test harness: a cancelled close must change nothing
        check(NAME in workspace_titles(), "Cancel keeps the workspace", workspace_titles())
        shot("cancelled", "after a click on Cancel: the workspace stays")

    # escape ---------------------------------------------------------------------------------------------------
    if check(bool(ask()), "Close Workspace asks again"):
        post_key(53)
        check(bool(wait(lambda: question() is None, 3)), "Escape answers the question as Cancel", dialogs())
        check(NAME in workspace_titles(), "Escape keeps the workspace", workspace_titles())

    # close ----------------------------------------------------------------------------------------------------
    if check(bool(ask()), "Close Workspace asks a third time"):
        shot("asked-again", "the close question before the click on Close")
        if click("Close", "button"):
            check(bool(wait(lambda: question() is None, 3)), "a click on Close answers the question", dialogs())
            check(bool(wait(lambda: NAME not in workspace_titles(), 10)), "Close closes the workspace", workspace_titles())
            shot("closed", "after a click on Close: the workspace closed")
finally:
    json.dump({"steps": steps, "failures": failures}, open(os.path.join(opts.out, "steps.json"), "w"), indent=1)
    if app is not None:
        print("the job's NX_APP_STOP stops the app (pid %d)" % app.pid, flush=True)
print("RESULT:", "PASS" if not failures else "FAIL " + "; ".join(failures), flush=True)
sys.exit(1 if failures else 0)
