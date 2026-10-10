#!/usr/bin/env python3
"""Live check: automation never confirms a money, destructive, consent or trust dialog (cx-zk9t).

  scripts/cmux-next/dialog-user-only-live.py --tag <tag> [--out DIR] [--app PATH]

Launches the tagged app (no activation, automation socket, bounded window),
then drives `debug.dialog` and `debug.quit` the way an agent with the debug
socket would:

  money        fixture "money" (Create a Cloud Machine?): press Create, key
               Return and set a field are refused; the dialog stays open;
               Escape (its cancel) closes it.
  destructive  fixture "confirm" (Close Workspace): press Close and key Return
               are refused; dismiss closes it.
  consent      fixture "credentials" (HTTP sign-in): set a field and press
               Sign In are refused; Cancel closes it.
  none         fixture "text" (Rename Tab): set and press Rename work.
  mixed        fixture "save": per button, Don't Save (press, Cmd-D) is refused,
               Save works.
  quit sheet   debug.quit {open} (the real sheet, when the app asks): pressing
               an end choice is refused; Keep works and quits the app.
  ax           when this process is trusted for Accessibility, each user-only
               dialog view publishes AXCmuxConfirmKind (else UNVERIFIED).

Each refused step must answer with `error` and `refused.confirm_kind`, and the
dialog must still be listed (with its `confirm_kind`). Window snapshots go to
--out. Quits the app it started (its PID only) and writes
dialog-user-only-live.json. Fleet GUI host only (cmux-lawrence-2).
Exit 1 on a failed check; an UNVERIFIED step alone is not a failure.
"""
import argparse, ctypes, ctypes.util, glob, json, os, plistlib, signal, socket, subprocess, sys, tempfile, time

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or tempfile.mkdtemp(prefix="dialog-user-only-"))
parser.add_argument("--app", help="tagged .app (default: found in DerivedData)")
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)
OUT = os.path.abspath(opts.out)

APP = opts.app or next(iter(sorted(glob.glob(os.path.expanduser(
    f"~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/cmux DEV {opts.tag}.app")))), None)
if not APP:
    sys.exit(f"no tagged app for {opts.tag}; pass --app")
with open(os.path.join(APP, "Contents/Info.plist"), "rb") as f:
    BINARY = os.path.join(APP, "Contents/MacOS", plistlib.load(f)["CFBundleExecutable"])
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
BASE_ENV = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""),
            "TMPDIR": os.environ.get("TMPDIR", "/tmp"), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"}
report = {"tag": opts.tag, "app": APP, "transcript": []}
failures = []


def rpc(method, params=None):
    """One request on the app's JSON-lines debug socket; every call goes into the transcript."""
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(60)
        conn.connect(SOCKET)
        conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = conn.recv(1 << 22)
            if not chunk:
                break
            buf += chunk
        conn.close()
        reply = json.loads(buf)
        result = reply.get("result") if reply.get("ok") else {"error": reply.get("error")}
    except (OSError, ValueError) as error:
        result = {"error": str(error)}
    if method not in ("debug.surfaces", "debug.window_snapshot"):
        brief = {k: v for k, v in (result or {}).items() if k != "dialogs"} if isinstance(result, dict) else result
        report["transcript"].append({"method": method, "params": params or {}, "reply": brief})
    return result or {}


def wait(predicate, seconds, step=0.25):
    deadline = time.time() + seconds
    while time.time() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(step)  # test harness wait, not app code
    return None


def check(label, ok, detail=""):
    print(f"{'ok  ' if ok else 'FAIL'} {label} {detail}", flush=True)
    if not ok:
        failures.append(label)


def dialog(id_):
    return next((d for d in rpc("debug.dialog").get("dialogs") or [] if d.get("id") == id_), None)


