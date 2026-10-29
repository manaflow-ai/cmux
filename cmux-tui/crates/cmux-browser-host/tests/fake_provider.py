"""A fake app provider for cmux-browser-host's owner test (tests/cli.rs).

Connects to the provider socket in argv[1] with the secret in argv[2], sends
`hello`, prints "acked" once the host answers `hello.ack`, then on the line
"close" from stdin closes its link and keeps running until it is killed:
the app runs with its provider link down.
"""
import json
import socket
import struct
import sys
import time


def frame(value):
    body = json.dumps(value).encode()
    return struct.pack(">I", len(body)) + body


def read_frame(conn):
    header = b""
    while len(header) < 4:
        chunk = conn.recv(4 - len(header))
        if not chunk:
            return None
        header += chunk
    (length,) = struct.unpack(">I", header)
    body = b""
    while len(body) < length:
        chunk = conn.recv(length - len(body))
        if not chunk:
            return None
        body += chunk
    return json.loads(body)


conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
conn.connect(sys.argv[1])
conn.sendall(frame({
    "t": "hello", "version": 1, "provider_id": "fake-app", "install_id": "fake-install",
    "secret": sys.argv[2], "engines": ["cef"], "tabs": [],
}))
ack = read_frame(conn)
if not ack or ack.get("t") != "hello.ack":
    print(f"no ack: {ack}", flush=True)
    sys.exit(1)
print("acked", flush=True)
if sys.stdin.readline().strip() == "close":
    conn.close()
    print("closed", flush=True)
while True:
    time.sleep(60)
