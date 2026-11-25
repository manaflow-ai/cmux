"""Time one cold Claude start through an acpmux daemon (ACPMUX_SOCKET): `initialize`, then `session/new`
for FOLDER. Prints one JSON line. Used by claude-session-new-ab-linux.sh.
    claude-session-new-client.py FOLDER ARM"""

import json
import os
import socket
import sys
import time


def call(reader, sock, method, params, rid):
    sock.sendall((json.dumps({"jsonrpc": "2.0", "id": rid, "method": method, "params": params}) + "\n").encode())
    while True:
        line = reader.readline()
        if not line:
            raise SystemExit("the daemon closed the connection")
        msg = json.loads(line)
        if msg.get("id") == rid and ("result" in msg or "error" in msg):
            return msg


def main():
    folder, arm = sys.argv[1], sys.argv[2]
    os.makedirs(folder, exist_ok=True)
    sock = socket.socket(socket.AF_UNIX)
    sock.connect(os.environ["ACPMUX_SOCKET"])
    reader = sock.makefile()
    began = time.monotonic()
    call(reader, sock, "initialize", {"protocolVersion": 1, "clientCapabilities": {}}, 1)
    init_ms = (time.monotonic() - began) * 1000
    began = time.monotonic()
    meta = {"acpmux": {"harness": "claude", "policy": "ask"}}
    answer = call(reader, sock, "session/new", {"cwd": folder, "mcpServers": [], "_meta": meta}, 2)
    new_ms = (time.monotonic() - began) * 1000
    print(json.dumps({"arm": arm, "init_ms": round(init_ms), "session_new_ms": round(new_ms),
                      "ok": "result" in answer, "error": answer.get("error")}), flush=True)


if __name__ == "__main__":
    main()
