#!/usr/bin/env python3
"""Stdio <-> TCP relay that delays each direction, for simulating a slow link.

Used as an ssh ProxyCommand: `ProxyCommand python3 delay_proxy.py HOST PORT CONFIG`.
CONFIG is a JSON file re-read about every 200 ms, so a running session can change
its link without reconnecting:
  {"one_way_ms": 75, "jitter_ms": 20, "stall_probability": 0.0, "stall_ms": 250}
Each chunk is released after one_way_ms plus uniform jitter; a stall (standing in
for a TCP retransmit after loss) adds stall_ms. Release times never go backwards,
so the byte stream stays in order, as TCP keeps it.
"""
import json, os, random, socket, sys, threading, time, heapq

host, port, config_path = sys.argv[1], int(sys.argv[2]), sys.argv[3]
config = {"one_way_ms": 0, "jitter_ms": 0, "stall_probability": 0.0, "stall_ms": 250}
config_read_at = 0.0

def current_config():
    global config, config_read_at
    now = time.monotonic()
    if now - config_read_at > 0.2:
        config_read_at = now
        try:
            with open(config_path) as f:
                config = {**config, **json.load(f)}
        except (OSError, ValueError):
            pass
    return config

def pump(read, write, close):
    lock = threading.Condition()
    queue = []
    last_release = [0.0]
    done = [False]

    def sender():
        while True:
            with lock:
                while not queue and not done[0]:
                    lock.wait()
                if not queue and done[0]:
                    break
                release, data = queue[0]
                delay = release - time.monotonic()
                if delay > 0:
                    lock.wait(delay)
                    continue
                queue.pop(0)
            try:
                write(data)
            except OSError:
                break
        close()

    threading.Thread(target=sender, daemon=True).start()
    while True:
        try:
            data = read()
        except OSError:
            data = b""
        with lock:
            if not data:
                done[0] = True
                lock.notify_all()
                return
            c = current_config()
            delay = c["one_way_ms"] + random.uniform(-c["jitter_ms"], c["jitter_ms"])
            if random.random() < c["stall_probability"]:
                delay += c["stall_ms"]
            release = max(time.monotonic() + max(delay, 0) / 1000.0, last_release[0])
            last_release[0] = release
            queue.append((release, data))
            lock.notify_all()

sock = socket.create_connection((host, port))
sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
stdin, stdout = sys.stdin.buffer.raw, sys.stdout.buffer.raw

def write_stdout(data):
    view = memoryview(data)
    while view:
        n = os.write(1, view)
        view = view[n:]

up = threading.Thread(target=pump, args=(lambda: os.read(0, 65536), sock.sendall,
                                          lambda: sock.shutdown(socket.SHUT_WR)), daemon=True)
up.start()
pump(lambda: sock.recv(65536), write_stdout, lambda: os._exit(0))
