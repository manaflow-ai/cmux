#!/usr/bin/env python3
"""Live check: bookmarks import from Chrome, Arc, Firefox and Safari on a tagged build.

  scripts/cmux-next/bookmarks-import-live.py --tag <tag> [--capture HELPER] [--out DIR]

Decision BOOKMARKS-IMPORT-EVERY-BROWSER I6. Builds synthetic browser profiles
in a scratch home (never the real one): Chrome with two profiles, Arc with a
sidebar (spaces, a pinned folder, Favorites), Firefox with places.sqlite held
open in WAL mode, Safari with a binary Bookmarks.plist, and an Orion folder
(HTML export only). Launches the tagged app with that home
(CMUX_NEXT_BROWSER_IMPORT_HOME, DEBUG builds), no activation, automation
socket, then drives the person path through the socket only:

  1. action.run bookmark.importFromBrowser opens the picker dialog; it must
     list exactly the five readable profiles and the Orion export line;
  2. one profile is unchecked, Import is pressed; bookmark.list must show one
     "Imported from <Browser> (<profile>)" folder per picked profile, the
     Arc pinned folder, no duplicate URL in a folder, and a summary toast;
  3. the toast's Undo (Cmd-Z path) removes every imported folder;
  4. the CLI path (`bookmark import-from-browser --browser firefox`) imports
     without a dialog.

With --capture it saves the picker, the toast and the Bookmark Manager in
light and dark through the one agent capture helper (its daemon must run:
scripts/agent-capture-helper.sh start): every on-screen window of the app is
captured and drawn back to front, so the dialog and toast overlays show.
GUI host only.
Quits the app by PID and stops the tag's daemons at the end.
"""
import argparse, glob, json, os, plistlib, sqlite3, subprocess, sys, tempfile, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tag_teardown import TagTeardown  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--capture", action="store_true",
                    help="save screenshots through the agent capture helper's daemon (scripts/agent-capture-helper.sh start)")
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or tempfile.mkdtemp(prefix="bookmarks-import-live-"))
parser.add_argument("--app", help="tagged .app (default: found in DerivedData)")
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)

APP = opts.app or next(iter(sorted(glob.glob(os.path.expanduser(
    f"~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/cmux DEV {opts.tag}.app")))), None)
if not APP:
    sys.exit(f"no tagged app for {opts.tag}")
with open(os.path.join(APP, "Contents/Info.plist"), "rb") as f:
    BINARY = os.path.join(APP, "Contents/MacOS", plistlib.load(f)["CFBundleExecutable"])
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
SCRATCH = tempfile.mkdtemp(prefix=f"bookmarks-import-{opts.tag}-")
HOME = os.path.join(SCRATCH, "home")
CONFIG = os.path.join(SCRATCH, "cmux.json")
with open(CONFIG, "w") as f:
    f.write("{}\n")
BASE_ENV = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"}
CLI_ENV = {**BASE_ENV, "CMUX_SOCKET_PATH": SOCKET, "CMUX_QUIET": "1"}
failures = []


def check(ok, what):
    print(("ok   " if ok else "FAIL ") + what, flush=True)
    if not ok:
        failures.append(what)


