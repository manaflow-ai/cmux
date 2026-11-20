#!/usr/bin/env python3
"""Live check: the tips card ("Did you know?"): its x menu (Hide This Tip, Mute Tips for 1 Day or 1 Week,
Never Show Tips) and each tip shown once, ever.

  scripts/cmux-next/tips-mute-live.py --tag <tag> [--out DIR] [--app PATH]

Launches the tagged app with no activation, the automation socket and a scratch cmux.json, then
drives the tips over the socket (`debug.updater {action: "tips", press?, at?}`: `press` is what the
card's menu item sends, `at` picks as at launch at that moment, so the expiry is read only when a
tip would show):

  1. a tip shows; Mute Tips for 1 Day hides it; no tip 23 h later; 15 days later the mute has ended
     and a tip shows (a tip on screen holds every tip for 14 days: FeatureTipBudget);
  2. Mute Tips for 1 Week: no tip 6 days later; a tip again 15 days later;
  3. Hide This Tip: that tip never comes back, 15 days later another one shows;
  4. a timed mute ends when Settings > Show Tips is turned off and on again;
  5. Never Show Tips writes sidebar.cards.tips = false; after a restart still no tip;
     settings.set sidebar.cards.tips true shows tips again;
  6. the x opens its menu (hint mode presses the x as a person does; debug.hints reads the open
     menu's items); window snapshots of the card, and with the agent capture helper (if its daemon
     runs) the card with the menu open, light and dark;
  7. each hint once: a hint the card showed is recorded as seen; after a restart it does not come
     back; the next day none (the 14-day budget); every 15 days every hint shows once, all
     different; with every hint seen no card shows.

`press: "reset"` forgets what the hints remember (a fresh install) before the steps that pick.

GUI host only. Quits the app by its own PID and stops the tag's daemons at the end.
"""
import argparse, glob, json, os, plistlib, socket, subprocess, sys, tempfile, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tag_teardown import TagTeardown  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or tempfile.mkdtemp(prefix="tips-mute-live-"))
parser.add_argument("--app", help="tagged .app (default: found in DerivedData)")
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)

APP = opts.app or next(iter(sorted(glob.glob(os.path.expanduser(
    f"~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/cmux DEV {opts.tag}.app")))), None)
if not APP:
    sys.exit(f"no tagged app for {opts.tag}")
with open(os.path.join(APP, "Contents/Info.plist"), "rb") as f:
    BINARY = os.path.join(APP, "Contents/MacOS", plistlib.load(f)["CFBundleExecutable"])
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
SCRATCH = tempfile.mkdtemp(prefix=f"tips-mute-{opts.tag}-")
CONFIG = os.path.join(SCRATCH, "cmux.json")
GHOSTTY = os.path.join(SCRATCH, "ghostty-config")
BASE_ENV = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"}
CAPTURE_SOCKET = os.path.expanduser("~/Library/Application Support/cmux/agent-capture/run/cua.sock")
MENU = ["Hide This Tip", "Mute Tips for 1 Day", "Mute Tips for 1 Week", "Never Show Tips"]
X_LABEL = "Hide or Mute Tips"
HOUR, DAY = 3600, 86400
failures = []
transcript = []


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


def tips(press=None, at=None):
    params = {"action": "tips"}
    if press:
        params["press"] = press
    if at is not None:
        params["at"] = at
    return rpc("debug.updater", params) or {}


def capture_call(name, args):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(60)
    s.connect(CAPTURE_SOCKET)
    s.sendall(json.dumps({"method": "call", "name": name, "args": args}).encode() + b"\n")
    data = b""
    while not data.endswith(b"\n"):
        chunk = s.recv(1 << 20)
        if not chunk:
            break
        data += chunk
    s.close()
    return json.loads(data or b"{}")


def capture_windows(name, pid):
    """Every on-screen window of the app (the main window and an open menu) through the agent
    capture helper; returns [(png, bounds)]. Empty when the helper's daemon does not run."""
    if not os.path.exists(CAPTURE_SOCKET):
        print(f"SKIP capture {name}: no agent capture helper socket", flush=True)
        return []
    try:
        listed = ((capture_call("list_windows", {"pid": pid}).get("result") or {}).get("structuredContent") or {}).get("windows") or []
    except (OSError, ValueError) as error:
        print(f"SKIP capture {name}: {error}", flush=True)
        return []
    shots = []
    for w in listed:
        if not w.get("is_on_screen", True) or not w.get("bounds") or w["bounds"]["width"] <= 1:
            continue
        path = os.path.join(opts.out, f"{name}-{w['window_id']}.png")
        capture_call("get_window_state", {"pid": pid, "window_id": w["window_id"], "max_elements": 1, "screenshot_out_file": path})
        if os.path.exists(path):
            shots.append({"png": path, "bounds": w["bounds"], "title": w.get("title")})
    write_json(f"{name}-windows.json", shots)
    print(f"capture {name}: {len(shots)} window(s)", flush=True)
    return shots


def write_json(name, value):
    with open(os.path.join(opts.out, name), "w") as f:
        json.dump(value, f, indent=1)


