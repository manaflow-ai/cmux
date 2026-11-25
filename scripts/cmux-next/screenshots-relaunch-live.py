#!/usr/bin/env python3
"""Live check: Show Screenshots is asked once, not on every relaunch (Lawrence, 2026-11-02, msg 19715).

  scripts/cmux-next/screenshots-relaunch-live.py --app PATH [--out DIR]

1. Launches the app with HOME set to a scratch home whose Desktop (the default macOS screenshot
   folder) holds three sample screenshots. A scratch home is not a folder macOS guards, so no
   privacy dialog stands in the way on a capture Mac nobody answers.
2. Opens cmux://screenshots (`screenshots.open`): the "Show your screenshots?" card shows (a first
   launch); still `card-first.png`.
3. Presses Space on the card (`debug.key`, the card's own key), as the person's click: the grid
   shows; still `grid-after-click.png`.
4. Quits, relaunches the same way and opens the page again: still `relaunch.png`. Fixed: the grid
   shows at once, no card. Before the fix: the card again.

Writes report.json with the app's remembered-click default after each phase. Removes that default
before and after. GUI host only. Exits 1 when the app does not answer its socket.
"""
import argparse, json, os, plistlib, pwd, shutil, signal, socket, subprocess, sys, tempfile, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import build_names  # noqa: E402
from tag_teardown import TagTeardown  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--app", required=True)
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or tempfile.mkdtemp(prefix="screenshots-relaunch-"))
parser.add_argument("--click-x", type=float, default=876)
parser.add_argument("--click-y", type=float, default=430)
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)
APP = os.path.abspath(opts.app.rstrip("/"))
with open(os.path.join(APP, "Contents/Info.plist"), "rb") as f:
    BUNDLE = plistlib.load(f)["CFBundleIdentifier"]
REAL_HOME = pwd.getpwuid(os.getuid()).pw_dir
FAKE_HOME = tempfile.mkdtemp(prefix="shots-home-", dir="/tmp")
KEY = "screenshots.showScreenshotsClicked"
SOCKETS = []
for home in (FAKE_HOME, REAL_HOME):
    SOCKETS += build_names.socket_paths(build_names.of_app(APP, home)["socket"], home)
report = {"bundle": BUNDLE, "phases": {}}


def rpc(method, params=None, timeout=20):
    for path in SOCKETS:
        try:
            conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            conn.settimeout(timeout)
            conn.connect(path)
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
        except (OSError, ValueError):
            continue
    return {"error": "no socket answers"}


def wait_until(predicate, seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:  # bounded wait for the app's own state
        value = predicate()
        if value:
            return value
        time.sleep(0.5)
    return None


def app_pids():
    out = subprocess.run(["pgrep", "-f", os.path.join(APP, "Contents/MacOS/")], capture_output=True, text=True).stdout
    return [int(p) for p in out.split()]


def remembered():
    out = subprocess.run(["defaults", "read", BUNDLE, KEY], capture_output=True, text=True)
    return out.stdout.strip() if out.returncode == 0 else "unset"


def shot(name):
    path = os.path.join(opts.out, name)
    subprocess.run(["screencapture", "-x", path], capture_output=True, timeout=20)
    return path if os.path.exists(path) else None


def launch():
    env = {"HOME": FAKE_HOME, "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1300,820"}
    args = ["open", "-n", "-a", APP]
    for k, v in env.items():
        args += ["--env", f"{k}={v}"]
    subprocess.run(args, check=True, timeout=30)
    if wait_until(lambda: "error" not in (rpc("debug.focus") or {"error": 1}), 90) is None:
        sys.exit("the app does not answer its socket")


def open_page():
    """Opens the page; its tab id when this run made it."""
    reply = rpc("action.run", {"action": "screenshots.open", "focus": True})
    print("screenshots.open", json.dumps(reply)[:300], flush=True)
    time.sleep(4)  # the page draws and, when it lists, reads the three samples
    return ((reply or {}).get("created") or [None])[0]


def quit_app():
    rpc("action.run", {"action": "quit", "wait": False}, timeout=10)
    if wait_until(lambda: not app_pids(), 20) is None:
        for pid in app_pids():
            os.kill(pid, signal.SIGTERM)  # the app this script launched, by its bundle path
        wait_until(lambda: not app_pids(), 10)


desktop = os.path.join(FAKE_HOME, "Desktop")
os.makedirs(desktop)
sample = os.path.join(desktop, "Screenshot 2026-11-02 at 10.00.00.png")
subprocess.run(["screencapture", "-x", sample], capture_output=True, timeout=20)
for n in (1, 2):
    if os.path.exists(sample):
        shutil.copy(sample, os.path.join(desktop, f"Screenshot 2026-11-02 at 10.0{n}.00.png"))
subprocess.run(["defaults", "delete", BUNDLE, KEY], capture_output=True)
teardown = TagTeardown(APP)
teardown.install()
try:
    launch()
    teardown.remember()
    tab = open_page()
    report["phases"]["first"] = {"shot": shot("card-first.png"), "remembered": remembered()}
    # The person's click on Show Screenshots: a synthesized click (debug.mouse, the app's own window) on the
    # button, centered in the page column (window-local points of the default layout), then Space, the card's key.
    # The app's first seconds keep its main thread busy (a request is refused "not_run" after 2 s): retry, bounded.
    clicked = wait_until(lambda: "error" not in (reply := rpc("debug.mouse", {"x": opts.click_x, "y": opts.click_y,
                                                                         "action": "click"}, timeout=30)) and reply, 60)
    print("click", json.dumps(clicked)[:200], flush=True)
    wait_until(lambda: remembered() != "unset", 10)  # the click reaches the button
    if remembered() == "unset":
        print("key", json.dumps(rpc("debug.key", {"key": "space"}))[:200], flush=True)
    time.sleep(3)  # the grid replaces the card and lists the samples
    report["phases"]["click"] = {"shot": shot("grid-after-click.png"), "remembered": remembered()}
    quit_app()
    teardown.end()
    launch()
    teardown.remember()
    open_page()
    report["phases"]["relaunch"] = {"shot": shot("relaunch.png"), "remembered": remembered()}
finally:
    quit_app()
    teardown.end()
    subprocess.run(["defaults", "delete", BUNDLE, KEY], capture_output=True)
    shutil.rmtree(FAKE_HOME, ignore_errors=True)
with open(os.path.join(opts.out, "report.json"), "w") as f:
    json.dump(report, f, indent=2)
print(json.dumps(report), flush=True)
