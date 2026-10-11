#!/usr/bin/env python3
"""Live check: Import Passwords from CSV on a tagged build, light and dark (cx-dwg.4).

  scripts/cmux-next/passwords-csv-import-live.py --tag <tag> [--capture] [--out DIR]

Decision PASSWORDS-IMPORT-ANY-BROWSER: the guided CSV import, counts only, a
line of its own for sign-ins saved with another password, and the offer to
move the plaintext file to the Trash. GUI host only (cmux-lawrence-2).

The CSV files are synthetic: made here, under a scratch folder, with random
passwords that this script never prints. The tagged app runs with Chromium's
mock Keychain and CMUX_NEXT_PASSWORD_IMPORT_MOCK_KEY=throwaway (DEBUG builds
only), so nothing touches a real Keychain item or a real password store.

The person path, with no socket shortcut:
  1. Cmd-Shift-P, "Passwords" and a pixel click on the palette row, then a
     pixel click on the Passwords page's Import CSV… button, all through
     Computer Use (cua-driver real key and mouse events, the tagged app
     frontmost in its own window); the action is person-only, so the socket
     cannot start it;
  2. the source sheet and the export steps sheet (cmux dialogs, pressed with
     debug.dialog, the same path as a click);
  3. the open panel: Go to Folder (Cmd-Shift-G), the file path, Return, Return
     through cua-driver;
  4. the summary dialog: round 1 (light) must say 3 imported and 3 not
     imported (a repeated row, an android:// sign-in, an empty password) and
     no conflict line; round 2 (dark) imports a second file with one changed
     password, one unchanged and one new: 1 imported, 1 not imported and the
     line "Already saved with a different password: 1". Round 1 keeps the
     file; round 2 presses Move to Trash and the file must leave its folder.
Then the app log must not contain any of the synthetic passwords.

With --capture it saves each sheet and summary in light and dark through
cua-driver window captures, composited back to front on the main window.
Quits the app by PID and stops the tag's daemons at the end.
"""
import argparse, glob, json, os, plistlib, secrets, subprocess, sys, tempfile, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tag_teardown import TagTeardown  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--capture", action="store_true", help="save screenshots through cua-driver window captures")
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or tempfile.mkdtemp(prefix="passwords-csv-live-"))
parser.add_argument("--app", help="tagged .app (default: found in DerivedData)")
parser.add_argument("--cua", default=os.path.expanduser("~/.local/bin/cua-driver"), help="cua-driver binary")
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
SCRATCH = tempfile.mkdtemp(prefix=f"passwords-csv-{opts.tag}-")
CONFIG = os.path.join(SCRATCH, "cmux.json")
BASE_ENV = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"}
# nx-remote ends what the job started only on evidence that names the job.
BASE_ENV.update({k: os.environ[k] for k in ("NX_JOB_ID", "NX_JOB_DIR") if k in os.environ})
CLI_ENV = {**BASE_ENV, "CMUX_SOCKET_PATH": SOCKET, "CMUX_QUIET": "1"}
failures = []
# One cua-driver session for the run: a pixel click needs that session's window capture.
SESSION = f"pwcsv-{opts.tag}"
report = {"tag": opts.tag, "checks": []}


def check(ok, what):
    print(("ok   " if ok else "FAIL ") + what, flush=True)
    report["checks"].append({"ok": bool(ok), "what": what})
    if not ok:
        failures.append(what)
    return ok


def write(path, data, mode=0o644):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb" if isinstance(data, bytes) else "w") as f:
        f.write(data)
    os.chmod(path, mode)


# Synthetic sign-ins: random values, kept in memory and in the 0600 files only, never printed.
SECRETS = {name: "proof-" + secrets.token_urlsafe(18) for name in ("alpha", "beta", "gamma", "alpha2", "delta", "android")}