def settle(seconds=1.0):
    time.sleep(seconds)  # let the window redraw before a screenshot (screenshot only)


def launch():
    log = open(os.path.join(opts.out, f"app-{len(apps)}.log"), "w")
    app = subprocess.Popen([BINARY], env={**BASE_ENV, "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
                                          "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": CONFIG,
                                          "CMUX_NEXT_GHOSTTY_CONFIG": GHOSTTY},
                           stdout=log, stderr=subprocess.STDOUT)
    apps.append(app)
    print(f"app pid {app.pid}", flush=True)
    wait_for(lambda: os.path.exists(SOCKET) and "error" not in rpc("debug.focus"), "app socket", 120)
    return app


def quit_app(app):
    rpc("action.run", {"action": "quitEndSessions"}, timeout=10)
    try:
        app.wait(timeout=30)
    except subprocess.TimeoutExpired:
        app.terminate()  # our own recorded PID only
        app.wait(timeout=30)


def loaded_tips(at):
    """The tips state once settings have loaded (enabled is "unknown" before)."""
    return wait_for(lambda: (lambda s: s if s.get("enabled") in ("true", "false") else None)(tips(at=at)),
                    "settings loaded (tips enabled known)", 30) or {}


def setting():
    return (rpc("settings.get", {"path": "sidebar.cards.tips"}) or {}).get("value")


def menu_pass(app, mode):
    """Hint mode presses the card's x (a person's click): its menu opens; debug.hints reads it."""
    rpc("debug.appearance", {"mode": mode})
    rpc("debug.updater", {"action": "tip"})  # today's first tip on the card for the pictures
    settle(1.5)
    rpc("debug.window_snapshot", {"path": os.path.join(opts.out, f"card-{mode}.png")})
    capture_windows(f"card-{mode}", app.pid)
    rpc("settings.set", {"path": "labs.previewFeatures", "value": True})
    rpc("action.run", {"action": "hints.show", "origin": "script"})
    shown = wait_for(lambda: (rpc("debug.hints") or {}).get("hints"), "hint labels", 10) or []
    xs = [h for h in shown if h.get("title") == X_LABEL]
    check(len(xs) == 1, f"{mode}: hint mode labels the card's x '{X_LABEL}': {[h.get('title') for h in shown][:40]}")
    if not xs:
        rpc("debug.key", {"key": "Escape", "modifiers": []})
        return
    for letter in xs[0]["label"]:
        rpc("debug.key", {"key": letter.lower(), "modifiers": []})
    menu = wait_for(lambda: ((rpc("debug.hints") or {}).get("menu") or {}).get("open") and rpc("debug.hints")["menu"], "the x's menu opens", 10) or {}
    check(menu.get("items") == MENU, f"{mode}: the x opens {MENU}: {menu.get('items')}")
    settle(0.8)
    capture_windows(f"menu-{mode}", app.pid)
    rpc("debug.hints", {"dismiss_menu": True})
    wait_for(lambda: not ((rpc("debug.hints") or {}).get("menu") or {}).get("open"), "the menu closes", 10)


with open(CONFIG, "w") as f:
    f.write("{}\n")
with open(GHOSTTY, "w") as f:
    f.write("")
