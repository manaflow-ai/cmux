#!/usr/bin/env python3
"""Live check: a pane's tab bar ends in one hover "…", and `tabs.toolbarButtons` pins actions next to it.

  scripts/cmux-next/pane-toolbar-pins-live.py --app PATH --tag <tag> [--out DIR] [--no-checks]

Launches the tagged app (no activation, automation socket, its own cmux.json holding the retired
`tabs.hiddenButtons: ["splitDown"]`), splits the terminal pane and reads `debug.pane_chrome`:

  1. launch moves `tabs.hiddenButtons` to `tabs.toolbarButtons` (the buttons the old row showed)
     and removes the old key; then the test resets the file to `{}`;
  2. default: no button but "…", faded (alpha 0) while the pointer is away from the tab bar, and
     revealed while it is over the tab bar's tabs (debug.pointer_hover), like the strip's "+";
  3. "…"'s menu lists what opens in the pane, the pane's actions and Show in Tab Bar, nothing checked;
  4. `tabs.toolbarButtons: ["splitDown", "splitRight"]` shows those two buttons before "…" in the
     order written, faded at rest and revealed on hover; the menu leaves them out and checks them
     under Show in Tab Bar;
  5. the toolbar keeps its width while faded (no layout shift when it appears).

Window snapshots of each state (light and dark), with crops of the first pane's tab bar, go to
--out. GUI host only. Exits 1 when a check fails.
"""
import argparse, json, os, plistlib, socket, subprocess, sys, tempfile, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tag_teardown import TagTeardown  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--app", required=True)
parser.add_argument("--tag", required=True)
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or tempfile.mkdtemp(prefix="pane-toolbar-"))
parser.add_argument("--no-checks", action="store_true", help="snapshots only")
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
failures = []


def check(ok, what):
    if opts.no_checks:
        print("note " + what, flush=True)
        return
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
        return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}
    except (OSError, ValueError) as error:
        return {"error": str(error)}


