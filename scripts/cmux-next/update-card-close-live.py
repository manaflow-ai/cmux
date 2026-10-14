#!/usr/bin/env python3
"""Live check: the bottom-left update cards' Hide button (UPDATE-CARD-CLOSE, Lawrence 2026-10-14: "make
sure we can close bottom left thing for check for updates (like remind in X days, X button to close)",
then "need a more explicit button?": one click hides this version, remind-later moves to right-click).

  scripts/cmux-next/update-card-close-live.py --app "$NX_APP" [--out DIR]

Launches the tagged app with no activation, an isolated Chief home, the automation socket and a
scratch cmux.json. It forces an update state with the existing debug hooks
(`debug.updater {action: "stage" | "available"}`; no feed is touched and no fake appcast item is
served) and clicks through hint mode, which posts a real left click (a Shift label: a right click)
at the control; a right-click menu item is picked with `debug.hints {pick_menu}` (its own action):

  1. "Update Ready" 1.99.0 shows with a "Hide" button (VoiceOver label "Hide Until a Newer
     Version"); one click hides it at once (no menu);
  2. after a relaunch, 1.99.0 staged again stays hidden; 1.99.1 shows the card again;
  3. Check for Updates (the menu's action) shows a hidden card again and clears the hide;
  4. the card's right-click menu: Hide Until a Newer Version, Remind Me in 1 Day / 3 Days / 1 Week;
     Remind Me in 1 Day hides it; after a relaunch still hidden, also for a newer 1.99.2; 23 h later
     still hidden; 25 h later it shows;
  5. the found-update notice (debug.updater available): Hide hides 1.99.3 at once, 1.99.4
     shows it again, its right-click menu's Remind Me in 3 Days hides it;
  6. window captures (main display pixels, through $NX_CAPTURE) of each state, light and dark.

GUI host only (nx-remote --needs gui --app-from-fleet). It quits the app with its own quit and ends
with "$NX_APP_STOP"; it never signals a process.
"""
import argparse, json, os, plistlib, socket, subprocess, sys, tempfile, time

parser = argparse.ArgumentParser()
parser.add_argument("--app", default=os.environ.get("NX_APP"))
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or tempfile.mkdtemp(prefix="update-card-close-"))
opts = parser.parse_args()
if not opts.app:
    sys.exit("--app (or NX_APP) is required")
os.makedirs(opts.out, exist_ok=True)

APP = opts.app
TAG = os.environ.get("NX_APP_TAG") or os.path.basename(APP).removeprefix("cmux DEV ").removesuffix(".app")
with open(os.path.join(APP, "Contents/Info.plist"), "rb") as f:
    BINARY = os.path.join(APP, "Contents/MacOS", plistlib.load(f)["CFBundleExecutable"])
SOCKET = os.environ.get("NX_APP_SOCKET") or f"/tmp/cmux-debug-{TAG}.sock"
CAPTURE = os.environ.get("NX_CAPTURE")
SCRATCH = tempfile.mkdtemp(prefix=f"update-card-close-{TAG}-")
CONFIG = os.path.join(SCRATCH, "cmux.json")
GHOSTTY = os.path.join(SCRATCH, "ghostty-config")
BASE_ENV = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"}
MENU = ["Hide Until a Newer Version", "Remind Me in 1 Day", "Remind Me in 3 Days", "Remind Me in 1 Week"]
HIDE_LABEL = "Hide Until a Newer Version"
HOUR = 3600
failures, transcript, apps, shots = [], [], [], []


def check(ok, what):
    print(("ok   " if ok else "FAIL ") + what, flush=True)
    if not ok:
        failures.append(what)


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
        result = reply.get("result") if reply.get("ok") else {"error": reply.get("error")}
    except (OSError, ValueError) as error:
        result = {"error": str(error)}
    transcript.append({"method": method, "params": params or {}, "result": result})
    return result


def wait_for(predicate, what, seconds=20):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:  # bounded wait for the app's own state
        value = predicate()
        if value:
            return value
        time.sleep(0.2)
    check(False, f"timed out: {what}")
    return None


def snooze(press=None, at=None):
    params = {"action": "snooze"}
    if press:
        params["press"] = press
    if at is not None:
        params["at"] = at
    return rpc("debug.updater", params) or {}


def stage(version):
    rpc("debug.updater", {"action": "stage", "version": version, "changes": 6})
    return snooze()


def settle(seconds=1.0):
    time.sleep(seconds)  # let the window redraw before a capture (capture only)


