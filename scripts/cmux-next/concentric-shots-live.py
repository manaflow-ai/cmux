#!/usr/bin/env python3
"""Light and dark shots of the containers that hold buttons, for the concentric rule's Before/After (Lawrence
2026-11-15: "all dialogs needs concentric padding with buttons inside").

  scripts/cmux-next/concentric-shots-live.py --app APP --tag TAG --out DIR

GUI host only (cmux-lawrence-2); never on a laptop. Launches the tagged app (no activation, automation socket,
isolated Chief), then for each surface and appearance writes the app's own window image (`debug.window_snapshot`, the window server's
composite with the overlay panels that toasts and dialogs draw in; no Screen Recording grant, so it works over SSH):
  playground   the Toast Playground: every toast style, the "Option or Shift + drag selects text" hint among them
  toast        the Stop all agents toast in the window (an action, Don't Show Again off, close)
  confirm      the confirm dialog card (Cancel, Close)
  save         the three-button save dialog card
  update       the sidebar's Update Ready card
  updated      the sidebar's Updated card, hovered so its close x shows
  notice       a tip's notice card ("Did you know?") with its close x
  keycaps      the Keycap Playground: every dialog keycap style on a real card's buttons, rest, hover and pressed
  dialogs      the confirm and save dialogs alone (dialog-confirm, dialog-save), for keycap Before/After

--only NAME[,NAME] shoots just those surfaces.
"""
import argparse, hashlib, json, os, plistlib, socket, subprocess, sys, tempfile, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from state_wait import wait_stable  # noqa: E402
from safe_log import safe_print  # noqa: E402  (a line before a kill never skips the kill)

parser = argparse.ArgumentParser()
parser.add_argument("--app", required=True)
parser.add_argument("--tag", required=True)
parser.add_argument("--out", required=True)
parser.add_argument("--only", default="")
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
SCRATCH = tempfile.mkdtemp(prefix=f"concentric-{opts.tag}-")


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


def snapshot(path, window=None):
    """The app's own image of a window with its overlay panels (no Screen Recording grant needed over SSH)."""
    params = {"path": path, "webviews": False}
    params.update({"window": window} if window is not None else {"kind": "main"})
    return rpc("debug.window_snapshot", params, timeout=40)


def settled(what, window=None, reads=4, interval=0.2, timeout=15):
    """Waits until the window's snapshot (the main one by default) is the same image `reads` times in a row: the
    surface came in and stopped moving. Best effort: a surface still moving at the deadline is shot anyway."""
    probe = os.path.join(SCRATCH, "settle.png")

    def image():
        reply = snapshot(probe, window() if callable(window) else window)
        if (reply or {}).get("error") or not os.path.exists(probe):
            raise RuntimeError(f"no snapshot: {reply}")
        with open(probe, "rb") as f:
            digest = hashlib.sha256(f.read()).hexdigest()
        os.remove(probe)
        return digest

    if wait_stable(image, what, timeout=timeout, interval=interval, reads=reads, raise_on_timeout=False) is None:
        print(f"note: no snapshot of {what} in {timeout} s", flush=True)


def window_with(word):
    """The id of a visible window whose title has `word`, or None (playground_window, without its print)."""
    return next((w["id"] for w in (rpc("debug.window_list") or {}).get("windows") or []
                 if word in (w.get("title") or "").lower()), None)


ONLY = set(filter(None, opts.only.split(",")))


def wanted(name):
    return not ONLY or name in ONLY


def playground_window(word="playground"):
    windows = (rpc("debug.window_list") or {}).get("windows") or []
    pick = [w for w in windows if word in (w.get("title") or "").lower()] or \
        [w for w in windows if w.get("kind") not in ("main", "panel", "TUINSWindow") and w.get("visible")]
    print("playground window", json.dumps(pick[:1]), flush=True)
    return pick[0]["id"] if pick else None


def shoot(name, prepare=None, cleanup=None, window=None):
    frames = {}
    for mode in ("light", "dark"):
        rpc("debug.appearance", {"mode": mode})
        time.sleep(1.0)  # capture harness: the theme repaints
        if prepare:
            prepare()
            time.sleep(1.5)  # capture harness: the surface's entrance ends
        path = os.path.join(opts.out, f"{name}-{mode}.png")
        frames[mode] = snapshot(path, window() if window else None)
        print("shot", path, os.path.exists(path), flush=True)
        if cleanup:
            cleanup()
            time.sleep(0.8)  # capture harness: the surface's exit ends
    with open(os.path.join(opts.out, f"{name}-frames.json"), "w") as f:
        json.dump(frames, f)


