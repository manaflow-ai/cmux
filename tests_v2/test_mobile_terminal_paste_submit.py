#!/usr/bin/env python3
"""Exercise the phone's paste RPC against a real terminal, including Enter.

Requires an explicitly selected tagged app. The child captures the bytes the
agent actually receives, so accepting an RPC without submitting cannot pass.
Run on a leased Mac; this creates and closes only its own workspace.
"""

import json
import os
from pathlib import Path
import shlex
import socket
import sys
import tempfile
import time
import uuid


CAPTURE = r'''
import json, os, select, sys, termios, time, tty
from pathlib import Path
root = Path(sys.argv[1])
saved = termios.tcgetattr(0)
try:
    tty.setraw(0)
    os.write(1, b"\x1b[?2004h")
    (root / "ready").touch()
    data = bytearray()
    chunks = []
    last = time.monotonic()
    while True:
        if select.select([0], [], [], 0.05)[0]:
            chunk = os.read(0, 65536)
            data.extend(chunk)
            last = time.monotonic()
            chunks.append({"bytes": list(chunk), "time": last})
        if data and time.monotonic() - last > 0.3:
            (root / "input.json").write_text(json.dumps({"bytes": list(data), "chunks": chunks}))
            data.clear()
            chunks.clear()
finally:
    os.write(1, b"\x1b[?2004l")
    termios.tcsetattr(0, termios.TCSANOW, saved)
'''


def call(path, method, params=None):
    with socket.socket(socket.AF_UNIX) as sock:
        sock.settimeout(15)
        sock.connect(path)
        sock.sendall((json.dumps({
            "id": str(uuid.uuid4()), "method": method, "params": params or {}
        }) + "\n").encode())
        response = b""
        while b"\n" not in response:
            chunk = sock.recv(65536)
            if not chunk:
                raise RuntimeError("Socket closed before replying")
            response += chunk
        reply = json.loads(response.split(b"\n")[0])
        if not reply.get("ok"):
            raise RuntimeError(f"{method}: {reply}")
        return reply.get("result", {})


def wait_for(path):
    deadline = time.monotonic() + 15
    while not path.exists():
        if time.monotonic() >= deadline:
            raise AssertionError(f"Timed out waiting for {path.name}")
        time.sleep(0.05)


def main():
    path = os.environ.get("CMUX_SOCKET_PATH", "")
    if not path.startswith("/tmp/cmux-debug-") or not path.endswith(".sock"):
        raise RuntimeError("CMUX_SOCKET_PATH must explicitly name a tagged socket")
    identity = call(path, "system.identify")
    if identity.get("socket_path") != path:
        raise RuntimeError(f"Unexpected socket identity: {identity}")
    with tempfile.TemporaryDirectory(prefix="cmux-reply-submit-") as directory:
        root = Path(directory)
        script = root / "capture.py"
        script.write_text(CAPTURE)
        workspace = call(path, "workspace.create", {
            "initial_command": shlex.join([sys.executable, "-u", str(script), str(root)]),
            "working_directory": str(root),
            "title": "Feed reply verification",
        })["workspace_id"]
        try:
            wait_for(root / "ready")
            surfaces = call(path, "surface.list", {"workspace_id": workspace})["surfaces"]
            surface = surfaces[0]["id"]
            for text in ["Continue", "First line\nSecond line 🧪", "Keep `literal` $text; \\"]:
                capture = root / "input.json"
                capture.unlink(missing_ok=True)
                result = call(path, "mobile.terminal.paste", {
                    "workspace_id": workspace, "surface_id": surface,
                    "text": text, "submit_key": "return",
                })
                assert result.get("submitted") is True, result
                wait_for(capture)
                received = json.loads(capture.read_text())
                actual = bytes(received["bytes"])
                expected = b"\x1b[200~" + text.encode() + b"\x1b[201~\r"
                assert actual == expected, (actual, expected)
                # Agent editors such as Gemini protect Enter for 40 ms after
                # a paste. Prove the separation at the PTY, not just in RPCs.
                paste_end = len(expected) - 1
                consumed = 0
                paste_time = enter_time = None
                for chunk in received["chunks"]:
                    consumed += len(chunk["bytes"])
                    if consumed >= paste_end and paste_time is None:
                        paste_time = chunk["time"]
                    if consumed > paste_end:
                        enter_time = chunk["time"]
                        break
                assert enter_time - paste_time >= 0.04, "Enter arrived inside the editor's paste-protection window"
                print(f"PASS exact paste and separate Enter: {text!r}")
        finally:
            call(path, "workspace.close", {"workspace_id": workspace})
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
