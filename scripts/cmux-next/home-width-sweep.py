#!/usr/bin/env python3
"""Width sweep for clipped blue (outgoing) bubbles in the Swift Home transcript (u2891/Lawrence 2026-10-19:
"user bubbles clipped at right edge").

Launches the tagged app with no activation, opens the DEBUG Home fixture (the real transcript view over a
HomeStore over the mock owner), sends two long messages of mine through the field, and then, through the debug
socket only, sweeps the transcript width from 360 to 1600 pt in 20 pt steps, two ways:
  - window: the window's width (`debug.window.ax_set_frame`), the transcript follows its pane;
  - trim: the window at 1640 pt and the transcript narrowed with the debug width trim (`debug.home.drive resize`).
Then a divider drag while the reply streams (`drag-streaming`: three width changes per main-thread turn).\nEach sweep runs once without a reply streaming and once while the fixture's Chief streams a reply
(`debug.home.drive stream`, a longer text each step). At each width it reads the drawn rows (`rows`) and marks a
step clipped when an outgoing balloon's right edge is past the transcript host's right edge or the window's.
A clipped step saves a window snapshot; so do 360, 620, 1200 and 1600 pt. Writes OUT/sweep.json.
Runs on the GUI host only:
  nx-remote --needs gui --app-from-fleet cmux --tag <tag> --ref <sha> -- \
    'python3 scripts/cmux-next/home-width-sweep.py --tag <tag> --app "$NX_APP" --out "$NX_ARTIFACTS"; "$NX_APP_STOP"'
Exit 0: no clip; 1: a clip (see sweep.json and the PNGs); 2: the harness could not run.
"""
import argparse, json, os, re, socket, subprocess, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import home_classic  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--app", default=None)
parser.add_argument("--out", default="/tmp/home-width-sweep")
opts = parser.parse_args()
home = os.environ["HOME"]
app = opts.app or f"{home}/Library/Developer/Xcode/DerivedData/cmux-{opts.tag}/Build/Products/Debug/cmux DEV {opts.tag}.app"
sock = f"/tmp/cmux-debug-{opts.tag}.sock"
os.makedirs(opts.out, exist_ok=True)
WIDTHS = list(range(360, 1601, 20))
SHOTS = {360, 620, 1200, 1600}
LONG = ("Fix all. Make sure that we have proper Sentry crash analytics set up so everything is observable to us. "
        "Can you check Sentry CLI to see if there are any crashes there that you can fix?")
LONG2 = "You should always run the suites on the fleet, rebase on the branch, and push without force when it is green."
REPLY_WORDS = ("The new path deletes the old switching code and writes it again in one place, so a tab switch reads "
               "one state and the sidebar follows it without a second pass over the rows. ").split()


def rpc(method, params=None, timeout=35):
    try:
        c = socket.socket(socket.AF_UNIX); c.settimeout(timeout); c.connect(sock)
        c.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = c.recv(1 << 22)
            if not chunk:
                break
            buf += chunk
        c.close()
        reply = json.loads(buf)
        return reply.get("result", reply)
    except Exception as error:
        return {"ok": False, "error": f"socket: {error}"}


def poll(predicate, timeout=30):
    deadline = time.time() + timeout
    while time.time() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.25)  # harness wait for the app, not app code
    return None


def texts():
    return (rpc("debug.home.drive", {"action": "texts", "limit": 20}) or {}).get("texts") or []


def clipped(rows):
    """The outgoing balloons past the host's or the window's right edge (0.5 pt slack for pixel snapping)."""
    right = min(rows.get("hostRight") or 1e9, rows.get("windowWidth") or 1e9)
    bad = []
    for r in rows.get("rows") or []:
        if not r.get("outgoing"):
            continue
        b = r.get("balloon") or {}
        edge = max(b.get("x", 0) + b.get("width", 0), r.get("x", 0) + r.get("width", 0))
        if edge > right + 0.5:
            bad.append({"key": r.get("key"), "kind": r.get("kind"), "right": round(edge, 2), "limit": round(right, 2)})
    return bad


results = {"tag": opts.tag, "host": socket.gethostname(), "widths": WIDTHS, "sweeps": {}}
env = {"HOME": home, "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"), "SHELL": "/bin/zsh",
       "PATH": f"{home}/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1",
       "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_DEV_BACKEND_MODE": "local", **home_classic.ENV}
if os.path.exists(sock):
    os.unlink(sock)
process = subprocess.Popen([f"{app}/Contents/MacOS/cmux DEV"], env=env, cwd=opts.out, stdin=subprocess.DEVNULL,
                           stdout=open(os.path.join(opts.out, "app.log"), "a"), stderr=subprocess.STDOUT, start_new_session=True)
