#!/usr/bin/env python3
"""Snapshots of a tagged app over a see-through window (background-opacity 0.6): which surfaces paint opaque."""
import hashlib, json, os, socket, subprocess, sys, tempfile, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from state_wait import wait_stable, wait_until
TAG, APP, OUT = sys.argv[1], sys.argv[2], sys.argv[3]
SOCKET = "/tmp/cmux-debug-%s.sock" % TAG
os.makedirs(OUT, exist_ok=True)
def rpc(method, params=None, timeout=30):
    try:
        c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); c.settimeout(timeout); c.connect(SOCKET)
        c.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = c.recv(1 << 20)
            if not chunk: break
            buf += chunk
        r = json.loads(buf); return r.get("result") if r.get("ok") else {"error": r.get("error")}
    except (OSError, ValueError) as e:
        return {"error": str(e)}
scratch = tempfile.mkdtemp(prefix="transp-")
cfg, gh = os.path.join(scratch, "cmux.json"), os.path.join(scratch, "ghostty")
open(cfg, "w").write("{}"); open(gh, "w").write("background-opacity = 0.6\n")
env = {"HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
       "PATH": "/usr/bin:/bin", "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_TEST_WINDOW_SCREEN": "last",
       "CMUX_NEXT_CONFIG_FILE": cfg, "CMUX_NEXT_GHOSTTY_CONFIG": gh, "CMUX_NEXT_TEST_WINDOW_FRAME": "40,430,1200,760"}
log = os.path.join(OUT, "app.log")
subprocess.run(["open", "-n", "--stdout", log, "--stderr", log] + [a for k, v in env.items() for a in ("--env", "%s=%s" % (k, v))] + [APP])
for _ in range(240):
    if os.path.exists(SOCKET) and (rpc("debug.windows") or {}).get("windows"): break
    time.sleep(0.5)
def picture():
    probe = os.path.join(scratch, "settle.png")
    rpc("debug.window_snapshot", {"kind": "main", "path": probe}, timeout=60)
    with open(probe, "rb") as f:
        return hashlib.sha1(f.read()).hexdigest()
def shot(name):
    # The surface painted: the main window's snapshot is the same picture three reads in a row.
    if wait_stable(picture, name + " painted", timeout=15, interval=0.1, reads=3, raise_on_timeout=False) is None:
        print("note: %s did not hold still in 15 s" % name, flush=True)
    print(name, json.dumps(rpc("debug.window_snapshot", {"kind": "main", "path": os.path.join(OUT, name + ".png")}, timeout=60))[:160], flush=True)
try:
    shot("1-new-tab-page")
    for name, action, args in [("2-terminal", "newSurface", {}), ("3-browser", "openBrowser", {"url": "https://example.com"}),
                               ("4-settings", "openSettings", {}), ("5-agent-chat", "palette.newAgentChat", {})]:
        print(name, json.dumps(rpc("action.run", {"id": action, "args": args}))[:120], flush=True)
        time.sleep(1)  # proof capture: the tab lands
        rpc("action.run", {"id": "selectSurfaceByNumber", "args": {"index": 9}})
        shot(name)
finally:
    rpc("action.run", {"id": "quit", "args": {"endSessions": True}}, timeout=10)
    # The app quit: its socket no longer answers (NX_APP_STOP checks it is gone).
    if not wait_until(lambda: "error" in (rpc("debug.windows", timeout=2) or {"error": 1}), "the app to quit", timeout=20,
                      interval=0.2, raise_on_timeout=False):
        print("note: the app still answered 20 s after its quit", flush=True)
    stop = os.environ.get("NX_APP_STOP")
    if stop: subprocess.run([stop], timeout=60)
