#!/usr/bin/env python3
"""tailnet stable-node bench helpers: the VM echo server, the load client, the front proxy, and the report.

  serve  --port P                         TCP line echo and UDP datagram echo (one "VM")
  client --proto tcp|udp --target H:P --duration S --out F [--idle S]
  proxy  --listen H:P --upstream-file F --pidfile F
                                          TCP front; SIGUSR1 aborts its backend legs, and each
                                          reconnects to the upstream named in the file
  report --variant V --moves F --tcp F [--udp F]
  summary --dir D                         the whole run as one JSON line (tailnet-stable-node-run.v1)
  statusdiff A B                          compare two `tailscale status --json` snapshots

Called only by scripts/bench/tailnet-stable-node.sh. Every line of client output is a JSON event with
a wall-clock t in ns, so the moves (also wall-clock ns) line up across namespaces on one kernel.
"""
import argparse
import asyncio
import bisect
import json
import math
import os
import signal
import time


def now_ns():
    return time.time_ns()


def pct(xs, p):
    if not xs:
        return None
    xs = sorted(xs)
    return round(xs[max(0, math.ceil(p / 100 * len(xs)) - 1)], 3)


def parse(line):
    seq, ts = line.split()[:2]
    return int(seq), int(ts)


class Echo(asyncio.DatagramProtocol):
    def connection_made(self, transport):
        self.transport = transport

    def datagram_received(self, data, addr):
        self.transport.sendto(data, addr)


async def serve(port):
    loop = asyncio.get_running_loop()
    await loop.create_datagram_endpoint(Echo, local_addr=("0.0.0.0", port))

    async def handle(r, w):
        try:
            while True:
                line = await r.readline()
                if not line:
                    break
                w.write(line)
                await w.drain()
        except OSError:
            pass
        finally:
            w.close()

    srv = await asyncio.start_server(handle, "0.0.0.0", port)
    async with srv:
        await srv.serve_forever()


async def tcp_session(r, w, end, idle, log, seq):
    """Send numbered lines at 100 Hz and read the echoes. Returns (seq, why) when the session breaks."""
    last = [time.monotonic()]

    async def reader():
        while True:
            line = await r.readline()
            if not line:
                raise ConnectionError("eof")
            text = line.decode()
            who = ""
            if ":" in text:  # stable_node echo answers "NAME:<chunk>": keep the name, it says which backend
                who, text = text.split(":", 1)
            try:
                q, ts = parse(text)
            except ValueError:
                continue
            t = now_ns()
            last[0] = time.monotonic()
            log(ev="rx", seq=q, t=t, rtt_ms=round((t - ts) / 1e6, 3), who=who)

    rt = asyncio.ensure_future(reader())
    why = None
    try:
        while time.monotonic() < end:
            if rt.done():
                why = "eof"
                break
            if time.monotonic() - last[0] > idle:
                why = "idle"
                break
            seq += 1
            w.write(f"{seq} {now_ns()}\n".encode())
            await asyncio.wait_for(w.drain(), idle)
            await asyncio.sleep(0.01)
    except (OSError, asyncio.TimeoutError) as e:
        why = type(e).__name__
    finally:
        rt.cancel()
        w.close()
    if why is not None:
        log(ev="disconnect", t=now_ns(), why=why)
    return seq


async def open_conn(host, port, socks):
    """A TCP stream to HOST:PORT, through a SOCKS5 server at SOCKS (HOST:PORT) when given."""
    if not socks:
        return await asyncio.open_connection(host, port)
    sh, sp = socks.rsplit(":", 1)
    r, w = await asyncio.open_connection(sh, int(sp))
    w.write(b"\x05\x01\x00")
    await r.readexactly(2)
    hb = host.encode()
    w.write(b"\x05\x01\x00\x03" + bytes([len(hb)]) + hb + int(port).to_bytes(2, "big"))
    head = await r.readexactly(4)
    if head[1] != 0:
        w.close()
        raise OSError(f"socks connect failed code {head[1]}")
    if head[3] == 3:
        n = (await r.readexactly(1))[0]
    else:
        n = {1: 4, 4: 16}.get(head[3], 4)
    await r.readexactly(n + 2)
    return r, w


