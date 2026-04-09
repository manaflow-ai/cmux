#!/usr/bin/env python3
"""Docker integration: remote SSH proxy endpoint via `cmux ssh`."""

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
MAX_REMOTE_DAEMON_SIZE_BYTES = int(os.environ.get("CMUX_SSH_TEST_MAX_DAEMON_SIZE_BYTES", "15000000"))
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


def _parse_host_port(docker_port_output: str) -> int:
    # docker port output form: "127.0.0.1:49154\n" or ":::\d+".
    text = docker_port_output.strip()
    if not text:
        raise cmuxError("docker port output was empty")
    last = text.split(":")[-1]
    return int(last)


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


def _shell_single_quote(value: str) -> str:
    return "'" + value.replace("'", "'\"'\"'") + "'"


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

    atyp = head[3]
    if atyp == 0x01:
        _ = _recv_exact(sock, 4)
    elif atyp == 0x03:
        ln = _recv_exact(sock, 1)[0]
        _ = _recv_exact(sock, ln)
    elif atyp == 0x04:
        _ = _recv_exact(sock, 16)
    else:
        raise cmuxError(f"invalid SOCKS5 atyp in reply: 0x{atyp:02x}")
    _ = _recv_exact(sock, 2)  # bound port


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


def _http_get_on_connected_socket(sock: socket.socket, host: str, port: int, path: str = "/") -> str:
    request = (
        f"GET {path} HTTP/1.1\r\n"
        f"Host: {host}:{port}\r\n"
        "Connection: close\r\n"
        "\r\n"
    ).encode("utf-8")
    sock.sendall(request)
    return _read_http_response_from_connected_socket(sock)


def _socks5_connect(proxy_host: str, proxy_port: int, target_host: str, target_port: int) -> socket.socket:
    sock = socket.create_connection((proxy_host, proxy_port), timeout=6)
    sock.settimeout(6)

    # greeting: no-auth only
    sock.sendall(b"\x05\x01\x00")
    greeting = _recv_exact(sock, 2)
    if greeting != b"\x05\x00":
        sock.close()
        raise cmuxError(f"SOCKS5 greeting failed: {greeting!r}")

    try:
        host_bytes = socket.inet_aton(target_host)
        atyp = b"\x01"  # IPv4
        addr = host_bytes
    except OSError:
        host_encoded = target_host.encode("utf-8")
        if len(host_encoded) > 255:
            sock.close()
            raise cmuxError("target host too long for SOCKS5 domain form")
        atyp = b"\x03"  # domain
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

        # Send greeting + CONNECT + first upstream payload in one write to exercise
        # SOCKS request parsing when pending bytes already exist in the handshake buffer.
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
    first = 0x81  # FIN + text
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


def _ssh_run(host: str, host_port: int, key_path: Path, script: str, *, check: bool = True) -> subprocess.CompletedProcess[str]:
    return _run(
        [
            "ssh",
            "-o",
            "UserKnownHostsFile=/dev/null",
            "-o",
            "StrictHostKeyChecking=no",
            "-o",
            "ConnectTimeout=5",
            "-p",
            str(host_port),
            "-i",
            str(key_path),
            host,
            f"sh -lc {_shell_single_quote(script)}",
        ],
        check=check,
    )


def _wait_for_ssh(host: str, host_port: int, key_path: Path, timeout: float = 20.0) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        probe = _ssh_run(host, host_port, key_path, "echo ready", check=False)
        if probe.returncode == 0 and "ready" in probe.stdout:
            return
        time.sleep(0.5)
    raise cmuxError("Timed out waiting for SSH server in docker fixture to become ready")


def _remote_binary_size_bytes(host: str, host_port: int, key_path: Path, remote_path: str) -> int:
    script = f"""
set -eu
p={_shell_single_quote(remote_path)}
case "$p" in
  /*) full="$p" ;;
  *) full="$HOME/$p" ;;
esac
test -x "$full"
wc -c < "$full"
"""
    proc = _ssh_run(host, host_port, key_path, script, check=True)
    text = proc.stdout.strip().splitlines()[-1].strip()
    return int(text)