pid = process.pid
code = 2
try:
    if not home_classic.require(rpc):
        sys.exit(2)
    rpc("debug.window.ax_set_frame", {"frames": [[40, 40, 1100, 820]]})
    opened = rpc("debug.home_native_fixture.open", {"new": True}) or {}
    if not opened.get("ok") or not poll(lambda: texts(), timeout=60):
        print("FAIL the Home fixture did not open", json.dumps(opened)[:300], flush=True)
        sys.exit(2)
    for text in (LONG, LONG2):
        rpc("debug.home.drive", {"action": "focus"})
        rpc("debug.home.drive", {"action": "type", "text": text})
        sent = rpc("debug.home.drive", {"action": "send"})
        if not sent.get("ok"):
            print("FAIL the send was refused", sent, flush=True)
            sys.exit(2)
    # The mock Chief answers each send after 1.5 s typing; wait for both answers before sweeping.
    poll(lambda: len(texts()) > 0 and texts()[-1] not in (LONG, LONG2), timeout=20)
    time.sleep(4)  # harness wait: the second answer and its animations

    words = 0

    def stream_more(on):
        global words
        if not on:
            return
        words += 3
        text = " ".join(REPLY_WORDS[i % len(REPLY_WORDS)] for i in range(words))
        rpc("debug.home.drive", {"action": "stream", "text": text})

    for mode in ("window", "trim"):
        for streaming in (False, True):
            name = f"{mode}-{'streaming' if streaming else 'still'}"
            steps = []
            if mode == "trim":
                rpc("debug.window.ax_set_frame", {"frames": [[40, 40, 1640, 820]]})
                time.sleep(0.5)
            for width in WIDTHS:
                stream_more(streaming)
                if mode == "window":
                    rpc("debug.window.ax_set_frame", {"frames": [[40, 40, width, 820]]})
                    time.sleep(0.25)  # harness wait: the window's layout and the next display frame
                else:
                    base = (rpc("debug.home.drive", {"action": "rows"}) or {})
                    full = (base.get("hostRight") or 0) + (base.get("trim") or 0) - (base.get("hostX") or 0)
                    trim = max(0.0, full - width)
                    rpc("debug.home.drive", {"action": "resize", "trims": [trim]})
                    time.sleep(0.12)  # harness wait: one display frame for a deferred width pass
                rows = rpc("debug.home.drive", {"action": "rows"}) or {}
                bad = clipped(rows)
                entry = {"width": width, "windowWidth": rows.get("windowWidth"), "hostX": rows.get("hostX"),
                         "hostRight": rows.get("hostRight"), "trim": rows.get("trim"),
                         "outgoing": sum(1 for r in rows.get("rows") or [] if r.get("outgoing")), "clipped": bad}
                if bad or width in SHOTS:
                    path = os.path.join(opts.out, f"{name}-{width}{'-CLIPPED' if bad else ''}.png")
                    rpc("debug.window_snapshot", {"path": path})
                    entry["png"] = os.path.basename(path)
                steps.append(entry)
                print(f"{name} {width}: window {entry['windowWidth']} host {entry['hostX']}..{entry['hostRight']} "
                      f"outgoing {entry['outgoing']} {'CLIPPED ' + json.dumps(bad) if bad else 'ok'}", flush=True)
            if streaming:
                rpc("debug.home.drive", {"action": "stream", "text": "Done.", "done": True})
                words = 0
                time.sleep(2)  # harness wait: the post and its animation
            if mode == "trim":
                rpc("debug.home.drive", {"action": "resize", "trims": [0]})
            results["sweeps"][name] = steps
    # Divider drag while the reply streams: three width changes in one main-thread turn (one display frame), as a
    # drag's mouse events come faster than frames, then the frame. The rows after the turn are the ones that frame shows.
    rpc("debug.window.ax_set_frame", {"frames": [[40, 40, 1640, 820]]})
    time.sleep(0.5)
    base = rpc("debug.home.drive", {"action": "rows"}) or {}
    full = (base.get("hostRight") or 0) + (base.get("trim") or 0) - (base.get("hostX") or 0)
    host_x = base.get("hostX") or 0
    trims = [t for t in range(0, int(full) - 360, 12)]
    path = trims + trims[::-1]
    drag, stale_ms = [], []
    for round_index in range(0, len(path), 3):
        stream_more(True)
        step = path[round_index:round_index + 3]
        out = rpc("debug.home.drive", {"action": "resize", "trims": step}) or {}
        steps = out.get("steps") or []
        last = steps[-1] if steps else {}
        width = full - (last.get("trim") or 0)
        right = host_x + width
        bad = [round(r.get("maxX", 0), 2) for r in last.get("rows") or [] if r.get("outgoing") and r.get("maxX", 0) > right + 0.5]
        entry = {"trims": step, "width": width, "ms": [round(x.get("ms", 0), 2) for x in steps], "deferred": out.get("deferred"),
                 "passes": out.get("passes"), "clipped": bad}
        if bad:
            snap = os.path.join(opts.out, f"drag-streaming-{int(width)}-CLIPPED.png")
            rpc("debug.window_snapshot", {"path": snap})
            entry["png"] = os.path.basename(snap)
        drag.append(entry)
        print(f"drag-streaming {int(width)}: ms {entry['ms']} deferred {entry['deferred']} "
              f"{'CLIPPED ' + json.dumps(bad) if bad else 'ok'}", flush=True)
        time.sleep(0.02)  # harness wait: one display frame (its tick runs a deferred width pass)
    rpc("debug.home.drive", {"action": "stream", "text": "Done.", "done": True})
    results["sweeps"]["drag-streaming"] = [dict(e, clipped=e["clipped"]) for e in drag]
    clips = {k: [s["width"] for s in v if s["clipped"]] for k, v in results["sweeps"].items()}
    results["clippedWidths"] = clips
    print("CLIPPED widths:", json.dumps(clips), flush=True)
    code = 1 if any(clips.values()) else 0
finally:
    with open(os.path.join(opts.out, "sweep.json"), "w") as handle:
        json.dump(results, handle, indent=1)
    rpc("action.run", {"id": "quitEndSessions"})
    poll(lambda: subprocess.run(["kill", "-0", str(pid)], capture_output=True).returncode != 0, timeout=25)
    acp = "%s/.acpmux/builds/com.cmuxterm.app.debug.%s" % (home, re.sub(r"[^a-z0-9]+", ".", opts.tag.lower()).strip("."))
    subprocess.run([f"{app}/Contents/Resources/bin/acpmux", "daemon", "shutdown", "--end-agents"], capture_output=True,
                   env=dict(os.environ, ACPMUX_HOME=acp, ACPMUX_SOCKET=f"{acp}/acpmux.sock"))
sys.exit(code)
