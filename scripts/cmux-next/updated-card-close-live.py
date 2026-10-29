#!/usr/bin/env python3
"""Live check: the "Updated to Nightly" card's x closes it (Lawrence 2026-10-23: "i cant X this out
anymore even when hovering on it").

  scripts/cmux-next/updated-card-close-live.py --app "$NX_APP" [--out DIR]

Launches the tagged app with no activation, an isolated Chief home, the automation socket and a
scratch cmux.json, and shows the Updated card (`debug.updater {action: "updated"}`). Then:

  1. the pointer on the card shows its x; no other window of the app is over it, and the window's
     own hit test at its center reaches the x, which takes a first click in a window that is not
     key (a Chromium page's window holds the key while the person works in a chat);
  2. a click on the x (`debug.mouse`, the path a real click takes: the app's event queue, the
     window's hit test; the window is not key) closes the card;
  3. after a relaunch the card stays closed (the close is saved for this build);
  4. the card shown again: a click into it, then Escape closes it;
  5. main window captures (debug.window_snapshot): the card with the pointer on its x, and the
     sidebar after the close.

GUI host only (nx-remote --needs gui --app-from-fleet). With --real (an input host, nx-remote --needs
input) the app runs active and the real pointer moves and clicks. It quits the app with its own quit; it never
signals a process.
"""
import argparse, json, os, plistlib, socket, subprocess, sys, tempfile, time

parser = argparse.ArgumentParser()
parser.add_argument("--app", default=os.environ.get("NX_APP"))
parser.add_argument("--real", action="store_true",
                    help="input host (--needs input): the app runs active; the real pointer moves (pointer-probe) and clicks (cua-driver)")
parser.add_argument("--cua", default=os.path.expanduser("~/.local/bin/cua-driver"))
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or tempfile.mkdtemp(prefix="updated-card-close-"))
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
SCRATCH = tempfile.mkdtemp(prefix=f"updated-card-close-{TAG}-")
CONFIG = os.path.join(SCRATCH, "cmux.json")
GHOSTTY = os.path.join(SCRATCH, "ghostty-config")
BASE_ENV = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"}
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


def shot(name):
    """The main window as the window server composited it (`debug.window_snapshot`, kind main)."""
    time.sleep(1.0)  # let the window redraw before a capture (capture only)
    path = os.path.join(opts.out, f"{name}.png")
    done = rpc("debug.window_snapshot", {"kind": "main", "path": path}, timeout=60) or {}
    ok = os.path.exists(path)
    print(f"capture {name}: {'ok' if ok else 'failed'} {done}", flush=True)
    if ok:
        shots.append(name)


def launch():
    log = open(os.path.join(opts.out, f"app-{len(apps)}.log"), "w")
    activation = {} if opts.real else {"CMUX_NEXT_NO_ACTIVATE": "1"}
    app = subprocess.Popen([BINARY], env={**BASE_ENV, **activation, "CMUX_NEXT_CHIEF_ISOLATED": "1",
                                          "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_TEST_WINDOW_SCREEN": "0",
                                          "CMUX_NEXT_CONFIG_FILE": CONFIG, "CMUX_NEXT_GHOSTTY_CONFIG": GHOSTTY},
                           stdout=log, stderr=subprocess.STDOUT)
    apps.append(app)
    print(f"app pid {app.pid}", flush=True)
    wait_for(lambda: os.path.exists(SOCKET) and "error" not in (rpc("debug.focus") or {"error": 1}), "app socket", 120)
    rpc("debug.appearance", {"mode": "dark"})
    return app


def quit_app(app):
    rpc("action.run", {"action": "quitEndSessions"}, timeout=10)
    try:
        app.wait(timeout=60)
    except subprocess.TimeoutExpired:
        check(False, f"app {app.pid} did not quit by itself")


PROBE = None
if opts.real:
    PROBE = os.path.join(tempfile.mkdtemp(prefix="pointer-probe-"), "pointer-probe")
    subprocess.run(["xcrun", "swiftc", "-O", os.path.join(os.path.dirname(os.path.abspath(__file__)), "pointer-probe.swift"),
                    "-o", PROBE], check=True)


def probe(*args):
    return subprocess.run([PROBE, *map(str, args)], capture_output=True, text=True, timeout=20).stdout.strip()


def cua(tool, params):
    try:
        out = subprocess.run([opts.cua, "call", tool, json.dumps(params)], capture_output=True, text=True, timeout=60).stdout
        return json.loads(out)
    except (OSError, subprocess.TimeoutExpired, ValueError) as error:
        return {"error": str(error)}


