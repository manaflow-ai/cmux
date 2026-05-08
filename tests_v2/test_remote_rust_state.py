#!/usr/bin/env python3
"""
Focused coverage for Rust-owned workspace.remote state.

This test intentionally covers model-only remote paths so CMX should handle the
state locally without asking the Swift native worker to start SSH/proxy side
effects.
"""

import os
import base64
import hashlib
import json
import socket
import struct
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET_PATH", "/tmp/cmux-debug.sock")


def _remote(result: dict, label: str) -> dict:
    remote = (result or {}).get("remote")
    if not isinstance(remote, dict):
        raise cmuxError(f"{label} returned no remote payload: {result}")
    return remote


def _must(condition: bool, message: str) -> None:
    if not condition:
        raise cmuxError(message)


def _assert_model_connected(result: dict, label: str) -> dict:
    remote = _remote(result, label)
    _must(remote.get("configured_by") == "cmx-rust", f"{label} should be Rust configured: {result}")
    _must(remote.get("connected_by") == "cmx-rust", f"{label} should be Rust connected: {result}")
    _must(
        remote.get("connection_owner") == "cmx-rust-model",
        f"{label} should be model-only Rust owned: {result}",
    )
    _must(remote.get("state") == "connected", f"{label} should report connected: {result}")
    _must(remote.get("connected") is True, f"{label} should set connected=true: {result}")
    return remote


def _recv_exact(conn: socket.socket, byte_count: int) -> bytes:
    chunks = []
    remaining = byte_count
    while remaining:
        chunk = conn.recv(remaining)
        if not chunk:
            raise RuntimeError("socket closed while reading")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def _recv_ws_json(conn: socket.socket) -> dict | None:
    while True:
        header = _recv_exact(conn, 2)
        first, second = header[0], header[1]
        opcode = first & 0x0F
        masked = bool(second & 0x80)
        length = second & 0x7F
        if length == 126:
            length = struct.unpack("!H", _recv_exact(conn, 2))[0]
        elif length == 127:
            length = struct.unpack("!Q", _recv_exact(conn, 8))[0]
        mask = _recv_exact(conn, 4) if masked else b""
        payload = _recv_exact(conn, length) if length else b""
        if masked:
            payload = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
        if opcode == 0x8:
            return None
        if opcode == 0x9:
            _send_ws_text(conn, "")
            continue
        if opcode in (0x1, 0x2):
            return json.loads(payload.decode("utf-8"))


def _send_ws_text(conn: socket.socket, payload: str) -> None:
    data = payload.encode("utf-8")
    if len(data) < 126:
        header = bytes([0x81, len(data)])
    elif len(data) <= 0xFFFF:
        header = bytes([0x81, 126]) + struct.pack("!H", len(data))
    else:
        header = bytes([0x81, 127]) + struct.pack("!Q", len(data))
    conn.sendall(header + data)


