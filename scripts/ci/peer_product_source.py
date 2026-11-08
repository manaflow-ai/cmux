#!/usr/bin/env python3
"""Trusted exact-object peer source for immutable compiled CI products.

The peer service exposes only HEAD/GET for one caller-supplied immutable object
key. It never lists cache contents, exposes cache paths, or accepts writes.
Client requests use one monotonic deadline across underlying receives, and the
server bounds client socket time plus concurrent requests so a slow peer falls
through to the existing sources. Transport is acceleration only: callers still
verify the content digest and run the canonical product restore validator before
publishing locally.

On an owned Mac, `fetch` first asks glaeda's LAN helper (LAN_FETCH_HELPER) for the
object by content digest from another PR mini's node-local cache: about 7 s for the
~830 MB product instead of ~130 s from GitHub. Another PR mini is not a trust root
(PR jobs there can write its cache), so the helper's answer counts only when the
bytes hash to the digest GitHub recorded (EXPECTED_SHA256); anything else is a miss
and the existing sources run. The helper is used only when it and every directory
above it are root-owned and not group- or other-writable, so a job can neither
rewrite nor rename it, and it runs with a minimal environment: no tokens.
"""
from __future__ import annotations

import argparse
import contextlib
import hashlib
import hmac
import http.client
import json
import os
import re
import socket
import ssl
import pwd
import stat
import subprocess
import tempfile
import threading
import time
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Callable, Iterator
from urllib.parse import urlsplit

import node_product_cache as cache

MAX_PEERS = 8
MAX_OBJECT_BYTES = 20 * 1024**3
DEFAULT_LOOKUP_TIMEOUT_SECONDS = 5.0
DEFAULT_TRANSFER_TIMEOUT_SECONDS = 180.0
DEFAULT_SERVER_CLIENT_TIMEOUT_SECONDS = 30.0
DEFAULT_SERVER_MAX_ACTIVE_REQUESTS = 16
OBJECT_PATH_PREFIX = "/v1/objects/"
OBJECT_KEY_RE = re.compile(r"[a-f0-9]{64}")
# glaeda-lan-fetch (glaeda scripts/glaeda-lan-fetch), installed root-owned by the operator
# (glaeda-seed-lan helper-install). Not under /Users/Shared/cmux-build-fleet: the fleet
# user owns that tree, so a job could rename a root-owned file there.
LAN_FETCH_HELPER = Path("/Library/Application Support/glaeda/bin/glaeda-lan-fetch")
# Its own lookup (6 s) and transfer (180 s) limits, plus margin.
LAN_FETCH_TIMEOUT_SECONDS = 200.0


class PeerUnavailable(RuntimeError):
    """One peer cannot serve the exact requested object."""


@dataclass(frozen=True)
class PeerSource:
    url: str

    def __post_init__(self) -> None:
        parsed = urlsplit(self.url)
        if (
            parsed.scheme != "https"
            or not parsed.netloc
            or parsed.username
            or parsed.password
            or parsed.query
            or parsed.fragment
            or parsed.path not in ("", "/")
        ):
            raise ValueError("peer source must be one HTTPS origin")

    @property
    def origin(self) -> str:
        return self.url.rstrip("/")


@dataclass(frozen=True)
class PeerAvailability:
    object_key: str
    schema_generation: int
    size_bytes: int
    content_digest: str

    def validate_for(self, identity: cache.Identity) -> None:
        if (
            self.object_key != identity.key()
            or self.schema_generation != cache.SCHEMA_GENERATION
            or self.content_digest != identity.archive_digest
            or not 0 < self.size_bytes <= MAX_OBJECT_BYTES
        ):
            raise PeerUnavailable("peer offer does not match exact object identity")


@dataclass
class OpenLocalObject:
    path: Path
    size_bytes: int
    content_digest: str
    identity: cache.Identity


def _identity_from_metadata(value: dict) -> cache.Identity:
    raw = value.get("identity")
    if not isinstance(raw, dict):
        raise PeerUnavailable("peer object metadata has no identity")
    try:
        return cache.Identity(**raw)
    except (TypeError, ValueError) as error:
        raise PeerUnavailable("peer object identity is invalid") from error