def snapshot(name, listed):
    if listed and listed.get("window"):
        rpc("debug.window_snapshot", {"window": int(listed["window"]), "path": os.path.join(OUT, f"{name}.png")})
        report.setdefault("snapshots", []).append(f"{name}.png" if os.path.exists(os.path.join(OUT, f"{name}.png")) else None)


def refused(label, id_, kind, params):
    """One step automation must not take: refused, typed, and the dialog still open."""
    reply = rpc("debug.dialog", {"id": id_, **params})
    open_after = dialog(id_)
    check(f"{label}: {json.dumps(params)} refused", bool(reply.get("error")) and (reply.get("refused") or {}).get("confirm_kind") == kind,
          json.dumps(reply)[:300])
    check(f"{label}: still open after {json.dumps(params)}", open_after is not None)


def user_only_round(label, fixture, kind, refused_steps, closing, closed_key):
    opened = rpc("debug.dialog", {"open": fixture})
    id_ = opened.get("opened")
    check(f"{label}: fixture {fixture} opened", isinstance(id_, (int, float)), json.dumps(opened)[:300])
    if not isinstance(id_, (int, float)):
        return
    id_ = int(id_)
    listed = dialog(id_)
    check(f"{label}: listed with confirm_kind {kind}", (listed or {}).get("confirm_kind") == kind, json.dumps(listed)[:300])
    snapshot(f"{label}-dialog", listed)
    report[f"{label}_ax"] = ax_kind(listed)
    for params in refused_steps:
        refused(label, id_, kind, params)
    reply = rpc("debug.dialog", {"id": id_, **closing})
    check(f"{label}: {json.dumps(closing)} allowed", reply.get(closed_key) is True and not reply.get("error"), json.dumps(reply)[:300])
    check(f"{label}: closed", dialog(id_) is None)


# Accessibility: AXCmuxConfirmKind on the dialog view (what our computer-use drivers read).
def ax_kind(listed):
    if not listed:
        return "UNVERIFIED: no dialog"
    try:
        ax = ctypes.cdll.LoadLibrary(ctypes.util.find_library("ApplicationServices"))
        cf = ctypes.cdll.LoadLibrary(ctypes.util.find_library("CoreFoundation"))
    except OSError as error:
        return f"UNVERIFIED: {error}"
    ax.AXIsProcessTrusted.restype = ctypes.c_bool
    if not ax.AXIsProcessTrusted():
        return "UNVERIFIED: this process is not trusted for Accessibility"
    cf.CFStringCreateWithCString.restype = ctypes.c_void_p
    cf.CFStringCreateWithCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint32]
    cf.CFGetTypeID.argtypes = [ctypes.c_void_p]
    cf.CFStringGetTypeID.restype = cf.CFArrayGetTypeID.restype = cf.CFGetTypeID.restype = ctypes.c_ulong
    cf.CFArrayGetCount.argtypes = [ctypes.c_void_p]
    cf.CFArrayGetValueAtIndex.restype = ctypes.c_void_p
    cf.CFArrayGetValueAtIndex.argtypes = [ctypes.c_void_p, ctypes.c_long]
    cf.CFStringGetCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_long, ctypes.c_uint32]
    ax.AXUIElementCreateApplication.restype = ctypes.c_void_p
    ax.AXUIElementCreateApplication.argtypes = [ctypes.c_int]
    ax.AXUIElementCopyAttributeValue.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.POINTER(ctypes.c_void_p)]

    def name(text):
        return cf.CFStringCreateWithCString(None, text.encode(), 0x08000100)

    def attr(element, key):
        value = ctypes.c_void_p()
        return value.value if ax.AXUIElementCopyAttributeValue(element, name(key), ctypes.byref(value)) == 0 else None

    def text(value):
        if not value or cf.CFGetTypeID(value) != cf.CFStringGetTypeID():
            return None
        buf = ctypes.create_string_buffer(256)
        return buf.value.decode() if cf.CFStringGetCString(value, buf, 256, 0x08000100) else None

    found = []

    def walk(element, depth):
        if depth > 40 or len(found) > 20:
            return
        if text(attr(element, "AXIdentifier")) == listed.get("identifier"):
            found.append(text(attr(element, "AXCmuxConfirmKind")))
        children = attr(element, "AXChildren")
        if children and cf.CFGetTypeID(children) == cf.CFArrayGetTypeID():
            for i in range(cf.CFArrayGetCount(children)):
                walk(cf.CFArrayGetValueAtIndex(children, i), depth + 1)

    windows = attr(ax.AXUIElementCreateApplication(APP_PID), "AXWindows")
    if windows and cf.CFGetTypeID(windows) == cf.CFArrayGetTypeID():
        for i in range(cf.CFArrayGetCount(windows)):
            walk(cf.CFArrayGetValueAtIndex(windows, i), 0)
    if not found:
        return "UNVERIFIED: dialog not in the AX tree"
    ok = found[0] == listed.get("confirm_kind")
    check(f"ax: {listed.get('identifier')} publishes AXCmuxConfirmKind", ok, repr(found))
    return found[0]


