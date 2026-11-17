#!/usr/bin/env python3
"""The Density Playground, live: opened from the Command Palette, tuned from its own fields, saved as a new density.

  scripts/cmux-next/density-playground-live.py --app APP --tag TAG --out DIR

GUI host only (cmux-lawrence-2); never on a laptop. Launches the tagged app with a scratch config and an isolated
Chief, then:
  1. Command-Shift-P, types "Density Playground", Return (the palette row the person uses), shot of the palette;
  2. light and dark shots of the main window and the playground at Default (`before-*`);
  3. types into the playground as a person does: a name ("Roomy": a built-in is never changed, the name makes a
     copy), then sidebar row height and gap (Vertical tabs, Command-1), tab row height and gap (Horizontal tabs,
     Command-2), one frame per step (`frames/`, joined into `tuning.mp4`);
  4. light and dark shots after (`after-*`), the saved config (`config-after.json`);
  5. quits, launches again on the same config and shoots the main window: the custom density is still in use.
Window images come from `debug.window_snapshot` (the window server's composite; no Screen Recording grant).
"""
import argparse, json, os, plistlib, shutil, socket, subprocess, sys, tempfile, time

parser = argparse.ArgumentParser()
parser.add_argument("--app", required=True)
parser.add_argument("--tag", required=True)
parser.add_argument("--out", required=True)
opts = parser.parse_args()
os.makedirs(os.path.join(opts.out, "frames"), exist_ok=True)
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
SCRATCH = tempfile.mkdtemp(prefix=f"density-playground-{opts.tag}-")
CONFIG = os.path.join(SCRATCH, "cmux.json")
open(CONFIG, "w").write("{}")
GHOSTTY = os.path.join(SCRATCH, "ghostty")
open(GHOSTTY, "w").write("")

# ANSI virtual key codes (US layout).
CODES = {**{c: k for c, k in zip("asdfhgzxcv", [0, 1, 2, 3, 4, 5, 6, 7, 8, 9])},
         **{c: k for c, k in zip("bqweryt", [11, 12, 13, 14, 15, 16, 17])},
         "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29,
         "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46, ".": 47, " ": 49,
         "return": 36, "tab": 48, "escape": 53}
CMD, SHIFT = 55, 56


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


def wait(predicate, seconds):
    end = time.monotonic() + seconds
    while time.monotonic() < end:  # bounded wait for the live app's own state
        try:
            value = predicate()
        except Exception:  # the app may not answer yet
            value = None
        if value:
            return value
        time.sleep(0.25)
    return None


def keys(*strokes, gap=30):
    """Raw key transitions into the key window: each stroke is a key name or character, or (modifiers, key)."""
    steps = []
    for stroke in strokes:
        mods, key = stroke if isinstance(stroke, tuple) else ((), stroke)
        upper = isinstance(key, str) and len(key) == 1 and key.isupper()
        held = [CMD if m == "cmd" else SHIFT for m in mods] + ([SHIFT] if upper else [])
        code = CODES[key.lower() if upper else key]
        steps += [{"key_code": m, "down": True, "after_ms": gap} for m in held]
        steps += [{"key_code": code, "down": True, "after_ms": gap}, {"key_code": code, "down": False, "after_ms": gap}]
        steps += [{"key_code": m, "down": False, "after_ms": gap} for m in reversed(held)]
    # The GUI host is shared: another run's app may have taken activation, and a panel takes keys only in the
    # active app. Activate again, then make the panel key (`key_window`: its identifier).
    subprocess.run(["/usr/bin/open", "-b", INFO["CFBundleIdentifier"]], check=False)
    # Active once one of its windows is key (a read-only check).
    if not wait(lambda: any(w.get("key") for w in windows()), 5):
        print("the app did not become active", flush=True)
    reply = rpc("debug.key", {"sequence": steps, "key_window": "cmux.densityPlayground"})
    time.sleep(len(steps) * gap / 1000 + 0.6)  # capture harness: the sequence plays, then the change draws
    return reply


def type_text(text):
    return keys(*list(text))


def field(value):
    """Tab to the next field (a field Tab enters selects its text), type `value`, Return."""
    keys("tab")
    type_text(value)
    return keys("return")


def windows():
    return (rpc("debug.window_list") or {}).get("windows") or []


def playground():
    pick = [w for w in windows() if "density" in (w.get("title") or "").lower()]
    return pick[0]["id"] if pick else None


def snapshot(path, window=None):
    params = {"path": path, "webviews": False}
    params.update({"window": window} if window is not None else {"kind": "main"})
    return rpc("debug.window_snapshot", params, timeout=40)


def pair(name):
    """The main window and the playground, light and dark."""
    for mode in ("light", "dark"):
        rpc("debug.appearance", {"mode": mode})
        time.sleep(1.2)  # capture harness: the theme repaints
        print(name, mode, snapshot(os.path.join(opts.out, f"{name}-main-{mode}.png")), flush=True)
        if playground() is not None:
            snapshot(os.path.join(opts.out, f"{name}-playground-{mode}.png"), playground())
    rpc("debug.appearance", {"mode": "light"})
    time.sleep(0.8)  # capture harness: back to light for the frames