def _extract_daemon_version_platform(remote_path: str) -> tuple[str, str]:
    parts = [segment for segment in remote_path.strip().split("/") if segment]
    try:
        marker_index = parts.index("cmuxd-remote")
    except ValueError as exc:
        raise cmuxError(f"remote daemon path missing cmuxd-remote marker: {remote_path!r}") from exc

    required_len = marker_index + 4
    _must(
        len(parts) >= required_len,
        f"remote daemon path should include version/platform/binary: {remote_path!r}",
    )
    version = parts[marker_index + 1]
    platform = parts[marker_index + 2]
    binary_name = parts[marker_index + 3]
    _must(binary_name == "cmuxd-remote", f"unexpected daemon binary name in remote path: {remote_path!r}")
    _must(bool(version), f"daemon version should not be empty in remote path: {remote_path!r}")
    _must(bool(platform), f"daemon platform should not be empty in remote path: {remote_path!r}")
    return version, platform


def _local_cached_daemon_binary(version: str, platform: str) -> Path:
    return Path(tempfile.gettempdir()) / "cmux-remote-daemon-build" / version / platform / "cmuxd-remote"


def _local_file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _local_binary_contains_version_marker(path: Path, version: str) -> bool:
    marker = version.encode("utf-8")
    tail = b""
    with path.open("rb") as handle:
        while True:
            chunk = handle.read(1024 * 1024)
            if not chunk:
                return False
            haystack = tail + chunk
            if marker in haystack:
                return True
            tail = haystack[-max(len(marker) - 1, 0) :]


def _remote_binary_sha256(host: str, host_port: int, key_path: Path, remote_path: str) -> str:
    script = f"""
set -eu
p={_shell_single_quote(remote_path)}
case "$p" in
  /*) full="$p" ;;
  *) full="$HOME/$p" ;;
esac
test -x "$full"
if command -v sha256sum >/dev/null 2>&1; then
  sha256sum "$full" | awk '{{print $1}}'
elif command -v shasum >/dev/null 2>&1; then
  shasum -a 256 "$full" | awk '{{print $1}}'
else
  openssl dgst -sha256 "$full" | awk '{{print $NF}}'
fi
"""
    proc = _ssh_run(host, host_port, key_path, script, check=True)
    digest = proc.stdout.strip().splitlines()[-1].strip().lower()
    _must(len(digest) == 64 and all(ch in "0123456789abcdef" for ch in digest), f"invalid remote SHA256 digest: {digest!r}")
    return digest


def _wait_connected_proxy_port(client: cmux, workspace_id: str, timeout: float = 45.0) -> tuple[dict, int]:
    deadline = time.time() + timeout
    last_status = {}
    proxy_port: int | None = None
    while time.time() < deadline:
        last_status = client._call("workspace.remote.status", {"workspace_id": workspace_id}) or {}
        remote = last_status.get("remote") or {}
        state = str(remote.get("state") or "")
        proxy = remote.get("proxy") or {}
        port_value = proxy.get("port")
        if isinstance(port_value, int):
            proxy_port = port_value
        elif isinstance(port_value, str) and port_value.isdigit():
            proxy_port = int(port_value)
        if state == "connected" and proxy_port is not None:
            return last_status, proxy_port
        time.sleep(0.5)
    raise cmuxError(f"Remote proxy did not converge to connected state: {last_status}")


