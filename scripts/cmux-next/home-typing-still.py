#!/usr/bin/env python3
"""Tagged-app still of the Swift Home's typing indicator on the app's theme (MessagesLab 5c56f4f).

Launches the tagged app with no activation, opens the DEBUG Home fixture (the real transcript view
over a HomeStore over the mock owner: after a send its Chief waits 1.5 s, types for 1.5 s, then
answers, MockHomeSource.scheduleReplies), sends a message through the field's send path
(debug.home.drive type + send) and takes window snapshots at 2.0 s and 2.6 s, while the Chief types: the typing bubble (RowCell.typingBody, Fixture.typingFill) in the app's own theme.
Passes when the send goes and the bubble is in the image: its box (debug.home.drive typing) is
read from the app and the mean colour inside it must differ from the background beside it. Socket only, no system input. Runs on
cmux-lawrence-2; ends with the DEBUG quit fixture and the tag's `acpmux daemon shutdown`.

Usage: home-typing-still.py --tag <tag> [--out DIR]
"""
import argparse, json, os, socket, subprocess, sys, time

parser = argparse.ArgumentParser()
parser.add_argument("--tag", required=True)
parser.add_argument("--out", default="/tmp/home-typing-still")
opts = parser.parse_args()
home = os.environ["HOME"]
app = f"{home}/Library/Developer/Xcode/DerivedData/cmux-{opts.tag}/Build/Products/Debug/cmux DEV {opts.tag}.app"
sock = f"/tmp/cmux-debug-{opts.tag}.sock"
os.makedirs(opts.out, exist_ok=True)
failures = []


def rpc(method, params=None, timeout=35):
    try:
        c = socket.socket(socket.AF_UNIX); c.settimeout(timeout); c.connect(sock)
        c.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = c.recv(1 << 20)
            if not chunk:
                break
            buf += chunk
        c.close()
        reply = json.loads(buf)
        return reply.get("result", reply)
    except Exception as error:
        return {"ok": False, "error": f"socket: {error}"}


def api(**params):
    return rpc("debug.home.api", params)


def check(name, ok, detail=""):
    print(("ok   " if ok else "FAIL ") + name + ("" if ok else f"  {json.dumps(detail)[:500]}"), flush=True)
    if not ok:
        failures.append(name)
    return ok


def poll(predicate, timeout=20):
    deadline = time.time() + timeout
    while time.time() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.25)  # test harness wait, not app code
    return None




