from __future__ import annotations

import argparse
import json
import os
import socket
import sys
import tempfile
import uuid
from pathlib import Path
from typing import Any


METHOD_ALIASES = {
    "ping": "system.ping",
    "identify": "system.identify",
    "capabilities": "system.capabilities",
}


def default_socket_path() -> Path:
    explicit = os.environ.get("CMUX_SOCKET_PATH") or os.environ.get("CMUX_SOCKET")
    if explicit:
        return Path(explicit)

    runtime_dir = os.environ.get("XDG_RUNTIME_DIR")
    base_dir = Path(runtime_dir) / "cmux" if runtime_dir else Path(tempfile.gettempdir()) / "cmux"
    return base_dir / "cmux.sock"


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Send a JSON socket command to cmux Linux.")
    parser.add_argument("--socket", dest="socket_path", default=None, help="Unix socket path")
    parser.add_argument("method", help="Socket method, for example system.ping or ping")
    parser.add_argument("params", nargs="?", default=None, help="JSON object or @path JSON file")
    return parser


def load_params(raw: str | None) -> dict[str, Any]:
    if raw is None:
        return {}

    source = Path(raw[1:]).read_text(encoding="utf-8") if raw.startswith("@") else raw
    value = json.loads(source)
    if not isinstance(value, dict):
        raise ValueError("params must be a JSON object")
    return value


def read_response(sock: socket.socket) -> dict[str, Any]:
    chunks: list[bytes] = []
    while True:
        chunk = sock.recv(4096)
        if not chunk:
            break
        chunks.append(chunk)
        if b"\n" in chunk:
            break

    raw = b"".join(chunks).split(b"\n", 1)[0]
    if not raw:
        raise OSError("empty response from cmux socket")

    value = json.loads(raw.decode("utf-8"))
    if not isinstance(value, dict):
        raise OSError("invalid response from cmux socket")
    return value


def send_command(socket_path: Path, method: str, params: dict[str, Any]) -> dict[str, Any]:
    request = {
        "id": str(uuid.uuid4()),
        "method": METHOD_ALIASES.get(method, method),
        "params": params,
    }
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.connect(str(socket_path))
        sock.sendall((json.dumps(request, separators=(",", ":")) + "\n").encode("utf-8"))
        return read_response(sock)


def print_json(value: Any, stream: Any) -> None:
    print(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True), file=stream)


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    socket_path = Path(args.socket_path) if args.socket_path else default_socket_path()

    try:
        params = load_params(args.params)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"cmux: invalid params: {error}", file=sys.stderr)
        return 2

    try:
        response = send_command(socket_path, args.method, params)
    except OSError as error:
        print(f"cmux: failed to connect to {socket_path}: {error}", file=sys.stderr)
        return 2
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        print(f"cmux: invalid socket response: {error}", file=sys.stderr)
        return 2

    if response.get("ok") is True:
        print_json(response.get("result", {}), sys.stdout)
        return 0

    print_json(response.get("error", response), sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
