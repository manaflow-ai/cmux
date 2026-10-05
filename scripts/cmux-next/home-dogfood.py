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
import argparse, glob, json, os, signal, socket, subprocess, sys, tempfile, time

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
           "CMUX_NEXT_TEST_WINDOW_FRAME": f"40,40,{WIDTH},{HEIGHT}"}
    if opts.activate:
        env.pop("CMUX_NEXT_NO_ACTIVATE")
    log = open(os.path.join(opts.out, f"app-{opts.tag}.log"), "a")
    app = subprocess.Popen([BINARY], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
    print(f"launched pid {app.pid}", flush=True)
    if not wait(lambda: os.path.exists(SOCKET) and (rpc("debug.surfaces") or {}).get("windows"), 180):
        sys.exit("the tagged app did not come up")
    time.sleep(2)
    shot("01-home-chief-tab")
    print("fixture:", rpc("debug.home_native_fixture.open", {"attachments": True}), flush=True)
    time.sleep(6)
    shot("02-conversation-photo-video-file")
    drive("focus")
    drive("type", text="How are you doing?")
    time.sleep(0.8)
    shot("03-typed")
    record("rec-send-receive", 7)
    time.sleep(0.4)
    drive("send")
    time.sleep(0.9)
    shot("04-sent")
    time.sleep(1.0)
    shot("05-typing")
    time.sleep(4.5)
    shot("06-received")
    drive("tapback")
    time.sleep(1.5)
    shot("07-tapback")
    print("attach:", rpc("debug.home.attach", {"paths": [opts.photo], "via": "drop"}), flush=True)
    time.sleep(3)
    drive("focus")
    drive("type", text="A photo")
    time.sleep(0.8)
    shot("08-photo-chip")
    drive("send")
    time.sleep(3)
    shot("09-photo-sent")
    drive("video")
    time.sleep(1.5)
    shot("10-video-playing")
    drive("video")
    time.sleep(0.5)
    shot("11-video-paused")
    drive("scroll", dy=-500)
    time.sleep(1.2)
    shot("12-scrolled-up")
    drive("focus")
    drive("type", text="Sent while scrolled up")
    record("rec-scrolled-up-send", 3)
    time.sleep(0.3)
    drive("send")
    time.sleep(0.25)
    shot("13-scrolled-up-send-mid")
    time.sleep(2.5)
    shot("14-scrolled-up-send-done")
    theme("Catppuccin Latte")
    time.sleep(4)
    shot("15-light-theme")
    theme("Catppuccin Mocha")
    time.sleep(4)
    shot("16-dark-theme")
    print("done", flush=True)
finally:
    if app and app.poll() is None:
        app.send_signal(signal.SIGKILL)
        print(f"killed {app.pid}", flush=True)
