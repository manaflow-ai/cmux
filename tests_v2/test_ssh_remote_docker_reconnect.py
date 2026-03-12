#!/usr/bin/env python3
"""Docker integration: remote SSH reconnect after host restart."""

from __future__ import annotations

import glob
import hashlib
import json
import os
import secrets
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import time
from base64 import b64encode
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")
REMOTE_HTTP_PORT = int(os.environ.get("CMUX_SSH_TEST_REMOTE_HTTP_PORT", "43173"))
REMOTE_WS_PORT = int(os.environ.get("CMUX_SSH_TEST_REMOTE_WS_PORT", "43174"))
DOCKER_SSH_HOST = os.environ.get("CMUX_SSH_TEST_DOCKER_HOST", "127.0.0.1")
DOCKER_PUBLISH_ADDR = os.environ.get("CMUX_SSH_TEST_DOCKER_BIND_ADDR", "127.0.0.1")


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _find_cli_binary() -> str:
    env_cli = os.environ.get("CMUXTERM_CLI")
    if env_cli and os.path.isfile(env_cli) and os.access(env_cli, os.X_OK):
        return env_cli

    fixed = os.path.expanduser("~/Library/Developer/Xcode/DerivedData/cmux-tests-v2/Build/Products/Debug/cmux")
    if os.path.isfile(fixed) and os.access(fixed, os.X_OK):
        return fixed

    candidates = glob.glob(os.path.expanduser("~/Library/Developer/Xcode/DerivedData/**/Build/Products/Debug/cmux"), recursive=True)
    candidates += glob.glob("/tmp/cmux-*/Build/Products/Debug/cmux")
    candidates = [p for p in candidates if os.path.isfile(p) and os.access(p, os.X_OK)]
    if not candidates:
        raise cmuxError("Could not locate cmux CLI binary; set CMUXTERM_CLI")
    candidates.sort(key=lambda p: os.path.getmtime(p), reverse=True)
    return candidates[0]


def _run(cmd: list[str], *, env: dict[str, str] | None = None, check: bool = True) -> subprocess.CompletedProcess[str]:
    proc = subprocess.run(cmd, capture_output=True, text=True, env=env, check=False)
    if check and proc.returncode != 0:
        merged = f"{proc.stdout}\n{proc.stderr}".strip()
        raise cmuxError(f"Command failed ({' '.join(cmd)}): {merged}")
    return proc


def _run_cli_json(cli: str, args: list[str]) -> dict:
    env = dict(os.environ)
    env.pop("CMUX_WORKSPACE_ID", None)
    env.pop("CMUX_SURFACE_ID", None)
    env.pop("CMUX_TAB_ID", None)
    proc = _run([cli, "--socket", SOCKET_PATH, "--json", *args], env=env)
    try:
        return json.loads(proc.stdout or "{}")
    except Exception as exc:  # noqa: BLE001
        raise cmuxError(f"Invalid JSON output for {' '.join(args)}: {proc.stdout!r} ({exc})")


def _docker_available() -> bool:
    if shutil.which("docker") is None:
        return False
    probe = _run(["docker", "info"], check=False)
    return probe.returncode == 0


def _curl_via_socks(proxy_port: int, target_url: str) -> str:
    if shutil.which("curl") is None:
        raise cmuxError("curl is required for SOCKS proxy verification")
    proc = _run(
        [
            "curl",
            "--silent",
            "--show-error",
            "--max-time",
            "5",
            "--socks5-hostname",
            f"127.0.0.1:{proxy_port}",
            target_url,
        ],
        check=False,
    )
    if proc.returncode != 0:
        merged = f"{proc.stdout}\n{proc.stderr}".strip()
        raise cmuxError(f"curl via SOCKS proxy failed: {merged}")
    return proc.stdout


def _find_free_loopback_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def _recv_exact(sock: socket.socket, n: int) -> bytes:
    out = bytearray()
    while len(out) < n:
        chunk = sock.recv(n - len(out))
        if not chunk:
            raise cmuxError("unexpected EOF while reading socket")
        out.extend(chunk)
    return bytes(out)


