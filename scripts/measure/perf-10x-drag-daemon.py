#!/usr/bin/env python3
"""Daemon cost of one drag value (perf-10x drag; scripts/measure/perf-10x-drag.sh).

Starts one ephemeral headless cmux-tui, makes a workspace with a split and a
second column, then sends N `set-split-ratio` and N `set-viewport-pane-width`
requests one at a time (one in flight, like the app's coalescer) and prints the
round-trip p50/p95/max and the sustained rate. A second connection subscribes
to events, as the app does, so the daemon's per-change fan-out is in the cost.

Usage: perf-10x-drag-daemon.py --bin PATH [--n 360]
"""

import argparse
import json
import os
import socket
import subprocess
import tempfile
import threading
import time


class Conn:
    def __init__(self, path):
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.settimeout(30)
        self.sock.connect(path)
        self.buf = b""
        self.next_id = 1

    def send(self, obj):
        self.sock.sendall((json.dumps(obj) + "\n").encode())

    def read(self):
        while b"\n" not in self.buf:
            chunk = self.sock.recv(1 << 20)
            if not chunk:
                raise ConnectionError("socket closed")
            self.buf += chunk
        line, self.buf = self.buf.split(b"\n", 1)
        return json.loads(line)

    def call(self, cmd, **params):
        rid = self.next_id
        self.next_id += 1
        self.send({"id": rid, "cmd": cmd, **params})
        while True:
            msg = self.read()
            if msg.get("id") == rid and "ok" in msg:
                if not msg["ok"]:
                    raise RuntimeError(f"{cmd}: {msg.get('error')}")
                return msg.get("data") or {}


def walk(node, panes, splits):
    if isinstance(node, dict):
        if node.get("type") == "split" and "split" in node:
            splits.append(node["split"])
        if node.get("type") == "leaf" and "pane" in node:
            panes.append(node["pane"])
        for value in node.values():
            walk(value, panes, splits)
    elif isinstance(node, list):
        for value in node:
            walk(value, panes, splits)


def layout(conn):
    tree = conn.call("list-workspaces")
    panes, splits = [], []
    walk(tree.get("workspaces", []), panes, splits)
    return panes, splits


def pct(values, p):
    s = sorted(values)
    return s[min(len(s) - 1, int(round((len(s) - 1) * p)))]


def drain(path, stop):
    try:
        c = Conn(path)
        c.sock.settimeout(0.5)
        c.send({"id": 1, "cmd": "subscribe"})
        while not stop.is_set():
            try:
                c.read()
            except socket.timeout:
                pass
    except Exception:  # noqa: BLE001 (a missing subscribe command only drops the fan-out)
        pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", required=True)
    ap.add_argument("--n", type=int, default=360)
    args = ap.parse_args()
    root = tempfile.mkdtemp(prefix="pdrag.", dir="/private/tmp")
    sock = os.path.join(root, "s.sock")
    home = os.path.join(root, "home")
    os.makedirs(home)
    env = dict(os.environ, HOME=home, XDG_CONFIG_HOME=os.path.join(home, ".config"),
               XDG_STATE_HOME=os.path.join(home, ".state"), CMUX_TUI_CONFIG=os.path.join(root, "config.json"))
    log = open(os.path.join(root, "daemon.log"), "w")
    daemon = subprocess.Popen([args.bin, "--headless", "--session", "pdrag", "--socket", sock, "--ephemeral"],
                              stdout=log, stderr=subprocess.STDOUT, env=env, start_new_session=True)
    stop = threading.Event()
    try:
        deadline = time.time() + 30
        while not os.path.exists(sock):
            if daemon.poll() is not None or time.time() > deadline:
                raise RuntimeError("daemon did not start: " + open(os.path.join(root, "daemon.log")).read()[-2000:])
            time.sleep(0.1)
        time.sleep(0.2)
        c = Conn(sock)
        ident = c.call("identify")
        print(f"DRAG-DAEMON version={ident.get('version')} protocol={ident.get('protocol')}")
        panes, _ = layout(c)
        if not panes:
            c.call("new-workspace", name="drag")
            panes, _ = layout(c)
        c.call("split", pane=panes[0], dir="right")
        panes, splits = layout(c)
        try:
            c.call("new-pane-right", pane=panes[-1])
        except RuntimeError as error:
            print(f"DRAG-DAEMON new-pane-right failed: {error}")
        panes, splits = layout(c)
        threading.Thread(target=drain, args=(sock, stop), daemon=True).start()
        time.sleep(0.3)
        cases = [("set-split-ratio", lambda i: {"split": splits[0], "ratio": 0.3 + 0.4 * (i % 50) / 50, "transaction": 7001})]
        cases.append(("set-viewport-pane-width",
                      lambda i: {"pane": panes[-1], "width": 0.4 + 0.4 * (i % 50) / 50, "transaction": 7002}))
        for name, params in cases:
            times = []
            errors = 0
            start = time.perf_counter()
            for i in range(args.n):
                t0 = time.perf_counter()
                try:
                    c.call(name, **params(i))
                except RuntimeError as error:
                    errors += 1
                    if errors == 1:
                        print(f"DRAG-DAEMON {name} error: {error}")
                times.append(time.perf_counter() - t0)
            total = time.perf_counter() - start
            ms = lambda v: f"{v * 1000:.3f}"
            print(f"DRAG-DAEMON cmd={name} n={len(times)} rtt_p50_ms={ms(pct(times, 0.5))} rtt_p95_ms={ms(pct(times, 0.95))}"
                  f" rtt_max_ms={ms(max(times))} per_s={len(times) / total:.1f} errors={errors}")
    finally:
        stop.set()
        daemon.terminate()
        try:
            daemon.wait(10)
        except subprocess.TimeoutExpired:
            daemon.kill()


if __name__ == "__main__":
    main()