async def client(proto, host, port, duration, out, idle, socks=None):
    ev = open(out, "w", buffering=1)

    def log(**kw):
        ev.write(json.dumps(kw) + "\n")

    end = time.monotonic() + duration
    seq = 0
    loop = asyncio.get_running_loop()
    if proto == "udp":

        class C(asyncio.DatagramProtocol):
            def datagram_received(self, data, addr):
                try:
                    q, ts = parse(data.decode())
                except ValueError:
                    return
                t = now_ns()
                log(ev="rx", seq=q, t=t, rtt_ms=round((t - ts) / 1e6, 3))

            def error_received(self, exc):
                pass

        tr, _ = await loop.create_datagram_endpoint(C, remote_addr=(host, port))
        while time.monotonic() < end:
            seq += 1
            try:
                tr.sendto(f"{seq} {now_ns()}\n".encode())
            except OSError:
                pass
            await asyncio.sleep(0.01)
        await asyncio.sleep(0.5)
        tr.close()
    else:
        while time.monotonic() < end:
            try:
                r, w = await asyncio.wait_for(open_conn(host, port, socks), 2.0)
            except (OSError, asyncio.TimeoutError):
                await asyncio.sleep(0.05)
                continue
            log(ev="connect", t=now_ns())
            seq = await tcp_session(r, w, end, idle, log, seq)
    log(ev="end", sent=seq)
    ev.close()


async def proxy(listen, upstream_file, pidfile):
    host, port = listen.rsplit(":", 1)
    live = set()

    def upstream():
        h, p = open(upstream_file).read().strip().rsplit(":", 1)
        return h, int(p)

    class Leg:
        """The backend leg for one client connection. Reconnects keep the client leg open."""

        def __init__(self):
            self.br = self.bw = None
            self.gen = 0
            self.lock = asyncio.Lock()

        def cur(self):
            return self.br, self.bw, self.gen

        async def ensure(self, gen):
            async with self.lock:
                if self.gen != gen:
                    return
                while True:
                    try:
                        self.br, self.bw = await asyncio.open_connection(*upstream())
                        break
                    except OSError:
                        await asyncio.sleep(0.05)
                self.gen += 1

    async def handle(cr, cw):
        leg = Leg()
        live.add(leg)

        async def c2b():
            while True:
                data = await cr.read(65536)
                if not data:
                    return
                while True:
                    _, bw, g = leg.cur()
                    try:
                        bw.write(data)
                        await bw.drain()
                        break
                    except OSError:
                        await leg.ensure(g)

        async def b2c():
            while True:
                br, _, g = leg.cur()
                try:
                    data = await br.read(65536)
                except OSError:
                    data = b""
                if not data:
                    await leg.ensure(g)
                    continue
                cw.write(data)
                await cw.drain()

        try:
            await leg.ensure(0)
            tasks = [asyncio.ensure_future(c2b()), asyncio.ensure_future(b2c())]
            await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
            for t in tasks:
                t.cancel()
        except (OSError, asyncio.CancelledError):
            pass
        finally:
            live.discard(leg)
            if leg.bw is not None:
                leg.bw.close()
            cw.close()

    loop = asyncio.get_running_loop()

    def on_move():
        for leg in list(live):
            if leg.bw is not None:
                leg.bw.transport.abort()

    loop.add_signal_handler(signal.SIGUSR1, on_move)
    with open(pidfile, "w") as f:
        f.write(str(os.getpid()))
    srv = await asyncio.start_server(handle, host, int(port))
    async with srv:
        await srv.serve_forever()


def load(path):
    try:
        with open(path) as f:
            return [json.loads(line) for line in f if line.strip()]
    except FileNotFoundError:
        return []


