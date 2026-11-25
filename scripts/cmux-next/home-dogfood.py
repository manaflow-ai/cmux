#!/usr/bin/env python3
"""The Home dogfood preflight on a tagged build (cmux-lawrence-2 only):
every advertised path, a screenshot each, and a recording of send and
receive: the Chief tab; the Home fixture conversation (attachments: photo,
video, PDF); text typed and sent; the Chief typing and answering; a
tapback; a photo attached by drop (chip) and sent; the video playing
inline; a scroll up and a send there (no gap); a light theme and a dark
theme (written to the scratch cmux.json; the config watcher applies them).

Derived from home-polish.py: the Home polish pass on a tagged build, next to MessagesLabAppKitNative's
own recordings: window snapshots and 120 Hz window recordings
(`debug.window_record`) of the Home fixture (`debug.home_native_fixture.open`
with attachments: the real Home view over the mock owner) through every
state: the conversation with attachments, the header, typing in the field,
a send (morph, Delivered), the Chief typing and answering, a tapback, a
scroll, and the Chief tab. Drives the view through its own entry points
(`debug.home.drive`). Run on cmux-lawrence-2 only; launches the tagged app
itself (no-activate, scratch config) and kills only that app.

Usage: home-dogfood.py --tag <tag> [--out DIR] [--size 818x1060] [--app PATH]
"""
import argparse, glob, hashlib, json, os, signal, socket, subprocess, sys, tempfile, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import home_classic  # noqa: E402
from safe_log import safe_print  # noqa: E402  (a line in a cleanup path never skips the kill)
from state_wait import wait_stable, wait_until  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS", "/tmp"))
parser.add_argument("--size", default="818x1060")
parser.add_argument("--app", default=None)
parser.add_argument("--photo", required=True, help="an image file on this Mac to attach")
parser.add_argument("--activate", action="store_true",
                    help="let the window become key (its Liquid Glass renders as in use; lab Mac only)")
opts = parser.parse_args()
WIDTH, HEIGHT = (int(v) for v in opts.size.split("x"))
APP = opts.app or next(iter(sorted(glob.glob(os.path.expanduser(
    f"~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/cmux DEV {opts.tag}.app")))), None)
if not APP:
    sys.exit(f"no tagged app for {opts.tag}")
BINARY = os.path.join(APP, "Contents/MacOS/cmux DEV")
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
SCRATCH = tempfile.mkdtemp(prefix=f"homeshot-{opts.tag}-")
CONFIG = os.path.join(SCRATCH, "cmux.json")
GHOSTTY = os.path.join(SCRATCH, "ghostty")
open(CONFIG, "w").write("{}")
open(GHOSTTY, "w").write("")


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


def wait(predicate, seconds, step=0.5):
    end = time.time() + seconds
    while time.time() < end:
        value = predicate()
        if value:
            return value
        time.sleep(step)
    return None


app = None
os.makedirs(opts.out, exist_ok=True)


def shot(name):
    print(name, rpc("debug.window_snapshot", {"path": os.path.join(opts.out, f"{name}.png")}), flush=True)


def record(name, seconds):
    print(name, rpc("debug.window_record", {"dir": os.path.join(opts.out, name), "seconds": seconds}), flush=True)


def drive(action, **params):
    params["action"] = action
    reply = rpc("debug.home.drive", params)
    print("drive", action, reply, flush=True)
    return reply


def read(action):
    """A drive read (texts, rows, typing, geometry) without the drive log line."""
    reply = rpc("debug.home.drive", {"action": action})
    return reply if isinstance(reply, dict) else {}


def texts():
    return read("texts").get("texts") or []


def pixels():
    """A hash of a fresh window snapshot, for changes no socket state reports (video, tapback, theme)."""
    path = os.path.join(SCRATCH, "settle.png")
    if (rpc("debug.window_snapshot", {"path": path}) or {}).get("error"):
        return None
    with open(path, "rb") as handle:
        return hashlib.sha1(handle.read()).hexdigest()


# The shots are best effort: a wait that times out says what never happened and the shot is taken anyway.
def until(predicate, what, timeout=15):
    value = wait_until(predicate, what, timeout=timeout, interval=0.1, raise_on_timeout=False)
    if not value:
        safe_print(f"wait: {what} did not happen in {timeout} s; shooting anyway", flush=True)
    return value


def settle(get, what, timeout=10, reads=4):
    return wait_stable(get, what, timeout=timeout, interval=0.1, reads=reads, raise_on_timeout=False)


def changed_then_settled(before, get, what, timeout=15):
    """Wait until `get()` moved off `before`, then until it holds still."""
    until(lambda: get() != before, what, timeout)
    return settle(get, what)


def theme(name):
    with open(CONFIG, "w") as f:
        json.dump({"appearance": {"theme": name}} if name else {}, f)
    print("theme", name, flush=True)


