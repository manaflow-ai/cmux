#!/usr/bin/env python3
"""The `cu-rewrite` arm's host (README.md, "Arms"): cmux#37003's engine as its bridge reaches it,
without the cmux app or a Developer ID signed cmux Remote, which an eval VM has neither of.

cmux#37003's path is agent -> `acpmux computer-use-mcp` -> the cmux-tui daemon's
`computer-use-endpoint` -> cmux Remote -> its Computer Use worker (`cmux-remote worker computer-use`,
which loads libcmux_computer_use.dylib). The daemon refuses a cmux Remote that is not signed by the
team, so this script plays the daemon's and cmux Remote's two parts and nothing else:

- it starts the worker from the ad-hoc signed dev bundle and sends it the `configure` line (the
  worker contract in WorkerWire.swift): the policy (default: mode fullAccess, every other key at
  the engine's default, so the default deny list applies), a socket, a per-launch secret and a
  state directory; it waits for `{"type":"ready"}` and keeps the worker's stdin open;
- it listens on a socket of its own, the bridge's CMUX_TUI_SOCKET, and answers each
  `{"id","cmd":"computer-use-endpoint"}` line with the worker's socket and secret, the answer the
  real daemon gives once the worker is up (acpmux/src/computer_use/client.rs EndpointState).

  cu_rewrite_host.py --remote "PATH/cmux Remote (dev).app" --socket DAEMON_SOCK --state DIR [--policy JSON]

Python 3.9 standard library only.
"""

import argparse
import json
import os
import secrets
import socket
import subprocess
import sys
import threading


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--remote", required=True)
    p.add_argument("--socket", required=True)
    p.add_argument("--state", required=True)
    p.add_argument("--policy", default='{"mode": "fullAccess"}')
    a = p.parse_args()
    state = os.path.abspath(a.state)
    layout = os.path.join(state, "layout")
    os.makedirs(layout, mode=0o700, exist_ok=True)
    os.makedirs(os.path.join(state, "engine"), mode=0o700, exist_ok=True)
    worker_socket = os.path.join(layout, "computer-use.sock")
    secret = secrets.token_hex(32)
    binary = os.path.join(a.remote, "Contents", "MacOS", "cmux-remote")
    worker = subprocess.Popen([binary, "worker", "computer-use", "--layout-dir", layout], stdin=subprocess.PIPE,
                              stdout=subprocess.PIPE, stderr=sys.stderr, text=True)
    configure = {"type": "configure", "config": json.loads(a.policy), "socket": worker_socket, "secret": secret,
                 "state_dir": os.path.join(state, "engine"), "machine": "arena"}
    worker.stdin.write(json.dumps(configure) + "\n")
    worker.stdin.flush()
    ready = None
    for line in worker.stdout:
        try:
            msg = json.loads(line)
        except ValueError:
            continue
        print(f"cu_rewrite_host: worker said {line.strip()[:300]}", file=sys.stderr, flush=True)
        if msg.get("type") == "ready":
            ready = msg
            break
        if msg.get("type") == "unavailable":
            sys.exit(f"cu_rewrite_host: the worker is unavailable: {msg.get('reason')}")
    if ready is None:
        sys.exit(f"cu_rewrite_host: the worker exited ({worker.wait()}) before it was ready")

    def drain():
        # Later worker lines (request_permission, answers) are logged, never acted on.
        for line in worker.stdout:
            print(f"cu_rewrite_host: worker said {line.strip()[:300]}", file=sys.stderr, flush=True)

    threading.Thread(target=drain, daemon=True).start()
    endpoint = {"state": "ready", "socket": ready.get("socket") or worker_socket, "secret": secret, "pid": ready.get("pid") or worker.pid}

    if os.path.exists(a.socket):
        os.unlink(a.socket)
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(a.socket)
    os.chmod(a.socket, 0o600)
    server.listen(16)
    print(f"cu_rewrite_host: serving computer-use-endpoint on {a.socket}", file=sys.stderr, flush=True)

    def serve(conn):
        with conn, conn.makefile("rwb") as stream:
            for raw in stream:
                try:
                    req = json.loads(raw)
                except ValueError:
                    continue
                if req.get("cmd") == "computer-use-endpoint":
                    reply = {"id": req.get("id"), "ok": True, "data": endpoint}
                else:
                    reply = {"id": req.get("id"), "ok": False, "error": f"unknown command {req.get('cmd')}",
                             "error_code": "unknown_command"}
                stream.write((json.dumps(reply) + "\n").encode())
                stream.flush()

    try:
        while worker.poll() is None:
            server.settimeout(1.0)
            try:
                conn, _ = server.accept()
            except socket.timeout:
                continue
            threading.Thread(target=serve, args=(conn,), daemon=True).start()
    finally:
        server.close()
        if worker.poll() is None:
            worker.stdin.close()  # EOF stops the worker (WorkerWire)
            try:
                worker.wait(timeout=10)
            except subprocess.TimeoutExpired:
                worker.kill()
    sys.exit(f"cu_rewrite_host: the worker exited ({worker.returncode})")


if __name__ == "__main__":
    main()
