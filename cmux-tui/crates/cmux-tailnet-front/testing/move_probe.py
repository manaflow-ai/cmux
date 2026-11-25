#!/usr/bin/env python3
"""Move probe for stable-node-e2e.sh: runs in the tailnet client container.

Through the client's tailscaled SOCKS5 (localhost:1055) to HOST:PORT on the stable node:
- one long connection asks every INTERVAL s for DURATION s (it must stay on its first backend);
- a stream of new connections, one every INTERVAL s, each asks once and closes;
then closes the long connection and reconnects once. Prints one JSON object: every sample
with its start time, the backend that answered, latency and any error.
Usage: move_probe.py HOST PORT DURATION INTERVAL
"""
import json
import socket
import sys
import threading
import time

HOST, PORT, DURATION, INTERVAL = sys.argv[1], int(sys.argv[2]), float(sys.argv[3]), float(sys.argv[4])


def recvn(s, n):
    data = b""
    while len(data) < n:
        chunk = s.recv(n - len(data))
        if not chunk:
            raise OSError("socks closed")
        data += chunk
    return data


def connect():
    s = socket.create_connection(("127.0.0.1", 1055), timeout=10)
    s.sendall(b"\x05\x01\x00")
    if recvn(s, 2) != b"\x05\x00":
        raise OSError("socks auth refused")
    host = HOST.encode()
    s.sendall(b"\x05\x01\x00\x03" + bytes([len(host)]) + host + PORT.to_bytes(2, "big"))
    head = recvn(s, 4)
    if head[1] != 0:
        raise OSError(f"socks connect failed code {head[1]}")
    atyp = head[3]
    rest = {1: 4, 4: 16}.get(atyp)
    if rest is None:
        rest = recvn(s, 1)[0]
    recvn(s, rest + 2)
    return s


def ask(s, msg):
    s.sendall(msg.encode())
    reply = s.recv(4096).decode(errors="replace")
    if not reply:
        raise OSError("closed")
    return reply.split(":", 1)[0]


samples = {"long": [], "new": []}
lock = threading.Lock()
stop_at = time.time() + DURATION


def new_conns():
    i = 0
    while time.time() < stop_at:
        t0 = time.time()
        rec = {"t": t0}
        try:
            s = connect()
            rec["backend"] = ask(s, f"n{i}")
            s.close()
        except Exception as e:  # noqa: BLE001
            rec["error"] = str(e)
        rec["ms"] = (time.time() - t0) * 1000
        with lock:
            samples["new"].append(rec)
        i += 1
        time.sleep(max(0.0, INTERVAL - (time.time() - t0)))


long_conn = connect()
first = ask(long_conn, "hello")
thread = threading.Thread(target=new_conns)
thread.start()
i = 0
while time.time() < stop_at:
    t0 = time.time()
    rec = {"t": t0}
    try:
        rec["backend"] = ask(long_conn, f"l{i}")
    except Exception as e:  # noqa: BLE001
        rec["error"] = str(e)
    rec["ms"] = (time.time() - t0) * 1000
    samples["long"].append(rec)
    i += 1
    time.sleep(max(0.0, INTERVAL - (time.time() - t0)))
thread.join()
long_conn.close()
t_close = time.time()
reconnect = {}
try:
    s = connect()
    reconnect["backend"] = ask(s, "again")
    reconnect["ms"] = (time.time() - t_close) * 1000
    s.close()
except Exception as e:  # noqa: BLE001
    reconnect["error"] = str(e)
print(json.dumps({"first": first, "samples": samples, "reconnect": reconnect}))
