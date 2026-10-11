#!/usr/bin/env python3
"""Daemon-side cost of Cmd+D (splitRight), in the app's request order.

Usage:
  split-latency-bench.py --socket PATH [--runs N] [--label NAME] [--out FILE.jsonl]

PATH is a cmux-tui daemon socket: a local daemon, or the local socket of
`cmux-tui remote connect` (then every request crosses the link). Per run:
  1. `split` {pane, dir:right, cols, rows, terminal_id} on the control
     connection; a `subscribe` (tree deltas) connection times the first
     `pane-added` and `layout-changed` after the send
  2. `list-workspaces`, the resync the app's store runs after layout-changed
  3. a warm `identify` on the control connection (one plain round trip)
  4. a new connection with `identify` + `set-client-info` pipelined, the
     handshake of each terminal view's attach (TerminalAttachment)
  5. `attach-surface` {mode:bytes}: reply, then the first content
     (`vt-state` with data or the first `output`)
The run then closes the new surface. Times are milliseconds from the split
send; the summary prints p50 and p95 and `app_path_sum` (split + resync +
handshake + attach, the app's critical path without step 3).

Run it on a fleet Mac or a remote host, never on the laptop (it starts no
daemon: point it at a scratch daemon, e.g. `cmux-tui --headless --session
bench --socket S --state DIR`, with CMUX_TUI_DEBUG_SPANS=FILE for the
daemon's own marks). plans/cmux-next/remote-state-ownership.md section 1.
"""
import argparse
import json
import socket
import threading
import time
import uuid

now = time.perf_counter


class Conn:
    def __init__(self, path):
        self.s = socket.socket(socket.AF_UNIX)
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
        # Replies can arrive out of order on a link; keep the others.
        if rid in self.stash:
            return self.stash.pop(rid)
        while True:
            m = self.line(timeout)
            if "ok" in m or "error" in m:
                if m.get("id") == rid:
                    return m
                self.stash[m.get("id")] = m

    def close(self):
        self.s.close()


def percentile(values, q):
    v = sorted(x for x in values if x is not None)
    return v[min(len(v) - 1, int(q * len(v)))] if v else None


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[1])
    ap.add_argument("--socket", required=True)
    ap.add_argument("--runs", type=int, default=15)
    ap.add_argument("--label", default="split")
    ap.add_argument("--out")
    args = ap.parse_args()

    events = []
    lock = threading.Lock()

    def subscriber():
        c = Conn(args.socket)
        c.send({"cmd": "subscribe", "tree_events": "deltas"})
        while True:
            try:
                m = c.line(timeout=3600)
            except Exception:
                return
            if m.get("event"):
                with lock:
                    events.append((now(), m["event"]))

    ctl = Conn(args.socket)
    caps = set((ctl.reply(ctl.send({"cmd": "identify"})).get("data") or {}).get("capabilities") or [])
    threading.Thread(target=subscriber, daemon=True).start()
    time.sleep(0.3)

    def first_pane():
        tree = ctl.reply(ctl.send({"cmd": "list-workspaces"}))["data"]
        for w in tree.get("workspaces", []):
            for sc in w.get("screens", []):
                for p in sc.get("panes", []):
                    return p["id"]
        return None

    pane = first_pane()
    if pane is None:
        ctl.reply(ctl.send({"cmd": "new-workspace"}))
        time.sleep(1.0)
        pane = first_pane()
    if pane is None:
        raise SystemExit("no pane to split")

    rows = []
    for i in range(args.runs):
        with lock:
            events.clear()
        t0 = now()
        req = {"cmd": "split", "pane": pane, "dir": "right", "cols": 80, "rows": 24}
        if "terminal-placement-env-v1" in caps:
            req["terminal_id"] = uuid.uuid4().hex
        r = ctl.reply(ctl.send(req))
        t_split = now()
        if not r.get("ok"):
            print("split refused:", r)
            break
        surface = r["data"]["surface"]
        ctl.reply(ctl.send({"cmd": "list-workspaces"}))
        t_list = now()
        tq = now()
        ctl.reply(ctl.send({"cmd": "identify"}))
        rtt = (now() - tq) * 1000
        t_hs0 = now()
        a = Conn(args.socket)
        i1 = a.send({"cmd": "identify"})
        i2 = a.send({"cmd": "set-client-info", "name": "split-latency-bench", "kind": "bench"})
        a.reply(i1)
        a.reply(i2)
        t_hs = now()
        aid = a.send({"cmd": "attach-surface", "surface": surface, "mode": "bytes"})
        t_attach = t_first = None
        deadline = now() + 15
        while now() < deadline and (t_attach is None or t_first is None):
            try:
                m = a.line(timeout=max(0.1, deadline - now()))
            except Exception:
                break
            if m.get("id") == aid:
                t_attach = now()
                if not m.get("ok"):
                    print("attach refused:", m)
                    break
            ev = m.get("event")
            if t_first is None and (ev == "output" or (ev == "vt-state" and len(str(m.get("data") or "")) > 64)):
                t_first = now()
        a.close()
        with lock:
            seen = {}
            for t, name in events:
                if t >= t0 and name not in seen:
                    seen[name] = (t - t0) * 1000
        row = {
            "label": args.label, "run": i,
            "split_reply": (t_split - t0) * 1000,
            "ev_pane_added": seen.get("pane-added"),
            "ev_layout_changed": seen.get("layout-changed"),
            "list_workspaces": (t_list - t_split) * 1000,
            "warm_rtt": rtt,
            "attach_handshake": (t_hs - t_hs0) * 1000,
            "attach_reply": ((t_attach or t_hs) - t_hs) * 1000,
            "first_content_after_attach": ((t_first - t_hs) * 1000) if t_first else None,
        }
        row["app_path_sum"] = row["split_reply"] + row["list_workspaces"] + row["attach_handshake"] + row["attach_reply"]
        rows.append(row)
        print(json.dumps({k: (round(v, 1) if isinstance(v, float) else v) for k, v in row.items()}), flush=True)
        ctl.reply(ctl.send({"cmd": "close-surface", "surface": surface}))
        time.sleep(0.5)

    if args.out:
        with open(args.out, "a") as f:
            for r in rows:
                f.write(json.dumps(r) + "\n")
    print(f"== {args.label} n={len(rows)}")
    for k in ["split_reply", "ev_pane_added", "ev_layout_changed", "list_workspaces", "warm_rtt",
              "attach_handshake", "attach_reply", "first_content_after_attach", "app_path_sum"]:
        p50, p95 = percentile([r[k] for r in rows], 0.5), percentile([r[k] for r in rows], 0.95)
        if p50 is not None:
            print(f"{k:28s} p50 {p50:8.1f}  p95 {p95:8.1f}")


if __name__ == "__main__":
    main()
