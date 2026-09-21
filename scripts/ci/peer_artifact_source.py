#!/usr/bin/env python3
"""Authenticated exact-object peer transport for CMUX immutable products.

The peer API has no listing or write route. It serves only a caller-supplied
transport-independent object identity from the node-local immutable store.
Every fetched archive is size- and SHA-256-verified before the existing cmux
product validator sees it.
"""
from __future__ import annotations

import hashlib
import hmac
import http.server
import json
import os
import re
import shutil
import socket
import ssl
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Callable
from urllib.parse import urlsplit

import node_product_cache as cache

API_PREFIX = "/v1/objects/"
MAX_OBJECT_BYTES = 2 * 1024**3
DEFAULT_TIMEOUT_SECONDS = 180.0
_HEX64 = re.compile(r"[a-f0-9]{64}")


def _read_token(path_raw: str) -> str:
    path = Path(path_raw)
    if not path.is_absolute() or path.is_symlink():
        raise ValueError("peer token file must be an absolute regular file")
    stat = path.stat()
    if not path.is_file() or stat.st_mode & 0o077:
        raise ValueError("peer token file must be private")
    raw = path.read_text()
    if len(raw) > 4096:
        raise ValueError("peer token file is oversized")
    token = raw.strip()
    if len(token) < 32 or any(char.isspace() for char in token):
        raise ValueError("peer token is invalid")
    return token


def configured_token(env=os.environ) -> str | None:
    raw = env.get("CMUX_ARTIFACT_PEER_TOKEN_FILE", "").strip()
    if not raw:
        return None
    try:
        return _read_token(raw)
    except (OSError, ValueError):
        return None


def configured_peers(env=os.environ) -> list[str]:
    raw = env.get("CMUX_ARTIFACT_PEER_URLS", "").strip()
    if not raw:
        return []
    peers = []
    for value in raw.split(","):
        value = value.strip().rstrip("/")
        if not value:
            continue
        parsed = urlsplit(value)
        loopback_http = (
            parsed.scheme == "http"
            and parsed.hostname in {"127.0.0.1", "::1", "localhost"}
        )
        if (
            parsed.scheme != "https"
            and not loopback_http
            or not parsed.netloc
            or parsed.username
            or parsed.password
            or parsed.query
            or parsed.fragment
            or parsed.path not in ("", "/")
        ):
            continue
        peers.append(value)
    return peers[:8]


def _auth_header(token: str) -> str:
    return f"Bearer {token}"


def _identity_path(base: str, object_key: str) -> str:
    if not _HEX64.fullmatch(object_key):
        raise ValueError("invalid object identity")
    return f"{base}{API_PREFIX}{object_key}"


def _header(response, name: str) -> str:
    value = response.headers.get(name)
    if not isinstance(value, str):
        raise ValueError(f"missing {name}")
    return value


def _validate_headers(response, object_key: str, expected_digest: str) -> int:
    identity = _header(response, "X-CMUX-Object-Identity")
    schema = _header(response, "X-CMUX-Object-Schema")
    digest = _header(response, "X-CMUX-Content-SHA256")
    length = _header(response, "Content-Length")
    if identity != f"sha256:{object_key}" or schema != str(cache.SCHEMA_GENERATION):
        raise ValueError("peer object identity mismatch")
    if digest != f"sha256:{expected_digest}":
        raise ValueError("peer content digest mismatch")
    if not length.isdecimal():
        raise ValueError("peer object size is invalid")
    size = int(length)
    if not 0 < size <= MAX_OBJECT_BYTES:
        raise ValueError("peer object size is outside the reviewed bound")
    return size


def _open(request: urllib.request.Request, timeout: float):
    return urllib.request.urlopen(request, timeout=timeout)


def probe(
    base: str,
    object_key: str,
    expected_digest: str,
    token: str,
    *,
    opener: Callable = _open,
    timeout: float = 10.0,
) -> int | None:
    request = urllib.request.Request(
        _identity_path(base, object_key),
        method="HEAD",
        headers={"Authorization": _auth_header(token)},
    )
    try:
        with opener(request, timeout) as response:
            if getattr(response, "status", 200) != 200:
                return None
            return _validate_headers(response, object_key, expected_digest)
    except (
        OSError,
        ValueError,
        TimeoutError,
        urllib.error.URLError,
        urllib.error.HTTPError,
    ):
        return None


