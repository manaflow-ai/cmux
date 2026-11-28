"""cu-pointer-stays, inside the guest (guest.sh runs it in the console user's session).

Starts the target (cpsprobe target), the Rust Computer Use engine (cmux-rd __computer-use-worker, the
Screen Sharing helper's mode, built from the run's ref) with computerUse.allowForeground on, and a
screen video with the system cursor (screencapture -v -C). Then, for each gesture (click at x/y,
click on an element, drag, scroll, move_pointer) in delivery background and foreground, it parks the
real pointer where "the person" left it, samples the pointer every 10 ms through the call, and reads
the target's own event log for whether the gesture landed.

  python3 -I cps.py DIR       (DIR holds cpsprobe and cmux-rd; writes DIR/out)

Writes out/results.jsonl (one line per gesture), out/cps.txt (the CPS lines), out/cps.mov.
Python 3.9 (the image's Command Line Tools).
"""
from __future__ import annotations

import base64
import json
import os
import signal
import socket
import struct
import subprocess
import sys
import threading
import time
import uuid

D = sys.argv[1]
OUT = os.path.join(D, "out")
os.makedirs(OUT, exist_ok=True)
PROBE = os.path.join(D, "cpsprobe")
RD = os.path.join(D, "cmux-rd")
LOG = os.path.join(OUT, "target.log")
# Where "the person" leaves the pointer: the main display's bottom-right corner, 24 pt in, which is
# outside the target window (x 200..1000). A fixed point off a smaller display clamps to the edge,
# so main() derives it from `cpsprobe screen`, and each gesture's sample is measured from the
# position the park read back, never from the asked-for point.
PARK = (1700.0, 900.0)
VIDEO_S = 60  # the ten gestures take about 20 s; the movie covers them with room to spare
RESULTS = os.path.join(OUT, "results.jsonl")
T0 = time.time()


def note(**kw):
    kw.setdefault("t", round(time.time() - T0, 3))
    with open(RESULTS, "a") as f:
        f.write(json.dumps(kw) + "\n")


def probe(*args, timeout=30):
    p = subprocess.run([PROBE] + [str(a) for a in args], capture_output=True, text=True, timeout=timeout)
    try:
        return json.loads(p.stdout.strip().splitlines()[-1])
    except (ValueError, IndexError):
        return {"error": "probe %s: rc %s %s" % (args[0], p.returncode, p.stderr.strip()[:200])}


def log_size():
    try:
        return os.path.getsize(LOG)
    except OSError:
        return 0


def log_since(offset):
    with open(LOG) as f:
        f.seek(offset)
        return [line.split() for line in f.read().splitlines() if line.strip()]