def local_availability(store: cache.Store, object_key: str) -> PeerAvailability | None:
    if not OBJECT_KEY_RE.fullmatch(object_key):
        return None
    with store.lock(object_key):
        metadata = cache._read_json(store.entry(object_key) / cache.METADATA_NAME)
        if metadata is None:
            return None
        try:
            identity = _identity_from_metadata(metadata)
        except PeerUnavailable:
            return None
        if identity.key() != object_key:
            return None
        validated = cache._validate_entry_locked(store, identity)
        if validated is None:
            return None
        metadata, _ = validated
        return PeerAvailability(
            object_key=object_key,
            schema_generation=int(metadata["schema_generation"]),
            size_bytes=int(metadata["size"]),
            content_digest=str(metadata["object_digest"]),
        )


@contextlib.contextmanager
def open_local_object(
    store: cache.Store,
    object_key: str,
    *,
    draining: Callable[[], bool],
) -> Iterator[OpenLocalObject]:
    if not OBJECT_KEY_RE.fullmatch(object_key) or draining():
        raise PeerUnavailable("peer source is unavailable")
    lease = ""
    identity = None
    obj = None
    metadata = None
    with store.lock(object_key):
        if draining():
            raise PeerUnavailable("peer source is draining")
        raw = cache._read_json(store.entry(object_key) / cache.METADATA_NAME)
        if raw is None:
            raise PeerUnavailable("peer object is absent")
        identity = _identity_from_metadata(raw)
        if identity.key() != object_key:
            raise PeerUnavailable("peer object identity mismatch")
        validated = cache._validate_entry_locked(store, identity)
        if validated is None:
            raise PeerUnavailable("peer object is unavailable")
        metadata, obj = validated
        lease = cache._create_lease_locked(store, object_key)
    try:
        assert identity is not None and obj is not None and metadata is not None
        yield OpenLocalObject(
            path=obj,
            size_bytes=int(metadata["size"]),
            content_digest=str(metadata["object_digest"]),
            identity=identity,
        )
    finally:
        if lease:
            with contextlib.suppress(OSError):
                with store.lock(object_key):
                    cache._release_lease_locked(store, object_key, lease)


def _read_secret(path: Path) -> str:
    if not path.is_absolute():
        raise ValueError("peer token file must be absolute")
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode):
        raise ValueError("peer token must be a regular file")
    if info.st_uid != os.geteuid() or info.st_mode & 0o077:
        raise ValueError("peer token file must be private and owned by this user")
    if info.st_size <= 0 or info.st_size > 4096:
        raise ValueError("peer token size is invalid")
    token = path.read_text().strip()
    if len(token) < 32 or any(ord(char) < 0x21 or ord(char) > 0x7E for char in token):
        raise ValueError("peer token is invalid")
    return token


def configured_sources(env=os.environ) -> list[PeerSource]:
    raw = env.get("CMUX_ARTIFACT_PEER_URLS", "").strip()
    if not raw:
        return []
    values = [value.strip() for value in raw.split(",") if value.strip()]
    if len(values) > MAX_PEERS:
        return []
    try:
        return [PeerSource(value) for value in values]
    except ValueError:
        return []


def configured_token_loader(env=os.environ) -> Callable[[PeerSource], str]:
    raw = env.get("CMUX_ARTIFACT_PEER_TOKEN_FILE", "").strip()
    if not raw:
        def unavailable(_source: PeerSource) -> str:
            raise PeerUnavailable("peer token file is unavailable")
        return unavailable
    path = Path(raw).expanduser()

    def load(_source: PeerSource) -> str:
        try:
            return _read_secret(path)
        except (OSError, ValueError) as error:
            raise PeerUnavailable("peer token is unavailable") from error

    return load


def _connection(source: PeerSource, timeout: float) -> tuple[http.client.HTTPSConnection, str]:
    parsed = urlsplit(source.origin)
    host = parsed.hostname
    if host is None:
        raise PeerUnavailable("peer host is invalid")
    port = parsed.port or 443
    return (
        http.client.HTTPSConnection(
            host,
            port,
            timeout=max(0.001, timeout),
            context=ssl.create_default_context(),
        ),
        parsed.netloc,
    )


