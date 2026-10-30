#!/usr/bin/env python3
"""Live check: the browser omnibar's focus, hover and cursor rules (cx-d0d.80, `OmnibarPointer`).

  scripts/cmux-next/omnibar-pointer-live.py --tag <tag> [--out DIR] [--app PATH]
  scripts/cmux-next/omnibar-pointer-live.py --socket PATH   (an app already running)
  --engine chromium   a Chromium tab instead of a WebKit one

Launches the tagged app (no activation, automation socket, empty config), opens a WebKit tab and
walks the states with `debug.mouse` (the synthesized pointer and clicks), `debug.key` and
`debug.omnibar` (its `pointer` report: hover, the cursor region at a probe point, frames):

  1. cursor at rest: the I-beam over the text area (the text, above it, past its end), the arrow
     over the chip and the row, the pointing hand over an enabled button;
  2. hover: the bar and a button light under the pointer and clear when it leaves;
  3. a hover does not survive a tab switch: a tab hidden under the pointer and shown again after
     the pointer left shows no hover;
  4. focus: the first click selects the whole address, a second click places the caret, the
     I-beam stays over the text area while editing, Escape returns the keyboard to the page;
  5. a click on the bar above the text, and one past the end of the text, focuses and selects all:
     the I-beam area and the press area are one rectangle (`text_area`);
  6. Cmd-L focuses and selects; typed text reverts on Escape (still focused), a second Escape blurs;
  7. snapshots of rest, hover and editing in light and dark (`debug.window_snapshot`).

The cursor checks are rule checks: `probe_cursor` is the cursor `OmnibarPointer` gives for the
region AppKit hits at the point. `installed_text_cursor` (what the field last installed when AppKit
rebuilt its cursor rects) is printed as a note, because AppKit rebuilds cursor rects lazily for the
key window and a test window here is never key. `tracked_cursor` is the cursor the toolbar row set
on the last pointer move: the row sets it in any window state, because a Chromium page window takes
the key while the page has the keyboard and the parent's cursor rects then do nothing. A never-key
test window is that state, so the moves check the cursor the user sees there.

GUI host only (cmux-lawrence-2 or the M1 Max through nx-remote). An app it launched is quit and
the tag's daemons stopped at the end. Exits 1 when a check fails.
"""
import argparse, glob, json, os, plistlib, socket, subprocess, sys, tempfile, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tag_teardown import TagTeardown  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--tag")
parser.add_argument("--socket", help="attach to the app serving this automation socket instead of launching one")
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or tempfile.mkdtemp(prefix="omnibar-pointer-"))
parser.add_argument("--app", help="tagged .app (default: found in DerivedData)")
parser.add_argument("--engine", choices=("webkit", "chromium"), default="webkit")
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)
if not opts.socket and not opts.tag:
    parser.error("--tag or --socket is required")
SOCKET = opts.socket or f"/tmp/cmux-debug-{opts.tag}.sock"
URL = "https://example.com/"
URL2 = "https://example.org/"
failures = []


def check(ok, what):
    print(("ok   " if ok else "FAIL ") + what, flush=True)
    if not ok:
        failures.append(what)


def call(method, params=None, timeout=30):
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
        return json.loads(buf)
    except (OSError, ValueError) as error:
        return {"ok": False, "error": {"code": "socket", "message": str(error)}}


def rpc(method, params=None):
    reply = call(method, params)
    return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}