def csv_file(name, rows):
    """Apple Passwords' export header (Title,URL,Username,Password,Notes,OTPAuth)."""
    lines = ["Title,URL,Username,Password,Notes,OTPAuth"] + [",".join(row) for row in rows]
    path = os.path.join(SCRATCH, "exports", name)
    write(path, "\n".join(lines) + "\n", 0o600)
    return path


FIRST = csv_file("Passwords-1.csv", [
    ["Alpha", "https://alpha.cmux-proof.test/login", "alice", SECRETS["alpha"], "", ""],
    ["Beta", "https://beta.cmux-proof.test/", "bob", SECRETS["beta"], "", ""],
    ["Gamma", "https://gamma.cmux-proof.test/", "carol", SECRETS["gamma"], "", ""],
    # The same site and username again: the first row wins, this one is "repeated".
    ["Alpha again", "https://alpha.cmux-proof.test/other", "alice", SECRETS["alpha2"], "", ""],
    # Not a website sign-in.
    ["App", "android://hash@com.example.app/", "dave", SECRETS["android"], "", ""],
    # No password.
    ["Empty", "https://empty.cmux-proof.test/", "erin", "", "", ""],
])
SECOND = csv_file("Passwords-2.csv", [
    # Saved in round 1 with another password: a conflict, the saved one is kept.
    ["Alpha", "https://alpha.cmux-proof.test/login", "alice", SECRETS["alpha2"], "", ""],
    # Saved in round 1 with this password: already saved.
    ["Beta", "https://beta.cmux-proof.test/", "bob", SECRETS["beta"], "", ""],
    # New.
    ["Delta", "https://delta.cmux-proof.test/", "dan", SECRETS["delta"], "", ""],
])
write(CONFIG, "{}\n")
EMPTY_GHOSTTY = os.path.join(SCRATCH, "ghostty-config")
write(EMPTY_GHOSTTY, "")


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


def dialog(identifier):
    found = [d for d in rpc("debug.dialog").get("dialogs", []) if d.get("identifier") == identifier and d.get("visible", True)]
    return found[-1] if found else None


def cua(tool, args, timeout=60):
    r = subprocess.run([opts.cua, "call", tool, json.dumps(args)], capture_output=True, text=True, timeout=timeout)
    try:
        value = json.loads(r.stdout)
    except ValueError:
        value = {"raw": (r.stdout + r.stderr).strip()[-800:]}
    return r.returncode, value


def structured(value):
    if isinstance(value, dict):
        return value.get("structuredContent") or (value.get("result") or {}).get("structuredContent") or value
    return {}


def windows():
    _, listed = cua("list_windows", {"pid": app.pid})
    return [w for w in structured(listed).get("windows") or [] if w.get("bounds") and w["bounds"].get("width", 0) > 1]


def main_window():
    on_screen = [w for w in windows() if w.get("is_on_screen", True)]
    titled = [w for w in on_screen if w.get("title")]
    return (titled or on_screen or [None])[-1]


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
    """Every on-screen window of the app (main window, dialog overlays), drawn back to front."""
    if not opts.capture:
        return
    path = os.path.join(opts.out, f"{name}.png")
    listed = [w for w in windows() if w.get("is_on_screen", True)]
    if not listed:
        return check(False, f"capture {name}: no on-screen window")
    main = ([w for w in listed if w.get("title")] or listed)[-1]
    scale = 2.0
    layers = []
    # list_windows is front to back; draw back to front with the main window first.
    for w in [main] + [w for w in reversed(listed) if w is not main]:
        part = os.path.join(opts.out, "layers", f"{name}-{w['window_id']}.png")
        os.makedirs(os.path.dirname(part), exist_ok=True)
        cua("get_window_state", {"pid": app.pid, "window_id": w["window_id"], "max_elements": 1, "screenshot_out_file": part,
                                 "session": SESSION})
        if os.path.exists(part):
            b = w["bounds"]
            layers += [part, str((b["x"] - main["bounds"]["x"]) * scale), str((b["y"] - main["bounds"]["y"]) * scale),
                       str(b["width"] * scale), str(b["height"] * scale)]
    script = os.path.join(SCRATCH, "composite.swift")
    write(script, COMPOSITE_SWIFT)
    size = [str(int(main["bounds"][k] * scale)) for k in ("width", "height")]
    r = subprocess.run(["/usr/bin/swift", script, path, *size, *layers], capture_output=True, text=True, timeout=300)
    check(r.returncode == 0 and os.path.exists(path), f"capture {name}: {len(layers) // 5} window(s) -> {path} {r.stderr.strip()[-300:]}")


