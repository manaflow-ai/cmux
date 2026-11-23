"""Run with a cmux-rd binary. Each route must receive the first handshake datagram."""

import json
import os
import socket
import subprocess
import sys
import tempfile
from pathlib import Path


def probe(binary, order):
    with tempfile.TemporaryDirectory() as directory, socket.socket(
        socket.AF_INET, socket.SOCK_DGRAM
    ) as peer:
        peer.bind(("127.0.0.1", 0))
        peer.settimeout(2)
        candidate = f"host 127.0.0.1:{peer.getsockname()[1]}"
        answer = {
            "session": os.urandom(16).hex(),
            "peer_key": "09" + "00" * 31,
            "socket": str(Path(directory) / "viewer.sock"),
        }
        route = {"candidate": candidate}
        if order == "embedded":
            answer["candidates"] = [candidate]
            messages = [answer]
        elif order == "early":
            messages = [route, answer]
        else:
            messages = [answer, route]

        with subprocess.Popen(
            [binary, "connect"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE
        ) as viewer:
            try:
                viewer.stdin.write(b"".join(json.dumps(m).encode() + b"\n" for m in messages))
                viewer.stdin.flush()
                received = bool(peer.recv(65535))
            except (TimeoutError, BrokenPipeError):
                received = False
            finally:
                try:
                    _, stderr = viewer.communicate(timeout=3)
                except subprocess.TimeoutExpired:
                    viewer.kill()
                    _, stderr = viewer.communicate()
        print(f"{order}: handshake_datagram={int(received)}", flush=True)
        if not received and stderr:
            print(stderr.decode(errors="replace").strip(), file=sys.stderr)
        return received


if __name__ == "__main__":
    results = [probe(sys.argv[1], order) for order in ("embedded", "late", "early")]
    sys.exit(0 if all(results) else 1)
