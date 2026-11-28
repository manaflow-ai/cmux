#!/usr/bin/env python3
"""Tiny WebSocket echo server for SSH proxy integration tests."""

from __future__ import annotations

import argparse
import base64
import hashlib
import socket
import struct
import threading


GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


def _recv_exact(conn: socket.socket, n: int, pending: bytearray | None = None) -> bytes:
    data = bytearray()
    if pending:
        take = min(len(pending), n)
        if take:
            data.extend(pending[:take])
            del pending[:take]
    while len(data) < n:
        chunk = conn.recv(n - len(data))
        if not chunk:
            raise ConnectionError("unexpected EOF")
        data.extend(chunk)
    return bytes(data)


def _recv_until(conn: socket.socket, marker: bytes, limit: int = 8192) -> tuple[bytes, bytearray]:
    data = bytearray()
    while marker not in data:
        chunk = conn.recv(1024)
        if not chunk:
            raise ConnectionError("unexpected EOF while reading headers")
        data.extend(chunk)
        if len(data) > limit:
            raise ValueError("header too large")
    marker_end = data.index(marker) + len(marker)
    return bytes(data[:marker_end]), bytearray(data[marker_end:])


def _read_frame(conn: socket.socket, pending: bytearray | None = None) -> tuple[int, bytes]:
    first, second = _recv_exact(conn, 2, pending)
    opcode = first & 0x0F
    masked = (second & 0x80) != 0
    length = second & 0x7F
    if length == 126:
        length = struct.unpack("!H", _recv_exact(conn, 2, pending))[0]
    elif length == 127:
        length = struct.unpack("!Q", _recv_exact(conn, 8, pending))[0]

    mask_key = _recv_exact(conn, 4, pending) if masked else b""
    payload = _recv_exact(conn, length, pending) if length else b""
    if masked and payload:
        payload = bytes(b ^ mask_key[i % 4] for i, b in enumerate(payload))
    return opcode, payload


def _send_frame(conn: socket.socket, opcode: int, payload: bytes) -> None:
    first = 0x80 | (opcode & 0x0F)
    length = len(payload)
    if length < 126:
        header = bytes([first, length])
    elif length <= 0xFFFF:
        header = bytes([first, 126]) + struct.pack("!H", length)
    else:
        header = bytes([first, 127]) + struct.pack("!Q", length)
    conn.sendall(header + payload)


def handle_client(conn: socket.socket) -> None:
    try:
        request, pending = _recv_until(conn, b"\r\n\r\n")
        headers_raw = request.decode("utf-8", errors="replace").split("\r\n")
        header_map: dict[str, str] = {}
        for line in headers_raw[1:]:
            if not line or ":" not in line:
                continue
            k, v = line.split(":", 1)
            header_map[k.strip().lower()] = v.strip()

        key = header_map.get("sec-websocket-key", "")
        upgrade = header_map.get("upgrade", "").lower()
        connection_hdr = header_map.get("connection", "").lower()
        if not key or upgrade != "websocket" or "upgrade" not in connection_hdr:
            conn.sendall(b"HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n")
            return

        accept = base64.b64encode(hashlib.sha1((key + GUID).encode("utf-8")).digest()).decode("ascii")
        response = (
            "HTTP/1.1 101 Switching Protocols\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Accept: {accept}\r\n"
            "\r\n"
        )
        conn.sendall(response.encode("utf-8"))

        while True:
            opcode, payload = _read_frame(conn, pending)
            if opcode == 0x8:  # close
                _send_frame(conn, 0x8, b"")
                return
            if opcode == 0x9:  # ping
                _send_frame(conn, 0xA, payload)
                continue
            if opcode == 0x1:  # text
                _send_frame(conn, 0x1, payload)
                continue
            # ignore all other opcodes
    finally:
        try:
            conn.close()
        except Exception:
            pass


def main() -> int:
    parser = argparse.ArgumentParser(description="WebSocket echo server")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=43174)
    args = parser.parse_args()

    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as server:
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind((args.host, args.port))
        server.listen(16)
        while True:
            conn, _ = server.accept()
            thread = threading.Thread(target=handle_client, args=(conn,), daemon=True)
            thread.start()


if __name__ == "__main__":
    raise SystemExit(main())
