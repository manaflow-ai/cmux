#!/usr/bin/env python3
"""Chromium leg of the LocalApp isolation spike (stdlib only, Python 3.9+).

Drives headless Chrome over --remote-debugging-pipe with the same CDP methods the CEF host uses
through its in-process shim (CEFPaneHostBridge: Runtime.addBinding, Page.addScriptToEvaluateOnNewDocument,
Runtime.evaluate). It answers, for Chromium:
  - design A: does a CDP isolated world (worldName) open a WebSocket with the page's Origin, do
    page-world patches reach it, what crosses the shared DOM, and does a page spy see the token;
  - design B: the cost of relaying frames through CDP (Runtime.evaluate in, Runtime.bindingCalled out).
The same JS files as the WebKit leg (../Sources/LocalAppSpike/JS). One asyncio loop holds the
stand-in daemon, the CDP client and (for B) the relay, so all times share one clock.

Usage: bench.py CHROME_BINARY OUT_DIR [--rounds N] [--probe-only]
"""
import asyncio
import base64
import hashlib
import json
import os
import socket
import struct
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
JS = os.path.join(HERE, "..", "Sources", "LocalAppSpike", "JS")
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
WORLD = "cmux-acpmux"
TOKEN = "ef56" * 16
PAD = "x" * 200


def js(name):
    with open(os.path.join(JS, name + ".js")) as f:
        return f.read()


def now():
    return time.perf_counter_ns()


# ---------------------------------------------------------------- WebSocket framing

async def read_frame(reader):
    head = await reader.readexactly(2)
    opcode = head[0] & 0x0F
    masked = head[1] & 0x80
    length = head[1] & 0x7F
    if length == 126:
        length = struct.unpack(">H", await reader.readexactly(2))[0]
    elif length == 127:
        length = struct.unpack(">Q", await reader.readexactly(8))[0]
    mask = await reader.readexactly(4) if masked else None
    payload = await reader.readexactly(length)
    if mask:
        payload = bytes(b ^ mask[i & 3] for i, b in enumerate(payload))
    return opcode, payload


def frame_bytes(text, mask=False):
    payload = text.encode()
    n = len(payload)
    head = bytearray([0x81])
    bit = 0x80 if mask else 0
    if n < 126:
        head.append(bit | n)
    elif n < 65536:
        head.append(bit | 126)
        head += struct.pack(">H", n)
    else:
        head.append(bit | 127)
        head += struct.pack(">Q", n)
    if mask:
        key = os.urandom(4)
        head += key
        payload = bytes(b ^ key[i & 3] for i, b in enumerate(payload))
    return bytes(head) + payload


def nodelay(writer):
    sock = writer.get_extra_info("socket")
    if sock is not None:
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)


# ---------------------------------------------------------------- stand-in daemon

class Peer:
    def __init__(self, writer, origin):
        self.writer = writer
        self.origin = origin
        self.name = "?"
        self.first = None
        self.send_times = []
        self.ack_times = []
        self.count = self.next = self.acked = 0
        self.done = None