# --- the engine ---------------------------------------------------------------------------------
class Worker:
    def __init__(self):
        sock_dir = os.path.join(D, "sock")
        os.makedirs(sock_dir, mode=0o700, exist_ok=True)
        os.chmod(sock_dir, 0o700)
        self.socket = os.path.join(sock_dir, "cu.sock")
        self.secret = os.urandom(32).hex()
        self.err = open(os.path.join(OUT, "worker.err"), "w")
        self.proc = subprocess.Popen([RD, "__computer-use-worker"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=self.err, text=True, bufsize=1)
        self.control = []
        config = {"mode": "fullAccess", "allowForeground": True, "showCursor": True, "pauseOnTakeover": False,
                  "settle": "openai"}
        self.proc.stdin.write(json.dumps({"type": "configure", "config": config, "socket": self.socket,
                                          "secret": self.secret, "state_dir": os.path.join(D, "state"),
                                          "machine": "cps"}) + "\n")
        self.proc.stdin.flush()
        self.ready = threading.Event()
        threading.Thread(target=self._read, daemon=True).start()
        self.conn = None
        self.buf = b""
        self.next_id = 0

    def _read(self):
        for line in self.proc.stdout:
            try:
                msg = json.loads(line)
            except ValueError:
                continue
            self.control.append(msg)
            if msg.get("type") in ("ready", "unavailable", "error"):
                self.ready.set()
            if msg.get("type") == "ask":  # fullAccess asks nothing; answer anyway so no call hangs
                self.proc.stdin.write(json.dumps({"type": "answer", "id": msg.get("id"), "answer": "allow_session"}) + "\n")
                self.proc.stdin.flush()
        self.ready.set()

    def connect(self):
        self.conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.conn.settimeout(120)
        self.conn.connect(self.socket)
        self.conn.sendall((json.dumps({"secret": self.secret}) + "\n").encode())
        return self._line()

    def _line(self):
        while b"\n" not in self.buf:
            chunk = self.conn.recv(1 << 20)
            if not chunk:
                raise IOError("the worker closed the socket")
            self.buf += chunk
        line, self.buf = self.buf.split(b"\n", 1)
        return json.loads(line)

    def call(self, name, arguments):
        self.next_id += 1
        rid = self.next_id
        self.conn.sendall((json.dumps({"id": rid, "method": "tools/call", "name": name, "arguments": arguments,
                                       "session": "cps", "label": "CPS", "call_id": str(uuid.uuid4())}) + "\n").encode())
        while True:
            msg = self._line()
            if msg.get("id") == rid:
                return msg

    def stop(self):
        try:
            self.proc.stdin.close()
            self.proc.wait(timeout=15)
        except Exception:
            self.proc.kill()


def body_of(resp):
    r = resp.get("result") or {}
    return r.get("body"), r.get("is_error"), r.get("png")


def png_size(b64):
    raw = base64.b64decode(b64)
    if raw[:8] != b"\x89PNG\r\n\x1a\n":
        return None
    return struct.unpack(">II", raw[16:24])


def find_named(node, name):
    if isinstance(node, dict):
        if any(node.get(k) == name for k in ("name", "title", "label")) and node.get("id") is not None:
            return node
        for v in node.values():
            hit = find_named(v, name)
            if hit:
                return hit
    elif isinstance(node, list):
        for v in node:
            hit = find_named(v, name)
            if hit:
                return hit
    return None


def find_window(body):
    windows = body.get("windows") if isinstance(body, dict) else body
    for w in windows or []:
        if isinstance(w, dict) and w.get("title") == "CPS Target":
            return w
    return None


def main():
    lines = []
    target = subprocess.Popen([PROBE, "target", LOG], stdout=subprocess.DEVNULL, stderr=open(os.path.join(OUT, "target.err"), "w"))
    for _ in range(100):
        if os.path.exists(LOG) and "ready" in open(LOG).read():
            break
        time.sleep(0.1)
    note(phase="setup", what="target", ready=os.path.exists(LOG), pid=target.pid)

    global PARK
    screen = probe("screen")
    if screen.get("w") and screen.get("h"):
        PARK = (max(1010.0, float(screen["w"]) - 24.0), float(screen["h"]) - 24.0)
    note(phase="setup", what="screen", screen=screen, park=PARK)
    print("CPS-SETUP screen %s park %s" % (json.dumps(screen), PARK), flush=True)

    worker = Worker()
    worker.ready.wait(90)
    note(phase="setup", what="worker", control=worker.control[:3])
    if not any(m.get("type") == "ready" for m in worker.control):
        note(phase="setup", what="blocked", reason="the engine never said ready")
        return 4
    note(phase="setup", what="hello", hello=worker.connect())

    listed = worker.call("list_windows", {})
    body, _, _ = body_of(listed)
    win = find_window(body)
    note(phase="setup", what="list_windows", window=win, raw=None if win else str(listed)[:2000])
    if not win:  # the engine also takes a window's title as its id
        win = {"window_id": "CPS Target"}
    wid = str(win.get("window_id") or win.get("id"))
    frame = win.get("frame") or {}
    fw = float(frame.get("width") or frame.get("w") or 800)
    fh = float(frame.get("height") or frame.get("h") or 628)
    shot = worker.call("screenshot", {"window_id": wid, "force": True})
    _, _, png = body_of(shot)
    size = png_size(png) if png else None
    scale = (size[0] / fw) if size else 1.0
    note(phase="setup", what="screenshot", png=size, frame=frame, scale=scale)
    tree = worker.call("get_ui_tree", {"window_id": wid, "format": "json", "full": True})
    tbody, _, _ = body_of(tree)
    with open(os.path.join(OUT, "ui-tree.json"), "w") as f:
        json.dump(tbody, f)
    button = find_named(tbody, "CPS Button")
    note(phase="setup", what="button", element=button)

    def px(fx, fy):
        return round(fw * fx * scale, 1), round(fh * fy * scale, 1)

    cx, cy = px(0.5, 0.4)
    dx0, dy0 = px(0.3, 0.3)
    dx1, dy1 = px(0.6, 0.5)
    sx, sy = px(0.5, 0.5)
    mx, my = px(0.55, 0.45)
    gestures = [
        ("click", "xy", {"x": cx, "y": cy}, lambda ev: {"down", "up"} <= ev),
        ("click", "element", {"element_id": str(button.get("id")) if button else "missing"}, lambda ev: "button" in ev),
        ("drag", "", {"from_x": dx0, "from_y": dy0, "to_x": dx1, "to_y": dy1}, lambda ev: {"dragged", "up"} <= ev),
        ("scroll", "", {"x": sx, "y": sy, "dy": 3}, lambda ev: "scroll" in ev),
        ("move_pointer", "", {"x": mx, "y": my}, lambda ev: "moved" in ev),
    ]

    video = os.path.join(OUT, "cps.mov")
    rec = subprocess.Popen(["screencapture", "-v", "-C", "-k", "-x", "-V", str(VIDEO_S), video],
                           stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=open(os.path.join(OUT, "screencapture.err"), "w"))
    video_t0 = time.time()
    time.sleep(3)

    worst = 0.0
    for delivery in ("background", "foreground"):
        for tool, variant, args, landed_if in gestures:
            name = tool + ("-" + variant if variant else "")
            args = dict(args, window_id=wid, delivery=delivery)
            parked = probe("park", PARK[0], PARK[1])
            time.sleep(0.3)
            # The baseline is where the pointer is now (the park's readback), not where it was asked to go.
            base = probe("pos")
            bx, by = float(base.get("x", PARK[0])), float(base.get("y", PARK[1]))
            stop = os.path.join(D, "stop-%s-%s" % (name, delivery))
            sampler = subprocess.Popen([PROBE, "sample", str(bx), str(by), stop], stdout=subprocess.PIPE, text=True)
            time.sleep(0.1)
            offset = log_size()
            t_call = time.time()
            try:
                resp = worker.call(tool, args)
            except Exception as e:  # a dead worker is a result too
                resp = {"ok": False, "error": repr(e)}
            call_s = time.time() - t_call
            time.sleep(0.6)
            open(stop, "w").close()
            try:
                sample = json.loads(sampler.communicate(timeout=10)[0].strip().splitlines()[-1])
            except Exception as e:
                sample = {"error": repr(e)}
            events = log_since(offset)
            kinds = {e[1] for e in events if len(e) > 1}
            landed = bool(landed_if(kinds))
            moved = float(sample.get("max_pt", -1))
            worst = max(worst, moved)
            rbody, is_error, _ = body_of(resp)
            subprocess.run(["screencapture", "-C", "-x", os.path.join(OUT, "%s-%s.png" % (name, delivery))], timeout=30)
            line = "CPS %s %s moved_pt=%.2f landed=%s" % (name, delivery, moved, "true" if landed else "false")
            lines.append(line)
            print(line, flush=True)
            note(phase="gesture", tool=tool, variant=variant, delivery=delivery, args=args, parked=parked, base=[bx, by],
                 sample=sample, landed=landed, events=[" ".join(e) for e in events][:40], kinds=sorted(kinds),
                 call_s=round(call_s, 3), video_s=round(t_call - video_t0, 2), ok=resp.get("ok"), is_error=is_error,
                 error=resp.get("error"), body=json.dumps(rbody)[:1500] if rbody is not None else None)
    time.sleep(2)
    # screencapture -v writes its movie when its -V time runs out; a SIGINT ends it without one (the
    # first runs' 0-byte cps.mov, rc -2). So let it finish, and interrupt only one that overruns.
    try:
        rec.wait(timeout=VIDEO_S + 30)
    except subprocess.TimeoutExpired:
        rec.send_signal(signal.SIGINT)
        try:
            rec.wait(timeout=30)
        except subprocess.TimeoutExpired:
            rec.kill()
    try:
        rec_err = open(os.path.join(OUT, "screencapture.err")).read()[-1500:]
    except OSError:
        rec_err = ""
    vbytes = os.path.getsize(video) if os.path.exists(video) else 0
    note(phase="video", path=video, bytes=vbytes, rc=rec.returncode, stderr=rec_err)
    print("CPS-SETUP video %d bytes rc %s %s" % (vbytes, rec.returncode, rec_err.strip().replace("\n", " | ")[:600]), flush=True)
    with open(os.path.join(OUT, "cps.txt"), "w") as f:
        f.write("\n".join(lines) + "\n")
    worker.stop()
    target.terminate()
    return 1 if worst > 1.0 else 0


if __name__ == "__main__":
    try:
        rc = main()
    except Exception as e:
        note(phase="crash", error=repr(e))
        rc = 4
    sys.exit(rc)
