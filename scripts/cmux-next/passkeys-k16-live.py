#!/usr/bin/env python3
"""K16 live check (cx-d0d.47, plans/cmux-next/passkeys.md K16): launches a tagged DEV cmux-next
app, then runs passkeys-matrix-e2e.py --k16 against its socket. A CEF tab partly covered by the
command palette must stay VISIBLE, so a virtual-authenticator ceremony there completes.
`debug.cef.devtools` (the virtual authenticator) needs a Debug build.

Usage: passkeys-k16-live.py --tag TAG --app PATH.app --out DIR
"""
import argparse, json, os, plistlib, re, socket, subprocess, sys, tempfile, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tag_teardown import TagTeardown  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True, help="the bundle's tag (its socket comes from the bundle id)")
parser.add_argument("--app", required=True)
parser.add_argument("--out", required=True)
opts = parser.parse_args()
APP = os.path.abspath(opts.app)
with open(os.path.join(APP, "Contents/Info.plist"), "rb") as f:
    INFO = plistlib.load(f)
BINARY = os.path.join(APP, "Contents/MacOS", INFO["CFBundleExecutable"])
# Only a tagged DEV bundle: its socket is per tag, and the teardown never reaches another app.
PREFIX = "com.cmuxterm.app.debug."
if not INFO.get("CFBundleIdentifier", "").startswith(PREFIX):
    sys.exit(f"refusing {INFO.get('CFBundleIdentifier')}: not a tagged DEV bundle")
# The app's slug of its bundle tag (ControlSocketPath.sanitize): tag pk-k16 is bundle ...debug.pk.k16.
SOCKET = f"/tmp/cmux-debug-{re.sub(r'[^a-z0-9]+', '-', INFO['CFBundleIdentifier'][len(PREFIX):].lower()).strip('-')}.sock"
SCRATCH = tempfile.mkdtemp(prefix=f"passkeys-k16-{opts.tag}-")
CONFIG = os.path.join(SCRATCH, "cmux.json")
GHOSTTY = os.path.join(SCRATCH, "ghostty-config")
for path, text in ((CONFIG, "{}\n"), (GHOSTTY, "")):
    with open(path, "w") as handle:
        handle.write(text)
os.makedirs(opts.out, exist_ok=True)
ENV = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
       "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"}


def call(method, params=None):
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(5)
        conn.connect(SOCKET)
        conn.sendall(json.dumps({"id": 1, "method": method, "params": params or {}}).encode() + b"\n")
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = conn.recv(1 << 16)
            if not chunk:
                break
            buf += chunk
        conn.close()
        return json.loads(buf)
    except (OSError, ValueError):
        return {}


def ours():
    """The socket answers, and it is the app launched here."""
    reply = call("system.identify")
    return reply.get("ok") and (reply.get("result") or {}).get("pid") == app.pid


teardown = TagTeardown(APP)
teardown.install()
app = subprocess.Popen([BINARY], env={**ENV, "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_TEST_WINDOW_SCREEN": "last",
                                      "CMUX_NEXT_CONFIG_FILE": CONFIG, "CMUX_NEXT_GHOSTTY_CONFIG": GHOSTTY},
                       stdout=open(os.path.join(opts.out, "app.log"), "w"), stderr=subprocess.STDOUT)
print(f"app pid {app.pid}, scratch {SCRATCH}, out {opts.out}", flush=True)
status = 1
try:
    deadline = time.time() + 120
    while time.time() < deadline and not ours():
        time.sleep(0.5)  # test harness: the app starts
    if not ours():
        sys.exit(f"{SOCKET} is not the app launched here (pid {app.pid})")
    matrix = os.path.join(os.path.dirname(os.path.abspath(__file__)), "passkeys-matrix-e2e.py")
    status = subprocess.run([sys.executable, matrix, "--socket", SOCKET, "--k16", "--out", opts.out], timeout=300).returncode
finally:
    if ours():
        call("action.run", {"action": "quitEndSessions"})
    try:
        app.wait(timeout=20)
    except subprocess.TimeoutExpired:
        app.kill()  # the PID launched above, never a pattern
    teardown.end()
print(f"{'passed' if status == 0 else 'FAILED'}; artifacts in {opts.out}")
sys.exit(status)