def _request_deadline(timeout: float) -> float:
    """Return one absolute deadline for the full peer HTTP request."""
    return time.monotonic() + max(0.1, timeout)


def _remaining_timeout(deadline: float) -> float:
    """Return time left before deadline or fail the peer request."""
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise PeerUnavailable("peer request deadline exceeded")
    return max(0.001, remaining)


def _arm_connection_deadline(
    connection: http.client.HTTPSConnection,
    deadline: float,
) -> None:
    """Apply the remaining absolute deadline to connect/read/write socket work."""
    remaining = _remaining_timeout(deadline)
    connection.timeout = remaining
    if connection.sock is not None:
        connection.sock.settimeout(remaining)


def _read_response_once(
    connection: http.client.HTTPSConnection,
    response: http.client.HTTPResponse,
    deadline: float,
    size: int,
) -> bytes:
    """Read with a fresh remaining timeout for at most one buffered raw receive."""
    _arm_connection_deadline(connection, deadline)
    return response.read1(size)


def probe_http(
    source: PeerSource,
    object_key: str,
    token: str,
    *,
    timeout: float = DEFAULT_LOOKUP_TIMEOUT_SECONDS,
) -> PeerAvailability | None:
    if not OBJECT_KEY_RE.fullmatch(object_key):
        return None
    deadline = _request_deadline(timeout)
    connection, authority = _connection(source, _remaining_timeout(deadline))
    try:
        _arm_connection_deadline(connection, deadline)
        connection.request(
            "HEAD",
            OBJECT_PATH_PREFIX + object_key,
            headers={
                "Authorization": f"Bearer {token}",
                "Host": authority,
                "Accept": "application/octet-stream",
            },
        )
        _arm_connection_deadline(connection, deadline)
        response = connection.getresponse()
        while True:
            if not _read_response_once(connection, response, deadline, 64 * 1024):
                break
        if response.status == 404:
            return None
        if response.status != 200:
            raise PeerUnavailable(f"peer probe returned HTTP {response.status}")
        try:
            return PeerAvailability(
                object_key=response.getheader("X-Cmux-Object-Key", ""),
                schema_generation=int(response.getheader("X-Cmux-Object-Schema", "0")),
                size_bytes=int(response.getheader("Content-Length", "0")),
                content_digest=response.getheader("X-Cmux-Content-Sha256", ""),
            )
        except (TypeError, ValueError) as error:
            raise PeerUnavailable("peer availability response is invalid") from error
    except (OSError, ssl.SSLError, http.client.HTTPException) as error:
        raise PeerUnavailable("peer probe failed") from error
    finally:
        connection.close()