try:
    if os.path.exists(SOCKET):
        os.unlink(SOCKET)
    env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
           "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": CONFIG, "CMUX_NEXT_GHOSTTY_CONFIG": GHOSTTY,
           "CMUX_NEXT_TEST_WINDOW_FRAME": f"40,40,{WIDTH},{HEIGHT}", **home_classic.ENV}
    if opts.activate:
        env.pop("CMUX_NEXT_NO_ACTIVATE")
    log = open(os.path.join(opts.out, f"app-{opts.tag}.log"), "a")
    app = subprocess.Popen([BINARY], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
    safe_print(f"launched pid {app.pid}", flush=True)
    if not wait(lambda: os.path.exists(SOCKET) and (rpc("debug.surfaces") or {}).get("windows"), 180):
        sys.exit("the tagged app did not come up")
    if not home_classic.require(rpc):  # classic Home: these checks drive the native transcript
        sys.exit(2)
    settle(lambda: rpc("debug.home"), "the Chief tab")
    shot("01-home-chief-tab")
    safe_print("fixture:", rpc("debug.home_native_fixture.open", {"attachments": True, "new": True}), flush=True)
    # The fixture's transcript is shown and its attachments laid out (rows hold still).
    until(texts, "the fixture's transcript", 30)
    settle(lambda: read("rows"), "the fixture's rows", timeout=20)
    shot("02-conversation-photo-video-file")
    # The fixture's video is on screen now: it plays in its bubble.
    still = pixels()
    drive("video")
    # Playing: the window's pixels change (the video's frames advance).
    until(lambda: pixels() != still, "the video to play")
    shot("03-video-playing")
    drive("video")
    # Paused: two snapshots in a row are the same frame.
    settle(pixels, "the paused video", reads=2)
    shot("04-video-paused")
    drive("focus")
    drive("type", text="How are you doing?")
    settle(lambda: read("geometry"), "the field with the typed text")
    shot("05-typed")
    record("rec-send-receive", 7)
    time.sleep(0.4)  # sleep-ok: still frames in the recording before the send
    drive("send")
    # Sent: my message is in the transcript and its row's morph has ended (rows hold still).
    until(lambda: any("How are you doing?" in t for t in texts()), "my message in the transcript")
    settle(lambda: read("rows"), "the sent message's row")
    sent = texts()
    shot("06-sent")
    until(lambda: read("typing").get("ok"), "the Chief's typing bubble")
    shot("07-typing")
    # Received: the typing bubble is gone and the Chief's answer is in the transcript.
    until(lambda: not read("typing").get("ok") and texts() != sent, "the Chief's answer", 30)
    settle(lambda: read("rows"), "the answer's row")
    shot("08-received")
    before = pixels()
    drive("tapback")
    changed_then_settled(before, pixels, "the tapback on screen")
    shot("09-tapback")
    before = read("geometry")
    safe_print("attach:", rpc("debug.home.attach", {"paths": [opts.photo], "via": "drop"}), flush=True)
    # The chip grows the field: the geometry changes, then holds.
    changed_then_settled(before, lambda: read("geometry"), "the photo chip in the field")
    drive("focus")
    drive("type", text="A photo")
    settle(lambda: read("geometry"), "the field with the chip and text")
    shot("10-photo-chip")
    count = len(texts())
    drive("send")
    until(lambda: len(texts()) > count, "the photo message in the transcript")
    settle(lambda: read("rows"), "the photo message's row", timeout=15)
    shot("11-photo-sent")
    before = read("geometry")
    drive("scroll", dy=-500)
    changed_then_settled(before, lambda: read("geometry"), "the transcript to scroll up")
    shot("12-scrolled-up")
    drive("focus")
    drive("type", text="Sent while scrolled up")
    record("rec-scrolled-up-send", 3)
    time.sleep(0.3)  # sleep-ok: still frames in the recording before the send
    drive("send")
    time.sleep(0.25)  # sleep-ok: the shot is a sample 0.25 s into the send's animation (mid-move, on purpose)
    shot("13-scrolled-up-send-mid")
    until(lambda: any("Sent while scrolled up" in t for t in texts()), "the scrolled-up send in the transcript")
    settle(lambda: (read("rows"), read("geometry")), "the transcript after the scrolled-up send")
    shot("14-scrolled-up-send-done")
    # The config watcher applies the theme: the window's pixels change, then hold.
    before = pixels()
    theme("Catppuccin Latte")
    changed_then_settled(before, pixels, "the light theme", timeout=20)
    shot("15-light-theme")
    before = pixels()
    theme("Catppuccin Mocha")
    changed_then_settled(before, pixels, "the dark theme", timeout=20)
    shot("16-dark-theme")
    safe_print("done", flush=True)
finally:
    if app and app.poll() is None:
        app.send_signal(signal.SIGKILL)
        safe_print(f"killed {app.pid}", flush=True)
