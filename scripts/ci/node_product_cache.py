#!/usr/bin/env python3
"""Node-local immutable store for exact compiled CI products.

The store is acceleration only. Cross-node truth remains the GitHub artifact
(and optional R2 broker); every consumer still runs the canonical product
restore validation after a local object is materialized.
"""
from __future__ import annotations

import contextlib
import errno
import fcntl
import hashlib
import json
import os
import re
import secrets
import select
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Callable, Iterator

SCHEMA_GENERATION = 2
FORMAT_GENERATION = "app-host-products-tar-gz-v1"
PROVIDER = "github-actions"
ARCHIVE_NAME = "app-host-products.tar.gz"
OBJECT_NAME = "object.tar.gz"
METADATA_NAME = "metadata.json"
REUSE_RECEIPT = "Build/Products/cmux-product-reuse.json"
PRODUCT_RECEIPT = "Build/Products/cmux-test-products.json"
DEFAULT_BUDGET_BYTES = 24 * 1024**3
DEFAULT_WAIT_SECONDS = 180.0
DEFAULT_FILL_LEASE_SECONDS = 360.0
DEFAULT_RESTORE_LEASE_SECONDS = 2 * 60 * 60
MAX_RECEIPT_BYTES = 1024 * 1024
MAX_TAR_MEMBERS = 250_000
MAX_WAITERS_PER_FILL = 64
_HEX64 = re.compile(r"[a-f0-9]{64}")
_REVISION = re.compile(r"[a-f0-9]{6,64}")


def _digest(value: str) -> str:
    value = value.removeprefix("sha256:").lower()
    if not _HEX64.fullmatch(value):
        raise ValueError("invalid sha256 digest")
    return value


def _positive_int(value: str, label: str) -> int:
    if not value.isdecimal() or int(value) <= 0:
        raise ValueError(f"invalid {label}")
    return int(value)


@dataclass(frozen=True)
class Identity:
    repository: str
    artifact_id: int
    provider_digest: str
    archive_digest: str
    product_contract: str
    source_revision: str
    producer_run_id: int
    producer_run_attempt: int = 1
    schema_generation: int = SCHEMA_GENERATION
    format_generation: str = FORMAT_GENERATION
    provider: str = PROVIDER

    def as_dict(self) -> dict:
        return {
            "schema_generation": self.schema_generation,
            "format_generation": self.format_generation,
            "provider": self.provider,
            "repository": self.repository,
            "artifact_id": self.artifact_id,
            "provider_digest": self.provider_digest,
            "archive_digest": self.archive_digest,
            "product_contract": self.product_contract,
            "source_revision": self.source_revision,
            "producer_run_id": self.producer_run_id,
            "producer_run_attempt": self.producer_run_attempt,
        }

    def key(self) -> str:
        return hashlib.sha256(
            json.dumps(self.as_dict(), sort_keys=True, separators=(",", ":")).encode()
        ).hexdigest()

    @classmethod
    def from_env(cls, env=os.environ) -> "Identity":
        repository = env.get("GITHUB_REPOSITORY", "")
        if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
            raise ValueError("invalid repository")
        revision = env.get("CMUX_PRODUCT_SOURCE_REVISION", "").lower()
        if not _REVISION.fullmatch(revision):
            raise ValueError("invalid source revision")
        return cls(
            repository=repository,
            artifact_id=_positive_int(env.get("ARTIFACT_ID", ""), "artifact id"),
            provider_digest=_digest(env.get("ARTIFACT_PROVIDER_DIGEST", "")),
            archive_digest=_digest(env.get("EXPECTED_SHA256", "")),
            product_contract=_digest(env.get("CMUX_PRODUCT_CONTRACT", "")),
            source_revision=revision,
            producer_run_id=_positive_int(
                env.get("CMUX_PRODUCT_PRODUCER_RUN_ID", ""), "producer run id"
            ),
            producer_run_attempt=_positive_int(
                env.get("CMUX_PRODUCT_PRODUCER_RUN_ATTEMPT", "1"), "producer run attempt"
            ),
        )


def _canonical_contract_key(contract: dict) -> str:
    return hashlib.sha256(json.dumps(contract, sort_keys=True).encode()).hexdigest()


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _fsync_file(path: Path) -> None:
    with path.open("rb") as handle:
        os.fsync(handle.fileno())


def _fsync_dir(path: Path) -> None:
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def _mkdir(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True, mode=0o770)
    try:
        path.chmod(0o770)
    except PermissionError:
        pass