def transfer_http(
    source: PeerSource,
    object_key: str,
    token: str,
    target: Path,
    size: int,
    *,
    timeout: float = DEFAULT_TRANSFER_TIMEOUT_SECONDS,
) -> None:
    if not OBJECT_KEY_RE.fullmatch(object_key) or not 0 < size <= MAX_OBJECT_BYTES:
        raise PeerUnavailable("peer transfer request is invalid")
    deadline = _request_deadline(timeout)
    connection, authority = _connection(source, _remaining_timeout(deadline))
    copied = 0
    try:
        _arm_connection_deadline(connection, deadline)
        connection.request(
            "GET",
            OBJECT_PATH_PREFIX + object_key,
            headers={
                "Authorization": f"Bearer {token}",
                "Host": authority,
                "Accept": "application/octet-stream",
            },
        )
        _arm_connection_deadline(connection, deadline)
        response = connection.getresponse()
        if response.status != 200:
            while True:
                if not _read_response_once(connection, response, deadline, 64 * 1024):
                    break
            raise PeerUnavailable(f"peer fetch returned HTTP {response.status}")
        try:
            declared = int(response.getheader("Content-Length", "0"))
        except ValueError as error:
            raise PeerUnavailable("peer fetch size is invalid") from error
        if declared != size:
            raise PeerUnavailable("peer fetch size changed after probe")
        with target.open("xb") as output:
            while True:
                chunk = _read_response_once(
                    connection,
                    response,
                    deadline,
                    min(1024 * 1024, size - copied + 1),
                )
                if not chunk:
                    break
                copied += len(chunk)
                if copied > size:
                    raise PeerUnavailable("peer sent too many bytes")
                output.write(chunk)
            output.flush()
            os.fsync(output.fileno())
        if copied != size:
            raise PeerUnavailable("peer transfer ended early")
    except (OSError, ssl.SSLError, http.client.HTTPException) as error:
        raise PeerUnavailable("peer transfer failed") from error
    finally:
        connection.close()


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def fetch_exact(
    identity: cache.Identity,
    destination: Path,
    sources: list[PeerSource],
    *,
    probe: Callable[[PeerSource, str, str], PeerAvailability | None] = probe_http,
    transfer: Callable[[PeerSource, str, str, Path, int], None] = transfer_http,
    token_loader: Callable[[PeerSource], str] | None = None,
) -> dict:
    started = time.monotonic()
    object_key = identity.key()
    if destination.exists() or not sources:
        return {
            "status": "miss",
            "hit": False,
            "source": "",
            "source_index": -1,
            "lookup_seconds": round(time.monotonic() - started, 6),
            "transfer_seconds": 0.0,
            "bytes_transferred": 0,
        }
    token_loader = token_loader or configured_token_loader()
    destination.parent.mkdir(parents=True, exist_ok=True)
    for index, source in enumerate(sources[:MAX_PEERS]):
        lookup_started = time.monotonic()
        try:
            token = token_loader(source)
            offer = probe(source, object_key, token)
            lookup_seconds = time.monotonic() - lookup_started
            if offer is None:
                continue
            offer.validate_for(identity)
            transfer_started = time.monotonic()
            with tempfile.TemporaryDirectory(prefix="cmux-peer-product-", dir=destination.parent) as raw:
                staging = Path(raw)
                obj = staging / cache.ARCHIVE_NAME
                transfer(source, object_key, token, obj, offer.size_bytes)
                transfer_seconds = time.monotonic() - transfer_started
                if (
                    obj.stat().st_size != offer.size_bytes
                    or _sha256(obj) != identity.archive_digest
                ):
                    raise PeerUnavailable("peer object digest mismatch")
                products = staging / "products"
                products.mkdir()
                os.rename(obj, products / cache.ARCHIVE_NAME)
                if destination.exists():
                    raise PeerUnavailable("peer destination became occupied")
                os.rename(products, destination)
            return {
                "status": "hit",
                "hit": True,
                "source": "peer",
                "source_index": index,
                "object_key": object_key,
                "archive_bytes": offer.size_bytes,
                "lookup_seconds": round(lookup_seconds, 6),
                "transfer_seconds": round(transfer_seconds, 6),
                "bytes_transferred": offer.size_bytes,
            }
        except PeerUnavailable:
            continue
        except (OSError, ValueError, TypeError):
            continue
    return {
        "status": "miss",
        "hit": False,
        "source": "",
        "source_index": -1,
        "object_key": object_key,
        "lookup_seconds": round(time.monotonic() - started, 6),
        "transfer_seconds": 0.0,
        "bytes_transferred": 0,
    }


def _root_owned_chain(path: Path) -> bool:
    """PATH and every directory above it up to / are root-owned, not symlinks, and
    not group- or other-writable: nothing a non-root job can rewrite or rename."""
    for part in [path, *path.parents]:
        try:
            info = os.lstat(part)
        except OSError:
            return False
        if info.st_uid != 0 or stat.S_ISLNK(info.st_mode) or info.st_mode & 0o022:
            return False
    return True


