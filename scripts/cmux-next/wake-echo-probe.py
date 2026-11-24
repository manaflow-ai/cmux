#!/usr/bin/env python3
"""Guest-side probe for the wake-echo harness (cloud-wake-echo.ts, hq#21300).

  wake-echo-probe.py setup DIR CMUX_TUI NETHOST NETPORT
      find the guest's cmux-tui terminal daemon socket (or start an own one, labelled), make a `cat` terminal in it,
      write DIR/config.json, run the whole sequence once as a dry run, and print one JSON line (`@@setup {...}`).
  wake-echo-probe.py run DIR
      the long-lived probe: a 50 ms tick. When the tick gap after a pause shows up and DIR/arm names a cycle, it runs
      the sequence once and writes DIR/result.<seq>.json (marks are guest wall-clock epoch ms; the runner puts them
      on its own clock by an offset it measures).

The sequence, from the first tick after the gap (resumed_wall):
  net:    a thread loops a TCP connect (1 s timeout) to NETADDR:NETPORT until one succeeds -> net_up_at. NETADDR is
          NETHOST resolved once at setup: a name resolved after the wake waited out the resolver's 5 s timeout on
          a query sent before the network was back (run 45475656502: net_up +5.0 s on every cycle). The resolve is
          timed apart in its own thread -> dns_at (a mark, not a phase).
  daemon: a NEW unix connection: identify, set-client-info {name: wake-probe, kind: tui}, attach-surface -> pty_attach_at
          at the attach's ok reply; then `send` one marker character -> input_at; the first `output` event carrying
          the marker -> echo_at (echo_any_at: the first output event of any kind after the send).
Protocol client copied from split-latency-bench.py (Conn).
"""
import base64
import struct
import json
import os
import socket
import subprocess
import sys
import threading
import time


def now_ms():
    return time.time() * 1000.0