def _atomic_json(path: Path, value: dict) -> None:
    _mkdir(path.parent)
    fd, raw = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    tmp = Path(raw)
    try:
        with os.fdopen(fd, "w") as handle:
            json.dump(value, handle, sort_keys=True, separators=(",", ":"))
            handle.flush()
            os.fsync(handle.fileno())
        try:
            tmp.chmod(0o660)
        except PermissionError:
            pass
        os.replace(tmp, path)
        _fsync_dir(path.parent)
    finally:
        tmp.unlink(missing_ok=True)


def _read_json(path: Path) -> dict | None:
    try:
        value = json.loads(path.read_text())
        return value if isinstance(value, dict) else None
    except (OSError, ValueError, TypeError):
        return None


class Store:
    def __init__(self, root: Path):
        self.root = root
        if not root.is_absolute():
            raise ValueError("cache root must be absolute")
        if root.exists() and root.is_symlink():
            raise ValueError("cache root cannot be a symlink")
        for child in ("objects", "state", "fills", "leases", "locks", "signals", "staging"):
            _mkdir(root / child)

    def entry(self, key: str) -> Path:
        return self.root / "objects" / key[:2] / key

    def state(self, key: str) -> Path:
        return self.root / "state" / f"{key}.json"

    def fill(self, key: str) -> Path:
        return self.root / "fills" / f"{key}.json"

    def lease(self, key: str, token: str) -> Path:
        return self.root / "leases" / f"{key}.{token}.json"

    def signal(self, key: str, token: str) -> Path:
        return self.root / "signals" / f"{key}.{token}.fifo"

    def lock_path(self, key: str) -> Path:
        return self.root / "locks" / f"{key}.lock"

    @contextlib.contextmanager
    def lock(self, key: str, *, exclusive: bool = True, blocking: bool = True) -> Iterator[None]:
        path = self.lock_path(key)
        _mkdir(path.parent)
        fd = os.open(path, os.O_CREAT | os.O_RDWR, 0o660)
        try:
            try:
                os.fchmod(fd, 0o660)
            except PermissionError:
                pass
            mode = fcntl.LOCK_EX if exclusive else fcntl.LOCK_SH
            if not blocking:
                mode |= fcntl.LOCK_NB
            fcntl.flock(fd, mode)
            yield
        finally:
            try:
                fcntl.flock(fd, fcntl.LOCK_UN)
            finally:
                os.close(fd)


def configured_store(env=os.environ) -> Store | None:
    raw = env.get("CMUX_NODE_PRODUCT_CACHE_ROOT", "").strip()
    if not raw:
        return None
    try:
        return Store(Path(raw).expanduser())
    except (OSError, ValueError):
        return None


def budget_bytes(env=os.environ) -> int:
    raw = env.get("CMUX_NODE_PRODUCT_CACHE_MAX_BYTES", "").strip()
    if not raw:
        return DEFAULT_BUDGET_BYTES
    try:
        value = int(raw)
    except ValueError:
        return DEFAULT_BUDGET_BYTES
    return value if value > 0 else DEFAULT_BUDGET_BYTES


def wait_seconds(env=os.environ) -> float:
    raw = env.get("CMUX_NODE_PRODUCT_CACHE_WAIT_SECONDS", "").strip()
    if not raw:
        return DEFAULT_WAIT_SECONDS
    try:
        value = float(raw)
    except ValueError:
        return DEFAULT_WAIT_SECONDS
    return min(max(value, 0.0), 600.0)


def _metadata_matches(metadata: dict, identity: Identity) -> bool:
    return (
        metadata.get("schema_generation") == SCHEMA_GENERATION
        and metadata.get("format_generation") == FORMAT_GENERATION
        and metadata.get("identity") == identity.as_dict()
        and metadata.get("object_digest") == identity.archive_digest
        and isinstance(metadata.get("size"), int)
        and metadata["size"] > 0
        and metadata.get("source_class") in {"github", "r2", "peer", "producer-local"}
    )


def _active_leases_locked(store: Store, key: str, now: float | None = None) -> int:
    now = time.time() if now is None else now
    active = 0
    for path in (store.root / "leases").glob(f"{key}.*.json"):
        value = _read_json(path)
        if (
            value
            and isinstance(value.get("deadline_epoch"), (int, float))
            and value["deadline_epoch"] > now
        ):
            active += 1
        else:
            path.unlink(missing_ok=True)
    return active


def _create_lease_locked(store: Store, key: str, lifetime: float = DEFAULT_RESTORE_LEASE_SECONDS) -> str:
    token = secrets.token_hex(16)
    now = time.time()
    _atomic_json(store.lease(key, token), {
        "token": token,
        "created_epoch": now,
        "deadline_epoch": now + max(60.0, lifetime),
        "run_id": os.environ.get("GITHUB_RUN_ID", ""),
        "job": os.environ.get("GITHUB_JOB", ""),
    })
    return token