def _recv_until(sock: socket.socket, marker: bytes, limit: int = 16384) -> bytes:
    out = bytearray()
    while marker not in out:
        chunk = sock.recv(1024)
        if not chunk:
            raise cmuxError("unexpected EOF while reading response headers")
        out.extend(chunk)
        if len(out) > limit:
            raise cmuxError("response headers too large")
    return bytes(out)


def _read_socks5_connect_reply(sock: socket.socket) -> None:
    head = _recv_exact(sock, 4)
    if len(head) != 4 or head[0] != 0x05:
        raise cmuxError(f"invalid SOCKS5 reply: {head!r}")
    if head[1] != 0x00:
        raise cmuxError(f"SOCKS5 connect failed with status=0x{head[1]:02x}")

    reply_atyp = head[3]
    if reply_atyp == 0x01:
        _ = _recv_exact(sock, 4)
    elif reply_atyp == 0x03:
        ln = _recv_exact(sock, 1)[0]
        _ = _recv_exact(sock, ln)
    elif reply_atyp == 0x04:
        _ = _recv_exact(sock, 16)
    else:
        raise cmuxError(f"invalid SOCKS5 atyp in reply: 0x{reply_atyp:02x}")
    _ = _recv_exact(sock, 2)


def _read_http_response_from_connected_socket(sock: socket.socket) -> str:
    response = _recv_until(sock, b"\r\n\r\n")
    header_end = response.index(b"\r\n\r\n") + 4
    header_blob = response[:header_end]
    body = bytearray(response[header_end:])
    header_text = header_blob.decode("utf-8", errors="replace")

    status_line = header_text.split("\r\n", 1)[0]
    if "200" not in status_line:
        raise cmuxError(f"HTTP over SOCKS tunnel failed: {status_line!r}")

    content_length: int | None = None
    for line in header_text.split("\r\n")[1:]:
        if line.lower().startswith("content-length:"):
            try:
                content_length = int(line.split(":", 1)[1].strip())
            except Exception:  # noqa: BLE001
                content_length = None
            break

    if content_length is not None:
        while len(body) < content_length:
            chunk = sock.recv(4096)
            if not chunk:
                break
            body.extend(chunk)
    else:
        while True:
            try:
                chunk = sock.recv(4096)
            except socket.timeout:
                break
            if not chunk:
                break
            body.extend(chunk)

    return bytes(body).decode("utf-8", errors="replace")


def _socks5_connect(proxy_host: str, proxy_port: int, target_host: str, target_port: int) -> socket.socket:
    sock = socket.create_connection((proxy_host, proxy_port), timeout=6)
    sock.settimeout(6)

    sock.sendall(b"\x05\x01\x00")
    greeting = _recv_exact(sock, 2)
    if greeting != b"\x05\x00":
        sock.close()
        raise cmuxError(f"SOCKS5 greeting failed: {greeting!r}")

    try:
        host_bytes = socket.inet_aton(target_host)
        atyp = b"\x01"
        addr = host_bytes
    except OSError:
        host_encoded = target_host.encode("utf-8")
        if len(host_encoded) > 255:
            sock.close()
            raise cmuxError("target host too long for SOCKS5 domain form")
        atyp = b"\x03"
        addr = bytes([len(host_encoded)]) + host_encoded

    req = b"\x05\x01\x00" + atyp + addr + struct.pack("!H", target_port)
    sock.sendall(req)

    try:
        _read_socks5_connect_reply(sock)
    except Exception:
        sock.close()
        raise
    return sock


