#!/usr/bin/env python3
"""Record the tab hover card as the pointer crosses a tab strip, frame by frame (Lawrence 2026-11-15,
msg 34360: "this animation needs to be better", a recording of the tab card jumping, resizing at
once and its picture popping in).

  python3 scripts/cmux-next/tab-card-glide-record.py --app "$APP" --tag TAG --out DIR

Run it on a fleet GUI Mac in the console session (cmux-lawrence-2), never on a person's Mac. It
launches the tagged DEBUG app with a scratch cmux.json and CMUX_NEXT_NO_ACTIVATE=1 (it never takes
the focus from another agent on the host), opens three browser tabs (two pages with a
picture, one New Tab page left out) beside the terminal, rests on the first tab until its card
shows, then moves the pointer tab to tab: a slow pass, a fast pass back, and a turn back mid-glide.
The app records its own windows (the card's included) every composited frame while it does
(`debug.new_tab {action: "frame_strip", above: true}`: ScreenCaptureKit for this app's windows,
no Screen Recording grant); the pointer moves through `debug.mouse {action: "move"}` (the tab
strip's tracking path). DIR gets frame-NNN.png, strip.png, report.json and path.json (each move's
time from the recording's key). It quits the app with its own quit and signals nothing else.
"""
import argparse, json, os, plistlib, socket, subprocess, sys, tempfile, threading, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from safe_log import safe_print  # noqa: E402  (a line before a kill never skips the kill)

parser = argparse.ArgumentParser()
parser.add_argument("--app", required=True)
parser.add_argument("--tag", required=True)
parser.add_argument("--out", required=True)
parser.add_argument("--scale", type=float, default=0.3)
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
        value = check()
        if value:
            return value
        time.sleep(step)
    return None


APP = opts.app.rstrip("/")
with open(os.path.join(APP, "Contents/Info.plist"), "rb") as f:
    BINARY = os.path.join(APP, "Contents/MacOS", plistlib.load(f)["CFBundleExecutable"])
scratch = tempfile.mkdtemp(prefix=f"tab-card-glide-{opts.tag}-")
config = os.path.join(scratch, "cmux.json")
with open(config, "w") as f:
    f.write("{}\n")
if os.path.exists(SOCKET):
    os.unlink(SOCKET)
app = subprocess.Popen([BINARY], env={
    "HOME": os.environ["HOME"], "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"),
    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_CONFIG_FILE": config,
    "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1300,760",
    # Never takes the focus from whoever uses the host: cards still show in a no-activate run.
    "CMUX_NEXT_NO_ACTIVATE": "1"},
    stdout=open(os.path.join(opts.out, "app.log"), "w"), stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")
CLI_ENV = dict(os.environ, CMUX_SOCKET_PATH=SOCKET, CMUX_TAG=opts.tag)


def strip_tabs():
    """The visible strip's tabs (window points, top-left origin) that open a card, left to right."""
    best = []
    for strip in (rpc("debug.tab_drag") or {}).get("strips") or []:
        tabs = [t for t in strip.get("tabs") or [] if 0 <= t["frame"][0] < 1300 and t.get("label") != "New Tab"]
        if len(tabs) > len(best):
            best = tabs
    return sorted(best, key=lambda t: t["frame"][0])


def card_showing(showing=True):
    """`debug.hover_cards` says a card shows (or, with showing=False, none shows and the coordinator is idle)."""
    try:
        c = rpc("debug.hover_cards", timeout=5) or {}
    except OSError:
        return None
    if "error" in c:
        return None
    if showing:
        return c.get("card_showing") == "true" or c.get("visible") in (True, "true")
    return c.get("card_showing") != "true" and c.get("phase", "idle") == "idle"


def page_loaded():
    """The pane's selected page (the tab just opened) answers document.readyState complete."""
    try:
        return (rpc("browser.page.eval", {"script": "document.readyState"}, timeout=5) or {}).get("value") == "complete"
    except OSError:
        return False


def wait_stable(read, seconds, reads=3, step=0.2):
    """`read()` once it gave the same value `reads` times in a row (the strip laid out), else None."""
    deadline, last, same = time.monotonic() + seconds, object(), 0
    while time.monotonic() < deadline:  # bounded wait on the app's state
        value = read()
        same = same + 1 if value == last else 1
        last = value
        if same >= reads:
            return value
        time.sleep(step)
    return None