def main() -> int:
    if not _docker_available():
        print("SKIP: docker is not available")
        return 0

    cli = _find_cli_binary()
    repo_root = Path(__file__).resolve().parents[1]
    fixture_dir = repo_root / "tests" / "fixtures" / "ssh-remote"
    _must(fixture_dir.is_dir(), f"Missing docker fixture directory: {fixture_dir}")

    temp_dir = Path(tempfile.mkdtemp(prefix="cmux-ssh-docker-"))
    image_tag = f"cmux-ssh-test:{secrets.token_hex(4)}"
    container_name = f"cmux-ssh-test-{secrets.token_hex(4)}"
    workspace_id = ""
    workspace_id_shared = ""

    try:
        key_path = temp_dir / "id_ed25519"
        _run(["ssh-keygen", "-t", "ed25519", "-N", "", "-f", str(key_path)])
        pubkey = (key_path.with_suffix(".pub")).read_text(encoding="utf-8").strip()
        _must(bool(pubkey), "Generated SSH public key was empty")

        _run(["docker", "build", "-t", image_tag, str(fixture_dir)])
        _run([
            "docker", "run", "-d", "--rm",
            "--name", container_name,
            "-e", f"AUTHORIZED_KEY={pubkey}",
            "-e", f"REMOTE_HTTP_PORT={REMOTE_HTTP_PORT}",
            "-p", f"{DOCKER_PUBLISH_ADDR}::22",
            image_tag,
        ])

        port_info = _run(["docker", "port", container_name, "22/tcp"]).stdout
        host_ssh_port = _parse_host_port(port_info)
        host = f"root@{DOCKER_SSH_HOST}"
        _wait_for_ssh(host, host_ssh_port, key_path)

        fresh_check = _ssh_run(
            host,
            host_ssh_port,
            key_path,
            "test ! -e \"$HOME/.cmux/bin/cmuxd-remote\" && echo fresh",
            check=True,
        )
        _must("fresh" in fresh_check.stdout, "Fresh container should not have preinstalled cmuxd-remote")

        with cmux(SOCKET_PATH) as client:
            payload = _run_cli_json(
                cli,
                [
                    "ssh",
                    host,
                    "--name", "docker-ssh-forward",
                    "--port", str(host_ssh_port),
                    "--identity", str(key_path),
                    "--ssh-option", "UserKnownHostsFile=/dev/null",
                    "--ssh-option", "StrictHostKeyChecking=no",
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

            last_status, proxy_port = _wait_connected_proxy_port(client, workspace_id)

            daemon = ((last_status.get("remote") or {}).get("daemon") or {})
            _must(str(daemon.get("state") or "") == "ready", f"daemon should be ready in connected state: {last_status}")
            capabilities = daemon.get("capabilities") or []
            _must("proxy.stream" in capabilities, f"daemon hello capabilities missing proxy.stream: {daemon}")
            _must("proxy.socks5" in capabilities, f"daemon hello capabilities missing proxy.socks5: {daemon}")
            _must("session.basic" in capabilities, f"daemon hello capabilities missing session.basic: {daemon}")
            _must("session.resize.min" in capabilities, f"daemon hello capabilities missing session.resize.min: {daemon}")
            remote_path = str(daemon.get("remote_path") or "").strip()
            _must(bool(remote_path), f"daemon ready state should include remote_path: {daemon}")

            binary_size_bytes = _remote_binary_size_bytes(host, host_ssh_port, key_path, remote_path)
            _must(binary_size_bytes > 0, f"uploaded daemon binary should be non-empty: {binary_size_bytes}")
            _must(
                binary_size_bytes <= MAX_REMOTE_DAEMON_SIZE_BYTES,
                f"uploaded daemon binary too large: {binary_size_bytes} bytes > {MAX_REMOTE_DAEMON_SIZE_BYTES}",
            )
            daemon_version, daemon_platform = _extract_daemon_version_platform(remote_path)
            local_cached_binary = _local_cached_daemon_binary(daemon_version, daemon_platform)
            _must(
                local_cached_binary.is_file(),
                f"expected local daemon cache artifact at {local_cached_binary} after bootstrap upload",
            )
            _must(
                os.access(local_cached_binary, os.X_OK),
                f"local daemon cache artifact must be executable: {local_cached_binary}",
            )
            _must(
                _local_binary_contains_version_marker(local_cached_binary, daemon_version),
                f"local cached daemon binary should embed daemon version marker {daemon_version!r}: {local_cached_binary}",
            )
            local_sha256 = _local_file_sha256(local_cached_binary)
            remote_sha256 = _remote_binary_sha256(host, host_ssh_port, key_path, remote_path)
            _must(
                local_sha256 == remote_sha256,
                "uploaded daemon binary hash should match local cached build artifact "
                f"(local={local_sha256}, remote={remote_sha256})",
            )

            body = ""
            deadline_http = time.time() + 15.0
            while time.time() < deadline_http:
                try:
                    body = _curl_via_socks(proxy_port, f"http://127.0.0.1:{REMOTE_HTTP_PORT}/")
                except Exception:
                    time.sleep(0.5)
                    continue
                if "cmux-ssh-forward-ok" in body:
                    break
                time.sleep(0.3)

            _must("cmux-ssh-forward-ok" in body, f"Forwarded HTTP endpoint returned unexpected body: {body[:120]!r}")
            pipelined_body = _socks5_http_get_pipelined("127.0.0.1", proxy_port, "127.0.0.1", REMOTE_HTTP_PORT)
            _must(
                "cmux-ssh-forward-ok" in pipelined_body,
                f"SOCKS pipelined greeting/connect+payload path returned unexpected body: {pipelined_body[:120]!r}",
            )

            ws_message = "cmux-ws-over-socks-ok"
            echoed_message = _websocket_echo_via_socks(proxy_port, "127.0.0.1", REMOTE_WS_PORT, ws_message)
            _must(
                echoed_message == ws_message,
                f"WebSocket echo over SOCKS proxy mismatch: {echoed_message!r} != {ws_message!r}",
            )

            ws_connect_message = "cmux-ws-over-connect-ok"
            echoed_connect = _websocket_echo_via_connect(proxy_port, "127.0.0.1", REMOTE_WS_PORT, ws_connect_message)
            _must(
                echoed_connect == ws_connect_message,
                f"WebSocket echo over CONNECT proxy mismatch: {echoed_connect!r} != {ws_connect_message!r}",
            )

            payload_shared = _run_cli_json(
                cli,
                [
                    "ssh",
                    host,
                    "--name", "docker-ssh-forward-shared",
                    "--port", str(host_ssh_port),
                    "--identity", str(key_path),
                    "--ssh-option", "UserKnownHostsFile=/dev/null",
                    "--ssh-option", "StrictHostKeyChecking=no",
                ],
            )
            workspace_id_shared = str(payload_shared.get("workspace_id") or "")
            workspace_ref_shared = str(payload_shared.get("workspace_ref") or "")
            if not workspace_id_shared and workspace_ref_shared.startswith("workspace:"):
                listed_shared = client._call("workspace.list", {}) or {}
                for row in listed_shared.get("workspaces") or []:
                    if str(row.get("ref") or "") == workspace_ref_shared:
                        workspace_id_shared = str(row.get("id") or "")
                        break
            _must(bool(workspace_id_shared), f"cmux ssh output missing workspace_id for shared transport test: {payload_shared}")

            _, shared_proxy_port = _wait_connected_proxy_port(client, workspace_id_shared)
            _must(
                shared_proxy_port == proxy_port,
                f"identical SSH transports should share one local proxy endpoint: {proxy_port} vs {shared_proxy_port}",
            )

            try:
                client.close_workspace(workspace_id_shared)
                workspace_id_shared = ""
            except Exception:
                pass

            try:
                client.close_workspace(workspace_id)
                workspace_id = ""
            except Exception:
                pass

        print(
            "PASS: docker SSH proxy endpoint is reachable, handles HTTP + WebSocket egress over SOCKS and CONNECT through remote host, and is shared across identical transports; "
            f"uploaded cmuxd-remote size={binary_size_bytes} bytes, version={daemon_version}, platform={daemon_platform}"
        )
        return 0

    finally:
        if workspace_id:
            try:
                with cmux(SOCKET_PATH) as cleanup_client:
                    cleanup_client.close_workspace(workspace_id)
            except Exception:
                pass

        if workspace_id_shared:
            try:
                with cmux(SOCKET_PATH) as cleanup_client:
                    cleanup_client.close_workspace(workspace_id_shared)
            except Exception:
                pass

        _run(["docker", "rm", "-f", container_name], check=False)
        _run(["docker", "rmi", "-f", image_tag], check=False)
        shutil.rmtree(temp_dir, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