def lan_helper(env=os.environ, helper: Path = LAN_FETCH_HELPER) -> Path | None:
    """glaeda's LAN helper, when this job may run it; else None.

    Only on an owned Mac (a glaeda runner), for a job that is not root, and only
    an executable regular file in a root-owned chain (_root_owned_chain) that
    this job user cannot write.
    """
    if not cache.OWNED_RUNNER.fullmatch(env.get("RUNNER_NAME", "").strip()):
        return None
    if os.geteuid() == 0 or not helper.is_absolute():
        return None
    try:
        info = os.lstat(helper)
    except OSError:
        return None
    if (
        not stat.S_ISREG(info.st_mode)
        or not info.st_mode & 0o111
        or not _root_owned_chain(helper)
        or os.access(helper, os.W_OK)
    ):
        return None
    return helper


def lan_fetch_exact(
    identity: cache.Identity,
    destination: Path,
    helper: Path,
    *,
    timeout: float = LAN_FETCH_TIMEOUT_SECONDS,
) -> dict:
    """Ask glaeda's LAN helper for the exact archive; a hit only when its bytes match the digest.

    The result's `source` ("lan" on a hit) and `lan_status`, `lan_seconds` and
    `lan_peer` are a contract: they become step outputs that the fleet routing's
    admissions.jsonl reads. Keep their names and meanings stable; add fields
    rather than renaming these.
    """
    started = time.monotonic()
    miss = {
        "status": "miss",
        "hit": False,
        "source": "",
        "source_index": -1,
        "lookup_seconds": 0.0,
        "transfer_seconds": 0.0,
        "bytes_transferred": 0,
        "lan_status": "miss",
    }
    if destination.exists():
        return {**miss, "lan_status": "destination-occupied"}
    try:
        destination.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="cmux-lan-product-", dir=destination.parent) as raw:
            staging = Path(raw)
            obj = staging / cache.ARCHIVE_NAME
            env = {"PATH": "/usr/bin:/bin", "HOME": pwd.getpwuid(os.getuid()).pw_dir, "LANG": "C"}
            try:
                proc = subprocess.run(
                    [str(helper), "product", identity.archive_digest, str(obj),
                     "--max-bytes", str(MAX_OBJECT_BYTES)],
                    stdin=subprocess.DEVNULL,
                    capture_output=True,
                    text=True,
                    env=env,
                    timeout=timeout,
                )
            except (OSError, subprocess.SubprocessError):
                return {**miss, "lan_status": "error", "lan_seconds": round(time.monotonic() - started, 6)}
            elapsed = time.monotonic() - started
            if proc.returncode != 0:
                status = "miss" if proc.returncode == 3 else "error"
                return {**miss, "lan_status": status, "lan_seconds": round(elapsed, 6)}
            info = obj.lstat()
            # One link, checked before hashing: a helper that kept another name for the file
            # could change it after the digest check.
            if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or not 0 < info.st_size <= MAX_OBJECT_BYTES:
                return {**miss, "lan_status": "unsafe-file", "lan_seconds": round(elapsed, 6)}
            if _sha256(obj) != identity.archive_digest:
                return {**miss, "lan_status": "digest-mismatch", "lan_seconds": round(elapsed, 6)}
            record = {}
            for line in reversed(proc.stdout.splitlines()):
                with contextlib.suppress(ValueError):
                    value = json.loads(line)
                    if isinstance(value, dict):
                        record = value
                        break
            # No-replace: claim DESTINATION with mkdir (fails if anything is there), then move
            # the verified file in.
            try:
                destination.mkdir()
            except FileExistsError:
                return {**miss, "lan_status": "destination-occupied"}
            try:
                os.rename(obj, destination / cache.ARCHIVE_NAME)
            except OSError:
                with contextlib.suppress(OSError):
                    destination.rmdir()
                raise
    except OSError:
        return {**miss, "lan_status": "error", "lan_seconds": round(time.monotonic() - started, 6)}
    peer_name = record.get("peer") if isinstance(record.get("peer"), str) else ""
    return {
        "status": "hit",
        "hit": True,
        "source": "lan",
        "source_index": -1,
        "object_key": identity.key(),
        "archive_bytes": info.st_size,
        "lookup_seconds": float(record.get("lookup_seconds") or 0.0) if isinstance(record.get("lookup_seconds"), (int, float)) else 0.0,
        "transfer_seconds": round(elapsed, 6),
        "bytes_transferred": info.st_size,
        "lan_status": "hit",
        "lan_seconds": round(elapsed, 6),
        "lan_peer": re.sub(r"[^A-Za-z0-9.-]", "", peer_name)[:64],
    }