def appearance(mode):
    rpc("debug.appearance", {"mode": mode})
    time.sleep(1.0)  # let the window redraw before the capture (screenshot only)


def pick_in_open_panel(path, before_ids):
    """Go to Folder in the open panel, the file's path, then Open. Returns the panel's window id."""
    panel = wait_for(lambda: next((w for w in windows() if w["window_id"] not in before_ids and w.get("is_on_screen", True)), None),
                     "open panel window", 20)
    if not panel:
        return None
    wid = panel["window_id"]
    report.setdefault("open_panel", []).append({"window": wid, "title": panel.get("title"), "bounds": panel.get("bounds")})
    code, sent = cua("hotkey", {"pid": app.pid, "window_id": wid, "keys": ["cmd", "shift", "g"]})
    report["open_panel"][-1]["go_to_folder"] = {"exit": code, "reply": structured(sent)}
    time.sleep(1.0)  # the Go to Folder field slides in (no app-side signal for a system panel)
    code, typed = cua("type_text", {"pid": app.pid, "window_id": wid, "text": path})
    report["open_panel"][-1]["type"] = {"exit": code, "reply": structured(typed)}
    time.sleep(0.5)  # the field resolves the path
    for _ in range(2):  # Return goes to the folder field's file, Return again opens it
        cua("press_key", {"pid": app.pid, "window_id": wid, "key": "return"})
        time.sleep(1.0)  # the panel moves to the file (system panel, no app-side signal)
        if not any(w["window_id"] == wid for w in windows()):
            break
    return wid


def ax_elements(wid):
    """cua-driver's AX snapshot of one window: (elements, snapshot reply)."""
    _, state = cua("get_window_state", {"pid": app.pid, "window_id": wid, "max_elements": 400, "session": SESSION})
    st = structured(state)
    return st.get("elements") or [], st


def element_text(e):
    return " ".join(str(e.get(k) or "") for k in ("label", "title", "name", "value", "description", "role_description"))


def element_frame(e):
    """(x, y, w, h) of an element in window-local screenshot pixels, from whichever field the driver gives."""
    for key in ("screenshot_frame", "frame_px", "pixel_frame", "frame", "bounds", "rect"):
        f = e.get(key)
        if isinstance(f, dict) and all(k in f for k in ("x", "y")):
            return f["x"], f["y"], f.get("width", f.get("w", 0)), f.get("height", f.get("h", 0)), key
        if isinstance(f, list) and len(f) == 4:
            return (*f, key)
    return None


def pixel_click(wid, label, what, roles=None):
    """A real left click (CGEvent) at the center of the AX element whose text contains `label`."""
    elements, st = ax_elements(wid)
    matches = [e for e in elements if label in element_text(e) and element_frame(e)
               and (not roles or any(r in str(e.get("role", "")) for r in roles))]
    report.setdefault("clicks", []).append({"what": what, "window": wid, "matches": matches[:3],
                                            "sample": elements[:4] if not matches else None,
                                            "keys": sorted(st.keys())})
    if not matches:
        return check(False, f"{what}: no AX element with {label!r} in window {wid} ({len(elements)} elements)")
    x, y, w, h, key = element_frame(matches[0])
    code, clicked = cua("click", {"pid": app.pid, "window_id": wid, "x": x + w / 2, "y": y + h / 2, "session": SESSION,
                                  "delivery_mode": "foreground"})
    report["clicks"][-1]["click"] = {"exit": code, "frame_key": key, "reply": structured(clicked)}
    return check(code == 0, f"{what}: pixel click at {x + w / 2:.0f},{y + h / 2:.0f} ({key}) exit {code}")