def _release_lease_locked(store: Store, key: str, token: str) -> None:
    if token:
        store.lease(key, token).unlink(missing_ok=True)


def _remove_entry_locked(store: Store, key: str) -> None:
    entry = store.entry(key)
    if entry.exists():
        try:
            entry.chmod(0o770)
        except OSError:
            pass
        try:
            for path in entry.iterdir():
                try:
                    path.chmod(0o660)
                except OSError:
                    pass
        except OSError:
            pass
        shutil.rmtree(entry, ignore_errors=True)
    store.state(key).unlink(missing_ok=True)


def _validate_entry_locked(store: Store, identity: Identity) -> tuple[dict, Path] | None:
    key = identity.key()
    entry = store.entry(key)
    metadata = _read_json(entry / METADATA_NAME)
    obj = entry / OBJECT_NAME
    if metadata is None or not _metadata_matches(metadata, identity) or not obj.is_file():
        if entry.exists():
            _remove_entry_locked(store, key)
        return None
    try:
        if obj.stat().st_size != metadata["size"] or _sha256(obj) != identity.archive_digest:
            _remove_entry_locked(store, key)
            return None
    except OSError:
        _remove_entry_locked(store, key)
        return None
    return metadata, obj


def _materialize(obj: Path, destination: Path) -> None:
    if destination.exists():
        raise FileExistsError("product destination already exists")
    _mkdir(destination.parent)
    staging = Path(tempfile.mkdtemp(prefix=".cmux-node-product-", dir=destination.parent))
    try:
        target = staging / ARCHIVE_NAME
        try:
            os.link(obj, target)
        except OSError as error:
            if error.errno not in {errno.EXDEV, errno.EPERM, errno.EACCES, errno.EMLINK}:
                raise
            with obj.open("rb") as source, target.open("xb") as output:
                shutil.copyfileobj(source, output, 1024 * 1024)
                output.flush()
                os.fsync(output.fileno())
        os.rename(staging, destination)
    finally:
        if staging.exists():
            shutil.rmtree(staging, ignore_errors=True)


def _state_update_locked(store: Store, key: str, **increments) -> dict:
    now_ns = time.time_ns()
    current = _read_json(store.state(key)) or {
        "last_used_ns": now_ns,
        "consumer_hit_count": 0,
        "verified_restore_count": 0,
    }
    current["last_used_ns"] = now_ns
    for field, amount in increments.items():
        current[field] = int(current.get(field, 0)) + amount
    _atomic_json(store.state(key), current)
    return current


def _stats_update(store: Store, **increments) -> dict:
    with store.lock("__stats__"):
        path = store.root / "state" / "stats.json"
        value = _read_json(path) or {
            "lookups": 0,
            "hits": 0,
            "fill_owners": 0,
            "waiters": 0,
            "fallbacks": 0,
            "evictions": 0,
            "evicted_bytes": 0,
            "bytes_avoided_github": 0,
            "bytes_avoided_peer": 0,
            "bytes_avoided_r2": 0,
        }
        for field, amount in increments.items():
            value[field] = int(value.get(field, 0)) + int(amount)
        _atomic_json(path, value)
        return value


def _snapshot(store: Store, stats: dict | None = None) -> dict:
    stats = stats or _read_json(store.root / "state" / "stats.json") or {}
    total_bytes = 0
    object_count = 0
    try:
        parents = list((store.root / "objects").glob("*"))
    except OSError:
        parents = []
    for parent in parents:
        try:
            if not parent.is_dir():
                continue
            entries = list(parent.iterdir())
        except OSError:
            continue
        for entry in entries:
            metadata = _read_json(entry / METADATA_NAME)
            if metadata and isinstance(metadata.get("size"), int):
                total_bytes += metadata["size"]
                object_count += 1
    lookups = int(stats.get("lookups", 0))
    hits = int(stats.get("hits", 0))
    evictions = int(stats.get("evictions", 0))
    return {
        "lookups": lookups,
        "hits": hits,
        "local_hit_rate": round(hits / lookups, 4) if lookups else 0.0,
        "object_count": object_count,
        "disk_bytes": total_bytes,
        "evictions": evictions,
        "eviction_rate": round(evictions / lookups, 4) if lookups else 0.0,
        "bytes_avoided_github": int(stats.get("bytes_avoided_github", 0)),
        "bytes_avoided_peer": int(stats.get("bytes_avoided_peer", 0)),
        "bytes_avoided_r2": int(stats.get("bytes_avoided_r2", 0)),
    }


def _fill_waiters(fill: dict | None) -> list[str]:
    if not fill:
        return []
    raw = fill.get("waiters", [])
    if not isinstance(raw, list):
        return []
    return [
        token
        for token in raw[:MAX_WAITERS_PER_FILL]
        if isinstance(token, str) and re.fullmatch(r"[a-f0-9]{32}", token)
    ]