def stats(events, moves):
    rx = sorted([e for e in events if e["ev"] == "rx"], key=lambda e: e["t"])
    ts = [e["t"] for e in rx]
    ends = [e for e in events if e["ev"] == "end"]
    sent = ends[-1]["sent"] if ends else None
    uniq = len({e["seq"] for e in rx})
    rtt = [e["rtt_ms"] for e in rx]
    stalls, resumes = [], []
    for m in moves:
        t = m["t_ns"]
        i = bisect.bisect_right(ts, t)
        if 0 < i < len(ts):
            # stall: last echo before the move to first echo after it; resume: move to first echo after it
            stalls.append((ts[i] - ts[i - 1]) / 1e6)
            resumes.append((ts[i] - t) / 1e6)
    return {
        "sent": sent,
        "echoed_unique": uniq,
        "lost": None if sent is None else sent - uniq,
        "rtt_ms": {"p50": pct(rtt, 50), "p95": pct(rtt, 95), "p99": pct(rtt, 99), "n": len(rtt)},
        "disconnects": sum(1 for e in events if e["ev"] == "disconnect"),
        "connects": sum(1 for e in events if e["ev"] == "connect"),
        "moves": len(moves),
        "stall_ms": {"p50": pct(stalls, 50), "p95": pct(stalls, 95), "n": len(stalls)},
        "resume_ms": {"p50": pct(resumes, 50), "p95": pct(resumes, 95), "p99": pct(resumes, 99)},
    }


def report(args):
    moves = load(args.moves)
    out = {"variant": args.variant, "tcp": stats(load(args.tcp), moves)}
    if args.udp:
        out["udp"] = stats(load(args.udp), moves)
    print(json.dumps(out, indent=2))


def summary(d):
    """The whole run as one JSON object: meta (connect, route, DERP), v1 and v2 stats, the tailnet view diff."""
    meta = json.load(open(os.path.join(d, "meta.json")))
    out = {"schema": "tailnet-stable-node-run.v1", "meta": meta}
    for v, udp in (("v1", True), ("v2", False)):
        moves = load(os.path.join(d, f"moves-{v}.jsonl"))
        block = {"tcp": stats(load(os.path.join(d, f"{v}-tcp.jsonl")), moves)}
        if udp:
            block["udp"] = stats(load(os.path.join(d, f"{v}-udp.jsonl")), moves)
        out[v] = block
    before, after = snap(os.path.join(d, "status-before.json")), snap(os.path.join(d, "status-after.json"))
    out["tailnet_view_unchanged"] = before == after
    print(json.dumps(out, sort_keys=True))


def snap(path):
    with open(path) as f:
        d = json.load(f)
    me = d.get("Self") or {}
    peers = {
        k: [v.get("HostName"), sorted(v.get("TailscaleIPs") or []), v.get("PublicKey")]
        for k, v in (d.get("Peer") or {}).items()
    }
    return {"self": [me.get("HostName"), sorted(me.get("TailscaleIPs") or []), me.get("PublicKey")], "peers": peers}


def statusdiff(a, b):
    sa, sb = snap(a), snap(b)
    changed = sa != sb
    print(json.dumps({"unchanged": not changed, "before": sa, "after": sb}, indent=2))


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("serve")
    s.add_argument("--port", type=int, required=True)
    c = sub.add_parser("client")
    c.add_argument("--proto", choices=["tcp", "udp"], required=True)
    c.add_argument("--target", required=True)
    c.add_argument("--duration", type=float, required=True)
    c.add_argument("--out", required=True)
    c.add_argument("--idle", type=float, default=1.0)
    c.add_argument("--socks", help="HOST:PORT of a SOCKS5 server to dial through (TCP only)")
    x = sub.add_parser("proxy")
    x.add_argument("--listen", required=True)
    x.add_argument("--upstream-file", required=True)
    x.add_argument("--pidfile", required=True)
    r = sub.add_parser("report")
    r.add_argument("--variant", required=True)
    r.add_argument("--moves", required=True)
    r.add_argument("--tcp", required=True)
    r.add_argument("--udp")
    m = sub.add_parser("summary")
    m.add_argument("--dir", required=True)
    d = sub.add_parser("statusdiff")
    d.add_argument("a")
    d.add_argument("b")
    args = p.parse_args()
    if args.cmd == "serve":
        asyncio.run(serve(args.port))
    elif args.cmd == "client":
        h, port = args.target.rsplit(":", 1)
        asyncio.run(client(args.proto, h, int(port), args.duration, args.out, args.idle, args.socks))
    elif args.cmd == "proxy":
        asyncio.run(proxy(args.listen, args.upstream_file, args.pidfile))
    elif args.cmd == "report":
        report(args)
    elif args.cmd == "summary":
        summary(args.dir)
    elif args.cmd == "statusdiff":
        statusdiff(args.a, args.b)


if __name__ == "__main__":
    main()