def _socks5_http_get_pipelined(proxy_host: str, proxy_port: int, target_host: str, target_port: int) -> str:
    sock = socket.create_connection((proxy_host, proxy_port), timeout=6)
    sock.settimeout(6)
    try:
        try:
            host_bytes = socket.inet_aton(target_host)
            atyp = b"\x01"
            addr = host_bytes
        except OSError:
            host_encoded = target_host.encode("utf-8")
            if len(host_encoded) > 255:
                raise cmuxError("target host too long for SOCKS5 domain form")
            atyp = b"\x03"
            addr = bytes([len(host_encoded)]) + host_encoded

        greeting = b"\x05\x01\x00"
        connect_req = b"\x05\x01\x00" + atyp + addr + struct.pack("!H", target_port)
        http_get = (
            "GET / HTTP/1.1\r\n"
            f"Host: {target_host}:{target_port}\r\n"
            "Connection: close\r\n"
            "\r\n"
        ).encode("utf-8")

        sock.sendall(greeting + connect_req + http_get)

        greeting_reply = _recv_exact(sock, 2)
        if greeting_reply != b"\x05\x00":
            raise cmuxError(f"SOCKS5 greeting failed: {greeting_reply!r}")
        _read_socks5_connect_reply(sock)
        return _read_http_response_from_connected_socket(sock)
    finally:
        try:
            sock.close()
        except Exception:
            pass


def _http_connect_tunnel(proxy_host: str, proxy_port: int, target_host: str, target_port: int) -> socket.socket:
    sock = socket.create_connection((proxy_host, proxy_port), timeout=6)
    sock.settimeout(6)
    request = (
        f"CONNECT {target_host}:{target_port} HTTP/1.1\r\n"
        f"Host: {target_host}:{target_port}\r\n"
        "Proxy-Connection: Keep-Alive\r\n"
        "\r\n"
    ).encode("utf-8")
    sock.sendall(request)
    header_blob = _recv_until(sock, b"\r\n\r\n")
    header_text = header_blob.decode("utf-8", errors="replace")
    status_line = header_text.split("\r\n", 1)[0]
    if "200" not in status_line:
        sock.close()
        raise cmuxError(f"HTTP CONNECT tunnel failed: {status_line!r}")
    return sock


def _encode_client_text_frame(payload: str) -> bytes:
    data = payload.encode("utf-8")
    first = 0x81
    mask = secrets.token_bytes(4)
    length = len(data)
    if length < 126:
        header = bytes([first, 0x80 | length])
    elif length <= 0xFFFF:
        header = bytes([first, 0x80 | 126]) + struct.pack("!H", length)
    else:
        header = bytes([first, 0x80 | 127]) + struct.pack("!Q", length)
    masked = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
    return header + mask + masked


def _read_server_text_frame(sock: socket.socket) -> str:
    first, second = _recv_exact(sock, 2)
    opcode = first & 0x0F
    masked = (second & 0x80) != 0
    length = second & 0x7F
    if length == 126:
        length = struct.unpack("!H", _recv_exact(sock, 2))[0]
    elif length == 127:
        length = struct.unpack("!Q", _recv_exact(sock, 8))[0]
    mask = _recv_exact(sock, 4) if masked else b""
    payload = _recv_exact(sock, length) if length else b""
    if masked and payload:
        payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))

    if opcode != 0x1:
        raise cmuxError(f"Expected websocket text frame opcode=0x1, got opcode=0x{opcode:x}")
    try:
        return payload.decode("utf-8")
    except Exception as exc:  # noqa: BLE001
        raise cmuxError(f"WebSocket response payload is not valid UTF-8: {exc}")


