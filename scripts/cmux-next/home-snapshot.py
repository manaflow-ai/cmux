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
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import home_classic  # noqa: E402
from safe_log import safe_print  # noqa: E402  (a line in a cleanup path never skips the kill)
from state_wait import wait_until, wait_stable  # noqa: E402

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


def shows_home():
    return any(w.get("shows_home") and w.get("home_view_installed") for w in (rpc("debug.home") or {}).get("windows") or [])


def texts():
    return (rpc("debug.home.drive", {"action": "texts"}) or {}).get("texts")


app = None
os.makedirs(opts.out, exist_ok=True)
try:
    if os.path.exists(SOCKET):
        os.unlink(SOCKET)
    env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
           "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1", "CMUX_NEXT_SOCKET_MODE": "automation",
           "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_NEXT_CONFIG_FILE": CONFIG, "CMUX_NEXT_GHOSTTY_CONFIG": GHOSTTY,
           "CMUX_NEXT_TEST_WINDOW_FRAME": f"40,40,{WIDTH},{HEIGHT}", **home_classic.ENV}
    log = open(os.path.join(opts.out, f"app-{opts.tag}.log"), "a")
    app = subprocess.Popen([BINARY], env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL)
    safe_print(f"launched pid {app.pid}", flush=True)
    if not wait(lambda: os.path.exists(SOCKET) and (rpc("debug.surfaces") or {}).get("windows"), 120):
        sys.exit("the tagged app did not come up")
    if not home_classic.require(rpc):  # classic Home: these checks drive the native transcript
        sys.exit(2)
    # A window shows the installed Home view before the fixture opens over it.
    if not wait_until(shows_home, "a window showing the installed Home view", timeout=30, raise_on_timeout=False):
        safe_print("no window shows the installed Home view yet; opening the fixture anyway", flush=True)
    safe_print("fixture:", rpc("debug.home_native_fixture.open", {"new": True}), flush=True)
    # The fixture's transcript is laid out: its texts are there and stop changing.
    fixture_texts = wait_until(texts, "the fixture transcript's texts", timeout=30, raise_on_timeout=False)
    fixture_texts = wait_stable(texts, "the fixture transcript", timeout=15, raise_on_timeout=False) or fixture_texts
    if not fixture_texts:
        safe_print("the fixture transcript shows no texts; snapshotting anyway", flush=True)
    safe_print("snapshot:", rpc("debug.window_snapshot", {"path": os.path.join(opts.out, f"home-fixture-{opts.tag}.png")}), flush=True)
    time.sleep(2)  # sleep-ok: the second snapshot is a later frame on purpose (the transcript holds still over 2 s)
    safe_print("snapshot:", rpc("debug.window_snapshot", {"path": os.path.join(opts.out, f"home-fixture-{opts.tag}-2.png")}), flush=True)
    # Close the fixture tab: the home workspace's Chief tab shows.
    rpc("debug.key", {"key": "w", "modifiers": ["cmd"]})
    rpc("debug.key", {"key": "1", "modifiers": ["cmd"]})
    # The Chief tab shows: a window shows Home, the fixture's texts are gone, and what shows stops changing.
    if not wait_until(lambda: shows_home() and texts() != fixture_texts, "the Chief tab in place of the fixture",
                      timeout=30, raise_on_timeout=False):
        safe_print("the Chief tab did not replace the fixture; snapshotting anyway", flush=True)
    wait_stable(texts, "the Chief tab's transcript", timeout=10, raise_on_timeout=False)
    safe_print("home:", json.dumps(rpc("debug.home"))[:400], flush=True)
    safe_print("snapshot:", rpc("debug.window_snapshot", {"path": os.path.join(opts.out, f"home-chief-{opts.tag}.png")}), flush=True)
finally:
    if app and app.poll() is None:
        app.send_signal(signal.SIGKILL)
        safe_print(f"killed {app.pid}", flush=True)