def quiet_wait(predicate, seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:  # bounded wait for the app's own state
        value = predicate()
        if value:
            return value
        time.sleep(0.2)
    return None


def chrome():
    report = rpc("debug.pane_chrome") or {}
    wins = report.get("windows") or [] if isinstance(report, dict) else []
    return wins[0] if wins else {}


def panes():
    return sorted(chrome().get("panes") or [], key=lambda p: p["strip"][0])


def first():
    found = panes()
    return found[0] if found else {}


def read_config():
    with open(CONFIG) as f:
        return json.load(f)


def write_config(value):
    # Whole-file replace, so the config watcher never reads a half-written file.
    with open(CONFIG + ".tmp", "w") as f:
        json.dump(value, f)
    os.replace(CONFIG + ".tmp", CONFIG)


def hover(point):
    return rpc("debug.pointer_hover", {"point": point})


def strip_point(pane, height):
    """The middle of the pane's tab strip, in window coordinates with a bottom-left origin."""
    x, y, w, h = pane["strip"]
    return [x + w * 0.45, height - (y + h / 2)]


def snapshot(name, pane):
    """Window snapshots in light and dark, and a crop of the first pane's tab bar."""
    for mode in ("light", "dark"):
        rpc("debug.appearance", {"mode": mode})
        quiet_wait(lambda: False, 0.6)  # capture harness: the theme repaints before the snapshot
        path = os.path.join(opts.out, f"{name}-{mode}.png")
        rpc("debug.window_snapshot", {"path": path})
        if os.path.exists(path) and pane:
            scale = chrome().get("scale") or 2
            sx, sy, sw, sh = pane["strip"]
            tx, ty, tw, th = pane["toolbar"]["frame"]
            left, top = int(sx * scale), int(sy * scale)
            width, height = int((tx + tw - sx) * scale), int(max(sh, th) * scale)
            crop = os.path.join(opts.out, f"{name}-{mode}-tabbar.png")
            subprocess.run(["sips", "-c", str(height), str(width), "--cropOffset", str(top), str(left), path, "--out", crop],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
        print(f"snapshot {path} {os.path.exists(path)}", flush=True)
    rpc("debug.appearance", {"mode": "system"})


def menu_rows(pane):
    return (pane.get("toolbar") or {}).get("more_menu") or []


def show_in_tab_bar(rows):
    for row in rows:
        if isinstance(row, dict) and row:
            return next(iter(row.values()))
    return None


with open(os.path.join(opts.app, "Contents/Info.plist"), "rb") as f:
    BINARY = os.path.join(opts.app, "Contents/MacOS", plistlib.load(f)["CFBundleExecutable"])
SCRATCH = tempfile.mkdtemp(prefix=f"pane-toolbar-{opts.tag}-")
CONFIG = os.path.join(SCRATCH, "cmux.json")
write_config({"tabs": {"hiddenButtons": ["splitDown"]}})
teardown = TagTeardown(opts.app)
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

try:
    if not quiet_wait(lambda: os.path.exists(SOCKET) and panes(), 180):
        check(False, "timed out: the app's first pane")
        raise SystemExit(1)
    # 1. The launch migration (after the first frames settle).
    migrated = quiet_wait(lambda: "toolbarButtons" in (read_config().get("tabs") or {}) and read_config(), 30) or read_config()
    print("migrated config", json.dumps(migrated), flush=True)
    check((migrated.get("tabs") or {}) == {"toolbarButtons": ["splitRight", "openDiffViewer", "file.open", "toggleSplitZoom"]},
          f"launch moves tabs.hiddenButtons [splitDown] to tabs.toolbarButtons and drops the old key: {migrated}")
    write_config({})
    quiet_wait(lambda: (first().get("toolbar") or {}).get("buttons") == [], 20)

    rpc("action.run", {"action": "splitRight", "origin": "script"})
    quiet_wait(lambda: len(panes()) >= 2, 20)
    height = (chrome().get("window_controls") or {}).get("band_frame") and None
    frame = rpc("debug.window_frame") or {}
    height = (frame.get("frame") or [0, 0, 1200, 800])[3] if isinstance(frame, dict) else 800

    # 2. Default: "…" only (no Search Tabs chevron), hidden at rest (tabs.restingControlOpacity 0), shown over the tabs.
    hover(None)
    pane = quiet_wait(lambda: (lambda p: p if p.get("toolbar") and not p["toolbar"]["revealed"] else None)(first()), 10) or first()
    print("rest", json.dumps(pane.get("toolbar")), flush=True)
    tool = pane.get("toolbar") or {}
    check(tool.get("buttons") == [] and (tool.get("more_alpha") or 0) == 0,
          f"default at rest: no buttons, \"…\" hidden: {tool}")
    rest_width = (tool.get("frame") or [0, 0, 0, 0])[2]
    snapshot("default-rest", pane)
    print("hover", hover(strip_point(pane, height)), flush=True)
    pane = quiet_wait(lambda: (lambda p: p if (p.get("toolbar") or {}).get("revealed") else None)(first()), 10) or first()
    tool = pane.get("toolbar") or {}
    check(tool.get("revealed") is True, f"hovering the tab bar's tabs reveals \"…\": {tool.get('revealed')}")
    check((tool.get("frame") or [0, 0, 0, 0])[2] == rest_width, "\"…\" keeps its width when it appears")
    snapshot("default-hover", pane)
    # 3. The menu.
    rows = menu_rows(pane)
    print("menu", json.dumps(rows, ensure_ascii=False), flush=True)
    check("Split Right" in rows and "Split Down" in rows, "\"…\" offers Split Right and Split Down")
    check(any(str(r).startswith("Search Tabs") for r in rows), f"\"…\" offers Search Tabs (was the bar's chevron): {rows}")
    pins = show_in_tab_bar(rows) or []
    check(bool(pins) and not any(str(r).startswith("✓") for r in pins), f"Show in Tab Bar lists the pinnable actions, none checked: {pins}")
    with open(os.path.join(opts.out, "menu-default.json"), "w") as f:
        json.dump(rows, f, ensure_ascii=False, indent=2)
    hover(None)

    # 4. Pinned buttons.
    write_config({"tabs": {"toolbarButtons": ["splitDown", "splitRight"]}})
    pane = quiet_wait(lambda: (lambda p: p if len((p.get("toolbar") or {}).get("buttons") or []) > 1 else None)(first()), 20) or first()
    tool = pane.get("toolbar") or {}
    print("pinned rest", json.dumps(tool, ensure_ascii=False), flush=True)
    check(tool.get("buttons") == ["Split Down", "Split Right"],
          f"pinned: Split Down and Split Right in the order written, no Search Tabs: {tool.get('buttons')}")
    check(tool.get("revealed") is False, "pinned buttons wait for the pointer too")
    pinned_width = (tool.get("frame") or [0, 0, 0, 0])[2]
    snapshot("pinned-rest", pane)
    hover(strip_point(pane, height))
    pane = quiet_wait(lambda: (lambda p: p if (p.get("toolbar") or {}).get("revealed") else None)(first()), 10) or first()
    tool = pane.get("toolbar") or {}
    check(tool.get("revealed") is True and (tool.get("frame") or [0, 0, 0, 0])[2] == pinned_width,
          "hovering reveals the pinned buttons in place")
    snapshot("pinned-hover", pane)
    rows = menu_rows(pane)
    print("menu pinned", json.dumps(rows, ensure_ascii=False), flush=True)
    check("Split Right" not in rows and "Split Down" not in rows, "the menu leaves out the pinned actions")
    pins = show_in_tab_bar(rows) or []
    check("✓ Split Right" in pins and "✓ Split Down" in pins, f"Show in Tab Bar checks the pinned actions: {pins}")
    with open(os.path.join(opts.out, "menu-pinned.json"), "w") as f:
        json.dump(rows, f, ensure_ascii=False, indent=2)
    hover(None)
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