class FakeRemoteDaemonWebSocket:
    def __init__(self) -> None:
        self._server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self._server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._server.bind(("127.0.0.1", 0))
        self._server.listen(1)
        self.port = int(self._server.getsockname()[1])
        self.url = f"ws://127.0.0.1:{self.port}/daemon"
        self.events: list[dict] = []
        self._active_conn: socket.socket | None = None
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._run, name="fake-cmuxd-ws", daemon=True)
        self._thread.start()

    def close(self) -> None:
        self._stop.set()
        try:
            self._server.close()
        except OSError:
            pass
        self._thread.join(timeout=2.0)

    def drop_active_connection(self) -> None:
        conn = self._active_conn
        if conn is None:
            return
        try:
            conn.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        try:
            conn.close()
        except OSError:
            pass

    def wait_for_event(self, predicate, label: str, timeout: float = 5.0) -> dict:
        deadline = time.time() + timeout
        while time.time() < deadline:
            for event in list(self.events):
                if predicate(event):
                    return event
            time.sleep(0.05)
        raise cmuxError(f"timed out waiting for fake daemon event {label}: {self.events}")

    def _run(self) -> None:
        try:
            self._server.settimeout(0.25)
            while not self._stop.is_set():
                try:
                    conn, _ = self._server.accept()
                except socket.timeout:
                    continue
                except OSError:
                    return
                self._active_conn = conn
                with conn:
                    self._handshake(conn)
                    stream_id = f"stream-rust-proxy-{len(self.events) + 1}"
                    while not self._stop.is_set():
                        payload = _recv_ws_json(conn)
                        if payload is None:
                            break
                        self.events.append(payload)
                        if payload.get("type") == "auth":
                            continue
                        request_id = payload.get("id")
                        method = payload.get("method")
                        params = payload.get("params") or {}
                        if method == "hello":
                            self._reply(
                                conn,
                                request_id,
                                {
                                    "name": "cmuxd-remote",
                                    "version": "fake-rust-proxy",
                                    "capabilities": [
                                        "session.basic",
                                        "session.resize.min",
                                        "proxy.http_connect",
                                        "proxy.socks5",
                                        "proxy.stream",
                                        "proxy.stream.push",
                                    ],
                                    "remote_path": "/fake/cmuxd-remote",
                                },
                            )
                        elif method == "proxy.open":
                            self._reply(conn, request_id, {"stream_id": stream_id})
                        elif method == "proxy.stream.subscribe":
                            self._reply(conn, request_id, {})
                        elif method == "proxy.write":
                            self._reply(conn, request_id, {})
                            data = base64.b64decode(str(params.get("data_base64") or ""))
                            self.events.append(
                                {
                                    "method": "proxy.write.decoded",
                                    "data": data.decode("utf-8", errors="replace"),
                                }
                            )
                            if b"GET /through-rust" in data:
                                body = b"CMX Rust proxy ok\n"
                                response = (
                                    b"HTTP/1.1 200 OK\r\n"
                                    b"Location: http://localhost/next\r\n"
                                    b"Set-Cookie: cmx=1; Domain=localhost\r\n"
                                    + b"Content-Length: "
                                    + str(len(body)).encode("ascii")
                                    + b"\r\nConnection: close\r\n\r\n"
                                    + body
                                )
                                encoded = base64.b64encode(response).decode("ascii")
                                _send_ws_text(
                                    conn,
                                    json.dumps(
                                        {
                                            "event": "proxy.stream.data",
                                            "stream_id": stream_id,
                                            "data_base64": encoded,
                                        }
                                    ),
                                )
                                _send_ws_text(
                                    conn,
                                    json.dumps(
                                        {
                                            "event": "proxy.stream.eof",
                                            "stream_id": stream_id,
                                            "data_base64": "",
                                        }
                                    ),
                                )
                        elif method == "proxy.close":
                            self._reply(conn, request_id, {})
                        else:
                            self._send_error(conn, request_id, "unsupported", f"unsupported {method}")
                self._active_conn = None
        except Exception as exc:
            self.events.append({"error": str(exc)})
            self._active_conn = None

    def _handshake(self, conn: socket.socket) -> None:
        request = b""
        while b"\r\n\r\n" not in request:
            chunk = conn.recv(4096)
            if not chunk:
                raise RuntimeError("websocket handshake closed")
            request += chunk
        headers = {}
        for line in request.decode("utf-8", errors="replace").split("\r\n")[1:]:
            if ":" in line:
                key, value = line.split(":", 1)
                headers[key.strip().lower()] = value.strip()
        key = headers.get("sec-websocket-key")
        if not key:
            raise RuntimeError("missing Sec-WebSocket-Key")
        accept = base64.b64encode(
            hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode("ascii")).digest()
        ).decode("ascii")
        conn.sendall(
            (
                "HTTP/1.1 101 Switching Protocols\r\n"
                "Upgrade: websocket\r\n"
                "Connection: Upgrade\r\n"
                f"Sec-WebSocket-Accept: {accept}\r\n"
                "\r\n"
            ).encode("ascii")
        )

    def _reply(self, conn: socket.socket, request_id, result: dict) -> None:
        _send_ws_text(conn, json.dumps({"id": request_id, "ok": True, "result": result}))

    def _send_error(self, conn: socket.socket, request_id, code: str, message: str) -> None:
        _send_ws_text(
            conn,
            json.dumps({"id": request_id, "ok": False, "error": {"code": code, "message": message}}),
        )


