#!/usr/bin/env python3
"""The cmux picker and the viewer actions on a running no-activate tagged build (R89).

Opens the command palette (Cmd-Shift-P), finds each viewer action in it, opens the
picker in place, types a path (path mode: Tab completes a segment, Return goes there),
filters a level by typing, moves with Ctrl-N and Ctrl-P, shows hidden entries with a
leading ".", enters a folder with Tab and leaves it with Left and Cmd-Up. Every step is
a `debug.key` into the palette panel or the window, and every screenshot is a
`debug.window_snapshot` of the app's own window. The app quits through `debug.quit`.
Run on cmux-lawrence-2, never the laptop.

Usage: picker-e2e.py --tag <tag> [--out DIR]
"""
import argparse, glob, json, os, signal, socket, subprocess, sys, tempfile, time

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or tempfile.mkdtemp(prefix="picker-e2e-"))
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
APP = next(iter(sorted(glob.glob(os.path.expanduser(
    f"~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/cmux DEV {opts.tag}.app")))), None)
if not APP:
    sys.exit(f"no tagged app for {opts.tag}")
BINARY = os.path.join(APP, "Contents/MacOS/cmux DEV")
SCRATCH = tempfile.mkdtemp(prefix=f"picker-{opts.tag}-")
FIXTURE = "/tmp/r89-picker-fixture"
CONFIG = os.path.join(SCRATCH, "cmux.json")
GHOSTTY = os.path.join(SCRATCH, "ghostty")
open(GHOSTTY, "w").write("")
open(CONFIG, "w").write("{}")
failures = []
LAST = {}  # the palette's report after the last key into it


def rpc(method, params=None):
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(30)
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


def wait(label, predicate, timeout):
    deadline = time.time() + timeout
    while time.time() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.1)  # test harness wait, not app code
    sys.exit(f"FAIL {label} (timed out after {timeout:.0f} s)")


def key(name, modifiers=None, target="palette"):
    params = {"key": name, "modifiers": modifiers or []}
    if target:
        params["target"] = target
    reply = rpc("debug.key", params) or {}
    time.sleep(0.15)  # test harness: let the palette's search and listing land
    if target == "palette":
        LAST.clear()
        LAST.update(reply)
    return reply


def type_text(text):
    for char in text:
        key(char)


def palette():
    """The palette's report after the last key (page title, selection, open)."""
    return dict(LAST)


def palette_window():
    """The palette panel. A no-activate app is never active, so the panel may report
    itself hidden; it is still drawn."""
    windows = (rpc("debug.window_list") or {}).get("windows", [])
    # The palette is the wide panel (child of the main window while it is open; a
    # no-activate run may list it without a parent).
    return next((w for w in windows if w.get("kind") in ("panel", "palette") and (w.get("frame") or {}).get("width", 0) >= 600), None)


def palette_open():
    """The palette controller's own answer to a no-op key (forward delete with the caret
    at the end of the query), which says whether the palette is open."""
    reply = key("forwarddelete")
    return not reply.get("error") and reply.get("palette_open")


def expect(label, condition, detail=""):
    print(("ok   " if condition else "FAIL ") + label + (f": {detail}" if detail and not condition else ""), flush=True)
    if not condition:
        failures.append(label)


def snapshot(name, palette_panel=True):
    path = os.path.join(opts.out, f"{name}.png")
    params = {"path": path}
    if palette_panel:
        panel = palette_window()
        if panel:
            params["window"] = panel["id"]
        else:
            print(f"no palette window in {json.dumps((rpc('debug.window_list') or {}).get('windows'))}", flush=True)
    reply = rpc("debug.window_snapshot", params) or {}
    print(f"snapshot {name}: {reply.get('path') or reply}", flush=True)
    return reply


def close_palette():
    """Escape until the palette closes (it clears a query and pops a pushed page first)."""
    for _ in range(5):
        if not palette_open():
            return
        key("escape")
    expect("the palette closes", not palette_open())


def open_palette_action(title):
    key("p", ["command", "shift"], target=None)
    wait("the palette opens", palette_open, 10)
    type_text(title)
    key("return")
    time.sleep(0.5)  # test harness: the picker's first listing


def make_fixture():
    subprocess.run(["rm", "-rf", FIXTURE], check=False)
    for path in ["alpha/.git", "alpha/src", "beta", "cloud-c10", "cloud-c9", "cla-audit", "gamma", ".hidden-dir"]:
        os.makedirs(os.path.join(FIXTURE, path), exist_ok=True)
    for path in ["README.md", "gamma/notes.md", "gamma/main.swift", ".env"]:
        open(os.path.join(FIXTURE, path), "w").write("# r89\n")