apps = []
teardown = TagTeardown(APP)
teardown.install()
print(f"scratch {SCRATCH}, out {opts.out}", flush=True)
try:
    app = launch()
    state = loaded_tips(time.time())
    check(state.get("enabled") == "true", f"tips on at launch: {state}")
    tips(press="reset")  # a tag that ran this script before has seen hints
    state = tips(at=time.time())
    check(bool(state.get("tip")), f"a tip shows: {state}")

    # 1. one day (the mute's end comes from the app clock: measure from the press)
    now = time.time()
    state = tips(press="tip-mute-day")
    check(state.get("tip") is None and bool(state.get("mutedUntil")), f"Mute Tips for 1 Day hides the tip and records the end: {state}")
    state = tips(at=now + 23 * HOUR)
    check(state.get("tip") is None, f"23 h later: still muted, no tip: {state}")
    state = tips(at=now + 15 * DAY)
    check(bool(state.get("tip")) and state.get("mutedUntil") is None, f"15 days later: the mute ended, a tip shows: {state}")

    # 2. one week (the mute's end comes from the app clock: now)
    real = time.time()
    state = tips(press="tip-mute-week")
    check(state.get("tip") is None and bool(state.get("mutedUntil")), f"Mute Tips for 1 Week hides the tip: {state}")
    state = tips(at=real + 6 * DAY)
    check(state.get("tip") is None, f"6 days later: still muted: {state}")
    state = tips(at=real + 15 * DAY)
    check(bool(state.get("tip")) and state.get("mutedUntil") is None, f"15 days later: a tip shows: {state}")

    # 3. hide this tip only
    hidden = state.get("tip")
    state = tips(press="tip-hide")
    check(state.get("tip") is None and state.get("mutedUntil") is None, f"Hide This Tip hides only today's tip, no mute: {state}")
    state = tips(at=real + 30 * DAY)
    check(bool(state.get("tip")) and state.get("tip") != hidden, f"15 days on another tip shows, never {hidden}: {state}")

    # 4. a timed mute ends when Settings > Show Tips turns on again (all reads inside the week)
    tips(press="reset")
    tips(at=time.time())
    real = time.time()
    state = tips(press="tip-mute-week")
    check(bool(state.get("mutedUntil")), f"muted for a week again: {state}")
    rpc("settings.set", {"path": "sidebar.cards.tips", "value": False})
    state = wait_for(lambda: (lambda s: s if s.get("enabled") == "false" else None)(tips(at=real + HOUR)), "the setting turns tips off") or {}
    check(bool(state.get("mutedUntil")), f"tips off: the week's mute is still recorded: {state}")
    rpc("settings.set", {"path": "sidebar.cards.tips", "value": True})
    state = wait_for(lambda: (lambda s: s if s.get("enabled") == "true" else None)(tips(at=real + 2 * DAY)), "the setting turns tips on") or {}
    check(state.get("mutedUntil") is None, f"Show Tips on again ends the timed mute 2 days into the week: {state}")

    # 5. never
    real = time.time()
    state = tips(press="tip-never")
    check(state.get("tip") is None, f"Never Show Tips hides the tip at once: {state}")
    check(wait_for(lambda: setting() is False, "sidebar.cards.tips is written false") is not None, "Never Show Tips writes sidebar.cards.tips = false")
    state = wait_for(lambda: (lambda s: s if s.get("enabled") == "false" else None)(tips(at=real + 3 * DAY)), "the setting's echo turns tips off") or {}
    check(state.get("tip") is None, f"tips off from the setting, no tip on a later day: {state}")
    with open(CONFIG) as f:
        written = f.read()
    print("cmux.json after Never Show Tips:", written.strip(), flush=True)
    check('"tips"' in written and "false" in written, "the scratch cmux.json holds sidebar.cards.tips false")
    quit_app(app)
    app = launch()
    state = loaded_tips(real + 4 * DAY)
    check(state.get("tip") is None and state.get("enabled") == "false", f"after a restart: tips stay off, no tip: {state}")
    tips(press="reset")
    rpc("settings.set", {"path": "sidebar.cards.tips", "value": True})
    state = wait_for(lambda: (lambda s: s if s.get("tip") else None)(tips(at=real + 4 * DAY)), "a tip after Show Tips on") or {}
    check(state.get("enabled") == "true" and bool(state.get("tip")), f"settings.set sidebar.cards.tips true: tips again: {state}")

    # 6. the x's menu, light and dark
    for mode in ["light", "dark"]:
        menu_pass(app, mode)
    # 7. each hint once, ever
    rpc("debug.updater", {"action": "untip"})
    tips(press="reset")
    start = time.time()
    state = tips(at=start)
    first = state.get("tip")
    check(bool(first), f"fresh state: a hint shows: {state}")
    state = wait_for(lambda: (lambda s: s if first in (s.get("seen") or "").split(",") else None)(tips(at=start)),
                     "the card on screen records the hint as seen") or {}
    check(first in (state.get("seen") or "").split(","), f"seen after the card showed it: {state}")
    quit_app(app)
    app = launch()
    state = loaded_tips(start)
    check(state.get("tip") is None and first in (state.get("seen") or "").split(","), f"after a restart the same hint does not come back: {state}")
    state = tips(at=start + DAY)
    check(state.get("tip") is None, f"the next day no hint: one every 14 days: {state}")
    shown = [first]
    for day in range(15, 15 * 16, 15):
        state = tips(at=start + day * DAY)
        if not state.get("tip"):
            break
        hint = state["tip"]
        wait_for(lambda: hint in (tips(at=start + day * DAY).get("seen") or "").split(","), f"hint {hint} recorded seen")
        shown.append(hint)
    check(len(shown) == len(set(shown)) and len(shown) >= 5, f"day after day each hint shows once, all different: {shown}")
    check(sorted(shown) == sorted((tips(at=start + 300 * DAY).get("seen") or "").split(",")), f"every hint shown is recorded seen: {shown}")
    state = tips(at=start + 400 * DAY)
    check(state.get("tip") is None, f"every hint seen: none picked a month later: {state}")
    rpc("action.run", {"action": "hints.show", "origin": "script"})
    labels = [h.get("title") for h in (wait_for(lambda: (rpc("debug.hints") or {}).get("hints"), "hint labels", 10) or [])]
    rpc("debug.key", {"key": "Escape", "modifiers": []})
    check(bool(labels) and X_LABEL not in labels, f"every hint seen: no hints card on screen (no '{X_LABEL}' control): {labels[:30]}")

    focus = rpc("debug.focus")
    check(not focus.get("app_active"), f"no activation: {focus}")
finally:
    if apps and apps[-1].poll() is None:
        quit_app(apps[-1])
    teardown.end()
    write_json("transcript.json", transcript)

print(f"{len(failures)} failure(s); artifacts in {opts.out}")
sys.exit(1 if failures else 0)