def _exercise_socks_proxy(proxy_port: int) -> bytes:
    with socket.create_connection(("127.0.0.1", proxy_port), timeout=5.0) as conn:
        conn.settimeout(5.0)
        conn.sendall(bytes([0x05, 0x01, 0x00]))
        greeting = _recv_exact(conn, 2)
        _must(greeting == bytes([0x05, 0x00]), f"unexpected SOCKS greeting response: {greeting!r}")

        host = b"cmux-loopback.localtest.me"
        request = (
            bytes([0x05, 0x01, 0x00, 0x03, len(host)])
            + host
            + bytes([0x00, 0x50])
        )
        conn.sendall(request)
        connect_response = _recv_exact(conn, 10)
        _must(
            connect_response[:2] == bytes([0x05, 0x00]),
            f"unexpected SOCKS connect response: {connect_response!r}",
        )
        conn.sendall(
            b"GET /through-rust HTTP/1.1\r\n"
            b"Host: cmux-loopback.localtest.me\r\n"
            b"Connection: close\r\n\r\n"
        )
        chunks = []
        while True:
            chunk = conn.recv(4096)
            if not chunk:
                break
            chunks.append(chunk)
        return b"".join(chunks)


def _wait_for_remote_state(c, workspace_id: str, state: str, timeout: float = 5.0) -> dict:
    deadline = time.time() + timeout
    last = {}
    while time.time() < deadline:
        last = c._call("workspace.remote.status", {"workspace_id": workspace_id}) or {}
        remote = _remote(last, f"workspace.remote.status waiting for {state}")
        if remote.get("state") == state:
            return remote
        time.sleep(0.1)
    raise cmuxError(f"timed out waiting for remote state {state}: {last}")