def _append_outputs(values: dict) -> None:
    output_path = os.environ.get("GITHUB_OUTPUT")
    if not output_path:
        return
    with open(output_path, "a") as output:
        for key, value in values.items():
            if isinstance(value, bool):
                value = str(value).lower()
            output.write(f"{key}={value}\n")


def _report(result: dict) -> None:
    record = {
        "run_id": os.environ.get("GITHUB_RUN_ID"),
        "job": os.environ.get("GITHUB_JOB"),
        "runner_name": os.environ.get("RUNNER_NAME"),
        **result,
    }
    print("CMUX_PEER_PRODUCT_SOURCE " + json.dumps(record, sort_keys=True))
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with contextlib.suppress(OSError):
            with open(summary, "a") as handle:
                handle.write("### Trusted peer compiled product source\n\n```json\n")
                handle.write(json.dumps(record, indent=2, sort_keys=True))
                handle.write("\n```\n")


def _draining(marker: Path | None) -> bool:
    return marker is not None and marker.exists()


class PeerRequestHandler(BaseHTTPRequestHandler):
    server_version = "cmux-peer-artifact/1"
    protocol_version = "HTTP/1.1"

    def log_message(self, _format: str, *_args) -> None:
        return

    def _authorized(self) -> bool:
        supplied = self.headers.get("Authorization", "")
        expected = f"Bearer {self.server.peer_token}"
        return hmac.compare_digest(supplied, expected)

    def _object_key(self) -> str | None:
        if not self.path.startswith(OBJECT_PATH_PREFIX):
            return None
        value = self.path[len(OBJECT_PATH_PREFIX):]
        return value if OBJECT_KEY_RE.fullmatch(value) else None

    def _send_headers(self, offer: PeerAvailability) -> None:
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(offer.size_bytes))
        self.send_header("X-Cmux-Object-Key", offer.object_key)
        self.send_header("X-Cmux-Object-Schema", str(offer.schema_generation))
        self.send_header("X-Cmux-Content-Sha256", offer.content_digest)
        self.send_header("Cache-Control", "private, immutable")
        self.end_headers()

    def _refuse(self, status: int) -> None:
        self.send_response(status)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_HEAD(self) -> None:
        if not self._authorized():
            self._refuse(401)
            return
        key = self._object_key()
        if key is None:
            self._refuse(404)
            return
        if self.server.draining():
            self._refuse(503)
            return
        offer = local_availability(self.server.store, key)
        if offer is None:
            self._refuse(404)
            return
        self._send_headers(offer)

    def do_GET(self) -> None:
        if not self._authorized():
            self._refuse(401)
            return
        key = self._object_key()
        if key is None:
            self._refuse(404)
            return
        try:
            with open_local_object(
                self.server.store,
                key,
                draining=self.server.draining,
            ) as opened:
                offer = PeerAvailability(
                    object_key=key,
                    schema_generation=cache.SCHEMA_GENERATION,
                    size_bytes=opened.size_bytes,
                    content_digest=opened.content_digest,
                )
                self._send_headers(offer)
                with opened.path.open("rb") as source:
                    while chunk := source.read(1024 * 1024):
                        self.wfile.write(chunk)
        except PeerUnavailable:
            self._refuse(503)
        except (BrokenPipeError, ConnectionResetError, socket.timeout):
            return

    def do_POST(self) -> None:
        self._refuse(405)

    do_PUT = do_POST
    do_DELETE = do_POST
    do_PATCH = do_POST


class PeerHTTPServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(
        self,
        address,
        handler,
        *,
        store: cache.Store,
        token: str,
        drain_marker: Path | None,
        client_timeout_seconds: float = DEFAULT_SERVER_CLIENT_TIMEOUT_SECONDS,
        max_active_requests: int = DEFAULT_SERVER_MAX_ACTIVE_REQUESTS,
    ) -> None:
        if client_timeout_seconds <= 0:
            raise ValueError("peer client timeout must be positive")
        if max_active_requests <= 0:
            raise ValueError("peer active request limit must be positive")
        super().__init__(address, handler)
        self.store = store
        self.peer_token = token
        self._drain_marker = drain_marker
        self.client_timeout_seconds = client_timeout_seconds
        self.max_active_requests = max_active_requests
        self._request_slots = threading.BoundedSemaphore(max_active_requests)

    def get_request(self):
        request, client_address = super().get_request()
        try:
            # The listener defers TLS handshakes. Keep the accept loop free of
            # client-controlled handshake work; the bounded request worker will
            # perform it lazily under this socket deadline.
            request.settimeout(self.client_timeout_seconds)
            return request, client_address
        except BaseException:
            request.close()
            raise

    def process_request(self, request, client_address) -> None:
        if not self._request_slots.acquire(blocking=False):
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except BaseException:
            self._request_slots.release()
            raise

    def process_request_thread(self, request, client_address) -> None:
        try:
            super().process_request_thread(request, client_address)
        finally:
            self._request_slots.release()

    def draining(self) -> bool:
        return _draining(self._drain_marker)


def serve(args: argparse.Namespace) -> None:
    store = cache.Store(args.root.resolve())
    token = _read_secret(args.token_file.resolve())
    server = PeerHTTPServer(
        (args.bind, args.port),
        PeerRequestHandler,
        store=store,
        token=token,
        drain_marker=args.drain_marker.resolve() if args.drain_marker else None,
        client_timeout_seconds=args.client_timeout_seconds,
        max_active_requests=args.max_active_requests,
    )
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(args.cert.resolve(), args.key.resolve())
    server.socket = context.wrap_socket(
        server.socket,
        server_side=True,
        do_handshake_on_connect=False,
    )
    try:
        server.serve_forever()
    finally:
        server.server_close()


def main() -> None:
    parser = argparse.ArgumentParser(description="CMUX exact immutable peer artifact source")
    sub = parser.add_subparsers(dest="command", required=True)
    fetch_parser = sub.add_parser("fetch")
    fetch_parser.add_argument("destination", type=Path)
    serve_parser = sub.add_parser("serve")
    serve_parser.add_argument("--root", type=Path, required=True)
    serve_parser.add_argument("--bind", default="127.0.0.1")
    serve_parser.add_argument("--port", type=int, default=9443)
    serve_parser.add_argument("--cert", type=Path, required=True)
    serve_parser.add_argument("--key", type=Path, required=True)
    serve_parser.add_argument("--token-file", type=Path, required=True)
    serve_parser.add_argument("--drain-marker", type=Path)
    serve_parser.add_argument(
        "--client-timeout-seconds",
        type=float,
        default=DEFAULT_SERVER_CLIENT_TIMEOUT_SECONDS,
    )
    serve_parser.add_argument(
        "--max-active-requests",
        type=int,
        default=DEFAULT_SERVER_MAX_ACTIVE_REQUESTS,
    )
    args = parser.parse_args()

    if args.command == "serve":
        serve(args)
        return

    result = {
        "status": "miss",
        "hit": False,
        "source": "",
        "source_index": -1,
        "lookup_seconds": 0.0,
        "transfer_seconds": 0.0,
        "bytes_transferred": 0,
    }
    try:
        identity = cache.Identity.from_env()
        helper = lan_helper()
        lan = lan_fetch_exact(identity, args.destination, helper) if helper else {"lan_status": "unavailable"}
        if lan.get("hit"):
            result = lan
        else:
            result = fetch_exact(
                identity,
                args.destination,
                configured_sources(),
                token_loader=configured_token_loader(),
            )
            result.update({key: value for key, value in lan.items() if key.startswith("lan_")})
    except (OSError, ValueError, TypeError, PeerUnavailable):
        pass
    _append_outputs(result)
    _report(result)


if __name__ == "__main__":
    main()