def _register_waiter_locked(store: Store, key: str, fill: dict) -> tuple[str, Path, int, int] | None:
    waiters = _fill_waiters(fill)
    if len(waiters) >= MAX_WAITERS_PER_FILL:
        return None
    token = secrets.token_hex(16)
    path = store.signal(key, token)
    read_fd = -1
    keepalive_fd = -1
    try:
        os.mkfifo(path, 0o660)
        # Open the read end before publishing the waiter record. Keep one local
        # writer open so select() observes only an explicit producer write,
        # never a no-writer FIFO EOF/hangup.
        read_fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
        keepalive_fd = os.open(path, os.O_WRONLY | os.O_NONBLOCK)
        updated = dict(fill)
        updated["waiters"] = [*waiters, token]
        _atomic_json(store.fill(key), updated)
        return token, path, read_fd, keepalive_fd
    except Exception:
        if read_fd >= 0:
            os.close(read_fd)
        if keepalive_fd >= 0:
            os.close(keepalive_fd)
        path.unlink(missing_ok=True)
        raise


def _remove_waiter_locked(store: Store, key: str, token: str) -> None:
    fill = _read_json(store.fill(key))
    if not fill:
        return
    waiters = _fill_waiters(fill)
    if token not in waiters:
        return
    updated = dict(fill)
    updated["waiters"] = [value for value in waiters if value != token]
    _atomic_json(store.fill(key), updated)


def _finish_fill_locked(store: Store, key: str, token: str) -> list[str]:
    fill = _read_json(store.fill(key))
    if not token or not fill or fill.get("token") != token:
        return []
    waiters = _fill_waiters(fill)
    store.fill(key).unlink(missing_ok=True)
    return waiters


def _signal_waiters(store: Store, key: str, waiters: list[str]) -> None:
    for token in waiters:
        path = store.signal(key, token)
        fd = -1
        try:
            fd = os.open(path, os.O_WRONLY | os.O_NONBLOCK)
            os.write(fd, b"1")
        except OSError as error:
            if error.errno not in {errno.ENOENT, errno.ENXIO, errno.EPIPE}:
                raise
        finally:
            if fd >= 0:
                os.close(fd)
            path.unlink(missing_ok=True)


def _wait_for_fill_signal(read_fd: int, timeout: float) -> bool:
    ready, _, _ = select.select([read_fd], [], [], max(0.0, timeout))
    if not ready:
        return False
    try:
        return os.read(read_fd, 1) == b"1"
    except BlockingIOError:
        return False


def _hit_locked(
    store: Store,
    identity: Identity,
    destination: Path,
    started: float,
    *,
    waited: bool,
) -> dict | None:
    validated = _validate_entry_locked(store, identity)
    if not validated:
        return None
    key = identity.key()
    metadata, obj = validated
    _materialize(obj, destination)
    lease = _create_lease_locked(store, key)
    _state_update_locked(store, key, consumer_hit_count=1)
    avoided = metadata["size"]
    fallback = os.environ.get("CMUX_NODE_PRODUCT_CACHE_FALLBACK_SOURCE", "").strip()
    increments = {"hits": 1}
    if fallback == "peer":
        increments["bytes_avoided_peer"] = avoided
    elif fallback == "r2":
        increments["bytes_avoided_r2"] = avoided
    elif fallback == "github":
        increments["bytes_avoided_github"] = avoided
    stats = _stats_update(store, **increments)
    elapsed = time.monotonic() - started
    return {
        "status": "hit",
        "hit": True,
        "fill": False,
        "token": "",
        "lease": lease,
        "lookup_seconds": round(elapsed, 6),
        "waited_seconds": round(elapsed if waited else 0.0, 6),
        "archive_bytes": metadata["size"],
        "source_class": metadata["source_class"],
        "snapshot": _snapshot(store, stats),
    }


def _fallback_result(store: Store, started: float, *, waited: bool) -> dict:
    stats = _stats_update(store, fallbacks=1)
    elapsed = time.monotonic() - started
    return {
        "status": "fallback",
        "hit": False,
        "fill": False,
        "token": "",
        "lease": "",
        "lookup_seconds": round(elapsed, 6),
        "waited_seconds": round(elapsed if waited else 0.0, 6),
        "snapshot": _snapshot(store, stats),
    }


def acquire(
    store: Store | None,
    identity: Identity,
    destination: Path,
    *,
    wait: float = DEFAULT_WAIT_SECONDS,
    fill_lease: float = DEFAULT_FILL_LEASE_SECONDS,
) -> dict:
    started = time.monotonic()
    if store is None:
        return {"status": "disabled", "hit": False, "fill": False, "token": "", "lease": "", "lookup_seconds": 0.0, "waited_seconds": 0.0}
    key = identity.key()
    _stats_update(store, lookups=1)
    stale_waiters: list[str] = []
    registration: tuple[str, Path, int, int] | None = None
    fill_result: dict | None = None
    immediate_fallback = False

    with store.lock(key):
        hit = _hit_locked(store, identity, destination, started, waited=False)
        if hit:
            return hit

        now = time.time()
        fill = _read_json(store.fill(key))
        active = (
            fill is not None
            and isinstance(fill.get("deadline_epoch"), (int, float))
            and fill["deadline_epoch"] > now
            and isinstance(fill.get("token"), str)
            and len(fill["token"]) >= 16
        )
        if not active:
            stale_waiters = _fill_waiters(fill)
            token = secrets.token_hex(16)
            _atomic_json(store.fill(key), {
                "token": token,
                "created_epoch": now,
                "deadline_epoch": now + max(fill_lease, wait, 1.0),
                "run_id": os.environ.get("GITHUB_RUN_ID", ""),
                "job": os.environ.get("GITHUB_JOB", ""),
                "waiters": [],
            })
            stats = _stats_update(store, fill_owners=1)
            fill_result = {
                "status": "fill",
                "hit": False,
                "fill": True,
                "token": token,
                "lease": "",
                "lookup_seconds": round(time.monotonic() - started, 6),
                "waited_seconds": 0.0,
                "snapshot": _snapshot(store, stats),
            }
        elif wait <= 0:
            immediate_fallback = True
        else:
            registration = _register_waiter_locked(store, key, fill)
            if registration is None:
                immediate_fallback = True
            else:
                _stats_update(store, waiters=1)

    if stale_waiters:
        _signal_waiters(store, key, stale_waiters)
    if fill_result is not None:
        return fill_result
    if immediate_fallback:
        return _fallback_result(store, started, waited=False)

    assert registration is not None
    waiter_token, signal_path, read_fd, keepalive_fd = registration
    try:
        signaled = _wait_for_fill_signal(read_fd, wait)
    finally:
        os.close(keepalive_fd)
        os.close(read_fd)
        signal_path.unlink(missing_ok=True)

    if not signaled:
        with store.lock(key):
            _remove_waiter_locked(store, key, waiter_token)
        return _fallback_result(store, started, waited=True)

    with store.lock(key):
        hit = _hit_locked(store, identity, destination, started, waited=True)
        if hit:
            return hit
    return _fallback_result(store, started, waited=True)

def github_metadata(identity: Identity) -> dict:
    raw = subprocess.check_output(
        ["gh", "api", f"repos/{identity.repository}/actions/artifacts/{identity.artifact_id}"],
        text=True,
        timeout=20,
    )
    return json.loads(raw)


def same_run_provider_metadata(identity: Identity) -> dict:
    """Reconstruct provider metadata only for this exact producing workflow attempt.

    Same-run GitHub workflow outputs establish the accepted producer identity.
    This keeps a verified peer hit usable during a GitHub API outage without
    making the peer a new trust root.
    """
    if (
        os.environ.get("GITHUB_REPOSITORY", "").casefold() != identity.repository.casefold()
        or os.environ.get("GITHUB_RUN_ID", "") != str(identity.producer_run_id)
        or os.environ.get("GITHUB_RUN_ATTEMPT", "1") != str(identity.producer_run_attempt)
    ):
        raise ValueError("peer product producer is not this workflow attempt")
    return {
        "id": identity.artifact_id,
        "expired": False,
        "digest": "sha256:" + identity.provider_digest,
        "workflow_run": {"id": identity.producer_run_id},
        "created_at": None,
    }


def _verify_provider(identity: Identity, metadata: dict) -> str | None:
    digest = metadata.get("digest", "")
    run = metadata.get("workflow_run")
    if (
        metadata.get("id") != identity.artifact_id
        or metadata.get("expired") is not False
        or not isinstance(digest, str)
        or _digest(digest) != identity.provider_digest
        or not isinstance(run, dict)
        or run.get("id") != identity.producer_run_id
    ):
        raise ValueError("provider artifact identity mismatch")
    created = metadata.get("created_at")
    return created if isinstance(created, str) else None


def _read_receipts(archive: Path) -> tuple[dict, dict]:
    found: dict[str, dict] = {}
    with tarfile.open(archive, "r:gz") as tar:
        for count, member in enumerate(tar, 1):
            if count > MAX_TAR_MEMBERS:
                raise ValueError("too many product archive members")
            if member.name not in {REUSE_RECEIPT, PRODUCT_RECEIPT}:
                continue
            if member.name in found or not member.isfile() or member.size > MAX_RECEIPT_BYTES:
                raise ValueError("invalid product receipt entry")
            source = tar.extractfile(member)
            if source is None:
                raise ValueError("missing product receipt body")
            raw = source.read(MAX_RECEIPT_BYTES + 1)
            if len(raw) > MAX_RECEIPT_BYTES:
                raise ValueError("oversized product receipt")
            value = json.loads(raw)
            if not isinstance(value, dict):
                raise ValueError("invalid product receipt")
            found[member.name] = value
    if set(found) != {REUSE_RECEIPT, PRODUCT_RECEIPT}:
        raise ValueError("missing product receipt")
    return found[REUSE_RECEIPT], found[PRODUCT_RECEIPT]


def _verify_archive(archive: Path, identity: Identity) -> int:
    size = archive.stat().st_size
    if size <= 0 or _sha256(archive) != identity.archive_digest:
        raise ValueError("compiled product archive digest mismatch")
    reuse, product = _read_receipts(archive)
    contract = reuse.get("contract")
    if (
        not isinstance(contract, dict)
        or _canonical_contract_key(contract) != identity.product_contract
        or reuse.get("revision") != identity.source_revision
        or product.get("revision") != identity.source_revision
    ):
        raise ValueError("compiled product receipt identity mismatch")
    return size


def _copy_verified(source: Path, target: Path, expected_digest: str) -> int:
    digest = hashlib.sha256()
    size = 0
    with source.open("rb") as incoming, target.open("xb") as output:
        for chunk in iter(lambda: incoming.read(1024 * 1024), b""):
            output.write(chunk)
            digest.update(chunk)
            size += len(chunk)
        output.flush()
        os.fsync(output.fileno())
    if digest.hexdigest() != expected_digest:
        raise ValueError("compiled product changed while publishing")
    return size


def _publish_locked(
    store: Store,
    identity: Identity,
    archive: Path,
    source_class: str,
    provider_created_at: str | None,
) -> dict:
    key = identity.key()
    existing = _validate_entry_locked(store, identity)
    if existing:
        metadata, _ = existing
        return metadata
    verified_size = _verify_archive(archive, identity)
    parent = store.entry(key).parent
    _mkdir(parent)
    staging = Path(tempfile.mkdtemp(prefix=f"{key}.", dir=store.root / "staging"))
    try:
        obj = staging / OBJECT_NAME
        copied = _copy_verified(archive, obj, identity.archive_digest)
        if copied != verified_size:
            raise ValueError("compiled product size changed while publishing")
        created_epoch = time.time()
        metadata = {
            "schema_generation": SCHEMA_GENERATION,
            "format_generation": FORMAT_GENERATION,
            "identity": identity.as_dict(),
            "object_digest": identity.archive_digest,
            "size": copied,
            "created_epoch": created_epoch,
            "provider_created_at": provider_created_at,
            "source_class": source_class,
        }
        metadata_path = staging / METADATA_NAME
        metadata_path.write_text(json.dumps(metadata, sort_keys=True, separators=(",", ":")))
        _fsync_file(metadata_path)
        obj.chmod(0o444)
        metadata_path.chmod(0o444)
        _fsync_dir(staging)
        final = store.entry(key)
        if final.exists():
            _remove_entry_locked(store, key)
        os.rename(staging, final)
        final.chmod(0o555)
        _fsync_dir(parent)
        return metadata
    finally:
        if staging.exists():
            try:
                staging.chmod(0o770)
            except OSError:
                pass
            shutil.rmtree(staging, ignore_errors=True)


def _abort_fill_locked(store: Store, key: str, token: str) -> list[str]:
    return _finish_fill_locked(store, key, token)