class Server:
    PAGE = b"<!doctype html><html><body>bench</body></html>"

    def __init__(self):
        self.peers = {}
        self.port = 0

    async def start(self):
        self.server = await asyncio.start_server(self.handle, "127.0.0.1", 0)
        self.port = self.server.sockets[0].getsockname()[1]

    @property
    def origin(self):
        return "http://127.0.0.1:%d" % self.port

    async def handle(self, reader, writer):
        try:
            request = (await reader.readuntil(b"\r\n\r\n")).decode()
        except (asyncio.IncompleteReadError, ConnectionError):
            return  # a speculative preconnect that sent nothing
        lines = request.split("\r\n")
        headers = {}
        for line in lines[1:]:
            if ": " in line:
                k, v = line.split(": ", 1)
                headers[k.lower()] = v
        if headers.get("upgrade", "").lower() != "websocket":
            writer.write(b"HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % len(self.PAGE) + self.PAGE)
            await writer.drain()
            writer.close()
            return
        accept = base64.b64encode(hashlib.sha1((headers["sec-websocket-key"] + GUID).encode()).digest()).decode()
        writer.write(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n" % accept).encode())
        nodelay(writer)
        peer = Peer(writer, headers.get("origin"))
        try:
            while True:
                opcode, payload = await read_frame(reader)
                if opcode == 8:
                    break
                if opcode == 1:
                    self.on_text(peer, payload.decode())
        except (asyncio.IncompleteReadError, ConnectionError):
            pass

    def on_text(self, peer, text):
        if text.startswith('{"a":'):
            t = now()
            seq = int(text[5:-1])
            if seq >= len(peer.ack_times) or peer.ack_times[seq]:
                return
            peer.ack_times[seq] = t
            peer.acked += 1
            if peer.next < peer.count:
                self.send(peer, peer.next)
                peer.next += 1
            if peer.acked == peer.count and peer.done and not peer.done.done():
                peer.done.set_result(None)
            return
        if peer.first is None:
            peer.first = text
            msg = json.loads(text)
            peer.name = msg.get("params", {}).get("clientInfo", {}).get("name", "?")
            self.peers[peer.name] = peer
            peer.writer.write(frame_bytes('{"jsonrpc":"2.0","id":0,"result":{"_meta":{"acpmux":{"origin":"local"}}}}'))

    def send(self, peer, seq):
        text = ('{"jsonrpc":"2.0","method":"session/update","params":{"s":%d,"update":{"sessionUpdate":"agent_message_chunk",'
                '"content":{"type":"text","text":"%s"}}}}' % (seq, PAD))
        peer.send_times[seq] = now()
        peer.writer.write(frame_bytes(text))

    async def stream(self, name, count, window):
        peer = self.peers[name]
        peer.send_times = [0] * count
        peer.ack_times = [0] * count
        peer.count, peer.next, peer.acked = count, 0, 0
        peer.done = asyncio.get_event_loop().create_future()
        while peer.next < min(window, count):
            self.send(peer, peer.next)
            peer.next += 1
        await asyncio.wait_for(peer.done, 120)
        lat = [a - s for s, a in zip(peer.send_times, peer.ack_times)]
        return lat, max(peer.ack_times) - min(peer.send_times)


# ---------------------------------------------------------------- CDP over the pipe

class PipeReader(asyncio.Protocol):
    def __init__(self, cdp):
        self.cdp = cdp
        self.buffer = b""

    def data_received(self, data):
        self.buffer += data
        while b"\0" in self.buffer:
            message, self.buffer = self.buffer.split(b"\0", 1)
            self.cdp.dispatch(json.loads(message))


class CDP:
    def __init__(self, chrome):
        self.chrome = chrome
        self.next_id = 1
        self.pending = {}
        self.listeners = []

    async def launch(self, profile):
        cmd_r, cmd_w = os.pipe()
        res_r, res_w = os.pipe()
        cmd_r = os.dup(cmd_r) if cmd_r < 10 else cmd_r
        res_w = os.dup(res_w) if res_w < 10 else res_w
        hi_cmd_r = 100
        hi_res_w = 101
        os.dup2(cmd_r, hi_cmd_r)
        os.dup2(res_w, hi_res_w)

        def child():
            os.dup2(hi_cmd_r, 3)
            os.dup2(hi_res_w, 4)

        args = [self.chrome, "--headless=new", "--remote-debugging-pipe", "--no-first-run", "--no-default-browser-check",
                "--disable-background-timer-throttling", "--disable-renderer-backgrounding",
                "--disable-backgrounding-occluded-windows", "--disable-extensions", "--user-data-dir=" + profile,
                "about:blank"]
        self.proc = subprocess.Popen(args, close_fds=False, preexec_fn=child,
                                     stdout=subprocess.DEVNULL, stderr=open(os.path.join(profile, "chrome.log"), "w"))
        for fd in (cmd_r, res_w, hi_cmd_r, hi_res_w):
            try:
                os.close(fd)
            except OSError:
                pass
        loop = asyncio.get_event_loop()
        await loop.connect_read_pipe(lambda: PipeReader(self), os.fdopen(res_r, "rb", buffering=0))
        self.writer, _ = await loop.connect_write_pipe(asyncio.Protocol, os.fdopen(cmd_w, "wb", buffering=0))
        print("SPIKE-INFO chrome pid=%d" % self.proc.pid, flush=True)

    def dispatch(self, message):
        if "id" in message and message["id"] in self.pending:
            future = self.pending.pop(message["id"])
            if not future.done():
                future.set_result(message)
            return
        for listener in self.listeners:
            listener(message)

    def post(self, method, params=None, session=None):
        """Sends without waiting for the reply (fire and forget, as the CEF bridge's evaluate)."""
        message = {"id": self.next_id, "method": method, "params": params or {}}
        if session:
            message["sessionId"] = session
        self.next_id += 1
        self.writer.write(json.dumps(message).encode() + b"\0")
        return message["id"]

    async def call(self, method, params=None, session=None):
        future = asyncio.get_event_loop().create_future()
        ident = self.post(method, params, session)
        self.pending[ident] = future
        reply = await asyncio.wait_for(future, 60)
        if "error" in reply:
            raise RuntimeError("%s: %s" % (method, reply["error"]))
        return reply.get("result", {})

    def stop(self):
        # Only the Chrome this script started (its recorded pid), never a pattern kill.
        self.proc.terminate()
        try:
            self.proc.wait(10)
        except subprocess.TimeoutExpired:
            self.proc.kill()


# ---------------------------------------------------------------- one page per mode

class Page:
    def __init__(self, cdp, server, mode, spy):
        self.cdp, self.server, self.mode, self.spy = cdp, server, mode, spy
        self.iso_context = None
        self.loaded = None
        self.relay_writer = None
        self.first_out = True
        self.inbox = []
        self.scheduled = False
        self.flushes = 0
        self.frames = 0

    async def open(self):
        target = await self.cdp.call("Target.createTarget", {"url": "about:blank"})
        attached = await self.cdp.call("Target.attachToTarget", {"targetId": target["targetId"], "flatten": True})
        self.session = attached["sessionId"]
        self.cdp.listeners.append(self.event)
        s = self.session
        await self.cdp.call("Page.enable", {}, s)
        await self.cdp.call("Runtime.enable", {}, s)
        if self.spy:
            await self.cdp.call("Page.addScriptToEvaluateOnNewDocument", {"source": js("page-spy")}, s)
            # A binding scoped to the isolated world: does the page world get it?
            await self.cdp.call("Runtime.addBinding", {"name": "__isoOnlyBinding", "executionContextName": WORLD}, s)
        await self.cdp.call("Page.addScriptToEvaluateOnNewDocument", {"source": js("bench-page")}, s)
        if self.mode == "isolated":
            await self.cdp.call("Page.addScriptToEvaluateOnNewDocument", {"source": js("isolated-world"), "worldName": WORLD}, s)
        if self.mode.startswith("relay"):
            await self.cdp.call("Runtime.addBinding", {"name": "__relaySend"}, s)
        self.loaded = asyncio.get_event_loop().create_future()
        await self.cdp.call("Page.navigate", {"url": self.server.origin + "/page"}, s)
        await asyncio.wait_for(self.loaded, 30)
        if self.mode == "isolated":
            for _ in range(100):
                if self.iso_context:
                    break
                await asyncio.sleep(0.01)  # test harness only

    def event(self, message):
        if message.get("sessionId") != self.session:
            return
        method = message.get("method")
        params = message.get("params", {})
        if method == "Page.loadEventFired" and self.loaded and not self.loaded.done():
            self.loaded.set_result(None)
        elif method == "Runtime.executionContextCreated":
            context = params["context"]
            if context.get("name") == WORLD and context.get("auxData", {}).get("type") == "isolated":
                self.iso_context = context["id"]
        elif method == "Runtime.bindingCalled" and params.get("name") == "__relaySend":
            self.outbound(params["payload"])

    async def page(self, expression):
        result = await self.cdp.call("Runtime.evaluate", {"expression": expression, "awaitPromise": True, "returnByValue": True}, self.session)
        if "exceptionDetails" in result:
            raise RuntimeError("page: %s" % result["exceptionDetails"])
        return result["result"].get("value")

    async def isolated(self, function, *args):
        result = await self.cdp.call("Runtime.callFunctionOn", {
            "functionDeclaration": function, "arguments": [{"value": a} for a in args],
            "executionContextId": self.iso_context, "awaitPromise": True, "returnByValue": True}, self.session)
        if "exceptionDetails" in result:
            raise RuntimeError("isolated: %s" % result["exceptionDetails"])
        return result["result"].get("value")

    async def connect(self):
        url = "ws://127.0.0.1:%d/" % self.server.port
        if self.mode == "direct":
            await self.page("startDirect(%s, %s)" % (json.dumps(url), json.dumps(TOKEN)))
        elif self.mode == "isolated":
            await self.page("window.__pending = startIsolated(); true")
            await self.isolated("(url, token) => globalThis.__acpmuxConnect(url, token)", url, TOKEN)
            await self.page("window.__pending")
        else:
            await self.relay_connect(url)
            await self.page("startRelay(%s, (t) => __relaySend(t))" % json.dumps(self.mode))

    # ---- design B: the host owns the socket

    async def relay_connect(self, url):
        reader, writer = await asyncio.open_connection("127.0.0.1", self.server.port)
        nodelay(writer)
        key = base64.b64encode(os.urandom(16)).decode()
        writer.write(("GET / HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                      "Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\nOrigin: cmux-agent://pane\r\n\r\n"
                      % (self.server.port, key)).encode())
        await reader.readuntil(b"\r\n\r\n")
        self.relay_writer = writer
        asyncio.ensure_future(self.relay_receive(reader))

    async def relay_receive(self, reader):
        try:
            while True:
                opcode, payload = await read_frame(reader)
                if opcode != 1:
                    continue
                text = payload.decode()
                if self.mode == "relay-perframe":
                    self.deliver([text])
                    continue
                self.inbox.append(text)
                if not self.scheduled:
                    self.scheduled = True
                    asyncio.get_event_loop().call_soon(self.flush)
        except (asyncio.IncompleteReadError, ConnectionError):
            pass

    def flush(self):
        # At most 64 frames per evaluate, as NativeRelayTransport.maximumBatch.
        frames, self.inbox = self.inbox[:64], self.inbox[64:]
        self.scheduled = bool(self.inbox)
        if self.scheduled:
            asyncio.get_event_loop().call_soon(self.flush)
        self.deliver(frames)

    def deliver(self, frames):
        self.flushes += 1
        self.frames += len(frames)
        self.cdp.post("Runtime.evaluate", {"expression": "__relayRecv(%s)" % json.dumps(frames), "silent": True}, self.session)

    def outbound(self, text):
        if self.first_out:
            self.first_out = False
            msg = json.loads(text)
            if msg.get("method") != "initialize":
                return
            msg.setdefault("params", {}).setdefault("_meta", {}).setdefault("acpmux", {})["localAppToken"] = TOKEN
            text = json.dumps(msg)
        self.relay_writer.write(frame_bytes(text, mask=True))


# ---------------------------------------------------------------- runs

def pct(values, p):
    if not values:
        return float("nan")
    s = sorted(values)
    i = min(len(s) - 1, max(0, -(-int(len(s) * p * 1000) // 1000) - 1))
    return s[i] / 1e6


async def probes(cdp, server):
    for mode in ("direct", "isolated", "relay"):
        page = Page(cdp, server, mode, spy=True)
        await page.open()
        iso = None
        if mode == "isolated":
            iso = await page.isolated("() => %s" % js("isolated-probe").strip())
            iso_binding = await page.isolated("() => typeof globalThis.__isoOnlyBinding")
        await page.connect()
        await server.stream(mode, 50, 50)
        seen = await page.page("JSON.stringify(window.__spySeen)") or ""
        probe = await page.page("window.__probe()")
        page_binding = await page.page("typeof window.__isoOnlyBinding")
        peer = server.peers[mode]
        print("SPIKE-PROBE chromium mode=%s spyCaughtToken=%s spySawFrames=%s serverGotToken=%s origin=%s page=%s isolated=%s "
              "isoOnlyBinding(page)=%s isoOnlyBinding(iso)=%s"
              % (mode, TOKEN in seen, "agent_message_chunk" in seen, TOKEN in (peer.first or ""), peer.origin, probe, iso,
                 page_binding, iso_binding if mode == "isolated" else "-"), flush=True)


async def bench(cdp, server, rounds, out):
    modes = ["direct", "isolated", "relay", "relay-perframe"]
    pages = {}
    for mode in modes:
        page = Page(cdp, server, mode, spy=False)
        await page.open()
        await page.connect()
        await server.stream(mode, 500, 500)
        pages[mode] = page
    samples = {m: {"seq": [], "burst": [], "totals": [], "cpu": [], "flushes": 0, "frames": 0} for m in modes}
    for r in range(rounds):
        for o in range(len(modes)):
            mode = modes[(r + o) % len(modes)]
            s = samples[mode]
            lat, _ = await server.stream(mode, 300, 1)
            s["seq"] += lat
            page = pages[mode]
            page.flushes = page.frames = 0
            cpu0 = time.thread_time_ns()
            lat, total = await server.stream(mode, 2000, 2000)
            s["cpu"].append(time.thread_time_ns() - cpu0)
            s["burst"] += lat
            s["totals"].append(total)
            s["flushes"] += page.flushes
            s["frames"] += page.frames
    rows = []
    d = samples["direct"]
    for mode in modes:
        s = samples[mode]
        row = {
            "engine": "chromium", "mode": mode, "rounds": rounds,
            "seq_p50_ms": pct(s["seq"], .5), "seq_p95_ms": pct(s["seq"], .95), "seq_p99_ms": pct(s["seq"], .99),
            "burst_p50_ms": pct(s["burst"], .5), "burst_p95_ms": pct(s["burst"], .95), "burst_p99_ms": pct(s["burst"], .99),
            "burst_total_median_ms": pct(s["totals"], .5), "burst_total_max_ms": pct(s["totals"], 1),
            "host_thread_cpu_median_ms": pct(s["cpu"], .5),
            "seq_overhead_p50_ms": pct(s["seq"], .5) - pct(d["seq"], .5),
            "seq_overhead_p95_ms": pct(s["seq"], .95) - pct(d["seq"], .95),
            "seq_overhead_p99_ms": pct(s["seq"], .99) - pct(d["seq"], .99),
            "burst_total_overhead_ms": pct(s["totals"], .5) - pct(d["totals"], .5),
        }
        if s["flushes"]:
            row["relay_frames_per_flush"] = s["frames"] / s["flushes"]
        rows.append(row)
        print("SPIKE-BENCH " + json.dumps(row, sort_keys=True), flush=True)
    with open(os.path.join(out, "chromium-bench.json"), "w") as f:
        json.dump(rows, f, indent=2, sort_keys=True)


async def main():
    chrome, out = sys.argv[1], sys.argv[2]
    rounds = int(sys.argv[sys.argv.index("--rounds") + 1]) if "--rounds" in sys.argv else 5
    os.makedirs(out, exist_ok=True)
    server = Server()
    await server.start()
    profile = tempfile.mkdtemp(prefix="localapp-spike-chrome-", dir=out)
    cdp = CDP(chrome)
    await cdp.launch(profile)
    try:
        version = await cdp.call("Browser.getVersion")
        print("SPIKE-INFO chromium " + json.dumps(version), flush=True)
        await probes(cdp, server)
        if "--probe-only" not in sys.argv:
            await bench(cdp, server, rounds, out)
    finally:
        cdp.stop()


if __name__ == "__main__":
    asyncio.run(main())
