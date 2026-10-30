"""Minimal Chrome DevTools Protocol client (stdlib only).

Used against the tagged app's `remote-debugging-port`, which the runner sets
through CMUX_NEXT_CEF_EXTRA_SWITCHES (Debug builds of development bundles
only). It reaches extension targets (service workers, popups, the side panel)
that the cmux socket does not expose.
"""
import base64
import json
import os
import socket
import struct
import time
import urllib.request
from urllib.parse import urlparse


def targets(port):
    with urllib.request.urlopen(f"http://127.0.0.1:{port}/json/list", timeout=5) as response:
        return json.loads(response.read())


def browser(port):
    with urllib.request.urlopen(f"http://127.0.0.1:{port}/json/version", timeout=5) as response:
        return Session(json.loads(response.read())["webSocketDebuggerUrl"])


def target_infos(port):
    """Target.getTargets: like /json/list plus browserContextId (profile)."""
    session = browser(port)
    try:
        return session.call("Target.getTargets")["targetInfos"]
    finally:
        session.close()


def page_session(port, target_id):
    return Session(f"ws://127.0.0.1:{port}/devtools/page/{target_id}")


def wait_target(port, predicate, timeout=15):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            for target in targets(port):
                if predicate(target):
                    return target
        except OSError:
            pass
        time.sleep(0.25)
    return None


class Session:
    def __init__(self, ws_url, timeout=15):
        url = urlparse(ws_url)
        self.sock = socket.create_connection((url.hostname, url.port), timeout=timeout)
        key = base64.b64encode(os.urandom(16)).decode()
        request = (f"GET {url.path} HTTP/1.1\r\nHost: {url.hostname}:{url.port}\r\nUpgrade: websocket\r\n"
                   f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n")
        self.sock.sendall(request.encode())
        header = b""
        while b"\r\n\r\n" not in header:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise ConnectionError("websocket handshake failed")
            header += chunk
        if b" 101 " not in header.split(b"\r\n", 1)[0]:
            raise ConnectionError(header.split(b"\r\n", 1)[0].decode(errors="replace"))
        self.buffer = header.split(b"\r\n\r\n", 1)[1]
        self.next_id = 1

    def _send(self, text):
        payload = text.encode()
        mask = os.urandom(4)
        head = bytearray([0x81])
        if len(payload) < 126:
            head.append(0x80 | len(payload))
        elif len(payload) < 65536:
            head.append(0x80 | 126)
            head += struct.pack(">H", len(payload))
        else:
            head.append(0x80 | 127)
            head += struct.pack(">Q", len(payload))
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        self.sock.sendall(bytes(head) + mask + masked)

    def _read(self, count):
        while len(self.buffer) < count:
            chunk = self.sock.recv(1 << 20)
            if not chunk:
                raise ConnectionError("websocket closed")
            self.buffer += chunk
        data, self.buffer = self.buffer[:count], self.buffer[count:]
        return data

    def _recv(self):
        message = b""
        while True:
            first, second = self._read(2)
            length = second & 0x7F
            if length == 126:
                length = struct.unpack(">H", self._read(2))[0]
            elif length == 127:
                length = struct.unpack(">Q", self._read(8))[0]
            data = self._read(length)
            opcode = first & 0x0F
            if opcode == 0x8:
                raise ConnectionError("websocket closed by peer")
            if opcode in (0x9, 0xA):
                continue
            message += data
            if first & 0x80:
                return json.loads(message)

    def call(self, method, params=None, timeout=15):
        request_id = self.next_id
        self.next_id += 1
        self._send(json.dumps({"id": request_id, "method": method, "params": params or {}}))
        self.sock.settimeout(timeout)
        while True:
            message = self._recv()
            if message.get("id") == request_id:
                if "error" in message:
                    raise RuntimeError(f"{method}: {message['error'].get('message')}")
                return message.get("result", {})

    def evaluate(self, expression, timeout=30):
        result = self.call("Runtime.evaluate", {"expression": expression, "awaitPromise": True,
                                                "returnByValue": True}, timeout=timeout)
        if result.get("exceptionDetails"):
            raise RuntimeError(json.dumps(result["exceptionDetails"])[:400])
        return result.get("result", {}).get("value")

    def click(self, x, y):
        """Trusted mouse click (counts as a user gesture)."""
        for kind in ("mousePressed", "mouseReleased"):
            self.call("Input.dispatchMouseEvent", {"type": kind, "x": x, "y": y, "button": "left", "clickCount": 1})

    def click_selector(self, selector):
        box = self.evaluate(f"(() => {{ const r = document.querySelector({json.dumps(selector)}).getBoundingClientRect();"
                            " return [r.x + r.width / 2, r.y + r.height / 2]; })()")
        self.click(*box)

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass
