#!/usr/bin/env python3
"""Live check: the bookmark bubble is a popup of the shared native host (NativePopupHost, hq
.cmux-scratch/omnibar-popups/REUSE.md slice 1), not an NSPopover.

  scripts/cmux-next/bookmark-bubble-live.py --tag <tag> [--app PATH] [--out DIR] [--page-popup] [--real-click]

Launches the tagged app (no activation, automation socket, empty config), opens a WebKit tab and
walks the bubble through the socket:

  1. `bookmark.addPage` opens it: one visible `bookmarks.edit` panel, a child of the browser
     window, its card under the star and inside the window's width; no NSPopover window;
  2. the same action again closes it (the star toggles the bubble), the page stays bookmarked.
     A raw click on the star is not checked here: the test window is never key, so AppKit drops
     a first click on the star (it takes no first mouse); a real click needs an active app;
  3. it opens again, and a click on the page outside it closes it;
  4. it opens again with the window not key: `debug.window_list` shows it shown (alpha 1);
  5. a star pressed before the page has a title: the name follows the title when it arrives
     (saved on close);
  6. Page Info opens on the same host (REUSE.md slice 3): a `pageInfo` child panel of the browser
     window under the omnibar; a click on the page closes it;
  7. with --real-click (a `nx-remote --needs input` job only): a real pointer click on the star
     (cua-driver, foreground) opens the bubble and a second one closes it.

With $NX_CAPTURE (GUI host) it saves 2x captures of the window with the bubble (light and dark)
as bubble-light.png / bubble-dark.png, and of Page Info as pageinfo-light.png / pageinfo-dark.png. With --page-popup it then runs page-popup-escape-e2e.py on
the same app (the page menus moved onto the same host). GUI host only; exits 1 on a failure.
"""
import argparse, glob, json, os, plistlib, socket, subprocess, sys, tempfile, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tag_teardown import TagTeardown  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--app")
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or tempfile.mkdtemp(prefix="bookmark-bubble-"))
parser.add_argument("--page-popup", action="store_true")
parser.add_argument("--real-click", action="store_true")
parser.add_argument("--cua", default=os.path.expanduser("~/.local/bin/cua-driver"))
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
failures = []


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
    except (OSError, ValueError) as error:
        return {"error": str(error)}
    return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}


