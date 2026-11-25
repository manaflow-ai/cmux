#!/usr/bin/env python3
"""Record a sidebar workspace card's Show details and Hide details, frame by frame (Lawrence 2026-11-17, msg 38370:
"fix jank like shadows stuff", a recording of the card's rim, corners and shadow breaking while it resized).

  python3 scripts/cmux-next/workspace-card-fold-record.py --app "$APP" --tag TAG --out DIR

Run it on a fleet GUI Mac in the console session (cmux-lawrence-2), never on a person's Mac. It launches the tagged
DEBUG app with a scratch cmux.json and CMUX_NEXT_NO_ACTIVATE=1 (it never takes the focus from another agent on the
host), rests the pointer on the first workspace row until its card shows, then presses Show details, waits, and
presses Hide details (`debug.hover_cards {press: ...}`, the button's own press). The app records its own windows (the
card's included) every composited frame while it does (`debug.new_tab {action: "frame_strip", above: true}`). DIR gets
frame-NNN.png, strip.png, report.json and presses.json (each press's time from the recording's start). It quits the
app with its own quit and signals nothing else.
"""
import argparse, json, os, plistlib, socket, subprocess, tempfile, threading, time
import sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from safe_log import safe_print  # noqa: E402  (a line before a kill never skips the kill)

parser = argparse.ArgumentParser()
parser.add_argument("--app", required=True)
parser.add_argument("--tag", required=True)
parser.add_argument("--out", required=True)
parser.add_argument("--scale", type=float, default=1.0)
opts = parser.parse_args()
SOCKET = f"/tmp/cmux-debug-{opts.tag}.sock"
os.makedirs(opts.out, exist_ok=True)


def rpc(method, params=None, timeout=60):
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
    reply = json.loads(buf or b"{}")
    return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}


def wait(check, seconds, step=0.2):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:  # bounded wait on the app's state
        try:
            value = check()
        except OSError:
            value = None
        if value:
            return value
        time.sleep(step)
    return None


def xywh(f):
    return [f["x"], f["y"], f["width"], f["height"]] if isinstance(f, dict) else list(f)


def first_row():
    rows = ((rpc("debug.sidebar_rows") or {}).get("windows") or [{}])[0].get("rows") or []
    for row in rows:
        if str(row.get("key", "")).startswith("workspace") and row.get("in_list") and row.get("title") == "Fleet tools GCP grant":
            f = xywh(row["window_frame"])
            return row.get("title"), (f[0] + f[2] * 0.4, f[1] + f[3] / 2)
    return None


def card_showing(showing=True):
    """`debug.hover_cards` says a card shows (or, with showing=False, none shows and the coordinator is idle)."""
    c = rpc("debug.hover_cards", timeout=5) or {}
    if "error" in c:
        return None
    if showing:
        return c.get("card_showing") == "true" or c.get("visible") in (True, "true")
    return c.get("card_showing") != "true" and c.get("phase", "idle") == "idle"


APP = opts.app.rstrip("/")
with open(os.path.join(APP, "Contents/Info.plist"), "rb") as f:
    BINARY = os.path.join(APP, "Contents/MacOS", plistlib.load(f)["CFBundleExecutable"])
scratch = tempfile.mkdtemp(prefix=f"card-fold-{opts.tag}-")
config = os.path.join(scratch, "cmux.json")
with open(config, "w") as f:
    f.write("{}\n")
if os.path.exists(SOCKET):
    os.unlink(SOCKET)
app = subprocess.Popen([BINARY], env={
    "HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_CONFIG_FILE": config,
    "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1100,760", "CMUX_NEXT_NO_ACTIVATE": "1"},
    stdout=open(os.path.join(opts.out, "app.log"), "w"), stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)

try:
    wait(lambda: os.path.exists(SOCKET) and "error" not in (rpc("debug.focus") or {"error": 1}), 180)
    if not (rpc("debug.focus") or {}).get("windows"):
        rpc("action.run", {"action": "newWindow", "origin": "script"})
    wait(lambda: (rpc("debug.focus") or {}).get("windows"), 60)
    # A workspace named like the recording's (a fresh profile has none): its card is the one recorded.
    cli = os.path.join(APP, "Contents/Resources/bin/cmux")
    cli_env = dict(os.environ, CMUX_SOCKET_PATH=SOCKET, CMUX_TAG=opts.tag)
    for name in ("Fleet tools GCP grant",):
        made = subprocess.run([cli, "workspace", "create", "--name", name, "--json"], env=cli_env, capture_output=True, text=True, timeout=60)
        print("workspace", name, made.returncode, (made.stdout or made.stderr)[:200], flush=True)
        time.sleep(1.0)
    row = wait(first_row, 60)
    if not row:
        raise SystemExit("no workspace row")
    title, point = row
    print("row", title, point, flush=True)
    off = (700, 500)
    rpc("debug.mouse", {"action": "move", "x": off[0], "y": off[1]})
    if not wait(lambda: card_showing(False), 10):
        safe_print("note: a card still showed 10 s after the pointer moved off", flush=True)
    rpc("debug.mouse", {"action": "move", "x": point[0], "y": point[1]})
    # Past the dwell: the card shows, and its open animation ends (the report stops changing).
    if not wait(card_showing, 15):
        safe_print("note: the row's card did not show in 15 s", flush=True)
    last = None
    for _ in range(25):  # bounded: up to 5 s for two equal reads in a row
        now = json.dumps(rpc("debug.hover_cards", timeout=5) or {}, sort_keys=True)
        if now == last:
            break
        last = now
        time.sleep(0.2)
    print("card", json.dumps(rpc("debug.hover_cards") or {})[:400], flush=True)

    presses = [(0.4, "Show details"), (1.6, "Hide details"), (2.8, "Show details"), (3.25, "Hide details")]
    total = 4.6
    record = {}

    def run_strip():
        record["report"] = rpc("debug.new_tab", {
            "action": "frame_strip", "gesture": "mouse", "mouse": {"action": "move", "x": point[0], "y": point[1]},
            "above": True, "scale": opts.scale, "duration_ms": int(total * 1000), "content": "none", "dir": opts.out}, timeout=120)

    thread = threading.Thread(target=run_strip)
    thread.start()
    # sleep-ok: aligns the press timeline with the recorder's fixed 120 ms lead; the strip call blocks until the
    # recording ends, so nothing says when it began.
    time.sleep(0.2)  # the recorder's lead (120 ms)
    start = time.monotonic()
    sent = []
    for at, label in presses:
        delay = at - (time.monotonic() - start)
        if delay > 0:
            time.sleep(delay)
        reply = rpc("debug.hover_cards", {"press": label})
        sent.append({"at_s": round(time.monotonic() - start, 4), "press": label, "error": (reply or {}).get("error")})
    thread.join()
    wait(lambda: os.path.exists(os.path.join(opts.out, "strip.png")), 120, step=0.5)
    report = record.get("report") or {}
    with open(os.path.join(opts.out, "report.json"), "w") as f:
        json.dump(report, f, indent=1)
    with open(os.path.join(opts.out, "presses.json"), "w") as f:
        json.dump({"row": title, "point": point, "presses": sent}, f, indent=1)
    print("presses", sent, flush=True)
    print("frames", len([n for n in os.listdir(opts.out) if n.startswith("frame-")]), "error", report.get("error"), flush=True)
finally:
    try:
        rpc("action.run", {"action": "quitEndSessions", "origin": "script"}, timeout=20)
    except OSError:
        pass
    try:
        app.wait(timeout=30)
    except subprocess.TimeoutExpired:
        app.kill()  # the exact PID this script started
        app.wait()