def open_palette(wid):
    """Cmd-Shift-P to the frontmost tagged window; returns the palette panel window."""
    for attempt in range(3):
        before = {w["window_id"] for w in windows()}
        cua("bring_to_front", {"pid": app.pid})
        cua("hotkey", {"pid": app.pid, "window_id": wid, "delivery_mode": "foreground", "keys": ["cmd", "shift", "p"]})
        deadline = time.monotonic() + 4
        while time.monotonic() < deadline:  # bounded wait for the panel window
            panel = next((w for w in windows() if w["window_id"] not in before and w.get("is_on_screen")), None)
            if panel:
                return panel
            time.sleep(0.2)
    return None


def start_import(mode, wid):
    """The person path, with real input only: Cmd-Shift-P, "Passwords" typed, a pixel click on the
    palette's Passwords row; then a pixel click on the page's Import CSV… button (a real mouse-down
    in the page view is the user gesture the person-only action needs). The tagged app is frontmost
    in its own window (GUI host only)."""
    panel = open_palette(wid)
    if not check(panel is not None, f"{mode}: Cmd-Shift-P opens the command palette"):
        return
    cua("type_text", {"pid": app.pid, "window_id": panel["window_id"], "delivery_mode": "foreground", "text": "Passwords"})
    time.sleep(0.5)  # the palette filters
    # The palette panel exposes no AX elements, so its first row (selected after the filter) is
    # clicked where the panel draws it: centered, 16% down the panel (the search field, then the row) (measured on the panel
    # capture of this tagged build at the fixed test window frame).
    capture(f"palette-{mode}")
    _, st = ax_elements(panel["window_id"])  # the click below needs this snapshot of the panel
    width, height = st.get("screenshot_width") or 0, st.get("screenshot_height") or 0
    report.setdefault("clicks", []).append({"what": f"{mode}: palette first row", "panel": panel, "size": [width, height]})
    if not check(width > 0 and height > 0, f"{mode}: palette panel capture size {width}x{height}"):
        return
    code, clicked = cua("click", {"pid": app.pid, "window_id": panel["window_id"], "x": width * 0.5, "y": height * 0.16,
                                  "session": SESSION, "delivery_mode": "foreground"})
    report["clicks"][-1]["click"] = {"exit": code, "reply": structured(clicked)}
    check(code == 0, f"{mode}: pixel click on the palette's Passwords row (exit {code})")
    page = wait_for(lambda: (lambda st: st if st.get("painted") else None)(rpc("debug.page", {"page": "cmux.passwords"})),
                    f"{mode}: Passwords page painted", 20)
    if not page:
        return
    capture(f"page-{mode}")
    pixel_click(wid, "Import CSV", f"{mode}: the page's Import CSV\u2026 button")