class Conn:
    def __init__(self, path, timeout=5):
        self.s = socket.socket(socket.AF_UNIX)
        self.s.settimeout(timeout)
        self.s.connect(path)
        self.buf = b""
        self.n = 0
        self.stash = {}

    def send(self, obj):
        self.n += 1
        self.s.sendall((json.dumps(dict(obj, id=self.n)) + "\n").encode())
        return self.n

    def line(self, timeout=30):
        self.s.settimeout(timeout)
        while b"\n" not in self.buf:
            chunk = self.s.recv(1 << 20)
            if not chunk:
                raise EOFError("daemon closed the connection")
            self.buf += chunk
        raw, self.buf = self.buf.split(b"\n", 1)
        return json.loads(raw)

    def reply(self, rid, timeout=30):
        if rid in self.stash:
            return self.stash.pop(rid)
        deadline = time.monotonic() + timeout
        while True:
            m = self.line(max(0.1, deadline - time.monotonic()))
            if "ok" in m or "error" in m:
                if m.get("id") == rid:
                    return m
                self.stash[m.get("id")] = m

    def peer_pid(self):
        try:
            return struct.unpack("3i", self.s.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i")))[0]
        except Exception:
            return None

    def close(self):
        try:
            self.s.close()
        except Exception:
            pass


def proc_start(pid):
    """The process's start time in clock ticks after boot (/proc/PID/stat field 22): same pid and start, same process."""
    try:
        with open("/proc/%d/stat" % pid) as f:
            return int(f.read().rsplit(")", 1)[1].split()[19])
    except Exception:
        return None


def daemon_id(c):
    pid = c.peer_pid()
    return {"pid": pid, "start": proc_start(pid) if pid else None}


def make_terminal(c):
    """A new workspace with one `cat` terminal in it; returns its surface id."""
    ws = c.reply(c.send({"cmd": "create-workspace", "name": "wake-echo"}), 15)
    if not ws.get("ok"):
        raise RuntimeError("create-workspace: %s" % json.dumps(ws)[:300])
    term = c.reply(c.send({"cmd": "create-terminal", "key": ws["data"]["key"], "argv": ["/bin/cat"], "cols": 80, "rows": 24}), 15)
    if not term.get("ok"):
        raise RuntimeError("create-terminal: %s" % json.dumps(term)[:300])
    return term["data"]["surface"]


def payload_has(m, marker):
    """Whether an output event's payload carries the marker (base64 payloads are decoded first)."""
    for k, v in m.items():
        if k in ("event", "surface", "id", "seq", "terminal_id") or not isinstance(v, str):
            continue
        try:
            text = base64.b64decode(v, validate=True).decode("utf-8", "replace")
        except Exception:
            text = v
        if marker in text:
            return True
    return False


def sequence(cfg, marker, deadline_s=60.0):
    """One wake's marks (epoch ms, guest wall clock) and, when something failed, `error` naming the stage."""
    marks = {"marker": marker}
    deadline = time.monotonic() + deadline_s

    def dns():
        try:
            socket.getaddrinfo(cfg["nethost"], cfg["netport"], proto=socket.IPPROTO_TCP)
            marks["dns_at"] = now_ms()
        except Exception as e:  # noqa: BLE001
            marks["dns_error"] = type(e).__name__ + ": " + str(e)[:80]

    threading.Thread(target=dns, daemon=True).start()

    def net():
        while time.monotonic() < deadline:
            try:
                c = socket.create_connection((cfg.get("netaddr") or cfg["nethost"], cfg["netport"]), timeout=1.0)
                c.close()
                marks["net_up_at"] = now_ms()
                return
            except Exception as e:  # noqa: BLE001
                marks["net_last_error"] = type(e).__name__ + ": " + str(e)[:80]
                time.sleep(0.02)
        marks["net_error"] = "no TCP connect to %s:%s in %.0f s (%s)" % (cfg["nethost"], cfg["netport"], deadline_s, marks.get("net_last_error"))

    t = threading.Thread(target=net, daemon=True)
    t.start()
    c = None
    stage = "connect"
    try:
        while True:
            try:
                c = Conn(cfg["socket"])
                break
            except Exception as e:  # noqa: BLE001
                if time.monotonic() > deadline:
                    raise RuntimeError("daemon socket: %s" % e)
                time.sleep(0.02)
        marks["conn_at"] = now_ms()
        marks["daemon"] = daemon_id(c)
        stage = "handshake"
        i1 = c.send({"cmd": "identify"})
        i2 = c.send({"cmd": "set-client-info", "name": "wake-probe", "kind": "tui"})
        r1 = c.reply(i1, 30)
        r2 = c.reply(i2, 30)
        marks["handshake_at"] = now_ms()
        if not r1.get("ok") or not r2.get("ok"):
            raise RuntimeError("handshake refused: %s %s" % (json.dumps(r1)[:200], json.dumps(r2)[:200]))
        stage = "attach"
        aid = c.send({"cmd": "attach-surface", "surface": cfg["surface"], "mode": "bytes"})
        while True:
            m = c.line(max(0.1, deadline - time.monotonic()))
            if m.get("id") == aid and ("ok" in m or "error" in m):
                if not m.get("ok"):
                    if "unknown surface" in str(m.get("error")):
                        marks["surface_lost"] = surface_lost(c, cfg)
                    raise RuntimeError("attach refused: %s" % json.dumps(m)[:300])
                marks["pty_attach_at"] = now_ms()
                break
        stage = "send"
        marks["input_at"] = now_ms()
        sid = c.send({"cmd": "send", "surface": cfg["surface"], "text": marker})
        seen = []
        while True:
            m = c.line(max(0.1, deadline - time.monotonic()))
            if m.get("id") == sid and ("ok" in m or "error" in m):
                marks["send_reply_at"] = now_ms()
                if not m.get("ok"):
                    raise RuntimeError("send refused: %s" % json.dumps(m)[:300])
                continue
            if m.get("event") == "output" and (m.get("surface") in (None, cfg["surface"])):
                at = now_ms()
                marks.setdefault("echo_any_at", at)
                if payload_has(m, marker):
                    marks["echo_at"] = at
                    break
            elif len(seen) < 6:
                seen.append(str(m.get("event") or m.get("id"))[:30])
        marks["other_events"] = seen
    except Exception as e:  # noqa: BLE001
        marks["error"] = "%s: %s: %s" % (stage, type(e).__name__, str(e)[:300])
        if stage == "send" and "echo_any_at" in marks:
            marks["error"] += " (an output event arrived but none carried the marker)"
    finally:
        if c:
            c.close()
    t.join(max(0.0, deadline - time.monotonic()))
    if "net_up_at" not in marks and "net_error" in marks:
        marks.setdefault("error", marks["net_error"])
    return marks


def surface_lost(c, cfg):
    """Evidence when the daemon no longer knows the probe's terminal: whether it is the same daemon process as at
    setup, what workspaces it lists now, and a new terminal (config.json updated) so later cycles still measure."""
    ev = {"surface": cfg["surface"], "setup_daemon": cfg.get("daemon"), "daemon_now": daemon_id(c)}
    ev["same_daemon"] = ev["setup_daemon"] == ev["daemon_now"]
    try:
        r = c.reply(c.send({"cmd": "list-workspaces"}), 10)
        ev["workspaces"] = json.dumps(r.get("data"))[:1500]
    except Exception as e:  # noqa: BLE001
        ev["workspaces"] = "unread: %s" % e
    try:
        ev["new_surface"] = make_terminal(c)
        cfg2 = dict(cfg, surface=ev["new_surface"], daemon=ev["daemon_now"])
        tmp = os.path.join(cfg["dir"], "config.json.tmp")
        with open(tmp, "w") as f:
            json.dump(cfg2, f)
        os.rename(tmp, os.path.join(cfg["dir"], "config.json"))
    except Exception as e:  # noqa: BLE001
        ev["new_surface_error"] = "%s: %s" % (type(e).__name__, str(e)[:200])
    return ev


def daemon_ok(path):
    try:
        c = Conn(path, timeout=3)
        try:
            r = c.reply(c.send({"cmd": "list-workspaces"}), 3)
            return bool(r.get("ok"))
        finally:
            c.close()
    except Exception:
        return False


def sh(cmd, timeout=15, env=None):
    try:
        p = subprocess.run(cmd, shell=isinstance(cmd, str), capture_output=True, text=True, timeout=timeout, env=env)
        return p.returncode, p.stdout, p.stderr
    except Exception as e:  # noqa: BLE001
        return 1, "", str(e)


def candidates(binary, diag):
    out = []
    rc, so, se = sh([binary, "server", "status", "--json"])
    diag.append("server status --json rc=%s out=%s err=%s" % (rc, so.strip()[:200], se.strip()[:200]))
    try:
        st = json.loads(so)
        p = st.get("socket") or st.get("socket_path")
        if p:
            out.append(p)
    except Exception:
        pass
    rc, so, _ = sh("ss -xlnH 2>/dev/null; ss -xln 2>/dev/null")
    for tok in so.split():
        if tok.startswith("/") and "cmux" in tok and tok not in out:
            out.append(tok)
    return out


def setup(directory, binary, nethost, netport):
    os.makedirs(directory, exist_ok=True)
    diag = []
    daemon = "guest"
    sockets = candidates(binary, diag)
    diag.append("candidates %s" % sockets)
    path = next((p for p in sockets if daemon_ok(p)), None)
    if not path:
        daemon = "own (no guest daemon socket answered list-workspaces)"
        env = dict(os.environ, XDG_RUNTIME_DIR=os.path.join(directory, "run"), XDG_STATE_HOME=os.path.join(directory, "state"))
        os.makedirs(env["XDG_RUNTIME_DIR"], mode=0o700, exist_ok=True)
        subprocess.Popen([binary, "server", "start", "--session", "wake-echo"], env=env, stdout=open(os.path.join(directory, "daemon.log"), "w"), stderr=subprocess.STDOUT, start_new_session=True)
        end = time.monotonic() + 30
        while time.monotonic() < end and not path:
            rc, so, se = sh([binary, "server", "status", "--session", "wake-echo", "--json"], env=env)
            try:
                st = json.loads(so)
                p = st.get("socket") or st.get("socket_path")
                if p and daemon_ok(p):
                    path = p
            except Exception:
                pass
            time.sleep(0.2)
    if not path:
        print("@@setup " + json.dumps({"ok": False, "error": "no cmux-tui daemon socket found or started", "diag": diag}))
        return 1
    c = Conn(path)
    try:
        ident = c.reply(c.send({"cmd": "identify"}), 10).get("data") or {}
        daemon_proc = daemon_id(c)
        surface = make_terminal(c)
    except Exception as e:  # noqa: BLE001
        print("@@setup " + json.dumps({"ok": False, "error": "%s: %s" % (type(e).__name__, e), "socket": path, "diag": diag}))
        return 1
    finally:
        c.close()
    try:
        netaddr = socket.getaddrinfo(nethost, netport, proto=socket.IPPROTO_TCP)[0][4][0]
    except Exception as e:  # noqa: BLE001
        print("@@setup " + json.dumps({"ok": False, "error": "resolve %s: %s" % (nethost, e), "diag": diag}))
        return 1
    cfg = {"dir": directory, "socket": path, "surface": surface, "daemon": daemon_proc, "nethost": nethost, "netaddr": netaddr, "netport": netport}
    with open(os.path.join(directory, "config.json"), "w") as f:
        json.dump(cfg, f)
    dry = sequence(cfg, "0", 20.0)
    print("@@setup " + json.dumps({"ok": "error" not in dry, "daemon": daemon, "socket": path, "surface": surface, "daemon_proc": daemon_proc, "netaddr": netaddr, "version": ident.get("version"), "protocol": ident.get("protocol"), "capabilities": sorted(ident.get("capabilities") or [])[:60], "dry_run": dry, "diag": diag}))
    return 0 if "error" not in dry else 1


def run(directory):
    with open(os.path.join(directory, "config.json")) as f:
        cfg = json.load(f)
    arm_path = os.path.join(directory, "arm")
    log = open(os.path.join(directory, "gaps.log"), "a", buffering=1)
    lw, lm = now_ms(), time.monotonic() * 1000
    while True:
        time.sleep(0.05)
        w, m = now_ms(), time.monotonic() * 1000
        dw, dm = w - lw, m - lm
        if dw > 1000 or dm > 1000 or abs(dw - dm) > 500:
            gap = {"prev_wall": lw, "resumed_wall": w, "wall_gap": dw, "mono_gap": dm}
            arm = None
            try:
                with open(arm_path) as f:
                    arm = json.load(f)
                os.unlink(arm_path)
            except Exception:
                arm = None
            log.write(json.dumps(dict(gap, armed=arm is not None)) + "\n")
            if arm:
                with open(os.path.join(directory, "config.json")) as f:
                    cfg = json.load(f)
                res = dict(gap, seq=arm["seq"])
                res.update(sequence(cfg, arm["marker"], 90.0))
                tmp = os.path.join(directory, "result.%s.json.tmp" % arm["seq"])
                with open(tmp, "w") as f:
                    json.dump(res, f)
                os.rename(tmp, os.path.join(directory, "result.%s.json" % arm["seq"]))
            w, m = now_ms(), time.monotonic() * 1000
        lw, lm = w, m


if __name__ == "__main__":
    if sys.argv[1] == "setup":
        sys.exit(setup(sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5])))
    run(sys.argv[2])
