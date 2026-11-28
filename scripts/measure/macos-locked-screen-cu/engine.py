"""cmux's own Computer Use engine on a locked Mac, inside the guest (guest.sh runs it each round).

Leo, 2026-11-28 (ask c-cdd47d63a7): "BUT WHY CAN'T COMPUTER USE WORK ON A LOCKED SCREEN? CAN'T WE DO
SOMETHING?" The engine (cmux-rd __computer-use-worker, built from the run's ref, the worker NIGHTLY's
daemon starts) runs twice per round, with computerUse.whileLocked off and on (cmux#46243,
cmux-tui/crates/cmux-computer-use/src/locked.rs). Each run reads status, lists the windows, takes
TextEdit's window screenshot and types a marker into it in the background, and the document is read
back through Accessibility (lockprobe ax-text). Expected: unlocked, both land; locked, off answers
mac_locked and types nothing, on lands the marker.

  python3 -I engine.py DIR PHASE TEXTEDIT_PID     (DIR holds cmux-rd and lockprobe; JSON lines on stdout)

Python 3.9 (the image's Command Line Tools).
"""
from __future__ import annotations

import json
import os
import socket
import subprocess
import sys
import threading
import time
import uuid

D, PHASE, TE = sys.argv[1], sys.argv[2], sys.argv[3]
RD = os.path.join(D, "cmux-rd")
PROBE = os.path.join(D, "lockprobe")
OUT = os.path.join(D, "out")
WID_FILE = os.path.join(D, "engine-wid")  # the window id an unlocked round listed, for a refused list


def row(**kw):
    kw["phase"] = PHASE + "-engine-" + kw.pop("setting")
    print(json.dumps(kw), flush=True)


class Worker:
    def __init__(self, while_locked):
        sock_dir = os.path.join(D, "sock")
        os.makedirs(sock_dir, mode=0o700, exist_ok=True)
        os.chmod(sock_dir, 0o700)
        self.socket = os.path.join(sock_dir, "cu-%d.sock" % os.getpid())
        self.secret = os.urandom(32).hex()
        err = open(os.path.join(OUT, "engine-%s.err" % PHASE), "a")
        self.proc = subprocess.Popen([RD, "__computer-use-worker"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=err, text=True, bufsize=1)
        self.control = []
        config = {"mode": "fullAccess", "allowForeground": False, "showCursor": False, "pauseOnTakeover": False,
                  "settle": "openai", "whileLocked": while_locked}
        self.proc.stdin.write(json.dumps({"type": "configure", "config": config, "socket": self.socket,
                                          "secret": self.secret, "state_dir": os.path.join(D, "state"),
                                          "machine": "lsc"}) + "\n")
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
        self.conn.settimeout(60)
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
                                       "session": "lsc", "label": "LSC", "call_id": str(uuid.uuid4())}) + "\n").encode())
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


def outcome(resp):
    """(ok, code, body) of one tools/call answer; code is mac_locked when the lock refused it."""
    r = resp.get("result") or {}
    body = r.get("body")
    code = r.get("code") or (body.get("code") if isinstance(body, dict) else None)
    if not code and "mac_locked" in json.dumps(resp):
        code = "mac_locked"
    ok = bool(r) and not r.get("is_error") and not resp.get("error")
    if not r and resp.get("error"):
        code = code or str(resp.get("error"))[:80]
    return ok, code, body


def ax_text():
    p = subprocess.run([PROBE, "ax-text", TE], capture_output=True, text=True, timeout=30)
    return p.stdout


def find_textedit(body):
    windows = body.get("windows") if isinstance(body, dict) else body
    for w in windows or []:
        if not isinstance(w, dict):
            continue
        title = str(w.get("title") or "")
        if "note" in title.lower() and (str(w.get("pid") or "") in ("", TE) or "textedit" in json.dumps(w).lower()):
            return w
    for w in windows or []:
        if isinstance(w, dict) and str(w.get("pid") or "") == TE:
            return w
    return None


def run(setting, while_locked):
    w = Worker(while_locked)
    w.ready.wait(90)
    if not any(m.get("type") == "ready" for m in w.control):
        row(setting=setting, cmd="worker", ok=False, error="the engine never said ready: %s" % json.dumps(w.control[:2])[:200])
        w.stop()
        return {"ready": False}
    got = {"ready": True}
    try:
        w.connect()
        ok, code, body = outcome(w.call("status", {}))
        b = body if isinstance(body, dict) else {}
        row(setting=setting, cmd="status", ok=ok, error=code, note="screen_locked=%s while_locked=%s" % (
            b.get("screen_locked"), b.get("while_locked")))
        got["screen_locked"] = b.get("screen_locked")
        ok, code, body = outcome(w.call("list_windows", {}))
        win = find_textedit(body) if ok else None
        wid = str((win or {}).get("window_id") or (win or {}).get("id") or "")
        if wid:
            with open(WID_FILE, "w") as f:
                f.write(wid)
        elif os.path.exists(WID_FILE):
            wid = open(WID_FILE).read().strip()
        row(setting=setting, cmd="list_windows", ok=ok, error=code, note="textedit window %s" % (wid or "none"))
        got["list"] = (ok, code)
        if not wid:
            return got
        resp = w.call("screenshot", {"window_id": wid, "force": True})
        ok, code, _ = outcome(resp)
        png = (resp.get("result") or {}).get("png") or ""
        row(setting=setting, cmd="screenshot", ok=ok, error=code, note="png %d bytes (base64)" % len(png))
        got["shot"] = (ok, code)
        marker = " eng-%s-%s" % (setting, PHASE)
        ok, code, body = outcome(w.call("type_text", {"window_id": wid, "text": marker, "delivery": "background"}))
        landed = False
        for _ in range(50):  # 5 s at most: a route may not land while locked
            if marker.strip() in ax_text():
                landed = True
                break
            time.sleep(0.1)
        row(setting=setting, cmd="type_text", ok=ok, error=code, text=marker.strip(),
            note="landed=%s %s" % (landed, json.dumps(body)[:160] if not ok else ""))
        got["type"] = (ok, code, landed)
    except Exception as e:  # a dead worker is a result too
        row(setting=setting, cmd="error", ok=False, error=str(e)[:200])
    finally:
        w.stop()
    return got


def main():
    off = run("off", False)
    on = run("on", True)
    locked = bool(off.get("screen_locked") or on.get("screen_locked"))
    t_off = off.get("type") or (False, None, False)
    t_on = on.get("type") or (False, None, False)
    if locked:
        want = t_off[1] == "mac_locked" and not t_off[2] and t_on[0] and t_on[2]
        what = "locked: off refused mac_locked and typed nothing, on typed and the text landed"
    else:
        want = bool(t_off[0] and t_off[2] and t_on[0] and t_on[2])
        what = "unlocked: off and on both typed and landed"
    print(json.dumps({"phase": PHASE, "cmd": "engine-verdict", "ok": want, "note": "%s (expected: %s); off=%s on=%s" % (
        "PASS" if want else "FAIL", what, list(t_off), list(t_on))}), flush=True)


if __name__ == "__main__":
    main()