with open(os.path.join(opts.app, "Contents/Info.plist"), "rb") as f:
    BINARY = os.path.join(opts.app, "Contents/MacOS", plistlib.load(f)["CFBundleExecutable"])
if os.path.exists(SOCKET):
    os.unlink(SOCKET)
config = os.path.join(SCRATCH, "cmux.json")
open(config, "w").write("{}")
ghostty = os.path.join(SCRATCH, "ghostty")
open(ghostty, "w").write("")
app = subprocess.Popen([BINARY], env={
    "HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
    "CMUX_NEXT_CONFIG_FILE": config, "CMUX_NEXT_GHOSTTY_CONFIG": ghostty,
    "CMUX_NEXT_CHIEF_ISOLATED": "1", "CMUX_NEXT_CHIEF_HOME": os.path.join(SCRATCH, "chief"),
    "CMUX_NEXT_TEST_WINDOW_FRAME": "80,80,1000,620", "ACPMUX_AGENT_LAUNCH": "deny", "NX_REMOTE": "1"},
    stdout=open(os.path.join(opts.out, "app.log"), "w"), stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
print(f"app pid {app.pid}, scratch {SCRATCH}, out {opts.out}", flush=True)
try:
    if not wait(lambda: os.path.exists(SOCKET) and not (rpc("debug.window_frame") or {}).get("error"), 180):
        sys.exit("the tagged app did not come up")
    settled("the first window")
    stop_all = {"stopped": True, "subagents": ["a1", "a3"], "errors": ["a2: its turn did not stop: acpmux refused the cancel"]}
    if wanted("keycaps"):
        # The playground opens in the app's appearance: open it again after each switch.
        shoot("keycaps", lambda: print("keycaps", rpc("debug.toast", {"perform": "debug.keycapPlayground"}), flush=True),
              window=lambda: playground_window("keycap"))
    if wanted("dialogs"):
        # The quit-style confirm and the three-button save dialog: their keyed buttons' keycaps.
        shoot("dialog-confirm", lambda: rpc("debug.dialog", {"open": "confirm", "scope": "window"}),
              lambda: rpc("debug.dialog", {"key": "escape"}))
        shoot("dialog-save", lambda: rpc("debug.dialog", {"open": "save", "scope": "window"}),
              lambda: rpc("debug.dialog", {"key": "escape"}))
    if ONLY and not ONLY - {"keycaps", "dialogs"}:
        raise SystemExit(0)
    shoot("toast", lambda: rpc("debug.toast", {"stop_all": stop_all}),
          lambda: rpc("debug.toast", {"close": "home.stopAllAgents"}))
    shoot("confirm", lambda: rpc("debug.dialog", {"open": "confirm", "scope": "window"}),
          lambda: rpc("debug.dialog", {"key": "escape"}))
    shoot("save", lambda: rpc("debug.dialog", {"open": "save", "scope": "window"}),
          lambda: rpc("debug.dialog", {"key": "escape"}))
    print("stage", rpc("debug.updater", {"action": "stage", "version": "1.0.0-nightly.3932981759301", "changes": 3}), flush=True)
    settled("the update card")
    shoot("update")
    rpc("debug.updater", {"action": "unstage"})
    if True:  # the card with a close x: a tip's notice card (the Updated card is gone, 2026-11-22)
        print("tip", rpc("debug.updater", {"action": "tip"}), flush=True)
        settled("the notice card")
        shoot("notice")
        rpc("debug.updater", {"action": "untip"})
    print("playground", rpc("debug.toast", {"perform": "debug.toastPlayground"}), flush=True)
    # The playground window and its toasts come up: the window is listed, then its image stops changing.
    if wait(lambda: window_with("playground"), 15):
        settled("the playground window", window=lambda: window_with("playground"))
    else:
        safe_print("note: no playground window listed in 15 s", flush=True)
    shoot("playground", window=playground_window)
    print("toasts", json.dumps(rpc("debug.toast"))[:600], flush=True)
finally:
    rpc("debug.appearance", {"mode": "system"})
    rpc("debug.quit", {"fixture_quit": "end-sessions"})
    try:
        app.wait(timeout=20)
    except subprocess.TimeoutExpired:
        app.kill()  # the exact PID this script started
        app.wait()