app = None
try:
    make_fixture()
    if os.path.exists(SOCKET):
        os.unlink(SOCKET)
    env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
           "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": CONFIG, "CMUX_NEXT_GHOSTTY_CONFIG": GHOSTTY,
           "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1200,800"}
    app = subprocess.Popen([BINARY], env=env, stdout=open(os.path.join(SCRATCH, "app.log"), "a"),
                           stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL, cwd=FIXTURE)
    print(f"launched pid {app.pid}", flush=True)
    wait("the tagged app comes up", lambda: os.path.exists(SOCKET) and (rpc("debug.surfaces") or {}).get("windows"), 90)
    time.sleep(2)  # test harness: let the first workspace settle

    # 1. Each viewer action is in the palette.
    for title in ["Open Diff Viewer", "Open Diff Viewer in Folder", "Open Markdown File", "Open File"]:
        key("p", ["command", "shift"], target=None)
        wait("the palette opens", palette_open, 10)
        type_text(title)
        report = palette()
        expect(f"palette lists {title}", report.get("palette_selected") is not None, json.dumps(report))
        snapshot("palette-" + title.lower().replace(" ", "-"))
        close_palette()

    # 2. The picker in folder mode: Locations, a typed path, filtering, the list keys.
    open_palette_action("Open Diff Viewer in Folder")
    expect("the folder picker opens in place", palette_open() and palette().get("palette_text_input") is False, json.dumps(palette()))
    snapshot("picker-folder-start-locations")
    type_text("~")
    expect("~ filters, it does not jump", palette().get("palette_text_input") is False, json.dumps(palette()))
    key("delete")
    type_text("/tm")
    snapshot("picker-path-mode")
    key("tab")
    type_text("r89-pi")
    key("tab")
    snapshot("picker-path-completed")
    key("return")
    report = palette()
    expect("Return goes to the typed folder", (report.get("palette_page") or "").endswith("r89-picker-fixture"), json.dumps(report))
    snapshot("picker-fixture-folders")
    key("n", ["control"])
    first = palette().get("palette_selected")
    key("n", ["control"])
    second = palette().get("palette_selected")
    key("p", ["control"])
    back = palette().get("palette_selected")
    expect("Ctrl-N and Ctrl-P move the list", first != second and back == first, f"{first} {second} {back}")
    snapshot("picker-ctrl-n")
    type_text("c")
    snapshot("picker-typed-c-prefix-first")
    key("delete")
    type_text(".")
    snapshot("picker-hidden-dot")
    key("delete")
    type_text("alpha")
    key("tab")
    expect("Tab enters alpha", (palette().get("palette_page") or "").endswith("alpha"), json.dumps(palette()))
    key("left")
    expect("Left goes up", (palette().get("palette_page") or "").endswith("r89-picker-fixture"), json.dumps(palette()))
    key("up", ["command"])
    expect("Cmd-Up goes up", (palette().get("palette_page") or "").endswith("tmp"), json.dumps(palette()))
    snapshot("picker-cmd-up")
    close_palette()

    # 3. The picker in file mode (Markdown only, then any file).
    open_palette_action("Open Markdown File")
    type_text(FIXTURE + "/gamma/")
    snapshot("picker-markdown-path")
    key("return")
    snapshot("picker-markdown-gamma")
    expect("Return in path mode goes to gamma", (palette().get("palette_page") or "").endswith("gamma"), json.dumps(palette()))
    close_palette()
    open_palette_action("Open File")
    snapshot("picker-file")
    close_palette()

    print("FAILURES: " + ", ".join(failures) if failures else "ok: every step passed", flush=True)
finally:
    if app and app.poll() is None:
        print(f"debug.quit: {rpc('debug.quit', {'open': True})}", flush=True)
        time.sleep(1)  # test harness: the quit sheet, if any
        sheet = rpc("debug.quit") or {}
        if sheet.get("asking"):
            print(f"debug.quit press: {rpc('debug.quit', {'press': 'end-everything'})}", flush=True)
        try:
            app.wait(timeout=20)
            print(f"quit {app.pid} exit {app.returncode}", flush=True)
        except subprocess.TimeoutExpired:
            app.send_signal(signal.SIGKILL)  # the PID launched above, never a pattern
            print(f"killed {app.pid} (did not quit)", flush=True)
    if app and app.returncode not in (None, 0):
        print(open(os.path.join(SCRATCH, "app.log")).read()[-3000:])
sys.exit(1 if failures else 0)
