#!/usr/bin/env python3
"""The Home polish pass on a tagged build, next to MessagesLabAppKitNative's
own recordings: window snapshots and 120 Hz window recordings
(`debug.window_record`) of the Home fixture (`debug.home_native_fixture.open`
with attachments: the real Home view over the mock owner) through every
state: the conversation with attachments, the header, typing in the field,
a send (morph, Delivered), the Chief typing and answering, a tapback, a
scroll, and the Chief tab. Drives the view through its own entry points
(`debug.home.drive`). Run on cmux-lawrence-2 only; launches the tagged app
itself (no-activate, scratch config) and kills only that app.

Usage: home-polish.py --tag <tag> [--out DIR] [--size 818x1060] [--app PATH]
"""
import argparse, glob, hashlib, json, os, signal, socket, subprocess, sys, tempfile, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import home_classic  # noqa: E402
from state_wait import wait_until, wait_stable  # noqa: E402
from safe_log import safe_print  # noqa: E402  (a line in a cleanup path never skips the kill)

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS", "/tmp"))
parser.add_argument("--size", default="818x1060")
parser.add_argument("--app", default=None)
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


def recorded(name, seconds):
    """The recording `name` finished by itself: its frames.json lands when the recorder ends."""
    if not wait_until(lambda: os.path.exists(os.path.join(opts.out, name, "frames.json")), f"{name} to finish",
                      timeout=seconds + 15, interval=0.1, raise_on_timeout=False):
        safe_print(f"{name}: no frames.json {seconds + 15} s after it started", flush=True)


def pixels():
    """A hash of the window as drawn now (a scratch snapshot)."""
    path = os.path.join(SCRATCH, "settle.png")
    reply = rpc("debug.window_snapshot", {"path": path}) or {}
    if reply.get("error") or not os.path.exists(path):
        return None
    with open(path, "rb") as f:
        digest = hashlib.sha1(f.read()).hexdigest()
    os.unlink(path)
    return digest


def settled(what, timeout=15):
    """The window stopped changing (a layout, an animation, pictures loading): its snapshot is the same 3 times."""
    if wait_stable(pixels, what, timeout=timeout, interval=0.05, raise_on_timeout=False) is None:
        safe_print(f"{what}: the window never gave a stable snapshot in {timeout} s", flush=True)


def texts():
    return (rpc("debug.home.drive", {"action": "texts"}) or {}).get("texts") or []


def typing_shown():
    return bool((rpc("debug.home.drive", {"action": "typing"}) or {}).get("ok"))


def drive(action, **params):
    params["action"] = action
    reply = rpc("debug.home.drive", params)
    print("drive", action, reply, flush=True)
    return reply


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
    settled("the Chief tab")
    shot("01-chief-tab")
    safe_print("fixture:", rpc("debug.home_native_fixture.open", {"attachments": True, "new": True}), flush=True)
    # The fixture's transcript shows, then its attachments load and the window stops changing.
    if not wait_until(texts, "the fixture's transcript", timeout=30, interval=0.1, raise_on_timeout=False):
        safe_print("the fixture's transcript never showed texts in 30 s", flush=True)
    settled("the conversation with attachments", timeout=20)
    shot("02-conversation-attachments")
    drive("focus")
    drive("type", text="How are you doing?")
    settled("the typed field")
    shot("03-typed")
    record("rec-send-receive", 6)
    time.sleep(0.4)  # sleep-ok: the recording keeps still frames before the send
    before = len(texts())
    drive("send")
    # The sent message is in the transcript and its morph and Delivered have drawn (before the Chief types, 1.5 s).
    wait_until(lambda: (t := texts()) and len(t) > before and "How are you doing?" in t, "the sent message",
               timeout=10, interval=0.05, raise_on_timeout=False)
    wait_stable(pixels, "the sent message's morph", timeout=1.2, interval=0.05, raise_on_timeout=False)
    shot("04-sent-delivered")
    if not wait_until(typing_shown, "the Chief's typing row", timeout=10, interval=0.05, raise_on_timeout=False):
        safe_print("the Chief's typing row never showed", flush=True)
    shot("05-typing")
    sent = len(texts())
    # The Chief's answer lands, its typing row is gone, and the window stops changing.
    if not wait_until(lambda: len(texts()) > sent and not typing_shown(), "the Chief's answer", timeout=20, interval=0.1,
                      raise_on_timeout=False):
        safe_print("the Chief's answer never landed in 20 s", flush=True)
    settled("the received answer")
    shot("06-received")
    recorded("rec-send-receive", 6)
    record("rec-tapback", 2)
    time.sleep(0.3)  # sleep-ok: the recording keeps still frames before the tapback
    drive("tapback")
    settled("the tapback")
    shot("07-tapback")
    recorded("rec-tapback", 2)
    record("rec-scroll", 2)
    time.sleep(0.2)  # sleep-ok: the recording keeps still frames before the scroll
    drive("scroll", dy=-500)
    settled("the scroll")
    shot("08-scrolled")
    drive("scroll", dy=500)
    recorded("rec-scroll", 2)  # the recording ends before the app is killed
    safe_print("done", flush=True)
finally:
    if app and app.poll() is None:
        app.send_signal(signal.SIGKILL)
        safe_print(f"killed {app.pid}", flush=True)