def _parse_created(value: str | None) -> float | None:
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def finalize(
    store: Store | None,
    identity: Identity,
    archive: Path,
    *,
    token: str = "",
    lease_token: str = "",
    source_class: str = "github",
    restore_succeeded: bool,
    budget: int = DEFAULT_BUDGET_BYTES,
    provider_metadata: Callable[[Identity], dict] = github_metadata,
) -> dict:
    if store is None:
        return {"status": "disabled"}
    if source_class not in {"github", "r2", "peer", "producer-local"}:
        source_class = "github"
    key = identity.key()
    if not restore_succeeded:
        with store.lock(key):
            waiters = _abort_fill_locked(store, key, token)
            _release_lease_locked(store, key, lease_token)
        _signal_waiters(store, key, waiters)
        return {"status": "aborted"}

    started = time.monotonic()
    try:
        if token:
            provider = provider_metadata(identity)
            provider_created_at = _verify_provider(identity, provider)
            with store.lock(key):
                fill = _read_json(store.fill(key))
                if not fill or fill.get("token") != token:
                    return {"status": "lost-fill"}
                metadata = _publish_locked(
                    store, identity, archive, source_class, provider_created_at
                )
                state = _state_update_locked(store, key, verified_restore_count=1)
                fill_started = fill.get("created_epoch")
                waiters = _finish_fill_locked(store, key, token)
            _signal_waiters(store, key, waiters)
            reclaim_result = reclaim(store, budget, protected_key=key)
            producer_epoch = _parse_created(metadata.get("provider_created_at"))
            now_epoch = time.time()
            return {
                "status": "published",
                "fill_seconds": round(now_epoch - float(fill_started), 6)
                if isinstance(fill_started, (int, float)) else round(time.monotonic() - started, 6),
                "producer_to_consumer_seconds": round(now_epoch - producer_epoch, 6)
                if producer_epoch is not None else None,
                "archive_bytes": metadata["size"],
                "verified_restore_count": state["verified_restore_count"],
                **reclaim_result,
            }
        with store.lock(key):
            metadata = _read_json(store.entry(key) / METADATA_NAME)
            _release_lease_locked(store, key, lease_token)
            if metadata is None or not _metadata_matches(metadata, identity):
                return {"status": "evicted-after-materialize"}
            state = _state_update_locked(store, key, verified_restore_count=1)
        producer_epoch = _parse_created(metadata.get("provider_created_at"))
        now_epoch = time.time()
        return {
            "status": "verified-hit",
            "producer_to_consumer_seconds": round(now_epoch - producer_epoch, 6)
            if producer_epoch is not None else None,
            "verified_restore_count": state["verified_restore_count"],
        }
    except (OSError, ValueError, KeyError, TypeError, tarfile.TarError, subprocess.SubprocessError) as error:
        waiters = []
        with contextlib.suppress(OSError):
            with store.lock(key):
                waiters = _abort_fill_locked(store, key, token)
                _release_lease_locked(store, key, lease_token)
        with contextlib.suppress(OSError):
            _signal_waiters(store, key, waiters)
        return {"status": "cache-error", "error": type(error).__name__}


def seed(
    store: Store | None,
    identity: Identity,
    archive: Path,
    *,
    budget: int = DEFAULT_BUDGET_BYTES,
    provider_metadata: Callable[[Identity], dict] = github_metadata,
) -> dict:
    if store is None:
        return {"status": "disabled"}
    key = identity.key()
    try:
        provider = provider_metadata(identity)
        provider_created_at = _verify_provider(identity, provider)
        with store.lock(key):
            metadata = _publish_locked(
                store, identity, archive, "producer-local", provider_created_at
            )
            state = _read_json(store.state(key))
            if state is None:
                state = {
                    "last_used_ns": time.time_ns(),
                    "consumer_hit_count": 0,
                    "verified_restore_count": 0,
                }
                _atomic_json(store.state(key), state)
            current_fill = _read_json(store.fill(key)) or {}
            waiters = _abort_fill_locked(store, key, current_fill.get("token", ""))
        _signal_waiters(store, key, waiters)
        reclaim_result = reclaim(store, budget, protected_key=key)
        return {"status": "seeded", "archive_bytes": metadata["size"], **reclaim_result}
    except (OSError, ValueError, KeyError, TypeError, tarfile.TarError, subprocess.SubprocessError) as error:
        return {"status": "cache-error", "error": type(error).__name__}


def _reclaim_abandoned_staging(store: Store) -> tuple[int, int]:
    reclaimed = 0
    reclaimed_bytes = 0
    staging_root = store.root / "staging"
    for path in staging_root.iterdir():
        if not path.is_dir():
            continue
        key = path.name.split(".", 1)[0]
        if not _HEX64.fullmatch(key):
            continue
        try:
            with store.lock(key, blocking=False):
                if not path.exists():
                    continue
                size = 0
                for child in path.rglob("*"):
                    try:
                        if child.is_file():
                            size += child.stat().st_size
                    except OSError:
                        pass
                try:
                    path.chmod(0o770)
                except OSError:
                    pass
                for child in path.rglob("*"):
                    try:
                        child.chmod(0o660 if child.is_file() else 0o770)
                    except OSError:
                        pass
                shutil.rmtree(path, ignore_errors=True)
                if not path.exists():
                    reclaimed += 1
                    reclaimed_bytes += size
        except BlockingIOError:
            continue
    return reclaimed, reclaimed_bytes