def to_screen(point):
    """A window point from the top left to a screen point from the top left."""
    main = next((w for w in (rpc("debug.window_list") or {}).get("windows") or [] if w.get("kind") == "main" and w.get("visible")), {})
    f = main.get("frame") or {}
    return f.get("x", 0) + point[0], float(probe("screen")) - (f.get("y", 0) + f.get("height", 0)) + point[1]


def is_active():
    return (rpc("debug.focus") or {}).get("app_active")


def activate():
    if is_active():
        return
    reply = cua("bring_to_front", {"pid": apps[-1].pid})
    if wait_until(is_active, 3):
        return
    # A real click on the window's empty title area activates the app, as a person's would.
    x, y = to_screen((600, 12))
    scale = float(cua("get_screen_size", {}).get("scale_factor") or 2.0)
    click = cua("click", {"x": round(x * scale), "y": round(y * scale), "scope": "desktop"})
    check(bool(wait_until(is_active, 5)), f"the app is active (bring_to_front {str(reply)[:160]}; title click {str(click)[:160]})")


def wait_until(predicate, seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:  # bounded wait for the window server's state
        if predicate():
            return True
        time.sleep(0.2)
    return False


def pointer_move(point):
    """The pointer onto `point` (window points from the top left): real mouse-moved events along a
    path with --real, else a move posted to the app (`debug.mouse`)."""
    if not opts.real:
        rpc("debug.mouse", {"action": "move", "x": point[0], "y": point[1]})
        return
    activate()
    x, y = to_screen(point)
    try:
        x0, y0 = map(float, probe("where").split())
    except ValueError:
        x0, y0 = x - 40, y
    probe("path", x0, y0, x - 3, y, 8)
    probe("path", x - 3, y, x, y, 2)


def pointer_click(point):
    if not opts.real:
        rpc("debug.mouse", {"action": "click", "x": point[0], "y": point[1]})
        return
    pointer_move(point)
    x, y = to_screen(point)
    scale = float(cua("get_screen_size", {}).get("scale_factor") or 2.0)
    reply = cua("click", {"x": round(x * scale), "y": round(y * scale), "scope": "desktop"})
    print(f"   real click at screen ({x:.0f}, {y:.0f}): {(reply.get('summary') if isinstance(reply, dict) else None) or str(reply)[:160]}", flush=True)


def make_key():
    """The main window takes key, as the window a person points at is (WebKit hovers and takes a
    click without a first-mouse only in the key window); the app is not activated."""
    if opts.real:
        return activate()
    window = (((rpc("debug.focus") or {}).get("windows") or [{}])[0]).get("id")
    print(f"key window: {rpc('debug.window.focus', {'window': window})}", flush=True)


def surfaces():
    return rpc("debug.update_surfaces", {"action": "state"}) or {}


def show_card(name):
    wait_for(lambda: "error" not in (rpc("debug.updater", {"action": "updated", "previous": "0.0.1"}) or {"error": 1}),
             f"{name}: debug.updater updated", 30)
    state = wait_for(lambda: (lambda s: s if s.get("updatedFrame") and float(s.get("updatedHeight") or 0) > 0 else None)(surfaces()),
                     f"{name}: the Updated card shows and has drawn", 40) or {}
    check(bool(state.get("updatedFrame")), f"{name}: the Updated card shows: {state}")
    # The card grows once the notes of the whole update load: wait until its frame holds still.
    last, steady, deadline = None, 0, time.monotonic() + 20
    while time.monotonic() < deadline and steady < 5:  # bounded wait for the card's own layout
        state = surfaces()
        steady = steady + 1 if state.get("updatedFrame") == last else 0
        last = state.get("updatedFrame")
        time.sleep(0.4)
    print(f"{name}: settled frame {last}", flush=True)
    return state


def updated_page():
    pages = (rpc("debug.page", {"page": "cmux.changelog", "action": "list"}) or {}).get("pages") or []
    for page in pages:
        if page.get("parked"):
            continue
        state = rpc("debug.page", {"page": "cmux.changelog", "instance": page.get("instance"), "action": "state"}) or {}
        if "surface/updated" in json.dumps(state):
            return page.get("instance")
    return None


def window_point(state, instance, selector):
    """The center of `selector` in the card's page, in window points from the top-left."""
    found = rpc("debug.page", {"page": "cmux.changelog", "instance": instance, "action": "hover", "selector": selector}) or {}
    if "x" not in found:
        return None, found
    left, top, _, _ = state["updatedFrame"]
    zoom = float(state.get("updatedZoom") or 1)
    return (left + found["x"] * zoom, top + found["y"] * zoom), found


def closed():
    state = surfaces()
    return state if state.get("updatedCard") == "false" else None


with open(CONFIG, "w") as f:
    f.write("{}\n")
with open(GHOSTTY, "w") as f:
    f.write("")
print(f"app {APP}, tag {TAG}, scratch {SCRATCH}, out {opts.out}", flush=True)
try:
    app = launch()
    state = show_card("first")
    instance = wait_for(updated_page, "the Updated card's page", 20)
    frame = state.get("updatedCloseFrame")
    check(bool(frame), f"the card has an x: {frame}")
    point = (frame[0] + frame[2] / 2, frame[1] + frame[3] / 2) if frame else None
    if point:
        make_key()
        x, y = point
        windows = (rpc("debug.window_list") or {}).get("windows") or []
        main = next((w for w in windows if w.get("kind") == "main"), {})
        mf = main.get("frame") or {}
        # The x in screen points from the bottom left (window list frames), to find windows over it.
        sx, sy = mf.get("x", 0) + x, mf.get("y", 0) + mf.get("height", 0) - y
        for w in windows:
            f = w.get("frame") or {}
            over = f.get("x", 0) <= sx <= f.get("x", 0) + f.get("width", 0) and f.get("y", 0) <= sy <= f.get("y", 0) + f.get("height", 0)
            if over and w.get("visible") and not w.get("ignores_mouse") and w is not main and w.get("kind") != "main":
                check(False, f"1a. no window over the x takes the pointer: {w.get('class')} {w.get('kind')} {f}")
        pointer_move((x, y))
        shown = wait_for(lambda: surfaces().get("updatedCloseShown") == "true", "1b. the pointer on the card shows its x", 5)
        check(bool(shown), f"1b. the pointer on the card shows its x: {surfaces().get('updatedCloseShown')}")
        hit = rpc("debug.update_surfaces", {"action": "hit", "x": x, "y": y}) or {}
        check(hit.get("onUpdatedClose") is True and hit.get("acceptsFirstMouse") is True,
              f"1. a click at the x ({x:.0f}, {y:.0f}) reaches the x, which takes a first click in a window that is not key: {hit}")
        shot("1-card-pointer-on-x")
        pointer_click((x, y))
        after = wait_for(closed, "2. a click on the x closes the card", 10)
        check(after is not None, f"2. a click on the x closes the card: {after or surfaces()}")
        shot("2-card-closed")
        if after is None:
            # Controls: does the page's own click on the x close it (the dismiss chain), and does a
            # posted click reach the page at all (See What's New opens the changelog)?
            if surfaces().get("updatedCard") == "true":
                state = surfaces()
                see, _ = window_point(state, instance, ".wn-card-primary")
                if see:
                    pointer_click(see)
                    time.sleep(2)  # the changelog opens (bounded, diagnostic only)
                    print(f"control: posted click on See What's New -> topPage {surfaces().get('topPage')!r} selectedPage {surfaces().get('selectedPage')!r}", flush=True)
                rpc("debug.update_surfaces", {"action": "dismiss-updated"})

    quit_app(app)
    app = launch()
    time.sleep(3)  # the card would show at launch; give the sidebar its first layout (bounded)
    check(surfaces().get("updatedCard") == "false", f"3. after a relaunch the card stays closed: {surfaces()}")

    state = show_card("again")
    if state.get("updatedFrame"):
        left, top, width, _ = state["updatedFrame"]
        make_key()
        # A click into the card's text (its left part, under the eyebrow): the page takes key focus.
        pointer_click((left + 24, top + 14))
        rpc("debug.key", {"key": "Escape", "modifiers": []})
        after = wait_for(closed, "4. Escape closes the card", 10)
        check(after is not None, f"4. a click into the card, then Escape, closes it: {after or surfaces()}")
    quit_app(app)
finally:
    for app in apps:
        if app.poll() is None:
            quit_app(app)
    with open(os.path.join(opts.out, "transcript.json"), "w") as f:
        json.dump({"failures": failures, "shots": shots, "transcript": transcript}, f, indent=1)

print(f"{'FAIL' if failures else 'PASS'}: {len(failures)} failure(s); captures {shots}", flush=True)
sys.exit(1 if failures else 0)
