#!/usr/bin/env python3
"""End-to-end check of the agent pane's native transport against a real acpmux daemon.

Starts `acpmux daemon run` the way the app does (no --allow-dev-origin, no --dev), then connects
exactly as the Swift host does (AgentPaneTransport / AcpmuxConnection.request): an
`Authorization: Bearer <dashboard token>` header, `Origin: cmux-agent://pane`, and the LocalApp
token from ACPMUX_HOME/run/localapp.token in the first `initialize` frame only. The daemon must
report `_meta.acpmux.origin == "local"`. Control cases must stay remote: no LocalApp token, and the
dev server's Origin (which the old page-owned socket sent from a Debug app).

Usage: pane-localapp-e2e.py ACPMUX_BINARY       (Rust stays on a Testbox: run it there)
Stdlib only. Stops only the daemon it started (by its recorded pid).
"""
import base64
import json
import os
import socket
import struct
import subprocess
import sys
import tempfile
import time
import urllib.parse

PANE_ORIGIN = "cmux-agent://pane"


def frame(text, opcode=1):
    payload = text.encode()
    head = bytearray([0x80 | opcode])
    n = len(payload)
    if n < 126:
        head.append(0x80 | n)
    elif n < 65536:
        head += bytes([0x80 | 126]) + struct.pack(">H", n)
    else:
        head += bytes([0x80 | 127]) + struct.pack(">Q", n)
    key = os.urandom(4)
    return bytes(head) + key + bytes(b ^ key[i & 3] for i, b in enumerate(payload))


def read_exact(sock, n):
    data = b""
    while len(data) < n:
        chunk = sock.recv(n - len(data))
        if not chunk:
            raise ConnectionError("closed")
        data += chunk
    return data


def read_frame(sock):
    b0, b1 = read_exact(sock, 2)
    n = b1 & 0x7F
    if n == 126:
        n = struct.unpack(">H", read_exact(sock, 2))[0]
    elif n == 127:
        n = struct.unpack(">Q", read_exact(sock, 8))[0]
    return b0 & 0x0F, read_exact(sock, n)


def initialize_origin(port, dashboard, origin, local_token):
    """The daemon's `_meta.acpmux.origin` for one connection, or the refusal."""
    sock = socket.create_connection(("127.0.0.1", port), timeout=15)
    try:
        key = base64.b64encode(os.urandom(16)).decode()
        headers = ["GET / HTTP/1.1", "Host: 127.0.0.1:%d" % port, "Upgrade: websocket", "Connection: Upgrade",
                   "Sec-WebSocket-Key: " + key, "Sec-WebSocket-Version: 13", "Authorization: Bearer " + dashboard]
        if origin:
            headers.append("Origin: " + origin)
        sock.sendall(("\r\n".join(headers) + "\r\n\r\n").encode())
        response = b""
        while b"\r\n\r\n" not in response:
            response += sock.recv(4096)
        status = response.split(b"\r\n", 1)[0].decode()
        if " 101 " not in status:
            return "refused: " + status
        params = {"protocolVersion": 1, "clientInfo": {"name": "cmux-react-agent-pane", "version": "1"}, "clientCapabilities": {}}
        if local_token:
            params["_meta"] = {"acpmux": {"localAppToken": local_token}}
        sock.sendall(frame(json.dumps({"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": params})))
        while True:
            opcode, payload = read_frame(sock)
            if opcode == 8:
                return "closed"
            if opcode != 1:
                continue
            message = json.loads(payload)
            if message.get("id") == 0:
                if "error" in message:
                    return "error: " + json.dumps(message["error"])
                return message.get("result", {}).get("_meta", {}).get("acpmux", {}).get("origin", "absent")
    finally:
        sock.close()


def main():
    binary = os.path.abspath(sys.argv[1])
    home = tempfile.mkdtemp(prefix="pane-localapp-")
    read_fd, write_fd = os.pipe()
    env = dict(os.environ, ACPMUX_HOME=home, ACPMUX_SOCKET=os.path.join(home, "a.sock"))
    args = [binary, "daemon", "run", "--ready-fd", "3", "--listen", "127.0.0.1:0"]
    log = open(os.path.join(home, "daemon.log"), "w")

    def child():
        os.dup2(write_fd, 3)

    daemon = subprocess.Popen(args, env=env, stdout=log, stderr=log, stdin=subprocess.DEVNULL,
                              close_fds=False, preexec_fn=child)
    os.close(write_fd)
    print("started pid=%d args=%s" % (daemon.pid, " ".join(args[1:])))
    try:
        line = b""
        deadline = time.time() + 30
        while not line.endswith(b"\n") and time.time() < deadline:
            chunk = os.read(read_fd, 4096)
            if not chunk:
                break
            line += chunk
        ready = json.loads(line)
        web = urllib.parse.urlparse(ready["webUrl"])
        dashboard = urllib.parse.parse_qs(web.query)["token"][0]
        with open(os.path.join(home, "run", "localapp.token")) as f:
            local_token = f.read().strip()
        cmdline = open("/proc/%d/cmdline" % daemon.pid, "rb").read().split(b"\0") if os.path.exists("/proc") else []
        results = {
            "host (pane origin + token)": initialize_origin(web.port, dashboard, PANE_ORIGIN, local_token),
            "pane origin, no LocalApp token": initialize_origin(web.port, dashboard, PANE_ORIGIN, None),
            "dev server origin + token": initialize_origin(web.port, dashboard, "http://127.0.0.1:4176", local_token),
            "no origin + token": initialize_origin(web.port, dashboard, None, local_token),
        }
        for name, value in results.items():
            print("%-34s %s" % (name, value))
        dev_flags = [a.decode() for a in cmdline if a in (b"--dev", b"--allow-dev-origin")]
        print("daemon dev flags: %s" % (dev_flags or "none"))
        ok = (results["host (pane origin + token)"] == "local"
              and all(v != "local" for k, v in results.items() if not k.startswith("host"))
              and not dev_flags)
        print("PASS" if ok else "FAIL")
        return 0 if ok else 1
    finally:
        daemon.terminate()
        try:
            daemon.wait(10)
        except subprocess.TimeoutExpired:
            daemon.kill()


if __name__ == "__main__":
    sys.exit(main())
