#!/usr/bin/env python3
"""Window snapshots of the Mac Home transcript on a tagged build (for review
and before/after proof). Run on cmux-lawrence-2 or a fleet Mac, never on a
laptop. Launches the tagged app itself (no-activate, scratch config), opens
the Home fixture tab (`debug.home_native_fixture.open`, the real Home view
over the mock owner), then the Chief tab (Cmd-W, Cmd-1), captures each with
`debug.window_snapshot`, and kills only the app it started.

Usage: home-snapshot.py --tag <tag> [--out DIR] [--size 1100x720]
"""
import argparse, glob, json, os, signal, socket, subprocess, sys, tempfile, time

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS", "/tmp"))
parser.add_argument("--size", default="1100x720")
opts = parser.parse_args()
WIDTH, HEIGHT = (int(v) for v in opts.size.split("x"))
APP = next(iter(sorted(glob.glob(os.path.expanduser(
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
try:
    if os.path.exists(SOCKET):
        os.unlink(SOCKET)
    env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
           "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": CONFIG, "CMUX_NEXT_GHOSTTY_CONFIG": GHOSTTY,
           "CMUX_NEXT_TEST_WINDOW_FRAME": f"40,40,{WIDTH},{HEIGHT}"}
    log = open(os.path.join(opts.out, f"app-{opts.tag}.log"), "a")
    app = subprocess.Popen([BINARY], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
    print(f"launched pid {app.pid}", flush=True)
    if not wait(lambda: os.path.exists(SOCKET) and (rpc("debug.surfaces") or {}).get("windows"), 120):
        sys.exit("the tagged app did not come up")
    time.sleep(2)
    print("fixture:", rpc("debug.home_native_fixture.open"), flush=True)
    time.sleep(4)
    print("snapshot:", rpc("debug.window_snapshot", {"path": os.path.join(opts.out, f"home-fixture-{opts.tag}.png")}), flush=True)
    # Close the fixture tab: the home workspace's Chief tab shows.
    rpc("debug.key", {"key": "w", "modifiers": ["cmd"]})
    rpc("debug.key", {"key": "1", "modifiers": ["cmd"]})
    time.sleep(5)
    print("home:", json.dumps(rpc("debug.home"))[:400], flush=True)
    print("snapshot:", rpc("debug.window_snapshot", {"path": os.path.join(opts.out, f"home-chief-{opts.tag}.png")}), flush=True)
finally:
    if app and app.poll() is None:
        app.send_signal(signal.SIGKILL)
        print(f"killed {app.pid}", flush=True)
