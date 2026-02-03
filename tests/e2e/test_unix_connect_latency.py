import os
import socket
import subprocess
import tempfile
import time
import json
import select
from typing import Optional


CMUXD_BIN = os.environ.get("CMUXD_BIN", "/opt/cmuxterm/cmuxd/zig-out/bin/cmuxd")
DOCKER_E2E = os.environ.get("CMUX_E2E_DOCKER") == "1"


def _read_line(sock: socket.socket, timeout: float) -> Optional[bytes]:
    end = time.time() + timeout
    buf = b""
    while time.time() < end:
        rlist, _, _ = select.select([sock], [], [], 0.1)
        if not rlist:
            continue
        chunk = sock.recv(4096)
        if not chunk:
            return None
        buf += chunk
        if b"\n" in buf:
            line, _ = buf.split(b"\n", 1)
            return line
    return None


def _start_unix(path: str) -> subprocess.Popen:
    env = os.environ.copy()
    env.setdefault("SHELL", "/bin/sh")
    test_home = env.get("CMUXD_TEST_HOME", "/tmp/cmuxd-test-home")
    os.makedirs(test_home, exist_ok=True)
    env["HOME"] = test_home
    return subprocess.Popen(
        [CMUXD_BIN, "--unix", path],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
    )


def test_unix_connect_latency():
    max_connect = 2.0 if DOCKER_E2E else 1.0
    max_handshake = 1.0 if DOCKER_E2E else 0.5

    with tempfile.TemporaryDirectory() as tmpdir:
        socket_path = os.path.join(tmpdir, "cmuxd.sock")
        proc = _start_unix(socket_path)
        try:
            start = time.monotonic()
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            while True:
                try:
                    sock.connect(socket_path)
                    break
                except (FileNotFoundError, ConnectionRefusedError):
                    if time.monotonic() - start > max_connect:
                        raise TimeoutError("timed out waiting for unix socket")
                    time.sleep(0.01)

            connect_time = time.monotonic() - start

            hello = json.dumps({"type": "hello", "version": 1}).encode("utf-8") + b"\n"
            t0 = time.monotonic()
            sock.sendall(hello)
            line = _read_line(sock, timeout=max_handshake)
            handshake_time = time.monotonic() - t0

            print(f"cmuxd unix connect_time={connect_time:.4f}s handshake_time={handshake_time:.4f}s")

            assert connect_time <= max_connect
            assert line is not None
            msg = json.loads(line.decode("utf-8"))
            assert msg.get("type") == "welcome"
            assert handshake_time <= max_handshake
        finally:
            try:
                sock.close()
            except Exception:
                pass
            proc.terminate()
            proc.wait(timeout=5)