FRAME = [0]


def frame(label):
    FRAME[0] += 1
    base = os.path.join(opts.out, "frames", f"{FRAME[0]:02d}")
    snapshot(base + "-main.png")
    snapshot(base + "-playground.png", playground())
    print("frame", FRAME[0], label, flush=True)


with open(os.path.join(opts.app, "Contents/Info.plist"), "rb") as f:
    INFO = plistlib.load(f)
BINARY = os.path.join(opts.app, "Contents/MacOS", INFO["CFBundleExecutable"])


def launch(log):
    if os.path.exists(SOCKET):
        os.unlink(SOCKET)
    # Activated (a panel takes keys only in the active app), the window placed so the playground fits beside it.
    process = subprocess.Popen([BINARY], env={
        "HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_SOCKET_MODE": "automation",
        "CMUX_NEXT_CONFIG_FILE": CONFIG, "CMUX_NEXT_GHOSTTY_CONFIG": GHOSTTY,
        "CMUX_NEXT_CHIEF_ISOLATED": "1", "CMUX_NEXT_CHIEF_HOME": os.path.join(SCRATCH, "chief"),
        "ACPMUX_AGENT_LAUNCH": "deny", "NX_REMOTE": "1"},
        stdout=open(os.path.join(opts.out, log), "w"), stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
    if not wait(lambda: os.path.exists(SOCKET) and not (rpc("debug.window_frame") or {}).get("error"), 180):
        sys.exit("the tagged app did not come up")
    time.sleep(3)  # capture harness: the first window settles
    subprocess.run(["/usr/bin/open", "-b", INFO["CFBundleIdentifier"]], check=False)  # the running copy
    print("frame", rpc("debug.window_frame", {"frame": [16, 120, 860, 700]}), flush=True)  # AppKit points
    time.sleep(1.5)  # capture harness: activation and the move land
    return process


def quit_app(process):
    rpc("debug.appearance", {"mode": "system"})
    rpc("debug.quit", {"fixture_quit": "end-sessions"})
    try:
        process.wait(timeout=20)
    except subprocess.TimeoutExpired:
        process.kill()  # the exact PID this script started
        process.wait()


result = {}
app = launch("app.log")
print(f"app pid {app.pid}, scratch {SCRATCH}, out {opts.out}", flush=True)
try:
    # Some chrome to tune: two more workspaces in the sidebar and two more tabs in the strip.
    for stroke in ("n", "n", "t", "t"):
        print(stroke, rpc("debug.key", {"key": stroke, "modifiers": ["cmd"]}), flush=True)
        time.sleep(1.0)  # capture harness: the new workspace or tab draws
    print("palette", rpc("debug.key", {"key": "p", "modifiers": ["cmd", "shift"]}), flush=True)
    time.sleep(1.0)  # capture harness: the palette opens
    for character in "Density Playground":
        rpc("debug.key", {"key": "space" if character == " " else character, "target": "palette"})
    time.sleep(1.0)  # capture harness: the palette ranks
    print("palette shot", rpc("debug.palette.capture", {"path": os.path.join(opts.out, "palette.png")}), flush=True)
    print("open", rpc("debug.key", {"key": "return", "target": "palette"}), flush=True)
    result["opened"] = wait(playground, 10) is not None
    print("playground window", result["opened"], json.dumps(windows())[:400], flush=True)
    time.sleep(1.5)  # capture harness: the panel draws
    pair("before")
    frame("Default")
    # The name first: a built-in stays as it is, so naming it makes the copy that every later change goes into.
    print("name", keys("tab"), flush=True)
    type_text("Roomy")
    keys("return")
    frame("named Roomy")
    keys((("cmd",), "1"))  # the group's first value takes the keys, its text selected
    type_text("38")
    keys("return")
    frame("sidebar row height 38")
    field("6")
    frame("sidebar row gap 6")
    keys((("cmd",), "2"))
    frame("Horizontal tabs")
    type_text("36")
    keys("return")
    frame("tab height 36")
    field("6")
    frame("strip padding 6")
    time.sleep(1.5)  # the playground's save (600 ms after the last change)
    pair("after")
    shutil.copy(CONFIG, os.path.join(opts.out, "config-after.json"))
    config = json.load(open(CONFIG))
    appearance = config.get("appearance", {})
    result["saved"] = {"customDensity": appearance.get("customDensity"),
                       "names": [d.get("name") for d in appearance.get("customDensities", [])]}
    print("saved", json.dumps(result["saved"]), flush=True)
finally:
    quit_app(app)

# Again on the same config: the custom density is still the one in use.
app = launch("app-relaunch.log")
try:
    rpc("debug.appearance", {"mode": "light"})
    time.sleep(1.2)  # capture harness: the theme repaints
    print("relaunch", snapshot(os.path.join(opts.out, "relaunch-main-light.png")), flush=True)
finally:
    quit_app(app)

frames = sorted(f for f in os.listdir(os.path.join(opts.out, "frames")) if f.endswith(".png"))
result["frames"] = frames
json.dump(result, open(os.path.join(opts.out, "result.json"), "w"), indent=2)
print("result", json.dumps(result), flush=True)