def shot(name, popups=False):
    """The app's windows at main display pixels (the menu too with popups)."""
    if not CAPTURE:
        print(f"SKIP capture {name}: no NX_CAPTURE", flush=True)
        return
    settle()
    path = os.path.join(opts.out, f"{name}.png")
    cmd = ["bash", CAPTURE, "shot", "--pid", str(apps[-1].pid), "--out", path] + (["--with-popups"] if popups else [])
    done = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    ok = done.returncode == 0 and os.path.exists(path)
    print(f"capture {name}: {'ok' if ok else 'failed ' + done.stderr.strip()[-300:]}", flush=True)
    if ok:
        shots.append(name)


def launch():
    log = open(os.path.join(opts.out, f"app-{len(apps)}.log"), "w")
    app = subprocess.Popen([BINARY], env={**BASE_ENV, "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_CHIEF_ISOLATED": "1",
                                          "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_TEST_WINDOW_SCREEN": "0",
                                          "CMUX_NEXT_CONFIG_FILE": CONFIG, "CMUX_NEXT_GHOSTTY_CONFIG": GHOSTTY},
                           stdout=log, stderr=subprocess.STDOUT)
    apps.append(app)
    print(f"app pid {app.pid}", flush=True)
    wait_for(lambda: os.path.exists(SOCKET) and "error" not in rpc("debug.focus"), "app socket", 120)
    return app


def quit_app(app):
    """The app's own quit (no dialog); a relaunch then reads only what was saved."""
    rpc("action.run", {"action": "quitEndSessions"}, timeout=10)
    try:
        app.wait(timeout=60)
    except subprocess.TimeoutExpired:
        check(False, f"app {app.pid} did not quit by itself")


def press_hint(title, name, menu=False):
    """Clicks the control titled `title` through hint mode (`menu`: a right click)."""
    rpc("settings.set", {"path": "labs.previewFeatures", "value": True})
    rpc("action.run", {"action": "hints.show", "origin": "script"})
    shown = wait_for(lambda: (rpc("debug.hints") or {}).get("hints"), "hint labels", 10) or []
    xs = [h for h in shown if h.get("title") == title]
    check(len(xs) == 1, f"{name}: hint mode labels '{title}' (its VoiceOver label): {[h.get('title') for h in shown][:12]}")
    if not xs:
        rpc("debug.key", {"key": "Escape", "modifiers": []})
        return False
    for letter in xs[0]["label"]:
        rpc("debug.key", {"key": letter.lower() if not menu else letter.upper(), "modifiers": ["shift"] if menu else []})
    return True


def open_menu(name, expected):
    """Right-clicks the card's Hide button through hint mode; returns the menu's items."""
    if not press_hint(HIDE_LABEL, name, menu=True):
        return []
    menu = wait_for(lambda: (lambda m: m if m.get("open") else None)((rpc("debug.hints") or {}).get("menu") or {}), f"{name}: the right-click menu opens", 10) or {}
    check(menu.get("items") == expected, f"{name}: the right-click menu is {expected}: {menu.get('items')}")
    return menu.get("items") or []


def pick(title):
    rpc("debug.hints", {"pick_menu": title})
    wait_for(lambda: not ((rpc("debug.hints") or {}).get("menu") or {}).get("open"), "the menu closes", 10)


with open(CONFIG, "w") as f:
    f.write("{}\n")
with open(GHOSTTY, "w") as f:
    f.write("")