def import_round(mode, path, source, expect_lines, trash):
    appearance(mode)
    main = main_window()
    if not check(main is not None, f"{mode}: the app has an on-screen window"):
        return
    start_import(mode, main["window_id"])
    shown = wait_for(lambda: dialog("cmux.dialog.passwordCSV.source"), f"{mode}: source sheet")
    if not shown:
        return
    check(shown.get("title") == "Import Passwords from CSV", f"{mode}: source sheet title: {shown.get('title')}")
    capture(f"source-{mode}")
    rpc("debug.dialog", {"id": shown["id"], "set": {"source": source}})
    rpc("debug.dialog", {"id": shown["id"], "press": "continue"})
    steps = wait_for(lambda: dialog("cmux.dialog.passwordCSV.steps"), f"{mode}: export steps sheet")
    if not steps:
        return
    check(len(steps.get("lines") or []) == 3, f"{mode}: the export steps sheet lists 3 steps for {source}")
    capture(f"steps-{mode}")
    before = {w["window_id"] for w in windows()}
    rpc("debug.dialog", {"id": steps["id"], "press": "choose"})
    pick_in_open_panel(path, before)
    done = wait_for(lambda: dialog("cmux.dialog.passwordCSV.trash"), f"{mode}: summary dialog", 60)
    if not done:
        report[f"{mode}_dialogs"] = rpc("debug.dialog").get("dialogs")
        return
    lines = done.get("lines") or []
    report[f"{mode}_summary"] = lines
    check(lines[:-1] == expect_lines, f"{mode}: summary lines {lines[:-1]} == {expect_lines}")
    check(bool(lines) and "plain text" in lines[-1], f"{mode}: the summary offers to move the plaintext file to the Trash")
    capture(f"summary-{mode}")
    rpc("debug.dialog", {"id": done["id"], "press": "trash" if trash else "keep"})
    if trash:
        check(wait_for(lambda: not os.path.exists(path), f"{mode}: the file leaves its folder", 10) is not None,
              f"{mode}: Move to Trash moved the CSV")
        trashed = os.path.join(os.path.expanduser("~/.Trash"), os.path.basename(path))
        if os.path.exists(trashed):
            os.remove(trashed)  # the synthetic file this run made, by its exact path
    else:
        time.sleep(0.5)  # the dialog closes (no file change to wait on)
        check(os.path.exists(path), f"{mode}: Keep File keeps the CSV")


teardown = TagTeardown(APP)
teardown.install()
# No CMUX_NEXT_NO_ACTIVATE: the import is person-only, so its keys must reach a key window, and
# that guard gives the keyboard back to the previous app at once. GUI host only, never a laptop.
app = subprocess.Popen([BINARY], env={**BASE_ENV, "CMUX_NEXT_SOCKET_MODE": "automation",
                                      "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": CONFIG,
                                      "CMUX_NEXT_GHOSTTY_CONFIG": EMPTY_GHOSTTY,
                                      # DEBUG builds: allow the import under Chromium's mock Keychain, throwaway data only.
                                      "CMUX_NEXT_PASSWORD_IMPORT_MOCK_KEY": "throwaway"},
                       stdout=open(os.path.join(opts.out, "app.log"), "w"), stderr=subprocess.STDOUT)
print(f"app pid {app.pid}, scratch {SCRATCH}, out {opts.out}", flush=True)
try:
    wait_for(lambda: os.path.exists(SOCKET) and "error" not in rpc("debug.focus"), "app socket", 120)
    code, perms = cua("check_permissions", {})
    check(code == 0 and structured(perms).get("accessibility") is True, f"cua-driver has Accessibility: {structured(perms).get('accessibility')}")
    refused = rpc("action.run", {"action": "password.importCSV"})
    check("error" in json.dumps(refused).lower() or "person" in json.dumps(refused).lower(),
          f"the socket cannot start the import: {json.dumps(refused)[:200]}")
    import_round("light", FIRST, "apple",
                 ["Imported: 3. Not imported: 3 (already saved, repeated, or not a website sign-in)."], trash=False)
    import_round("dark", SECOND, "onePassword",
                 ["Imported: 1. Not imported: 1 (already saved, repeated, or not a website sign-in).",
                  "Already saved with a different password: 1. cmux kept the saved password."], trash=True)
    focus = rpc("debug.focus")
    report["focus_end"] = focus
finally:
    try:
        rpc("debug.quit", {"fixture_quit": "end-sessions"})
        app.wait(timeout=30)
    except Exception:  # noqa: BLE001 - the teardown below stops it by PID
        pass
    if app.poll() is None:
        app.terminate()
    teardown.end()
    with open(os.path.join(opts.out, "app.log"), "rb") as f:
        log = f.read()
    check(not any(value.encode() in log for value in SECRETS.values()), "the app log holds none of the synthetic passwords")
    with open(os.path.join(opts.out, "passwords-csv-live.json"), "w") as f:
        json.dump(report, f, indent=2, default=str)

print(f"{len(failures)} failure(s); artifacts in {opts.out}", flush=True)
sys.exit(1 if failures else 0)
