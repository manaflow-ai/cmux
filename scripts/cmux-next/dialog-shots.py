#!/usr/bin/env python3
"""Screenshots and key checks of every cmux dialog fixture (R96) on a tagged app.

Launches the tagged cmux-next app with the no-activate automation
environment, opens each `debug.dialog` fixture in the main window and once
app-wide, saves `debug.window_snapshot` PNGs of the main window and of the
overlay panel that holds the dialog, checks the keys (Return, Escape,
Command-D, Tab), then quits the app it started (its PID only).

  scripts/cmux-next/dialog-shots.py --tag <tag> --out <dir>

Run it on a fleet GUI host (cmux-lawrence-2), never on a laptop in use.
Exit 1 on a failed check.
"""
import argparse, glob, json, os, signal, subprocess, sys, tempfile, time

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--out", required=True)
parser.add_argument("--app", help="tagged .app (default: found in DerivedData)")
opts = parser.parse_args()

APP = opts.app or next(iter(sorted(glob.glob(os.path.expanduser(
    f"~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/cmux DEV {opts.tag}.app")))), None)
if not APP:
    sys.exit(f"no tagged app for {opts.tag}; pass --app")
BINARY = os.path.join(APP, "Contents/MacOS/cmux DEV")
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
SCRATCH = tempfile.mkdtemp(prefix=f"dialog-shots-{opts.tag}-")
CONFIG = os.path.join(SCRATCH, "cmux.json")
with open(CONFIG, "w") as f:
    f.write("{}\n")
BASE_ENV = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""),
            "TMPDIR": os.environ.get("TMPDIR", "/tmp"), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"}
os.makedirs(opts.out, exist_ok=True)
failures = []


def rpc(method, params=None):
    r = subprocess.run([CLI, "--socket", SOCKET, "rpc", method, json.dumps(params or {})], capture_output=True,
                       text=True, timeout=30, env={**BASE_ENV, "CMUX_SOCKET_PATH": SOCKET, "CMUX_QUIET": "1"})
    try:
        return json.loads(r.stdout)
    except ValueError:
        return {"error": (r.stdout + r.stderr).strip()}


def wait(predicate, seconds, step=0.25):
    deadline = time.time() + seconds
    while time.time() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(step)
    return None


def check(label, ok, detail=""):
    print(f"{'ok  ' if ok else 'FAIL'} {label} {detail}")
    if not ok:
        failures.append(label)


def shot(name, target):
    result = rpc("debug.window_snapshot", {**target, "path": os.path.join(opts.out, f"{name}.png")})
    check(f"snapshot {name}", "path" in result, json.dumps(result)[:200])


if os.path.exists(SOCKET):
    os.unlink(SOCKET)
env = {**BASE_ENV, "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
       "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": CONFIG,
       "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1100,720"}
log = open(os.path.join(SCRATCH, "app.log"), "a")
app = subprocess.Popen([BINARY], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
print(f"launched pid {app.pid} (log {SCRATCH}/app.log)")
try:
    if not wait(lambda: os.path.exists(SOCKET) and rpc("debug.surfaces").get("windows"), 90, 0.5):
        sys.exit("tagged app did not come up")
    time.sleep(1)
    for fixture in ["confirm", "text", "credentials", "save", "choice"]:
        opened = rpc("debug.dialog", {"open": fixture})
        dialogs = opened.get("dialogs") or []
        check(f"{fixture} open", len(dialogs) == 1 and dialogs[0].get("visible"), json.dumps(opened)[:300])
        if not dialogs:
            continue
        shot(f"{fixture}-window", {"kind": "main"})
        if dialogs[0].get("window"):
            shot(f"{fixture}-dialog", {"window": int(dialogs[0]["window"])})
        rpc("debug.dialog", {"dismiss": True})
    # Keys through the same path as typing.
    rpc("debug.dialog", {"open": "save"})
    pressed = rpc("debug.dialog", {"key": "cmd-d"})
    check("save: Command-D presses Don't Save", pressed.get("key") is True and not pressed.get("dialogs"), json.dumps(pressed)[:200])
    rpc("debug.dialog", {"open": "text"})
    rpc("debug.dialog", {"set": {"name": "build"}})
    returned = rpc("debug.dialog", {"key": "return"})
    check("text: Return presses Rename", returned.get("key") is True and not returned.get("dialogs"))
    rpc("debug.dialog", {"open": "confirm"})
    escaped = rpc("debug.dialog", {"key": "escape"})
    check("confirm: Escape cancels", escaped.get("key") is True and not escaped.get("dialogs"))
    rpc("debug.dialog", {"open": "credentials"})
    tabbed = rpc("debug.dialog", {"key": "tab"})
    check("credentials: Tab stays in the dialog", tabbed.get("key") is True and len(tabbed.get("dialogs") or []) == 1)
    rpc("debug.dialog", {"dismiss": True})
    # App scope (no window to attach to).
    app_dialog = rpc("debug.dialog", {"open": "confirm", "scope": "app"})
    dialogs = app_dialog.get("dialogs") or []
    check("app scope open", len(dialogs) == 1 and dialogs[0].get("scope") == "app", json.dumps(app_dialog)[:300])
    if dialogs and dialogs[0].get("window"):
        shot("confirm-app-scope", {"window": int(dialogs[0]["window"])})
    rpc("debug.dialog", {"dismiss": True})
    focus = rpc("debug.focus")
    check("no-activate: the app never took the keyboard", not focus.get("app_active"), json.dumps(focus)[:200])
finally:
    if app.poll() is None:
        app.send_signal(signal.SIGTERM)
        try:
            app.wait(30)
        except subprocess.TimeoutExpired:
            app.kill()
            app.wait()
print(f"screenshots in {opts.out}")
sys.exit(1 if failures else 0)