def reclaim(store: Store, budget: int, *, protected_key: str | None = None) -> dict:
    budget = max(0, int(budget))
    staging_reclaims, staging_reclaimed_bytes = _reclaim_abandoned_staging(store)
    candidates = []
    total = 0
    for prefix in (store.root / "objects").glob("*"):
        if not prefix.is_dir():
            continue
        for entry in prefix.iterdir():
            metadata = _read_json(entry / METADATA_NAME)
            if not metadata or not isinstance(metadata.get("size"), int):
                continue
            size = metadata["size"]
            total += size
            key = entry.name
            state = _read_json(store.state(key)) or {}
            candidates.append((int(state.get("last_used_ns", 0)), key, size))
    evicted = 0
    evicted_bytes = 0
    for _, key, size in sorted(candidates):
        if total <= budget:
            break
        if key == protected_key:
            continue
        try:
            with store.lock(key, blocking=False):
                entry = store.entry(key)
                if not entry.exists():
                    continue
                if _active_leases_locked(store, key):
                    continue
                _remove_entry_locked(store, key)
                total -= size
                evicted += 1
                evicted_bytes += size
        except BlockingIOError:
            continue
    stats = _stats_update(store, evictions=evicted, evicted_bytes=evicted_bytes) if evicted else None
    return {
        "disk_bytes": total,
        "evicted_objects": evicted,
        "evicted_bytes": evicted_bytes,
        "staging_reclaims": staging_reclaims,
        "staging_reclaimed_bytes": staging_reclaimed_bytes,
        "snapshot": _snapshot(store, stats),
    }


def _append_outputs(values: dict) -> None:
    path = os.environ.get("GITHUB_OUTPUT")
    if not path:
        return
    with open(path, "a") as output:
        for key, value in values.items():
            if isinstance(value, bool):
                value = str(value).lower()
            elif value is None:
                value = ""
            elif isinstance(value, (dict, list)):
                value = json.dumps(value, sort_keys=True, separators=(",", ":"))
            output.write(f"{key}={value}\n")


def _report(event: str, result: dict) -> None:
    record = {
        "event": event,
        "run_id": os.environ.get("GITHUB_RUN_ID"),
        "job": os.environ.get("GITHUB_JOB"),
        "runner_name": os.environ.get("RUNNER_NAME"),
        **result,
    }
    print("CMUX_NODE_PRODUCT_CACHE " + json.dumps(record, sort_keys=True))
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        try:
            with open(summary, "a") as handle:
                handle.write("### Node-local compiled product cache\n\n```json\n")
                handle.write(json.dumps(record, indent=2, sort_keys=True))
                handle.write("\n```\n")
        except OSError:
            pass


def main() -> None:
    if len(sys.argv) < 2 or sys.argv[1] not in {"acquire", "finalize", "seed"}:
        raise SystemExit("usage: node-product-cache.py acquire DEST | finalize ARCHIVE | seed ARCHIVE")
    command = sys.argv[1]
    store = configured_store()
    try:
        identity = Identity.from_env()
    except ValueError as error:
        result = {"status": "identity-unavailable", "error": type(error).__name__}
        if command == "acquire":
            result.update({"hit": False, "fill": False, "token": "", "lease": ""})
            _append_outputs(result)
        _report(command, result)
        return

    if command == "acquire":
        if len(sys.argv) != 3:
            raise SystemExit("usage: node-product-cache.py acquire DEST")
        try:
            result = acquire(store, identity, Path(sys.argv[2]), wait=wait_seconds())
        except (OSError, ValueError, TypeError) as error:
            result = {"status": "cache-error", "error": type(error).__name__, "hit": False, "fill": False, "token": "", "lease": ""}
        _append_outputs({
            "status": result.get("status", ""),
            "hit": result.get("hit", False),
            "fill": result.get("fill", False),
            "token": result.get("token", ""),
            "lease": result.get("lease", ""),
            "lookup_seconds": result.get("lookup_seconds", ""),
            "waited_seconds": result.get("waited_seconds", ""),
        })
    elif command == "finalize":
        if len(sys.argv) != 3:
            raise SystemExit("usage: node-product-cache.py finalize ARCHIVE")
        source_class = os.environ.get("CMUX_NODE_PRODUCT_SOURCE_CLASS", "github")
        result = finalize(
            store,
            identity,
            Path(sys.argv[2]),
            token=os.environ.get("CMUX_NODE_PRODUCT_CACHE_TOKEN", ""),
            lease_token=os.environ.get("CMUX_NODE_PRODUCT_CACHE_LEASE", ""),
            source_class=source_class,
            restore_succeeded=os.environ.get("CMUX_PRODUCT_RESTORE_SUCCEEDED") == "true",
            budget=budget_bytes(),
            provider_metadata=(
                same_run_provider_metadata if source_class == "peer" else github_metadata
            ),
        )
    else:
        if len(sys.argv) != 3:
            raise SystemExit("usage: node-product-cache.py seed ARCHIVE")
        result = seed(store, identity, Path(sys.argv[2]), budget=budget_bytes())
    _report(command, result)


if __name__ == "__main__":
    main()