def quiet_wait(predicate, seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:  # bounded wait for the app's own state
        value = predicate()
        if value:
            return value
        time.sleep(0.2)
    return None


def wait_for(predicate, what, seconds=20):
    value = quiet_wait(predicate, seconds)
    if not value:
        check(False, f"timed out: {what}")
    return value


def windows():
    report = rpc("debug.focus") or {}
    return report.get("windows") or [] if isinstance(report, dict) else []


def omnibar(probe=None):
    params = {"window": WINDOW}
    if probe:
        params.update({"probe_x": probe[0], "probe_y": probe[1]})
    reply = rpc("debug.omnibar", params) or {}
    return reply if isinstance(reply, dict) else {}


def pointer(probe=None):
    return omnibar(probe).get("pointer") or {}


def center(rect, dy=0.0):
    x, y, w, h = rect
    return (x + w / 2, y + h / 2 + dy)


def mouse(action, point, **extra):
    return rpc("debug.mouse", {"window": WINDOW, "action": action, "x": point[0], "y": point[1], **extra})


def key(name, modifiers=None):
    return rpc("debug.key", {"window": WINDOW, "key": name, "modifiers": modifiers or []})


def probe(point):
    report = pointer(point)
    return report.get("probe_region"), report.get("probe_cursor")


def selection_all(report):
    sel = report.get("selection") or [0, 0]
    return report.get("has_focus") and sel[0] == 0 and sel[1] == len(report.get("text") or "") and sel[1] > 0


def blur():
    for _ in range(5):
        if not omnibar().get("has_focus"):
            return True
        key("escape")
        quiet_wait(lambda: not omnibar().get("has_focus"), 2)
    return not omnibar().get("has_focus")


def snapshot(name):
    path = os.path.join(opts.out, f"{name}.png")
    rpc("debug.window_snapshot", {"window": WINDOW, "path": path})
    print(f"snapshot {path} {os.path.exists(path)}", flush=True)


app = teardown = None
if not opts.socket:
    APP = opts.app or next(iter(sorted(glob.glob(os.path.expanduser(
        f"~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/cmux DEV {opts.tag}.app")))), None)
    if not APP:
        sys.exit(f"no tagged app for {opts.tag}")
    with open(os.path.join(APP, "Contents/Info.plist"), "rb") as f:
        BINARY = os.path.join(APP, "Contents/MacOS", plistlib.load(f)["CFBundleExecutable"])
    SCRATCH = tempfile.mkdtemp(prefix=f"omnibar-pointer-{opts.tag}-")
    CONFIG = os.path.join(SCRATCH, "cmux.json")
    with open(CONFIG, "w") as f:
        f.write("{}\n")
    teardown = TagTeardown(APP)
    teardown.install()
    if os.path.exists(SOCKET):
        os.unlink(SOCKET)
    app = subprocess.Popen([BINARY], env={
        "HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
        "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": CONFIG,
        "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1200,800"},
        stdout=open(os.path.join(opts.out, "app.log"), "w"), stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
    print(f"app pid {app.pid}, scratch {SCRATCH}, out {opts.out}", flush=True)

WINDOW = None
try:
    wait_for(lambda: os.path.exists(SOCKET) and "error" not in (rpc("debug.focus") or {"error": 1}), "app socket", 180)
    if not windows():
        rpc("action.run", {"action": "newWindow", "origin": "script"})
    WINDOW = (wait_for(lambda: windows(), "a window", 60) or [{}])[0].get("id")
    print(f"open a {opts.engine} tab", rpc("action.run", {"action": f"openBrowser.{opts.engine}", "args": {"url": URL}, "focus": True}), flush=True)
    frames = (wait_for(lambda: (pointer().get("frames") or {}).get("text") and pointer()["frames"], "an omnibar with frames", 90)
              or {})
    print("frames", json.dumps(frames), flush=True)
    wait_for(lambda: omnibar().get("text"), "the omnibar shows the page address", 30)
    blur()
    bar, text, toolbar = frames.get("bar"), frames.get("text"), frames.get("toolbar")
    reload_id = next((name for name in frames if name.endswith("reload")), None)
    reload = frames.get(reload_id) if reload_id else None
    chip = frames.get("chip")
    page = (bar[0] + bar[2] / 2, bar[1] + bar[3] + 200) if bar else None
    # The frames at rest (the star shows only at rest), so the points below miss the badges.
    frames = (pointer().get("frames") or frames) if blur() else frames
    bar, text, toolbar = frames.get("bar"), frames.get("text"), frames.get("toolbar")
    text_area = frames.get("text_area")
    above_text = (text[0] + text[2] / 2, bar[1] + 1.5) if bar and text else None
    # Past the end of the short address, inside the text area (left of the star or the bar's end).
    past_text = (text_area[0] + text_area[2] - 4, bar[1] + bar[3] / 2) if bar and text_area else None
    star = frames.get("star")
    if past_text and star and star[0] <= past_text[0] <= star[0] + star[2]:
        check(False, f"the point past the text lands on the star: {past_text} {star}")
        past_text = None
    check(bool(text_area), f"the pointer report has the text area: {text_area}")

    # 1. Cursor at rest.
    rpc("debug.appearance", {"mode": "light"})
    snapshot("light-rest")
    if text:
        check(probe(center(text)) == ("text", "iBeam"), f"rest: I-beam over the text {probe(center(text))}")
    if above_text:
        check(probe(above_text) == ("bar", "iBeam"), f"rest: I-beam over the bar above the text {probe(above_text)}")
    if past_text:
        check(probe(past_text)[1] == "iBeam", f"rest: I-beam past the end of the text {probe(past_text)}")
    print(f"note installed_text_cursor at rest: {pointer().get('installed_text_cursor')}", flush=True)
    if chip:
        check(probe(center(chip))[1] == "arrow" and probe(center(chip))[0] == "control", f"arrow over the chip {probe(center(chip))}")
    if reload:
        check(probe(center(reload)) == ("button", "pointingHand"), f"pointing hand over a button {probe(center(reload))}")
    if toolbar and reload and bar:
        gap = ((reload[0] + reload[2] + bar[0]) / 2, toolbar[1] + 1)
        check(probe(gap)[1] == "arrow", f"arrow over the toolbar row {probe(gap)}")

    # 2. Hover follows the pointer; a move sets the cursor the rules give (`tracked_cursor`).
    for name, point, want in (("the text", center(text) if text else None, "iBeam"), ("the bar above the text", above_text, "iBeam"),
                              ("past the end of the text", past_text, "iBeam"), ("the chip", center(chip) if chip else None, "arrow"),
                              ("a button", center(reload) if reload else None, "pointingHand")):
        if point:
            mouse("move", point)
            check(pointer().get("tracked_cursor") == want, f"rest: a move over {name} sets the {want} {pointer().get('tracked_cursor')}")
    if bar and page:
        mouse("move", center(bar))
        check(bool(wait_for(lambda: pointer().get("bar_hovering"), "bar hover", 5)), "the bar lights under the pointer")
        snapshot("light-hover-bar")
        mouse("move", page)
        check(bool(wait_for(lambda: not pointer().get("bar_hovering"), "bar hover clears", 5)), "the bar clears when the pointer leaves")
    if reload and page:
        mouse("move", center(reload))
        check(bool(wait_for(lambda: reload_id in (pointer().get("hovered_buttons") or []), "button hover", 5)),
              f"Reload lights under the pointer {pointer().get('hovered_buttons')}")
        mouse("move", page)
        check(bool(wait_for(lambda: not pointer().get("hovered_buttons"), "button hover clears", 5)),
              f"no button stays lit after the pointer leaves {pointer().get('hovered_buttons')}")

    # 3. A hover does not survive a tab switch.
    if bar and page:
        mouse("move", center(bar))
        wait_for(lambda: pointer().get("bar_hovering"), "bar hover before the switch", 5)
        print("second tab", rpc("action.run", {"action": f"openBrowser.{opts.engine}", "args": {"url": URL2}, "focus": True}), flush=True)
        wait_for(lambda: "example.org" in (omnibar().get("text") or ""), "the second tab shows", 30)
        mouse("move", page)
        rpc("action.run", {"action": "prevSurface", "focus": True})
        wait_for(lambda: "example.com" in (omnibar().get("text") or ""), "the first tab shows again", 30)
        check(not pointer().get("bar_hovering") and not pointer().get("hovered_buttons"),
              f"no hover left on the tab shown again: {pointer()}")

    # 4. Focus by clicks; the I-beam only while editing.
    if text:
        blur()
        mouse("click", center(text))
        first = wait_for(lambda: selection_all(omnibar()) and omnibar(), "first click focuses and selects all", 5) or omnibar()
        check(selection_all(first), f"first click selects the whole address: {first.get('selection')} of {len(first.get('text') or '')}")
        check(probe(center(text)) == ("text", "iBeam"), f"I-beam over the text while editing {probe(center(text))}")
        print(f"note installed_text_cursor while editing: {pointer().get('installed_text_cursor')}", flush=True)
        for point in (center(text), above_text):
            if point:
                mouse("move", point)
                check(pointer().get("tracked_cursor") == "iBeam", f"editing: a move over the text area sets the I-beam {pointer().get('tracked_cursor')}")
        if above_text:
            check(probe(above_text)[1] == "iBeam", f"I-beam over the bar above the text while editing {probe(above_text)}")
        snapshot("light-editing")
        # The test window is never key, so AppKit drops a raw click on the field editor (it takes no
        # first mouse); debug.omnibar_mouse presses over the text as AppKit does for a key window.
        rpc("debug.omnibar_mouse", {"window": WINDOW, "character": 3})
        print("after second click", {k: omnibar().get(k) for k in ("phase", "text", "selection")}, flush=True)
        second = wait_for(lambda: (omnibar().get("selection") or [0, 1])[1] == 0 and omnibar(), "second click places the caret", 5) or omnibar()
        check(second.get("has_focus") and (second.get("selection") or [0, 1])[1] == 0, f"second click places the caret: {second.get('selection')}")
        # cx-d0d.87: the second click shows the full address with the caret at the click; it is
        # never an edit (phase editing), so one Escape returns to the page.
        after = omnibar()
        focused = after.get("phase") == "focused" and not after.get("elided") and after.get("text") == URL
        check(focused, f"the second click keeps the omnibar focused on the full address, not editing: "
                       f"{after.get('phase')} {after.get('text')!r} {after.get('selection')}")
        if not focused:  # the state machine's last inputs (DEBUG builds), to name the input that edited
            for line in (after.get("pointer") or {}).get("omnibar_trace") or []:
                print("   trace", line, flush=True)
        key("escape")
        print("after Escape", {k: omnibar().get(k) for k in ("phase", "text", "selection")}, flush=True)
        check(bool(wait_for(lambda: not omnibar().get("has_focus"), "one Escape blurs", 3)), "one Escape after the clicks returns to the page")
        blur()
        check(probe(center(text)) == ("text", "iBeam"), f"I-beam over the text after the omnibar blurs {probe(center(text))}")

    # 5. A click anywhere in the text area (the I-beam area) focuses and selects all.
    for name, point in (("above the text", above_text), ("past the end of the text", past_text)):
        if not point:
            continue
        for attempt in range(3):  # three presses each: a flake shows up here, not in a later run
            blur()
            before = omnibar()
            mouse("click", point)
            bar_click = bool(wait_for(lambda: selection_all(omnibar()), f"bar click {name} focuses", 5))
            after = omnibar()
            check(bar_click, f"a click on the bar {name} focuses and selects all ({attempt + 1}/3): {after.get('phase')} "
                             f"{after.get('text')!r} {after.get('selection')}")
            if not bar_click:  # what the field held before the click, and the state machine's last inputs
                print("   before the click", {k: before.get(k) for k in ("phase", "field_editor_active", "field_text", "field_selection")}, flush=True)
                for line in (after.get("pointer") or {}).get("omnibar_trace") or []:
                    print("   trace", line, flush=True)
        blur()

    # 6. Cmd-L, typed text, Escape twice.
    rpc("action.run", {"action": "focusLocation", "focus": True})
    check(bool(wait_for(lambda: selection_all(omnibar()), "Cmd-L focuses", 5)), f"Cmd-L focuses and selects all: {omnibar().get('selection')}")
    shown = omnibar().get("text")
    rpc("debug.omnibar_type", {"window": WINDOW, "text": "zzqx", "commit": False})
    wait_for(lambda: omnibar().get("phase") == "editing", "typing edits", 5)
    for _ in range(3):  # Escape closes a suggestion card first, then reverts
        key("escape")
        if quiet_wait(lambda: omnibar().get("phase") == "focused", 1.5):
            break
    reverted = omnibar()
    # The reverted address shows elided again (the host at rest), so compare without the scheme.
    def bare(value):
        return (value or "").removeprefix("https://").removeprefix("http://").rstrip("/")
    check(reverted.get("has_focus") and bare(reverted.get("text")) == bare(shown), f"Escape reverts typed text and keeps focus: {reverted.get('phase')} {reverted.get('text')!r}")
    key("escape")
    check(bool(wait_for(lambda: not omnibar().get("has_focus"), "second Escape blurs", 5)), "a second Escape returns to the page")
    check(omnibar().get("consistent") is True, "the field editor matches the state machine")

    # 7. Dark snapshots.
    rpc("debug.appearance", {"mode": "dark"})
    if page:
        mouse("move", page)
    snapshot("dark-rest")
    if bar:
        mouse("move", center(bar))
        snapshot("dark-hover-bar")
    if text:
        mouse("click", center(text))
        snapshot("dark-editing")
        blur()
    rpc("debug.appearance", {"mode": "system"})

    # 8. Pointer moves over a New Tab page and back over a browser toolbar keep the app alive.
    print("new tab page", rpc("action.run", {"action": "newTab.page", "focus": True}), flush=True)
    for point in ((600, 20), (600, 44), (300, 44), (600, 300), (40, 400)):
        mouse("move", point)
    check("error" not in (rpc("debug.focus") or {"error": 1}), "the app answers after moves over a New Tab page")
    rpc("action.run", {"action": "prevSurface", "focus": True})
    for point in ((center(text) if text else None), (center(reload) if reload else None), page):
        if point:
            mouse("move", point)
    check("error" not in (rpc("debug.focus") or {"error": 1}), "the app answers after moves over the toolbar and the page")
finally:
    if app:
        rpc("debug.quit", {"fixture_quit": "end-sessions"})
        try:
            app.wait(timeout=20)
        except subprocess.TimeoutExpired:
            app.kill()  # the exact PID this script started
            app.wait()
        teardown.end()

print(f"{len(failures)} failure(s); artifacts in {opts.out}")
sys.exit(1 if failures else 0)