def quiet_wait(predicate, seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:  # bounded wait for the app's own state
        value = predicate()
        if value:
            return value
        time.sleep(0.2)
    return None


def windows():
    return (rpc("debug.window_list") or {}).get("windows") or []


def bubbles():
    return [w for w in windows() if w.get("kind") == "bookmarks.edit" and w.get("visible") and (w.get("alpha") or 0) > 0.5]


APP = opts.app or next(iter(sorted(glob.glob(os.path.expanduser(
    f"~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/cmux DEV {opts.tag}.app")))), None)
if not APP:
    sys.exit(f"no tagged app for {opts.tag}")
with open(os.path.join(APP, "Contents/Info.plist"), "rb") as f:
    BINARY = os.path.join(APP, "Contents/MacOS", plistlib.load(f)["CFBundleExecutable"])
scratch = tempfile.mkdtemp(prefix=f"bookmark-bubble-{opts.tag}-")
config = os.path.join(scratch, "cmux.json")
with open(config, "w") as f:
    f.write("{}\n")
teardown = TagTeardown(APP)
teardown.install()
if os.path.exists(SOCKET):
    os.unlink(SOCKET)
app = subprocess.Popen([BINARY], env={
    "HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
    "CMUX_NEXT_TEST_WINDOW_SCREEN": "0", "CMUX_NEXT_CONFIG_FILE": config, "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,760,480"},
    stdout=open(os.path.join(opts.out, "app.log"), "w"), stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
print(f"app pid {app.pid}, out {opts.out}", flush=True)
try:
    check(bool(quiet_wait(lambda: os.path.exists(SOCKET) and "error" not in (rpc("debug.focus") or {"error": 1}), 180)), "app socket")
    focus_windows = lambda: (rpc("debug.focus") or {}).get("windows") or []
    if not focus_windows():
        rpc("action.run", {"action": "newWindow", "origin": "script"})
    WINDOW = (quiet_wait(focus_windows, 60) or [{}])[0].get("id")
    print("open", rpc("action.run", {"action": "openBrowser.webkit", "args": {"url": "https://example.com/"}, "focus": True}), flush=True)
    omnibar = lambda: rpc("debug.omnibar", {"window": WINDOW}) or {}
    check(bool(quiet_wait(lambda: "example.com" in (omnibar().get("text") or ""), 60)), "the tab shows example.com")
    main = next((w for w in windows() if w.get("kind") == "main" and w.get("visible")), None)
    check(main is not None, "the browser window is in debug.window_list")
    MARGIN = 10  # PopupStyle shadow band around the card in the panel frame

    def card(window):
        f = window["frame"]
        return {"x": f["x"] + MARGIN, "y": f["y"] + MARGIN, "width": f["width"] - 2 * MARGIN, "height": f["height"] - 2 * MARGIN}

    def open_bubble(what):
        quiet_wait(lambda: not [w for w in windows() if w.get("kind") == "bookmarks.edit" and w.get("visible")], 5)  # a closing one has faded
        rpc("action.run", {"action": "bookmark.addPage", "focus": True})
        shown = quiet_wait(lambda: bubbles(), 5) or []
        check(len(shown) == 1, f"{what}: one bookmark bubble shows ({len(shown)})")
        if len(shown) != 1:  # what the window list holds for the bubble
            print("   bubble windows", [{k: w.get(k) for k in ("id", "visible", "alpha", "key", "parent", "frame")}
                                      for w in windows() if w.get("kind") == "bookmarks.edit"], flush=True)
        return shown[0] if shown else None

    def saved():
        rows = (rpc("bookmark.list", {"text": "example.com"}) or {}).get("bookmarks") or []
        return [(r.get("title"), r.get("url")) for r in rows]

    # 1. Opens under the star as a child panel of the browser window.
    bubble = open_bubble("bookmark.addPage")
    first = saved()
    print("bookmarks after the add", first, flush=True)
    check(len(first) == 1, f"the star bookmarked the page once: {first}")
    if bubble and main:
        check(bubble.get("parent") == main.get("id"), f"the bubble is a child of the browser window: {bubble.get('parent')} vs {main.get('id')}")
        check("Popover" not in (bubble.get("class") or ""), f"the bubble is not an NSPopover window: {bubble.get('class')}")
        check(not any("Popover" in (w.get("class") or "") and w.get("visible") for w in windows()), "no NSPopover window is visible")
        mf, bf = main["frame"], card(bubble)
        star = ((omnibar().get("pointer") or {}).get("frames") or {}).get("star")
        if star:
            # Star in window points from the top left; screen y is up.
            star_bottom = mf["y"] + mf["height"] - (star[1] + star[3])
            card_top = bf["y"] + bf["height"]
            check(card_top <= star_bottom + 2 and card_top >= star_bottom - 40,
                  f"the bubble opens under the star: card top {card_top:.0f}, star bottom {star_bottom:.0f}")
            star_right = mf["x"] + star[0] + star[2]
            check(abs(bf["x"] + bf["width"] - star_right) <= 2, f"the bubble's trailing edge lines up with the star: {bf} star right {star_right}")
        check(bf["x"] >= mf["x"] - 30 and bf["x"] + bf["width"] <= mf["x"] + mf["width"] + 30,
              f"the bubble stays over the window: {bf} in {mf}")
    cap = os.environ.get("NX_CAPTURE")
    if cap and bubble:
        for mode, theme in (("light", "Catppuccin Latte"), ("dark", "Catppuccin Mocha")):
            rpc("settings.set", {"path": "appearance.theme", "value": theme})
            rpc("debug.appearance", {"mode": mode})
            time.sleep(1.5)  # proof capture only: the theme repaint
            path = os.path.join(opts.out, f"bubble-{mode}.png")
            result = subprocess.run(["bash", cap, "shot", "--pid", str(app.pid), "--with-popups", "--out", path],
                                    capture_output=True, text=True)
            print(f"capture {mode} rc={result.returncode} {os.path.exists(path)}", flush=True)
    # 2. The star toggles it.
    rpc("action.run", {"action": "bookmark.addPage", "focus": True})
    check(bool(quiet_wait(lambda: not bubbles(), 5)), "bookmark.addPage again closes the bubble")
    check(((omnibar().get("pointer") or {}).get("frames") or {}).get("star") is not None, "the star still shows (the page stays bookmarked)")
    named = lambda: [(t, u) for t, u in saved()]
    check([u for _, u in named()] == [u for _, u in first], f"closing the bubble keeps the bookmark: {saved()} (was {first})")
    check(all(t for t, _ in named()), f"the bookmark's name is the page title, not empty: {saved()}")
    # 3. A click on the page outside closes it.
    bubble = open_bubble("reopen")
    if bubble and main:
        # A click on the page under the toolbar (a click in the sidebar would move to another tab).
        bar = ((omnibar().get("pointer") or {}).get("frames") or {}).get("bar") or [300, 30, 300, 24]
        rpc("debug.mouse", {"window": WINDOW, "action": "click", "x": bar[0] + bar[2] / 2, "y": bar[1] + bar[3] + 150})
        check(bool(quiet_wait(lambda: not bubbles(), 5)), "a click outside the bubble closes it")
        check([u for _, u in saved()] == [u for _, u in first], f"a click outside keeps the bookmark: {saved()}")
    # 4. Shown without the keys (the app is never active here) it still shows.
    bubble = open_bubble("reopen without the keys")
    if bubble:
        check(not bubble.get("key"), f"the bubble takes no keys while the app is inactive: key={bubble.get('key')}")
    rpc("action.run", {"action": "bookmark.addPage", "focus": True})

    def capture(name):
        cap = os.environ.get("NX_CAPTURE")
        if not cap:
            return
        for mode, theme in (("light", "Catppuccin Latte"), ("dark", "Catppuccin Mocha")):
            rpc("settings.set", {"path": "appearance.theme", "value": theme})
            rpc("debug.appearance", {"mode": mode})
            time.sleep(1.5)  # proof capture only: the theme repaint
            path = os.path.join(opts.out, f"{name}-{mode}.png")
            result = subprocess.run(["bash", cap, "shot", "--pid", str(app.pid), "--with-popups", "--out", path],
                                    capture_output=True, text=True)
            print(f"capture {name} {mode} rc={result.returncode} {os.path.exists(path)}", flush=True)

    def click_page():
        bar = ((omnibar().get("pointer") or {}).get("frames") or {}).get("bar") or [300, 30, 300, 24]
        rpc("debug.mouse", {"window": WINDOW, "action": "click", "x": bar[0] + bar[2] / 2, "y": bar[1] + bar[3] + 150})

    # 5. A star pressed before the page has a title: the name follows the title.
    quiet_wait(lambda: not [w for w in windows() if w.get("kind") == "bookmarks.edit" and w.get("visible")], 5)
    rpc("action.run", {"action": "openBrowser.webkit", "args": {"url": "https://example.org/"}, "focus": True})
    # The star needs the page's URL; press it as soon as the tab has one, before the title loads.
    # Press again only while the star refuses (no URL yet): a second accepted press would close it.
    quiet_wait(lambda: "error" not in (rpc("action.run", {"action": "bookmark.addPage", "focus": True}) or {"error": 1}), 20)
    org = lambda: [r.get("title") for r in (rpc("bookmark.list", {"text": "example.org"}) or {}).get("bookmarks") or []]
    early = org()
    print("example.org bookmark right after the star", early, flush=True)
    check(bool(quiet_wait(bubbles, 5)), "the star opens the bubble on a page still loading")
    late = not any(t and "Example" in t for t in early)
    print("late title tested" if late else "NOTE late title not tested: the page had its title before the star", flush=True)
    quiet_wait(lambda: "example.org" in (omnibar().get("text") or ""), 30)
    time.sleep(10.0)  # proof only: the page title loads and hops into the open bubble (no title RPC)
    rpc("action.run", {"action": "bookmark.addPage", "focus": True})
    quiet_wait(lambda: not bubbles(), 5)
    titles = quiet_wait(lambda: [t for t in org() if t], 10) or org()
    check(any(t and "Example" in t for t in titles), f"the new bookmark's name is the page title: {titles}")
    # 6. Page Info on the same host.
    rpc("action.run", {"action": "browser.pageInfo", "focus": True})
    infos = lambda: [w for w in windows() if w.get("kind") == "pageInfo" and w.get("visible") and (w.get("alpha") or 0) > 0.5]
    info = (quiet_wait(infos, 5) or [None])[0]
    check(info is not None, "browser.pageInfo opens a pageInfo panel")
    if info and main:
        check(info.get("parent") == main.get("id"), f"Page Info is a child of the browser window: {info.get('parent')} vs {main.get('id')}")
        mf, inf = main["frame"], card(info)
        bar = ((omnibar().get("pointer") or {}).get("frames") or {}).get("bar")
        if bar:
            bar_bottom = mf["y"] + mf["height"] - (bar[1] + bar[3])
            card_top = inf["y"] + inf["height"]
            check(card_top <= bar_bottom + 2 and card_top >= bar_bottom - 40,
                  f"Page Info opens under the omnibar: card top {card_top:.0f}, bar bottom {bar_bottom:.0f}")
        capture("pageinfo")
        click_page()
        check(bool(quiet_wait(lambda: not infos(), 5)), "a click on the page closes Page Info")
    # 7. A real pointer click on the star toggles the bubble.
    if opts.real_click:
        # A real click: a mouse down/up posted at the HID tap (the window server's own input path).
        clicker = os.path.join(scratch, "click.swift")
        with open(clicker, "w") as f:
            f.write("import AppKit\nlet a = CommandLine.arguments\n"
                    "let p = CGPoint(x: Double(a[1])!, y: NSScreen.screens[0].frame.height - Double(a[2])!)\n"
                    "for t in [CGEventType.leftMouseDown, .leftMouseUp] {\n"
                    "  CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: p, mouseButton: .left)!.post(tap: .cghidEventTap)\n"
                    "  usleep(80_000)\n}\n")

        def real_click(what, wx, wy):
            mf = next((w for w in windows() if w.get("id") == main.get("id")), main)["frame"]
            x, y = mf["x"] + wx, mf["y"] + mf["height"] - wy  # window points from the top left -> screen, y up
            result = subprocess.run(["xcrun", "swift", clicker, str(x), str(y)], capture_output=True, text=True, timeout=120)
            print(f"{what}: real click at screen {x:.0f},{y:.0f} rc={result.returncode} {result.stderr[-200:]}", flush=True)

        def real_click_star(what):
            star = ((omnibar().get("pointer") or {}).get("frames") or {}).get("star")
            if not star or not main:
                return check(False, f"{what}: star {star}")
            real_click(what, star[0] + star[2] / 2, star[1] + star[3] / 2)

        # The first real click activates the app (a click on the page; the star takes no first mouse).
        bar = ((omnibar().get("pointer") or {}).get("frames") or {}).get("bar") or [300, 30, 300, 24]
        real_click("activate", bar[0] + bar[2] / 2, bar[1] + bar[3] + 150)
        time.sleep(1.0)  # proof only: activation

        rpc("action.run", {"action": "bookmark.addPage", "focus": True}) if bubbles() else None
        quiet_wait(lambda: not bubbles(), 5)
        real_click_star("open")
        check(bool(quiet_wait(bubbles, 5)), "a real click on the star opens the bubble")
        real_click_star("close")
        check(bool(quiet_wait(lambda: not bubbles(), 5)), "a second real click on the star closes the bubble")
    if opts.page_popup:
        result = subprocess.run([sys.executable, os.path.join(os.path.dirname(os.path.abspath(__file__)), "page-popup-escape-e2e.py"),
                                 "--socket", SOCKET, "--out", opts.out])
        check(result.returncode == 0, "page-popup-escape-e2e.py passes on the shared host")
finally:
    rpc("debug.quit", {"fixture_quit": "end-sessions"})
    try:
        app.wait(timeout=20)
    except subprocess.TimeoutExpired:
        app.kill()  # the exact PID this script started
        app.wait()
    teardown.end()

print(f"{len(failures)} failure(s); artifacts in {opts.out}")
sys.exit(1 if failures else 0)