def main() -> int:
    with cmux(SOCKET_PATH) as c:
        workspace_id = c.new_workspace()
        c.select_workspace(workspace_id)
        surfaces = c.list_surfaces(workspace_id)
        _must(len(surfaces) == 1, f"new workspace should start with one surface: {surfaces}")
        surface_id = surfaces[0][1]

        relay_port = 23001
        configured = c._call(
            "workspace.remote.configure",
            {
                "workspace_id": workspace_id,
                "destination": "rust-state.example.com",
                "auto_connect": False,
                "terminal_startup_command": "printf cmx-remote-state\\n",
                "relay_port": relay_port,
                "relay_id": "rust-state-relay",
                "relay_token": "a" * 64,
            },
        ) or {}
        configured_remote = _remote(configured, "workspace.remote.configure")
        _must(
            configured_remote.get("configured_by") == "cmx-rust",
            f"configure should stay Rust-owned: {configured}",
        )
        _must(
            configured_remote.get("relay_port") == relay_port,
            f"configure should store relay_port: {configured}",
        )
        _must(
            int(configured_remote.get("active_terminal_sessions") or 0) == 1,
            f"configure should seed one active remote terminal session: {configured}",
        )
        _must(
            surface_id
            in {str(value) for value in configured_remote.get("active_terminal_surface_ids") or []},
            f"configure should track the seeded terminal surface id: {configured}",
        )

        status = c._call("workspace.remote.status", {"workspace_id": workspace_id}) or {}
        status_remote = _remote(status, "workspace.remote.status")
        _must(
            int(status_remote.get("active_terminal_sessions") or 0) == 1,
            f"status should preserve Rust-owned active terminal count: {status}",
        )

        ended = c._call(
            "workspace.remote.terminal_session_end",
            {
                "workspace_id": workspace_id,
                "surface_id": surface_id,
                "relay_port": relay_port,
            },
        ) or {}
        ended_remote = _remote(ended, "workspace.remote.terminal_session_end")
        _must(
            str(ended.get("surface_id") or ended.get("surface_ref") or "") == surface_id,
            f"end should echo surface id: {ended}",
        )
        _must(int(ended.get("relay_port") or 0) == relay_port, f"end should echo relay_port: {ended}")
        _must(
            int(ended_remote.get("active_terminal_sessions") or 0) == 0,
            f"terminal_session_end should clear active terminal count: {ended}",
        )
        _must(
            ended_remote.get("enabled") is False,
            f"last Rust-owned remote terminal without browsers should demote workspace to local: {ended}",
        )

        final_status = c._call("workspace.remote.status", {"workspace_id": workspace_id}) or {}
        final_remote = _remote(final_status, "final workspace.remote.status")
        _must(
            final_remote.get("enabled") is False,
            f"final status should remain local after demotion: {final_status}",
        )

        vm_workspace_id = c.new_workspace()
        vm_configured = c._call(
            "workspace.remote.configure",
            {
                "workspace_id": vm_workspace_id,
                "destination": "vm-rust-model.example.com",
                "port": 2222,
                "auto_connect": True,
                "skip_daemon_bootstrap": True,
            },
        ) or {}
        vm_remote = _assert_model_connected(vm_configured, "vm workspace.remote.configure")
        _must(
            (vm_remote.get("daemon") or {}).get("state") == "ready",
            f"VM model configure should synthesize baked daemon readiness: {vm_configured}",
        )
        _must(
            (vm_remote.get("proxy") or {}).get("state") == "unavailable",
            f"VM model configure should leave proxy unavailable: {vm_configured}",
        )
        _must(
            "VM, proxy disabled" in str(vm_remote.get("detail") or ""),
            f"VM model configure should match Swift no-proxy detail: {vm_configured}",
        )

        vm_status = c._call("workspace.remote.status", {"workspace_id": vm_workspace_id}) or {}
        _assert_model_connected(vm_status, "vm workspace.remote.status")

        vm_disconnected = c._call(
            "workspace.remote.disconnect",
            {"workspace_id": vm_workspace_id},
        ) or {}
        vm_disconnected_remote = _remote(vm_disconnected, "vm workspace.remote.disconnect")
        _must(
            vm_disconnected.get("disconnectedBy") == "cmx-rust",
            f"VM model disconnect should stay Rust-local: {vm_disconnected}",
        )
        _must(
            vm_disconnected_remote.get("state") == "disconnected"
            and vm_disconnected_remote.get("connected") is False,
            f"VM model disconnect should transition to disconnected: {vm_disconnected}",
        )

        vm_reconnected = c._call(
            "workspace.remote.reconnect",
            {"workspace_id": vm_workspace_id},
        ) or {}
        _assert_model_connected(vm_reconnected, "vm workspace.remote.reconnect")
        c._call("workspace.remote.disconnect", {"workspace_id": vm_workspace_id, "clear": True})

        websocket_workspace_id = c.new_workspace()
        websocket_configured = c._call(
            "workspace.remote.configure",
            {
                "workspace_id": websocket_workspace_id,
                "destination": "ws-rust-model.example.com",
                "transport": "websocket",
                "auto_connect": True,
            },
        ) or {}
        websocket_remote = _assert_model_connected(
            websocket_configured,
            "websocket workspace.remote.configure",
        )
        _must(
            (websocket_remote.get("daemon") or {}).get("state") == "unavailable",
            f"websocket model configure without endpoint should not synthesize daemon readiness: {websocket_configured}",
        )
        websocket_disconnected = c._call(
            "workspace.remote.disconnect",
            {"workspace_id": websocket_workspace_id},
        ) or {}
        _must(
            websocket_disconnected.get("disconnectedBy") == "cmx-rust",
            f"websocket model disconnect should stay Rust-local: {websocket_disconnected}",
        )
        websocket_reconnected = c._call(
            "workspace.remote.reconnect",
            {"workspace_id": websocket_workspace_id},
        ) or {}
        _assert_model_connected(websocket_reconnected, "websocket workspace.remote.reconnect")
        c._call(
            "workspace.remote.disconnect",
            {"workspace_id": websocket_workspace_id, "clear": True},
        )

        auth_workspace_id = c.new_workspace()
        auth_configured = c._call(
            "workspace.remote.configure",
            {
                "workspace_id": auth_workspace_id,
                "destination": "fg-auth-rust-model.example.com",
                "transport": "websocket",
                "auto_connect": False,
                "foreground_auth_token": "fg-auth-token-rust",
            },
        ) or {}
        auth_configured_remote = _remote(auth_configured, "foreground auth configure")
        _must(
            auth_configured_remote.get("state") == "disconnected"
            and auth_configured_remote.get("configured_by") == "cmx-rust",
            f"foreground-auth configure should stay disconnected and Rust-owned: {auth_configured}",
        )
        wrong_auth_ready = c._call(
            "workspace.remote.foreground_auth_ready",
            {
                "workspace_id": auth_workspace_id,
                "foreground_auth_token": "wrong-token",
            },
        ) or {}
        _must(
            _remote(wrong_auth_ready, "wrong foreground auth").get("state") == "disconnected",
            f"wrong foreground-auth token should be a Rust-local no-op: {wrong_auth_ready}",
        )
        auth_ready = c._call(
            "workspace.remote.foreground_auth_ready",
            {
                "workspace_id": auth_workspace_id,
                "foreground_auth_token": "fg-auth-token-rust",
            },
        ) or {}
        _assert_model_connected(auth_ready, "foreground auth ready reconnect")
        c._call("workspace.remote.disconnect", {"workspace_id": auth_workspace_id, "clear": True})

        fake_daemon = FakeRemoteDaemonWebSocket()
        proxy_workspace_id = c.new_workspace()
        try:
            proxy_configured = c._call(
                "workspace.remote.configure",
                {
                    "workspace_id": proxy_workspace_id,
                    "destination": "ws-rust-proxy.example.com",
                    "transport": "websocket",
                    "auto_connect": True,
                    "daemon_websocket_url": fake_daemon.url,
                    "daemon_websocket_token": "token-rust-proxy",
                    "daemon_websocket_session_id": "session-rust-proxy",
                },
            ) or {}
            proxy_remote = _remote(proxy_configured, "websocket proxy workspace.remote.configure")
            _must(
                proxy_remote.get("configured_by") == "cmx-rust"
                and proxy_remote.get("connected_by") == "cmx-rust"
                and proxy_remote.get("connection_owner") == "cmx-rust-proxy",
                f"websocket endpoint should be Rust proxy owned: {proxy_configured}",
            )
            _must(
                (proxy_remote.get("daemon") or {}).get("version") == "fake-rust-proxy",
                f"websocket endpoint should use daemon hello payload: {proxy_configured}",
            )
            proxy = proxy_remote.get("proxy") or {}
            proxy_port = int(proxy.get("port") or 0)
            _must(
                proxy.get("state") == "ready" and proxy_port > 0,
                f"websocket endpoint should expose a ready local proxy: {proxy_configured}",
            )
            auth_event = fake_daemon.wait_for_event(
                lambda event: event.get("type") == "auth",
                "auth",
            )
            _must(
                auth_event.get("token") == "token-rust-proxy"
                and auth_event.get("session_id") == "session-rust-proxy",
                f"fake daemon should receive websocket auth payload: {fake_daemon.events}",
            )

            response = _exercise_socks_proxy(proxy_port)
            _must(b"CMX Rust proxy ok" in response, f"SOCKS proxy response was not forwarded: {response!r}")
            _must(
                b"Location: http://cmux-loopback.localtest.me/next" in response
                and b"Domain=cmux-loopback.localtest.me" in response,
                f"SOCKS proxy response headers were not rewritten for loopback alias: {response!r}",
            )
            open_event = fake_daemon.wait_for_event(
                lambda event: event.get("method") == "proxy.open",
                "proxy.open",
            )
            open_params = open_event.get("params") or {}
            _must(
                open_params.get("host") == "127.0.0.1" and int(open_params.get("port") or 0) == 80,
                f"proxy.open should normalize loopback alias through Rust: {open_event}",
            )
            write_event = fake_daemon.wait_for_event(
                lambda event: event.get("method") == "proxy.write.decoded"
                and "GET /through-rust" in str(event.get("data") or ""),
                "decoded proxy.write",
            )
            _must(
                "Host: localhost" in str(write_event.get("data") or ""),
                f"proxy.write should rewrite loopback alias Host header before daemon egress: {write_event}",
            )

            proxy_disconnected = c._call(
                "workspace.remote.disconnect",
                {"workspace_id": proxy_workspace_id},
            ) or {}
            _must(
                proxy_disconnected.get("disconnectedBy") == "cmx-rust",
                f"websocket proxy disconnect should stay Rust-local: {proxy_disconnected}",
            )
            proxy_reconnected = c._call(
                "workspace.remote.reconnect",
                {"workspace_id": proxy_workspace_id},
            ) or {}
            _must(
                (_remote(proxy_reconnected, "websocket proxy reconnect").get("proxy") or {}).get("state")
                == "ready",
                f"websocket proxy reconnect should restart Rust proxy: {proxy_reconnected}",
            )
            fake_daemon.drop_active_connection()
            failed_remote = _wait_for_remote_state(c, proxy_workspace_id, "error")
            _must(
                (failed_remote.get("proxy") or {}).get("error_code") == "proxy_unavailable",
                f"websocket proxy transport failure should surface proxy_unavailable: {failed_remote}",
            )
        finally:
            try:
                c._call("workspace.remote.disconnect", {"workspace_id": proxy_workspace_id, "clear": True})
            finally:
                fake_daemon.close()

    print("PASS: Rust-owned remote model configure/status/reconnect/session-end state")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