def fetch(
    base: str,
    object_key: str,
    expected_digest: str,
    expected_size: int,
    token: str,
    target: Path,
    *,
    opener: Callable = _open,
    timeout: float = DEFAULT_TIMEOUT_SECONDS,
) -> tuple[int, float]:
    request = urllib.request.Request(
        _identity_path(base, object_key),
        method="GET",
        headers={"Authorization": _auth_header(token)},
    )
    started = time.monotonic()
    with opener(request, timeout) as response:
        if getattr(response, "status", 200) != 200:
            raise ValueError("peer fetch unavailable")
        size = _validate_headers(response, object_key, expected_digest)
        if size != expected_size:
            raise ValueError("peer size changed between probe and fetch")
        digest = hashlib.sha256()
        copied = 0
        with target.open("xb") as output:
            while True:
                chunk = response.read(min(1024 * 1024, size - copied + 1))
                if not chunk:
                    break
                copied += len(chunk)
                if copied > size:
                    raise ValueError("peer transfer exceeded declared size")
                output.write(chunk)
                digest.update(chunk)
            output.flush()
            os.fsync(output.fileno())
        if copied != size or digest.hexdigest() != expected_digest:
            raise ValueError("peer transfer failed content verification")
    return copied, max(0.0, time.monotonic() - started)


def restore(
    peers: list[str],
    token: str | None,
    identity: cache.Identity,
    destination: Path,
    *,
    opener: Callable = _open,
) -> dict:
    started = time.monotonic()
    base_result = {
        "hit": False,
        "source": "peer",
        "lookup_seconds": 0.0,
        "transfer_seconds": 0.0,
        "bytes_transferred": 0,
        "archive_bytes": 0,
    }
    if not peers or token is None or destination.exists():
        return {**base_result, "status": "disabled" if not peers or token is None else "destination-exists"}

    object_key = identity.key()
    for base in peers:
        lookup_started = time.monotonic()
        size = probe(
            base,
            object_key,
            identity.archive_digest,
            token,
            opener=opener,
        )
        lookup_elapsed = max(0.0, time.monotonic() - lookup_started)
        if size is None:
            continue
        destination.parent.mkdir(parents=True, exist_ok=True)
        work = Path(tempfile.mkdtemp(prefix=".cmux-peer-artifact-", dir=destination.parent))
        try:
            archive = work / cache.ARCHIVE_NAME
            copied, transfer_seconds = fetch(
                base,
                object_key,
                identity.archive_digest,
                size,
                token,
                archive,
                opener=opener,
            )
            products = work / "products"
            products.mkdir()
            os.rename(archive, products / cache.ARCHIVE_NAME)
            os.rename(products, destination)
            return {
                **base_result,
                "status": "hit",
                "hit": True,
                "lookup_seconds": round(lookup_elapsed, 6),
                "transfer_seconds": round(transfer_seconds, 6),
                "bytes_transferred": copied,
                "archive_bytes": size,
                "wall_seconds": round(max(0.0, time.monotonic() - started), 6),
            }
        except (
            OSError,
            ValueError,
            TimeoutError,
            urllib.error.URLError,
            urllib.error.HTTPError,
        ):
            continue
        finally:
            shutil.rmtree(work, ignore_errors=True)
    return {
        **base_result,
        "status": "miss",
        "lookup_seconds": round(max(0.0, time.monotonic() - started), 6),
        "wall_seconds": round(max(0.0, time.monotonic() - started), 6),
    }


def _append_outputs(result: dict) -> None:
    path = os.environ.get("GITHUB_OUTPUT")
    if not path:
        return
    with open(path, "a") as output:
        for field in (
            "hit",
            "status",
            "lookup_seconds",
            "transfer_seconds",
            "bytes_transferred",
            "archive_bytes",
        ):
            value = result.get(field, "")
            if isinstance(value, bool):
                value = str(value).lower()
            output.write(f"{field}={value}\n")


def _report(result: dict) -> None:
    record = {
        "event": "peer_artifact",
        "run_id": os.environ.get("GITHUB_RUN_ID"),
        "job": os.environ.get("GITHUB_JOB"),
        **result,
    }
    print("CMUX_PEER_ARTIFACT " + json.dumps(record, sort_keys=True))
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        try:
            with open(summary, "a") as handle:
                handle.write("### Peer compiled product transport\n\n```json\n")
                handle.write(json.dumps(record, indent=2, sort_keys=True))
                handle.write("\n```\n")
        except OSError:
            pass