try:
    wait(lambda: os.path.exists(SOCKET) and "error" not in (rpc("debug.focus") or {"error": 1}), 180)
    if not (rpc("debug.focus") or {}).get("windows"):
        rpc("action.run", {"action": "newWindow", "origin": "script"})
    wait(lambda: (rpc("debug.focus") or {}).get("windows"), 60)
    # Pages in the same pane as tabs: two with a picture (one tall card), one short.
    # A fresh workspace (a restored session may hold other panes): its terminal tab plus two pages,
    # tabs of one strip (`tab create browser --pane`; `browser open` opens a column of its own).
    made = subprocess.run([CLI, "workspace", "create", "--name", "glide", "--json"], env=CLI_ENV, capture_output=True, text=True, timeout=60)
    value = (json.loads(made.stdout or "{}").get("value") or {}) if made.returncode == 0 else {}
    pane, workspace = value.get("pane_id"), value.get("workspace_id")
    print("workspace", workspace, "pane", pane, flush=True)
    for url in ("https://github.com/manaflow-ai/cmux", "https://www.iana.org/help/example-domains"):
        done = subprocess.run([CLI, "tab", "create", "browser", "--url", url, "--pane", pane], env=CLI_ENV,
                              capture_output=True, text=True, timeout=60)
        print(f"open {url}: {done.returncode}", flush=True)
        # The page opened in its tab and loaded (best effort: the hover pass below fetches each picture).
        if not wait(page_loaded, 20):
            safe_print(f"note: {url} not loaded in 20 s", flush=True)
    rpc("action.run", {"action": "goToWorkspace", "args": {"workspace": workspace}, "origin": "script"})
    # The strip shows the workspace's tabs and stops moving.
    if wait_stable(lambda: json.dumps(strip_tabs()), 15) is None:
        safe_print("note: the tab strip did not settle in 15 s", flush=True)
    tabs = wait(lambda: (lambda t: t if len(t) >= 3 else None)(strip_tabs()), 30) or strip_tabs()
    print("tabs", [(t.get("label"), t["frame"]) for t in tabs], flush=True)
    if len(tabs) < 3:
        sys.exit("fewer than three tabs to cross")
    centers = [(t["frame"][0] + t["frame"][2] * 0.4, t["frame"][1] + t["frame"][3] / 2) for t in tabs]
    off = (650, 500)
    # Each page's picture is fetched once (a card seen before shows its own picture at once, as in use).
    for x, y in centers:
        rpc("debug.mouse", {"action": "move", "x": x, "y": y})
        time.sleep(2.2)
    rpc("debug.mouse", {"action": "move", "x": off[0], "y": off[1]})
    if not wait(lambda: card_showing(False), 10):
        safe_print("note: a tab card still showed 10 s after the pointer left the strip", flush=True)

    # The pointer path, (seconds after the recording's first move, x, y): from tab 0, whose card shows, a
    # delay, a slow pass right, a fast pass back left, a turn back mid-glide, then off the strip.
    def ramp(t0, a, b, seconds, steps):
        return [(t0 + seconds * i / steps, a[0] + (b[0] - a[0]) * i / steps, a[1]) for i in range(1, steps + 1)]
    # The card shows on tab 0 before the recording (the 1.3 s delay is not motion); the recording's own
    # first move starts the slow pass. The app answers within its 15 s deadline, frames written.
    rpc("debug.mouse", {"action": "move", "x": centers[0][0], "y": centers[0][1]})
    # Its card shows (past the delay) and stops changing (the open animation done).
    if not wait(card_showing, 15):
        safe_print("note: tab 0's card did not show in 15 s", flush=True)
    wait_stable(lambda: json.dumps(rpc("debug.hover_cards", timeout=5) or {}, sort_keys=True), 5)
    first = ramp(0.0, centers[0], centers[1], 0.3, 18)
    path = first[:1]
    path += first[1:]; t = 0.3 + 0.5
    path += ramp(t, centers[1], centers[2], 0.3, 18); t += 0.3 + 0.5
    path += ramp(t, centers[2], centers[0], 0.2, 12); t += 0.2 + 0.5
    path += ramp(t, centers[0], centers[2], 0.16, 10); t += 0.16 + 0.05
    path += ramp(t, centers[2], centers[1], 0.08, 5); t += 0.08 + 0.6
    path += [(t, *off)]
    total = t + 0.3
    record = {}

    def run_strip():
        record["report"] = rpc("debug.new_tab", {
            "action": "frame_strip", "gesture": "mouse", "mouse": {"action": "move", "x": path[0][1], "y": path[0][2]},
            "above": True, "scale": opts.scale, "duration_ms": int(total * 1000), "content": "none", "dir": opts.out}, timeout=120)

    thread = threading.Thread(target=run_strip)
    thread.start()
    # sleep-ok: aligns the move timeline with the recorder's fixed 120 ms lead; the strip call blocks until the
    # recording ends, so nothing says when it began.
    time.sleep(0.2)  # the recorder's lead (120 ms) and the first move, sent by the strip itself
    start = time.monotonic()
    sent = []
    for at, x, y in path[1:]:
        delay = at - (time.monotonic() - start)
        if delay > 0:
            time.sleep(delay)
        rpc("debug.mouse", {"action": "move", "x": x, "y": y})
        sent.append({"at_s": round(time.monotonic() - start, 4), "x": x, "y": y})
    thread.join()
    # A long recording outlives the request's 15 s deadline: the app still writes every frame, then
    # strip.png last. The app stays up until it has.
    wait(lambda: os.path.exists(os.path.join(opts.out, "strip.png")), 120, step=0.5)
    report = record.get("report") or {}
    with open(os.path.join(opts.out, "report.json"), "w") as f:
        json.dump(report, f, indent=1)
    with open(os.path.join(opts.out, "path.json"), "w") as f:
        json.dump({"centers": centers, "moves": sent}, f, indent=1)
    print("frames", report.get("frames") or report.get("frame_count") or len([n for n in os.listdir(opts.out) if n.startswith("frame-")]),
          "error", report.get("error"), flush=True)
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