def _websocket_echo_on_connected_socket(sock: socket.socket, ws_host: str, ws_port: int, message: str, path_label: str) -> str:
    ws_key = b64encode(secrets.token_bytes(16)).decode("ascii")
    request = (
        "GET /echo HTTP/1.1\r\n"
        f"Host: {ws_host}:{ws_port}\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {ws_key}\r\n"
        "Sec-WebSocket-Version: 13\r\n"
        "\r\n"
    ).encode("utf-8")
    sock.sendall(request)
    header_blob = _recv_until(sock, b"\r\n\r\n")
    header_text = header_blob.decode("utf-8", errors="replace")
    status_line = header_text.split("\r\n", 1)[0]
    if "101" not in status_line:
        raise cmuxError(f"WebSocket handshake failed over {path_label}: {status_line!r}")

    expected_accept = b64encode(
        hashlib.sha1((ws_key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode("utf-8")).digest()
    ).decode("ascii")
    lowered_headers = {
        line.split(":", 1)[0].strip().lower(): line.split(":", 1)[1].strip()
        for line in header_text.split("\r\n")[1:]
        if ":" in line
    }
    if lowered_headers.get("sec-websocket-accept", "") != expected_accept:
        raise cmuxError(f"WebSocket handshake over {path_label} returned invalid Sec-WebSocket-Accept")

    sock.sendall(_encode_client_text_frame(message))
    return _read_server_text_frame(sock)


def _websocket_echo_via_socks(proxy_port: int, ws_host: str, ws_port: int, message: str) -> str:
    sock = _socks5_connect("127.0.0.1", proxy_port, ws_host, ws_port)
    try:
        return _websocket_echo_on_connected_socket(sock, ws_host, ws_port, message, "SOCKS proxy")
    finally:
        try:
            sock.close()
        except Exception:
            pass


def _websocket_echo_via_connect(proxy_port: int, ws_host: str, ws_port: int, message: str) -> str:
    sock = _http_connect_tunnel("127.0.0.1", proxy_port, ws_host, ws_port)
    try:
        return _websocket_echo_on_connected_socket(sock, ws_host, ws_port, message, "HTTP CONNECT proxy")
    finally:
        try:
            sock.close()
        except Exception:
            pass


def _start_container(image_tag: str, container_name: str, pubkey: str, host_ssh_port: int) -> None:
    for _ in range(20):
        proc = _run(
            [
                "docker",
                "run",
                "-d",
                "--rm",
                "--name",
                container_name,
                "-e",
                f"AUTHORIZED_KEY={pubkey}",
                "-e",
                f"REMOTE_HTTP_PORT={REMOTE_HTTP_PORT}",
                "-e",
                f"REMOTE_WS_PORT={REMOTE_WS_PORT}",
                "-p",
                f"{DOCKER_PUBLISH_ADDR}:{host_ssh_port}:22",
                image_tag,
            ],
            check=False,
        )
        if proc.returncode == 0:
            return
        time.sleep(0.5)
    merged = f"{proc.stdout}\n{proc.stderr}".strip()
    raise cmuxError(f"Failed to start ssh test container on fixed port {host_ssh_port}: {merged}")


def _wait_remote_connected(client: cmux, workspace_id: str, timeout: float) -> dict:
    deadline = time.time() + timeout
    last_status = {}
    while time.time() < deadline:
        last_status = client._call("workspace.remote.status", {"workspace_id": workspace_id}) or {}
        remote = last_status.get("remote") or {}
        proxy = remote.get("proxy") or {}
        port_value = proxy.get("port")
        proxy_port: int | None
        if isinstance(port_value, int):
            proxy_port = port_value
        elif isinstance(port_value, str) and port_value.isdigit():
            proxy_port = int(port_value)
        else:
            proxy_port = None
        if str(remote.get("state") or "") == "connected" and proxy_port is not None:
            return last_status
        time.sleep(0.5)
    raise cmuxError(f"Remote did not reach connected+proxy-ready state: {last_status}")


def _wait_remote_degraded(client: cmux, workspace_id: str, timeout: float) -> dict:
    deadline = time.time() + timeout
    last_status = {}
    while time.time() < deadline:
        last_status = client._call("workspace.remote.status", {"workspace_id": workspace_id}) or {}
        remote = last_status.get("remote") or {}
        state = str(remote.get("state") or "")
        if state in {"error", "connecting", "disconnected"}:
            return last_status
        time.sleep(0.5)
    raise cmuxError(f"Remote did not enter reconnecting/degraded state: {last_status}")


def main() -> int:
    if not _docker_available():
        print("SKIP: docker is not available")
        return 0

    cli = _find_cli_binary()
    repo_root = Path(__file__).resolve().parents[1]
    fixture_dir = repo_root / "tests" / "fixtures" / "ssh-remote"
    _must(fixture_dir.is_dir(), f"Missing docker fixture directory: {fixture_dir}")

    temp_dir = Path(tempfile.mkdtemp(prefix="cmux-ssh-reconnect-"))
    image_tag = f"cmux-ssh-test:{secrets.token_hex(4)}"
    container_name = f"cmux-ssh-reconnect-{secrets.token_hex(4)}"
    host_ssh_port = _find_free_loopback_port()
    workspace_id = ""
    container_running = False

    try:
        key_path = temp_dir / "id_ed25519"
        _run(["ssh-keygen", "-t", "ed25519", "-N", "", "-f", str(key_path)])
        pubkey = (key_path.with_suffix(".pub")).read_text(encoding="utf-8").strip()
        _must(bool(pubkey), "Generated SSH public key was empty")

        _run(["docker", "build", "-t", image_tag, str(fixture_dir)])
        _start_container(image_tag, container_name, pubkey, host_ssh_port)
        container_running = True

        with cmux(SOCKET_PATH) as client:
            payload = _run_cli_json(
                cli,
                [
                    "ssh",
                    f"root@{DOCKER_SSH_HOST}",
                    "--name",
                    "docker-ssh-reconnect",
                    "--port",
                    str(host_ssh_port),
                    "--identity",
                    str(key_path),
                    "--ssh-option",
                    "UserKnownHostsFile=/dev/null",
                    "--ssh-option",
                    "StrictHostKeyChecking=no",
                ],
            )
            workspace_id = str(payload.get("workspace_id") or "")
            workspace_ref = str(payload.get("workspace_ref") or "")
            if not workspace_id and workspace_ref.startswith("workspace:"):
                listed = client._call("workspace.list", {}) or {}
                for row in listed.get("workspaces") or []:
                    if str(row.get("ref") or "") == workspace_ref:
                        workspace_id = str(row.get("id") or "")
                        break
            _must(bool(workspace_id), f"cmux ssh output missing workspace_id: {payload}")

            first_status = _wait_remote_connected(client, workspace_id, timeout=45.0)
            first_daemon = ((first_status.get("remote") or {}).get("daemon") or {})
            _must(str(first_daemon.get("state") or "") == "ready", f"daemon should be ready after first connect: {first_status}")
            first_capabilities = {str(item) for item in (first_daemon.get("capabilities") or [])}
            _must("proxy.stream" in first_capabilities, f"daemon should advertise proxy.stream: {first_status}")
            _must("proxy.socks5" in first_capabilities, f"daemon should advertise proxy.socks5: {first_status}")
            _must("proxy.http_connect" in first_capabilities, f"daemon should advertise proxy.http_connect: {first_status}")
            first_proxy = ((first_status.get("remote") or {}).get("proxy") or {})
            first_proxy_port = first_proxy.get("port")
            if isinstance(first_proxy_port, str) and first_proxy_port.isdigit():
                first_proxy_port = int(first_proxy_port)
            _must(isinstance(first_proxy_port, int), f"connected status should include proxy port: {first_status}")

            first_body = ""
            first_deadline_http = time.time() + 15.0
            while time.time() < first_deadline_http:
                try:
                    first_body = _curl_via_socks(int(first_proxy_port), f"http://127.0.0.1:{REMOTE_HTTP_PORT}/")
                except Exception:
                    time.sleep(0.5)
                    continue
                if "cmux-ssh-forward-ok" in first_body:
                    break
                time.sleep(0.3)
            _must("cmux-ssh-forward-ok" in first_body, f"Forwarded HTTP endpoint failed before reconnect: {first_body[:120]!r}")
            first_pipelined_body = _socks5_http_get_pipelined("127.0.0.1", int(first_proxy_port), "127.0.0.1", REMOTE_HTTP_PORT)
            _must(
                "cmux-ssh-forward-ok" in first_pipelined_body,
                f"SOCKS pipelined greeting/connect+payload failed before reconnect: {first_pipelined_body[:120]!r}",
            )

            first_ws_socks_message = "cmux-reconnect-before-over-socks"
            echoed_before_socks = _websocket_echo_via_socks(int(first_proxy_port), "127.0.0.1", REMOTE_WS_PORT, first_ws_socks_message)
            _must(
                echoed_before_socks == first_ws_socks_message,
                f"WebSocket echo over SOCKS proxy failed before reconnect: {echoed_before_socks!r} != {first_ws_socks_message!r}",
            )

            first_ws_connect_message = "cmux-reconnect-before-over-connect"
            echoed_before_connect = _websocket_echo_via_connect(int(first_proxy_port), "127.0.0.1", REMOTE_WS_PORT, first_ws_connect_message)
            _must(
                echoed_before_connect == first_ws_connect_message,
                f"WebSocket echo over CONNECT proxy failed before reconnect: {echoed_before_connect!r} != {first_ws_connect_message!r}",
            )

            _run(["docker", "rm", "-f", container_name], check=False)
            container_running = False
            _wait_remote_degraded(client, workspace_id, timeout=20.0)

            _start_container(image_tag, container_name, pubkey, host_ssh_port)
            container_running = True

            second_status = _wait_remote_connected(client, workspace_id, timeout=60.0)
            second_daemon = ((second_status.get("remote") or {}).get("daemon") or {})
            _must(str(second_daemon.get("state") or "") == "ready", f"daemon should be ready after reconnect: {second_status}")
            second_capabilities = {str(item) for item in (second_daemon.get("capabilities") or [])}
            _must("proxy.stream" in second_capabilities, f"daemon should advertise proxy.stream after reconnect: {second_status}")
            _must("proxy.socks5" in second_capabilities, f"daemon should advertise proxy.socks5 after reconnect: {second_status}")
            _must("proxy.http_connect" in second_capabilities, f"daemon should advertise proxy.http_connect after reconnect: {second_status}")
            second_proxy = ((second_status.get("remote") or {}).get("proxy") or {})
            second_proxy_port = second_proxy.get("port")
            if isinstance(second_proxy_port, str) and second_proxy_port.isdigit():
                second_proxy_port = int(second_proxy_port)
            _must(isinstance(second_proxy_port, int), f"reconnected status should include proxy port: {second_status}")

            second_body = ""
            deadline_http = time.time() + 15.0
            while time.time() < deadline_http:
                try:
                    second_body = _curl_via_socks(int(second_proxy_port), f"http://127.0.0.1:{REMOTE_HTTP_PORT}/")
                except Exception:
                    time.sleep(0.5)
                    continue
                if "cmux-ssh-forward-ok" in second_body:
                    break
                time.sleep(0.3)
            _must("cmux-ssh-forward-ok" in second_body, f"Forwarded HTTP endpoint failed after reconnect: {second_body[:120]!r}")
            second_pipelined_body = _socks5_http_get_pipelined("127.0.0.1", int(second_proxy_port), "127.0.0.1", REMOTE_HTTP_PORT)
            _must(
                "cmux-ssh-forward-ok" in second_pipelined_body,
                f"SOCKS pipelined greeting/connect+payload failed after reconnect: {second_pipelined_body[:120]!r}",
            )

            second_ws_socks_message = "cmux-reconnect-after-over-socks"
            echoed_after_socks = _websocket_echo_via_socks(int(second_proxy_port), "127.0.0.1", REMOTE_WS_PORT, second_ws_socks_message)
            _must(
                echoed_after_socks == second_ws_socks_message,
                f"WebSocket echo over SOCKS proxy failed after reconnect: {echoed_after_socks!r} != {second_ws_socks_message!r}",
            )

            second_ws_connect_message = "cmux-reconnect-after-over-connect"
            echoed_after_connect = _websocket_echo_via_connect(int(second_proxy_port), "127.0.0.1", REMOTE_WS_PORT, second_ws_connect_message)
            _must(
                echoed_after_connect == second_ws_connect_message,
                f"WebSocket echo over CONNECT proxy failed after reconnect: {echoed_after_connect!r} != {second_ws_connect_message!r}",
            )

            try:
                client.close_workspace(workspace_id)
            except Exception:
                pass
            workspace_id = ""

        print("PASS: docker SSH remote reconnects and re-establishes HTTP + WebSocket egress over SOCKS and CONNECT")
        return 0

    finally:
        if workspace_id:
            try:
                with cmux(SOCKET_PATH) as cleanup_client:
                    cleanup_client.close_workspace(workspace_id)
            except Exception:
                pass

        if container_running:
            _run(["docker", "rm", "-f", container_name], check=False)
        _run(["docker", "rmi", "-f", image_tag], check=False)
        shutil.rmtree(temp_dir, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