def write(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb" if isinstance(data, bytes) else "w") as f:
        f.write(data)


def support(*parts):
    return os.path.join(HOME, "Library/Application Support", *parts)


def chromium_profile(root, folder, name, bookmarks):
    write(os.path.join(root, folder, "Preferences"), "{}")
    children = [{"type": "url", "name": t, "url": u} for t, u in bookmarks]
    write(os.path.join(root, folder, "Bookmarks"), json.dumps({"roots": {
        "bookmark_bar": {"name": "Bookmarks bar", "type": "folder", "children": children},
        "other": {"name": "Other bookmarks", "type": "folder", "children": []}}}))
    return {folder: {"name": name}}


def make_profiles():
    chrome = support("Google/Chrome")
    cache = {}
    cache.update(chromium_profile(chrome, "Default", "Personal", [
        ("cmux", "https://cmux.com/"), ("cmux again", "https://cmux.com/"), ("Docs", "https://docs.example.com/")]))
    cache.update(chromium_profile(chrome, "Profile 1", "Work", [("Tracker", "https://tracker.example.com/")]))
    write(os.path.join(chrome, "Local State"), json.dumps({"profile": {"info_cache": cache, "profiles_order": ["Default", "Profile 1"]}}))

    arc = support("Arc/User Data")
    write(os.path.join(arc, "Local State"), json.dumps({"profile": {"info_cache": {"Default": {"name": "Personal"}}}}))
    write(os.path.join(arc, "Default/Preferences"), "{}")
    items = [
        "top", {"id": "top", "childrenIds": ["fav"], "data": {"itemContainer": {}}},
        "fav", {"id": "fav", "childrenIds": [], "title": "Mail", "data": {"tab": {"savedURL": "https://mail.example.com/"}}},
        "pinned", {"id": "pinned", "childrenIds": ["t1", "list"], "data": {"itemContainer": {}}},
        "t1", {"id": "t1", "childrenIds": [], "title": "Arc pinned", "data": {"tab": {"savedURL": "https://arc.example.com/"}}},
        "list", {"id": "list", "childrenIds": ["t2"], "title": "Reading", "data": {"list": {}}},
        "t2", {"id": "t2", "childrenIds": [], "data": {"tab": {"savedURL": "https://read.example.com/", "savedTitle": "Article"}}},
        "unpinned", {"id": "unpinned", "childrenIds": ["open"], "data": {"itemContainer": {}}},
        "open", {"id": "open", "childrenIds": [], "title": "Open tab", "data": {"tab": {"savedURL": "https://open.example.com/"}}},
    ]
    spaces = ["s1", {"id": "s1", "title": "Personal", "profile": {"default": True},
                     "containerIDs": ["unpinned", "unpinned", "pinned", "pinned"]}]
    write(support("Arc/StorableSidebar.json"), json.dumps({"sidebar": {"containers": [{"global": {}}, {
        "items": items, "spaces": spaces, "topAppsContainerIDs": [{"default": True}, "top"]}]}}))

    firefox = support("Firefox")
    write(os.path.join(firefox, "profiles.ini"), "[Profile0]\nName=default-release\nIsRelative=1\nPath=Profiles/abc.default-release\nDefault=1\n")
    places = os.path.join(firefox, "Profiles/abc.default-release/places.sqlite")
    os.makedirs(os.path.dirname(places), exist_ok=True)
    db = sqlite3.connect(places)
    for sql in ["PRAGMA journal_mode=WAL", "PRAGMA wal_autocheckpoint=0",
                "CREATE TABLE moz_places(id INTEGER PRIMARY KEY, url TEXT)",
                "CREATE TABLE moz_bookmarks(id INTEGER PRIMARY KEY, type INTEGER, fk INTEGER, parent INTEGER, position INTEGER, title TEXT, guid TEXT, dateAdded INTEGER)",
                "INSERT INTO moz_bookmarks VALUES(1, 2, NULL, 0, 0, '', 'root________', 0)",
                "INSERT INTO moz_bookmarks VALUES(2, 2, NULL, 1, 0, 'toolbar', 'toolbar_____', 0)",
                "INSERT INTO moz_places VALUES(1, 'https://mozilla.example.org/')",
                "INSERT INTO moz_bookmarks VALUES(3, 1, 1, 2, 0, 'Mozilla', 'aaaaaaaaaaaa', 1700000000000000)"]:
        db.execute(sql)
    db.commit()  # the row stays in places.sqlite-wal while `db` is open (a running Firefox)

    write(os.path.join(HOME, "Library/Safari/Bookmarks.plist"), plistlib.dumps({"WebBookmarkType": "WebBookmarkTypeList", "Children": [
        {"WebBookmarkType": "WebBookmarkTypeList", "Title": "BookmarksBar", "Children": [
            {"WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": "https://apple.example.com/", "URIDictionary": {"title": "Apple"}}]}]},
        fmt=plistlib.FMT_BINARY))
    os.makedirs(support("Orion"), exist_ok=True)
    return db


def cli(*args, timeout=30):
    return subprocess.run([CLI, "--app-socket", SOCKET, *args], capture_output=True, text=True, timeout=timeout, env=CLI_ENV)


def rpc(method, params=None):
    r = cli("--json", "app", "call", method, json.dumps(params or {}))
    try:
        return json.loads(r.stdout)
    except ValueError:
        return {"error": (r.stdout + r.stderr).strip()}


def wait_for(predicate, what, seconds=20):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:  # bounded wait for the app's own state
        value = predicate()
        if value:
            return value
        time.sleep(0.2)
    check(False, f"timed out: {what}")
    return None


def dialog():
    found = [d for d in rpc("debug.dialog").get("dialogs", []) if d.get("identifier") == "cmux.dialog.bookmarks.importBrowser"]
    return found[-1] if found else None


def bookmarks():
    return rpc("bookmark.list", {"profile": "default"}).get("bookmarks", [])


def snapshot():
    return sorted((b["kind"], b["title"], b.get("url") or "", b.get("path") or "") for b in bookmarks())


def imported_folders():
    return {b["title"]: b for b in bookmarks() if b["kind"] == "folder" and b.get("source_key")}


CAPTURE_SOCKET = os.path.expanduser("~/Library/Application Support/cmux/agent-capture/run/cua.sock")


def capture_call(name, args):
    import socket
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


COMPOSITE_SWIFT = r"""
import AppKit
// composite.swift OUT W H [PNG X Y W H]...: draws each PNG into the rect X,Y,W,H (pixels, top-left origin) on a W x H canvas.
let a = CommandLine.arguments
let width = Int(a[2])!, height = Int(a[3])!
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
var i = 4
while i + 4 < a.count {
    if let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: a[i]) as CFURL, nil),
       let image = CGImageSourceCreateImageAtIndex(src, 0, nil) {
        let x = Double(a[i + 1])!, y = Double(a[i + 2])!, w = Double(a[i + 3])!, h = Double(a[i + 4])!
        ctx.draw(image, in: CGRect(x: x, y: Double(height) - y - h, width: w, height: h))
    }
    i += 5
}
let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[1]))
"""


def capture(name):
    """Each on-screen window of the app (main window, dialog and toast overlays) through the
    capture helper's window path, drawn back to front on the main window's frame."""
    if not opts.capture:
        return
    path = os.path.join(opts.out, f"{name}.png")
    listed = ((capture_call("list_windows", {"pid": app.pid}).get("result") or {}).get("structuredContent") or {}).get("windows") or []
    windows = [w for w in listed if w.get("is_on_screen", True) and w.get("bounds") and w["bounds"]["width"] > 1]
    if not windows:
        return check(False, f"capture {name}: no on-screen window")
    titled = [w for w in windows if w.get("title")]
    main = (titled or windows)[-1]
    scale = 2.0
    layers = []
    # list_windows is front to back; draw back to front with the main window first.
    for w in [main] + [w for w in reversed(windows) if w is not main]:
        part = os.path.join(opts.out, "layers", f"{name}-{w['window_id']}.png")
        os.makedirs(os.path.dirname(part), exist_ok=True)
        capture_call("get_window_state", {"pid": app.pid, "window_id": w["window_id"], "max_elements": 1, "screenshot_out_file": part})
        if os.path.exists(part):
            b = w["bounds"]
            layers += [part, str((b["x"] - main["bounds"]["x"]) * scale), str((b["y"] - main["bounds"]["y"]) * scale),
                       str(b["width"] * scale), str(b["height"] * scale)]
    script = os.path.join(SCRATCH, "composite.swift")
    write(script, COMPOSITE_SWIFT)
    size = [str(int(main["bounds"][k] * scale)) for k in ("width", "height")]
    r = subprocess.run(["/usr/bin/swift", script, path, *size, *layers], capture_output=True, text=True, timeout=300)
    check(r.returncode == 0 and os.path.exists(path), f"capture {name}: {len(layers) // 5} window(s) {[(w.get('title'), w['bounds']) for w in windows]} -> {path} {r.stderr.strip()[-300:]}")


manager_workspace = None


def open_manager():
    # The manager opens in the focused pane; Home has none, so the run makes one workspace for it.
    global manager_workspace
    if not manager_workspace:
        manager_workspace = rpc("action.run", {"action": "workspace.newAtBottom"}).get("created") or ["?"]
        time.sleep(2.0)  # the workspace's first pane shows before the manager opens in it (screenshot only)
    rpc("action.run", {"action": "bookmark.manager"})
    time.sleep(2.0)  # page load before the capture (screenshot only)


def appearance(mode):
    rpc("debug.appearance", {"mode": mode})
    time.sleep(1.0)  # let the window redraw before the capture (screenshot only)


firefox_db = make_profiles()
EMPTY_GHOSTTY = os.path.join(SCRATCH, "ghostty-config")
write(EMPTY_GHOSTTY, "")
teardown = TagTeardown(APP)
teardown.install()
app = subprocess.Popen([BINARY], env={**BASE_ENV, "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
                                      "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": CONFIG,
                                      "CMUX_NEXT_BROWSER_IMPORT_HOME": HOME,
                                      # The default Ghostty theme follows light and dark (no host config).
                                      "CMUX_NEXT_GHOSTTY_CONFIG": EMPTY_GHOSTTY},
                       stdout=open(os.path.join(opts.out, "app.log"), "w"), stderr=subprocess.STDOUT)
print(f"app pid {app.pid}, scratch {SCRATCH}, out {opts.out}", flush=True)
try:
    wait_for(lambda: os.path.exists(SOCKET) and "error" not in rpc("debug.focus"), "app socket", 120)
    print("debug.focus:", rpc("debug.focus"), flush=True)
    for mode in ["light", "dark"]:
        appearance(mode)
        rpc("action.run", {"action": "bookmark.importFromBrowser"})
        shown = wait_for(dialog, "import picker")
        if not shown:
            break
        picked = sorted(shown.get("values", {}))
        if mode == "light":
            check(picked == sorted(["chrome/Default", "chrome/Profile 1", "arc/Default", "firefox/Profiles/abc.default-release", "safari/Safari"]),
                  f"picker lists the five readable profiles, all checked: {shown.get('values')}")
            check(all(shown.get("values", {}).values()), "every profile starts checked")
            check(any("Orion" in line for line in shown.get("lines", [])), "picker explains the Orion HTML export")
        focus = rpc("debug.focus")
        check(not focus.get("app_active") and not focus.get("key_window"), f"no activation: {focus}")
        capture(f"picker-{mode}")
        before = snapshot()
        # Leave Chrome (Work) out, import the rest.
        rpc("debug.dialog", {"set": {"chrome/Profile 1": False}})
        rpc("debug.dialog", {"press": "import"})
        folders = wait_for(lambda: imported_folders() if snapshot() != before else None, "imported folders")
        names = sorted(folders or {})
        if mode == "dark":
            capture(f"toast-{mode}")
            open_manager()  # page load before the capture (screenshot only)
            capture(f"manager-{mode}")
            rpc("debug.key", {"key": "z", "modifiers": ["command"]})
            check(wait_for(lambda: snapshot() == before or None, "dark-round undo", 10) is not None, "dark-round undo restores the tree")
            continue
        check(names == sorted(["Imported from Google Chrome (Personal)", "Imported from Arc (Personal)", "Imported from Firefox (default-release)",
                               "Imported from Safari"]), f"one folder per picked profile: {names}")
        rows = bookmarks()
        urls = [(b["parent"], b.get("url")) for b in rows if b["kind"] == "url"]
        check(len(urls) == len(set(urls)), "no duplicate URL in one folder")
        check(any(b["title"] == "Reading" and b["kind"] == "folder" for b in rows), "the Arc pinned folder is kept")
        check(any(b.get("url") == "https://mozilla.example.org/" for b in rows), "Firefox bookmark read from the WAL")
        check(not any(b.get("url") == "https://open.example.com/" for b in rows), "Arc unpinned tabs are not bookmarks")
        check(not any(b.get("url") == "https://tracker.example.com/" for b in rows), "the unchecked profile stays out")
        toasts = rpc("debug.filepages").get("toasts", [])
        check(any("Bookmarks added: 7" in t and "Duplicates skipped: 1" in t for t in toasts), f"summary toast: {toasts}")
        capture(f"toast-{mode}")
        open_manager()
        capture(f"manager-{mode}")
        # Undo: Cmd-Z runs the summary toast's action (TOAST-UNDO-KEY).
        rpc("debug.key", {"key": "z", "modifiers": ["command"]})
        check(wait_for(lambda: snapshot() == before or None, "undo restores the tree as it was", 10) is not None, "undo is one step")
    # CLI path: no dialog.
    r = cli("bookmark", "import-from-browser", "--browser", "firefox", timeout=60)
    check(r.returncode == 0, f"CLI import exit 0: {r.stdout.strip()} {r.stderr.strip()}")
    check("Imported from Firefox (default-release)" in imported_folders(), "CLI import made the Firefox folder")
    check(dialog() is None, "CLI import shows no dialog")
finally:
    rpc("action.run", {"action": "quitEndSessions"})
    try:
        app.wait(timeout=20)
    except subprocess.TimeoutExpired:
        app.kill()
    firefox_db.close()
    teardown.end()

print(f"{len(failures)} failure(s); artifacts in {opts.out}")
sys.exit(1 if failures else 0)
