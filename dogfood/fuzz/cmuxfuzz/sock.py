"""Minimal v2 control-socket client: one JSON request per line, one reply per line."""

from __future__ import annotations

import itertools
import json
import socket
import time


class SocketTimeout(Exception):
    pass


class SocketError(Exception):
    def __init__(self, method: str, error: dict | str):
        self.method = method
        self.error = error
        code = error.get("code") if isinstance(error, dict) else ""
        message = error.get("message") if isinstance(error, dict) else str(error)
        super().__init__(f"{method}: {code} {message}".strip())


class CmuxSocket:
    """A fresh connection per request, so one wedged reply never poisons the next."""

    _ids = itertools.count(1)

    def __init__(self, path: str, *, timeout: float = 10.0):
        self.path = path
        self.timeout = timeout

    def call(self, method: str, params: dict | None = None, *, timeout: float | None = None) -> dict:
        limit = timeout or self.timeout
        request = {"id": next(self._ids), "method": method, "params": params or {}}
        deadline = time.monotonic() + limit
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
            conn.settimeout(limit)
            try:
                conn.connect(self.path)
                conn.sendall((json.dumps(request) + "\n").encode())
                buf = b""
                while b"\n" not in buf:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        raise SocketTimeout(f"{method}: no reply in {limit:g} s")
                    conn.settimeout(remaining)
                    chunk = conn.recv(1 << 20)
                    if not chunk:
                        break
                    buf += chunk
            except socket.timeout as error:
                raise SocketTimeout(f"{method}: no reply in {limit:g} s") from error
        line = buf.split(b"\n", 1)[0]
        if not line:
            raise SocketError(method, "connection closed without a reply")
        try:
            reply = json.loads(line)
        except ValueError as error:  # the connection closed partway through a reply
            raise SocketError(method, f"malformed reply ({error})") from error
        if not reply.get("ok"):
            raise SocketError(method, reply.get("error") or reply)
        return reply.get("result") or {}

    def ready(self) -> bool:
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
                conn.settimeout(2)
                conn.connect(self.path)
                conn.sendall(b"ping\n")
                return conn.recv(64).startswith(b"PONG")
        except OSError:
            return False