def read_png(path):
    """8-bit RGB or RGBA, non-interlaced PNG (window snapshots): (width, height, rows of bytes, 3 or 4 per pixel)."""
    import struct, zlib
    data = open(path, "rb").read()
    pos, idat, w = 8, b"", 0
    while pos < len(data):
        n, kind = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + n]
        if kind == b"IHDR":
            w, h, depth, ctype, _, _, interlace = struct.unpack(">IIBBBBB", body)
            if depth != 8 or ctype not in (2, 6) or interlace:
                raise ValueError(f"unsupported PNG depth {depth} colour type {ctype} interlace {interlace}")
            bpp = 4 if ctype == 6 else 3
        elif kind == b"IDAT":
            idat += body
        pos += 12 + n
    raw, stride, rows, prev = zlib.decompress(idat), w * bpp, [], bytearray(w * bpp)
    for y in range(h):
        f, line = raw[y * (stride + 1)], bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for i in range(stride):
            a = line[i - bpp] if i >= bpp else 0
            b = prev[i]
            c = prev[i - bpp] if i >= bpp else 0
            if f == 1: line[i] = (line[i] + a) & 255
            elif f == 2: line[i] = (line[i] + b) & 255
            elif f == 3: line[i] = (line[i] + (a + b) // 2) & 255
            elif f == 4:
                p = a + b - c; pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        rows.append(line); prev = line
    return w, h, (rows, bpp)


def mean_rgb(px, w, h, x0, y0, x1, y1):
    rows, bpp = px
    xs = range(max(0, int(x0)), min(w, int(x1))); ys = range(max(0, int(y0)), min(h, int(y1)))
    n = max(1, len(xs) * len(ys)); sums = [0, 0, 0]
    for y in ys:
        r = rows[y]
        for x in xs:
            for k in range(3): sums[k] += r[x * bpp + k]
    return [round(v / n, 1) for v in sums]


if os.path.exists(sock):
    os.unlink(sock)
env = {"HOME": home, "USER": os.environ.get("USER", ""), "TMPDIR": os.environ.get("TMPDIR", "/tmp"), "SHELL": "/bin/zsh",
       "PATH": f"{home}/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_NO_ACTIVATE": "1",
       "CMUX_NEXT_SOCKET_MODE": "automation", "CMUX_NEXT_TEST_WINDOW_SCREEN": "last", "CMUX_DEV_BACKEND_MODE": "local",
       "CMUX_NEXT_TEST_WINDOW_FRAME": "40,40,1200,800"}
process = subprocess.Popen([f"{app}/Contents/MacOS/cmux DEV"], env=env, cwd=opts.out, stdin=subprocess.DEVNULL,
                           stdout=open(os.path.join(opts.out, "app.log"), "a"), stderr=subprocess.STDOUT, start_new_session=True)
pid = process.pid
print(f"launched pid {pid}", flush=True)
try:
    inbox = poll(lambda: (r := api(call="inbox")) and "conversations" in r and r, timeout=180)
    if not check("the local owner answers inbox", bool(inbox), api(call="inbox")):
        sys.exit(1)
    opened = rpc("debug.home_native_fixture.open") or {}
    check("the Home fixture opens", bool(opened.get("ok")), opened)
    texts = poll(lambda: (t := (rpc("debug.home.drive", {"action": "texts"}) or {}).get("texts")) and t, timeout=60)
    check("the fixture's transcript shows messages", bool(texts), rpc("debug.home.drive", {"action": "texts"}))
    rpc("debug.home.drive", {"action": "focus"})
    rpc("debug.home.drive", {"action": "type", "text": "Typing still check"})
    sent = rpc("debug.home.drive", {"action": "send"}) or {}
    check("the send goes", bool(sent.get("ok")), sent)
    shots, box = [], {}
    for delay in (2.0, 0.6):
        time.sleep(delay)  # test harness: the mock Chief types from 1.5 s to 3.0 s after the send
        path = os.path.join(opts.out, "typing-%d.png" % len(shots))
        if not shots:
            box = rpc("debug.home.drive", {"action": "typing"}) or {}  # the box of the first shot
        rpc("debug.window_snapshot", {"path": path})
        shots.append(path)
    check("snapshots of the typing indicator", all(os.path.exists(p) for p in shots), shots)
    # The bubble must be in the image: its box from the app (debug.home.drive typing, window points,
    # bottom-left origin), then the mean colour inside it against the background just right of it.
    check("the app reports a typing bubble", bool(box.get("ok")), box)
    if box.get("ok") and os.path.exists(shots[0]):
        w, h, px = read_png(shots[0])
        scale = w / box["windowWidth"]
        x0, x1 = box["x"] * scale, (box["x"] + box["width"]) * scale
        y1 = (box["windowHeight"] - box["y"]) * scale; y0 = y1 - box["height"] * scale
        inner = mean_rgb(px, w, h, x0 + (x1 - x0) * 0.35, y0 + (y1 - y0) * 0.15, x1 - (x1 - x0) * 0.05, y1 - (y1 - y0) * 0.15)
        bg = mean_rgb(px, w, h, x1 + 20 * scale, y0, x1 + 60 * scale, y1)
        diff = sum(abs(a - b) for a, b in zip(inner, bg)) / 3
        print(f"     typing box px ({x0:.0f},{y0:.0f})-({x1:.0f},{y1:.0f}) inside {inner} background {bg} mean diff {diff:.1f}", flush=True)
        check("the typing bubble is in the image (inside differs from the background by more than 6 levels)", diff > 6,
              {"inside": inner, "background": bg})
finally:
    reply = rpc("debug.quit", {"fixture_quit": "end-sessions"}, timeout=10)
    if not (isinstance(reply, dict) and reply.get("quitting") == "end-sessions"):
        rpc("action.run", {"id": "quitEndSessions"}, timeout=10)
    poll(lambda: subprocess.run(["kill", "-0", str(pid)], capture_output=True).returncode != 0, timeout=25)
    acp = f"{home}/.acpmux/tags/{opts.tag}"
    subprocess.run([f"{app}/Contents/Resources/bin/acpmux", "daemon", "shutdown"], capture_output=True,
                   env=dict(os.environ, ACPMUX_HOME=acp, ACPMUX_SOCKET=f"{acp}/acpmux.sock"))

print(f"{len(failures)} failed: {failures}" if failures else "all checks passed", flush=True)
sys.exit(1 if failures else 0)