class PeerServer(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(
        self,
        address,
        store: cache.Store,
        token: str,
        drain_file: Path | None = None,
    ):
        self.store = store
        self.peer_token = token
        self.drain_file = drain_file
        super().__init__(address, PeerRequestHandler)


class PeerRequestHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "cmux-artifact-peer/1"

    def log_message(self, _format, *args):
        return

    def _authorized(self) -> bool:
        supplied = self.headers.get("Authorization", "")
        expected = _auth_header(self.server.peer_token)
        return hmac.compare_digest(supplied, expected)

    def _object_key(self) -> str | None:
        if not self.path.startswith(API_PREFIX):
            return None
        key = self.path[len(API_PREFIX):]
        return key if _HEX64.fullmatch(key) else None

    def _send_empty(self, status: int) -> None:
        self.send_response(status)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _admit(self) -> str | None:
        if not self._authorized():
            self._send_empty(404)
            return None
        if self.server.drain_file is not None and self.server.drain_file.exists():
            self._send_empty(503)
            return None
        key = self._object_key()
        if key is None:
            self._send_empty(404)
            return None
        return key

    def _headers(self, key: str, metadata: dict) -> None:
        self.send_header("X-CMUX-Object-Identity", f"sha256:{key}")
        self.send_header("X-CMUX-Object-Schema", str(cache.SCHEMA_GENERATION))
        self.send_header("X-CMUX-Content-SHA256", f"sha256:{metadata['object_digest']}")
        self.send_header("Content-Length", str(metadata["size"]))
        self.send_header("Cache-Control", "private, immutable")

    def do_HEAD(self):
        key = self._admit()
        if key is None:
            return
        offer = cache.peer_availability(self.server.store, key)
        if offer is None:
            self._send_empty(404)
            return
        self.send_response(200)
        self._headers(key, offer["metadata"])
        self.end_headers()

    def do_GET(self):
        key = self._admit()
        if key is None:
            return
        lease = cache.acquire_peer_transfer(self.server.store, key)
        if lease is None:
            self._send_empty(404)
            return
        try:
            metadata = lease["metadata"]
            self.send_response(200)
            self._headers(key, metadata)
            self.end_headers()
            with lease["path"].open("rb") as source:
                while chunk := source.read(1024 * 1024):
                    self.wfile.write(chunk)
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass
        finally:
            cache.release_peer_transfer(self.server.store, key, lease["lease"])

    def do_POST(self):
        self._send_empty(405)

    def do_PUT(self):
        self._send_empty(405)

    def do_DELETE(self):
        self._send_empty(405)


def make_server(
    store: cache.Store,
    token: str,
    host: str = "127.0.0.1",
    port: int = 0,
    *,
    drain_file: Path | None = None,
) -> PeerServer:
    return PeerServer((host, port), store, token, drain_file)


def serve(env=os.environ) -> None:
    store = cache.configured_store(env)
    token = configured_token(env)
    cert = env.get("CMUX_ARTIFACT_PEER_TLS_CERT", "").strip()
    key = env.get("CMUX_ARTIFACT_PEER_TLS_KEY", "").strip()
    bind = env.get("CMUX_ARTIFACT_PEER_BIND", "127.0.0.1").strip()
    port_raw = env.get("CMUX_ARTIFACT_PEER_PORT", "9443").strip()
    drain_raw = env.get("CMUX_ARTIFACT_PEER_DRAIN_FILE", "").strip()
    if store is None or token is None or not cert or not key or not port_raw.isdecimal():
        raise SystemExit("peer server requires cache root, private token file, TLS cert/key, and port")
    drain = Path(drain_raw) if drain_raw else None
    server = make_server(store, token, bind, int(port_raw), drain_file=drain)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(certfile=cert, keyfile=key)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    server.serve_forever()


def client(env=os.environ) -> None:
    result = {
        "hit": False,
        "status": "identity-unavailable",
        "lookup_seconds": 0.0,
        "transfer_seconds": 0.0,
        "bytes_transferred": 0,
        "archive_bytes": 0,
    }
    try:
        identity = cache.Identity.from_env(env)
        peers = configured_peers(env)
        token = configured_token(env)
        destination = Path(env["RUNNER_TEMP"]) / "app-host-products"
        result = restore(peers, token, identity, destination)
    except (KeyError, OSError, ValueError):
        pass
    _append_outputs(result)
    _report(result)


def main() -> None:
    if len(sys.argv) != 2 or sys.argv[1] not in {"fetch", "serve"}:
        raise SystemExit("usage: peer_artifact_source.py fetch|serve")
    if sys.argv[1] == "serve":
        serve()
    else:
        client()


if __name__ == "__main__":
    main()