CONFIG = os.path.join(OUT, "cmux.json")
with open(CONFIG, "w") as f:
    f.write("{}\n")
if os.path.exists(SOCKET):
    os.unlink(SOCKET)
env = {**BASE_ENV, "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_TEST_WINDOW_SCREEN": "last",
       "CMUX_NEXT_CONFIG_FILE": CONFIG, "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1100,720"}
log = open(os.path.join(OUT, "app.log"), "a")
app = subprocess.Popen([BINARY], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
APP_PID = app.pid
report["pid"] = app.pid
print(f"launched pid {app.pid} (log {OUT}/app.log)", flush=True)
try:
    if not wait(lambda: os.path.exists(SOCKET) and rpc("debug.surfaces").get("windows"), 120, 0.5):
        failures.append("tagged app did not come up")
        raise SystemExit("tagged app did not come up")

    user_only_round("money", "money", "money",
                    [{"press": "create"}, {"key": "return"}, {"set": {"name": "x"}}],
                    {"key": "escape"}, "key")
    user_only_round("destructive", "confirm", "destructive",
                    [{"press": "close"}, {"key": "return"}],
                    {"dismiss": True}, "dismissed")
    user_only_round("consent", "credentials", "consent",
                    [{"set": {"user": "agent"}}, {"press": "sign-in"}],
                    {"press": "cancel"}, "pressed")

    # none: a rename answers to automation as before.
    opened = rpc("debug.dialog", {"open": "text"})
    id_ = int(opened.get("opened") or 0)
    listed = dialog(id_)
    check("none: listed with confirm_kind none", (listed or {}).get("confirm_kind") == "none", json.dumps(listed)[:300])
    snapshot("none-dialog", listed)
    set_reply = rpc("debug.dialog", {"id": id_, "set": {"name": "renamed"}})
    check("none: set allowed", set_reply.get("set.name") is True and not set_reply.get("error"), json.dumps(set_reply)[:300])
    press_reply = rpc("debug.dialog", {"id": id_, "press": "rename"})
    check("none: press rename allowed", press_reply.get("pressed") is True and not press_reply.get("error"), json.dumps(press_reply)[:300])
    check("none: closed by the press", dialog(id_) is None)

    # mixed: the per-button rule. Don't Save is destructive; Save and Cancel are not.
    opened = rpc("debug.dialog", {"open": "save"})
    id_ = int(opened.get("opened") or 0)
    listed = dialog(id_)
    kinds = {b.get("id"): b.get("confirm_kind") for b in (listed or {}).get("buttons") or []}
    check("mixed: per-button kinds", kinds == {"dont-save": "destructive", "cancel": "none", "save": "none"}, json.dumps(kinds))
    snapshot("mixed-dialog", listed)
    refused("mixed", id_, "destructive", {"press": "dont-save"})
    refused("mixed", id_, "destructive", {"key": "cmd-d"})
    reply = rpc("debug.dialog", {"id": id_, "press": "save"})
    check("mixed: press save allowed", reply.get("pressed") is True and not reply.get("error"), json.dumps(reply)[:300])
    check("mixed: closed by the press", dialog(id_) is None)

    # The real quit sheet, when this launch asks (a terminal is open). The end choices are
    # destructive; Keep is not, and pressing it ends this run (last step on purpose).
    report["workspace_new"] = rpc("action.run", {"action": "workspace new", "args": {"focus": True}, "origin": "script"})
    wait(lambda: "terminal" in json.dumps(rpc("debug.focus") or {}), 20)
    rpc("debug.quit", {"open": True})
    asking = wait(lambda: rpc("debug.quit").get("asking"), 10, 0.5)
    report["quit_asked"] = bool(asking)
    if asking:
        sheet = next((d for d in rpc("debug.dialog").get("dialogs") or [] if d.get("identifier") == "cmux.dialog.quit"), None)
        snapshot("quit-dialog", sheet)
        buttons = [b.get("id") for b in (sheet or {}).get("buttons") or []]
        for button in [b for b in ("confirm-quit-everything", "end-everything") if b in buttons or b == "end-everything"]:
            reply = rpc("debug.quit", {"press": button})
            check(f"quit: press {button} refused", (reply.get("refused") or {}).get("confirm_kind") == "destructive", json.dumps(reply)[:300])
            check(f"quit: app alive after press {button}", app.poll() is None and rpc("debug.quit").get("asking") is True)
        reply = rpc("debug.quit", {"press": "keep"})
        check("quit: press keep allowed", reply.get("pressed") is True and not reply.get("error"), json.dumps(reply)[:300])
        try:
            app.wait(30)
        except subprocess.TimeoutExpired:
            pass
        check("quit: keep quits the app", app.poll() is not None)
    else:
        print("UNVERIFIED quit sheet: this launch quits without asking", flush=True)
finally:
    # Leave nothing behind (lane rule): quitEndSessions (an explicit quit, no sheet), then
    # this tag's acpmux daemon and cmux-tui session, then exact PIDs of this bundle only.
    if app.poll() is None:
        rpc("action.run", {"id": "quitEndSessions"})
        try:
            app.wait(30)
        except subprocess.TimeoutExpired:
            app.kill()
            app.wait()
    report["app_exit"] = app.returncode
    acpmux_home = os.path.join(os.path.expanduser("~"), ".cmux/chief/isolated", opts.tag, "acpmux")
    for argv, extra in (([os.path.join(APP, "Contents/Resources/bin/acpmux"), "daemon", "shutdown"],
                         {"ACPMUX_HOME": acpmux_home, "ACPMUX_SOCKET": os.path.join(acpmux_home, "acpmux.sock")}),
                        ([os.path.join(APP, "Contents/Resources/bin/cmux"), "server", "stop", "--session", f"cmux-app-{opts.tag}",
                          "--end-terminals"], {})):
        try:
            subprocess.run(argv, env={**BASE_ENV, **extra}, capture_output=True, timeout=30)
        except (OSError, subprocess.TimeoutExpired) as error:
            report.setdefault("teardown_errors", []).append(str(error))
    time.sleep(3)  # test harness: let the daemons exit before the leftover check
    rows = subprocess.run(["ps", "-axo", "pid=,command="], capture_output=True, text=True).stdout.splitlines()
    leftovers = [int(r.split(None, 1)[0]) for r in rows if APP + "/" in r and int(r.split(None, 1)[0]) != os.getpid()]
    report["helpers_ended"] = leftovers
    for pid in leftovers:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    report["failures"] = failures
    with open(os.path.join(OUT, "dialog-user-only-live.json"), "w") as f:
        json.dump(report, f, indent=1)
print("PASS" if not failures else "FAIL", f"(transcript {OUT}/dialog-user-only-live.json)")
sys.exit(1 if failures else 0)
