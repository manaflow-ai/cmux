#!/usr/bin/env python3
"""Small deterministic TCP/UDP relay for screen-stream-eval.

It deliberately runs in user space so the measurement step needs no packet-filter
privileges.  TCP is delayed in both directions; UDP is delayed and dropped with a
seeded PRNG in both directions.  The relay owns only the sockets it opens.
"""

from __future__ import annotations

import argparse
import heapq
import ipaddress
import json
from pathlib import Path
import random
import signal
import socket
import sys
import threading
import time


class DelayedUDP:
    def __init__(self, sock: socket.socket, delay_s: float, loss: float, seed: int, upstream: tuple[str, int]):
        self.sock = sock
        self.delay_s = delay_s
        self.loss = loss
        self.upstream = upstream
        self.rng = random.Random(seed)
        self.bench: tuple[str, int] | None = None
        self.events: list[tuple[float, int, bytes, tuple[str, int], str]] = []
        self.cv = threading.Condition()
        self.seq = 0
        self.stop = False
        self.probes = 0
        self.counts = {direction: {key: 0 for key in ("received", "dropped", "sent", "bytes_received", "bytes_sent")}
                       for direction in ("upstream", "downstream")}

    def enqueue(self, payload: bytes, addr: tuple[str, int], target: tuple[str, int]) -> None:
        direction = "downstream" if addr == self.upstream else "upstream"
        counts = self.counts[direction]
        counts["received"] += 1
        counts["bytes_received"] += len(payload)
        if self.loss and self.rng.random() < self.loss:
            counts["dropped"] += 1
            return
        with self.cv:
            self.seq += 1
            heapq.heappush(self.events, (time.monotonic() + self.delay_s, self.seq, payload, target, direction))
            self.cv.notify()

    def sender(self) -> None:
        while True:
            with self.cv:
                while not self.events and not self.stop:
                    self.cv.wait()
                if self.stop and not self.events:
                    return
                due, _, payload, target, direction = self.events[0]
                wait = due - time.monotonic()
                if wait > 0:
                    self.cv.wait(wait)
                    continue
                heapq.heappop(self.events)
            try:
                self.sock.sendto(payload, target)
                self.counts[direction]["sent"] += 1
                self.counts[direction]["bytes_sent"] += len(payload)
            except OSError:
                return

    def run(self) -> None:
        threading.Thread(target=self.sender, daemon=True).start()
        while not self.stop:
            try:
                payload, addr = self.sock.recvfrom(2**16)
            except OSError:
                return
            if addr[0] == self.upstream[0] and addr[1] == self.upstream[1]:
                if self.bench is not None:
                    self.enqueue(payload, addr, self.bench)
            else:
                # Explicit zero-byte eval registration is consumed locally. It
                # precedes Hello and is not part of the seeded loss sequence.
                if not payload:
                    self.bench = addr
                    self.probes += 1
                elif addr == self.bench:
                    self.enqueue(payload, addr, self.upstream)

    def close(self) -> None:
        with self.cv:
            self.stop = True
            self.cv.notify_all()
        self.sock.close()


def tcp_copy(src: socket.socket, dst: socket.socket, delay_s: float, done: threading.Event) -> None:
    try:
        while not done.is_set():
            data = src.recv(65536)
            if not data:
                return
            if delay_s:
                time.sleep(delay_s)
            dst.sendall(data)
    except OSError:
        pass
    finally:
        done.set()
        for sock in (src, dst):
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass


def tcp_session(client: socket.socket, upstream_addr: tuple[str, int], delay_s: float) -> None:
    try:
        upstream = socket.create_connection(upstream_addr, timeout=10)
    except OSError:
        client.close()
        return
    done = threading.Event()
    threading.Thread(target=tcp_copy, args=(client, upstream, delay_s, done), daemon=True).start()
    threading.Thread(target=tcp_copy, args=(upstream, client, delay_s, done), daemon=True).start()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--listen-host", default="127.0.0.1")
    parser.add_argument("--listen-port", type=int, required=True)
    parser.add_argument("--upstream-host", default="127.0.0.1")
    parser.add_argument("--upstream-port", type=int, required=True)
    parser.add_argument("--rtt-ms", type=float, required=True)
    parser.add_argument("--loss-pct", type=float, required=True)
    parser.add_argument("--seed", type=int, required=True)
    parser.add_argument("--stats-path", type=Path)
    args = parser.parse_args()
    if args.rtt_ms < 0 or args.loss_pct < 0 or args.loss_pct > 100:
        parser.error("rtt-ms must be non-negative and loss-pct must be in [0, 100]")
    if not all(ipaddress.ip_address(host).is_loopback for host in (args.listen_host, args.upstream_host)):
        parser.error("eval relay requires numeric loopback endpoints")
    delay_s = args.rtt_ms / 2000.0
    upstream = (args.upstream_host, args.upstream_port)
    tcp = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    for sock in (tcp, udp):
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.bind((args.listen_host, args.listen_port))
    tcp.listen(8)
    udp_relay = DelayedUDP(udp, delay_s, args.loss_pct / 100.0, args.seed, upstream)
    udp_thread = threading.Thread(target=udp_relay.run, daemon=True)
    udp_thread.start()
    stop = threading.Event()

    def stats(_signum=None, _frame=None) -> None:
        if args.stats_path is not None:
            obj = {"seed":args.seed,"rtt_ms":args.rtt_ms,"loss_pct":args.loss_pct,
                   "unix_ms":time.time_ns() // 1_000_000,"probes":udp_relay.probes,
                   "directions":udp_relay.counts}
            temporary = args.stats_path.with_suffix(".tmp")
            temporary.write_text(json.dumps(obj))
            temporary.replace(args.stats_path)

    def shutdown(_signum, _frame) -> None:
        stats()
        stop.set()
        udp_relay.close()
        tcp.close()

    signal.signal(signal.SIGUSR1, stats)
    stats()
    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)
    print(f"netem: listening {args.listen_host}:{args.listen_port} -> {args.upstream_host}:{args.upstream_port} rtt_ms={args.rtt_ms:g} loss_pct={args.loss_pct:g} seed={args.seed}", flush=True)
    while not stop.is_set():
        try:
            client, _ = tcp.accept()
        except OSError:
            break
        threading.Thread(target=tcp_session, args=(client, upstream, delay_s), daemon=True).start()
    return 0


if __name__ == "__main__":
    sys.exit(main())