print(f"app {APP}, tag {TAG}, scratch {SCRATCH}, out {opts.out}", flush=True)
try:
    app = launch()
    rpc("debug.appearance", {"mode": "dark"})
    snooze(press="clear")

    # 1. one click on Hide
    state = stage("1.99.0")
    check(state.get("readyCard") == "true", f"Update Ready 1.99.0 shows: {state}")
    shot("1-ready-dark")
    press_hint(HIDE_LABEL, "ready card Hide")
    state = wait_for(lambda: (lambda s: s if s.get("readyCard") == "false" else None)(snooze()), "Hide hides the card") or {}
    check(state.get("closedVersion") == "1.99.0", f"one click on Hide hides the card and records 1.99.0: {state}")
    check(not ((rpc("debug.hints") or {}).get("menu") or {}).get("open"), "Hide opens no menu")
    shot("2-ready-hidden-dark")

    # 2. relaunch: the same version stays hidden, a newer one shows
    quit_app(app)
    app = launch()
    rpc("debug.appearance", {"mode": "dark"})
    state = stage("1.99.0")
    check(state.get("readyCard") == "false" and state.get("closedVersion") == "1.99.0", f"after a relaunch 1.99.0 stays hidden: {state}")
    state = stage("1.99.1")
    check(state.get("readyCard") == "true", f"a newer version (1.99.1) shows the card again: {state}")

    # 3. Check for Updates shows a hidden card again
    press_hint(HIDE_LABEL, "ready card 1.99.1 Hide")
    wait_for(lambda: snooze().get("readyCard") == "false", "1.99.1 hidden")
    rpc("action.run", {"action": "palette.checkForUpdates", "origin": "script"})
    state = wait_for(lambda: (lambda s: s if s.get("readyCard") == "true" else None)(snooze()), "Check for Updates shows the card") or {}
    check(state.get("readyCard") == "true" and state.get("closedVersion") is None,
          f"Check for Updates shows the hidden card and clears the hide: {state}")

    # 4. remind me later from the right-click menu, across a relaunch and a newer version
    rpc("debug.appearance", {"mode": "light"})
    shot("3-ready-light")
    open_menu("ready card", MENU)
    shot("4-ready-menu-light", popups=True)
    pressed = time.time()
    pick(MENU[1])
    state = snooze()
    check(state.get("readyCard") == "false" and bool(state.get("remindAfter")), f"Remind Me in 1 Day hides the card and records the end: {state}")
    quit_app(app)
    app = launch()
    rpc("debug.appearance", {"mode": "light"})
    state = stage("1.99.1")
    check(state.get("readyCard") == "false" and bool(state.get("remindAfter")), f"after a relaunch the reminder holds: {state}")
    state = stage("1.99.2")
    check(state.get("readyCard") == "false", f"a newer version waits for the reminder too: {state}")
    state = snooze(at=pressed + 23 * HOUR)
    check(state.get("readyCard") == "false", f"23 h later still hidden: {state}")
    state = snooze(at=pressed + 25 * HOUR)
    check(state.get("readyCard") == "true" and state.get("remindAfter") is None, f"25 h later the card shows again: {state}")

    # 5. the found-update notice
    rpc("debug.updater", {"action": "unstage"})
    rpc("debug.updater", {"action": "available", "version": "1.99.3"})
    state = wait_for(lambda: (lambda s: s if s.get("noticeCard") == "available" else None)(snooze()), "the found-update notice") or {}
    check(state.get("noticeCard") == "available", f"the found-update notice shows: {state}")
    shot("5-notice-light")
    press_hint(HIDE_LABEL, "notice Hide")
    state = wait_for(lambda: (lambda s: s if s.get("noticeCard") == "none" else None)(snooze()), "Hide hides the notice") or {}
    check(state.get("closedVersion") == "1.99.3", f"one click on the notice's Hide hides 1.99.3: {state}")
    rpc("debug.updater", {"action": "available", "version": "1.99.4"})
    state = wait_for(lambda: (lambda s: s if s.get("noticeCard") == "available" else None)(snooze()), "1.99.4 shows the notice") or {}
    check(state.get("noticeCard") == "available", f"a newer found version (1.99.4) shows the notice again: {state}")
    open_menu("notice card", ["Update", "Release Notes", "-"] + MENU)
    shot("6-notice-menu-light", popups=True)
    pick(MENU[2])
    state = wait_for(lambda: (lambda s: s if s.get("noticeCard") == "none" else None)(snooze()), "Remind Me in 3 Days hides the notice") or {}
    check(state.get("noticeCard") == "none" and bool(state.get("remindAfter")), f"Remind Me in 3 Days hides the notice: {state}")

    focus = rpc("debug.focus")
    check(not focus.get("app_active"), f"no activation: {focus.get('app_active')}")
finally:
    if apps and apps[-1].poll() is None:
        snooze(press="clear")
        rpc("debug.updater", {"action": "unstage"})
        quit_app(apps[-1])
    if os.environ.get("NX_APP_STOP"):
        subprocess.run([os.environ["NX_APP_STOP"]], timeout=120)
    with open(os.path.join(opts.out, "transcript.json"), "w") as f:
        json.dump(transcript, f, indent=1)
    with open(os.path.join(opts.out, "shots.json"), "w") as f:
        json.dump(shots, f)

print(f"{len(failures)} failure(s); artifacts in {opts.out}")
sys.exit(1 if failures else 0)
