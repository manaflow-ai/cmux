#!/usr/bin/env python3
"""Conditional R2 writes and a lease lock, for publishers that run side by side.

The DEV publisher (cmux-next-dev-daily.yml) has no concurrency group: a group
replaces a pending run, which the dev-build rule forbids. Its writers stay
correct with R2's conditional requests instead.

    r2_cas.py get --key KEY --out FILE
        Writes the object to FILE and prints its ETag, or prints "absent".

    r2_cas.py put --key KEY --file FILE --cache-control CC [--content-type T]
                  (--if-match ETAG | --if-absent)
        Writes FILE only while the object still has ETAG (or does not exist).
        Exits 3 when another writer changed it first (HTTP 412 or 409).

    r2_cas.py delete --key KEY
        Removes an object this run alone created (a name unique to the run).
        Unconditional: R2 does not document conditional DELETE.

    r2_cas.py lock --key KEY --owner ID --ttl SECONDS --wait SECONDS
                   [--renew-every SECONDS --max-hold SECONDS --pid-file FILE]
        Takes the lease at KEY: creates it only while absent, or replaces a
        released or expired lease only while it still holds the bytes read.
        Expiry is judged on R2's clock (the response Date against the lease's
        Last-Modified), never a runner's, so runners' clock skew cannot end a
        live lease early, and by the TTL stored in the lease record (its
        writer's), never the waiter's; a record without one is given
        LEGACY_TTL. A transient R2 error (a dropped connection, a
        timeout, a 429 or 5xx) is retried for the rest of the wait, and a write
        whose response was lost is recognised by the attempt's own token on the
        next read. Exits 3 when the wait runs out.
        With --renew-every it then starts a heartbeat in the background (its
        PID in FILE) that renews the lease every SECONDS, so a short TTL
        frees a dead holder's lease quickly while a live one keeps it. The
        heartbeat stops when the lease is no longer this attempt's, when the
        job's Runner.Worker exits, after --max-hold seconds, or on unlock; and
        the runner's job-end orphan cleanup ends it with the job.

    r2_cas.py holds --key KEY --owner ID
        Exits 0 while ID holds the lease, 3 when it does not.

    r2_cas.py unlock --key KEY --owner ID [--pid-file FILE]
        Stops the heartbeat in FILE, then marks the lease released (a
        conditional PUT; R2 does not document conditional DELETE) while it
        still names ID and holds the bytes read. Exits 0 when it released the
        lease and 4 when there was nothing to release (absent, released, or
        another owner's).

Every call reads AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, R2_ENDPOINT and
R2_BUCKET from the environment.
"""

from __future__ import annotations

import argparse
import datetime as dt
import email.utils
import http.client
import importlib.util
import json
import os
import secrets
import signal
import subprocess
import sys
import time
import urllib.error
from pathlib import Path

_spec = importlib.util.spec_from_file_location("upload_r2_object", Path(__file__).with_name("upload-r2-object.py"))
r2 = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(r2)

CONFLICT = 3
NOTHING_TO_RELEASE = 4
POLL = 10
# A lease record without its own "ttl" (#32275's format: no heartbeat) was written
# with the longest TTL any writer then passed (publish-nightly's 180-minute timeout).
LEGACY_TTL = 10800


def _target(key: str, cache_control: str = "no-cache", content_type: str = "application/octet-stream") -> argparse.Namespace:
    return argparse.Namespace(
        endpoint_url=os.environ["R2_ENDPOINT"], bucket=os.environ["R2_BUCKET"], key=key,
        cache_control=cache_control, content_type=content_type,
    )


def _now() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def read(key: str) -> tuple[str | None, bytes, float]:
    """The object's ETag, bytes and age in seconds on R2's clock; (None, b"", 0) when absent."""
    request = r2._build_signed_request(_target(key), b"", _now(), method="GET")
    try:
        with r2._open_signed_request(request, timeout=120) as response:
            body = response.read()
            now = email.utils.parsedate_to_datetime(response.headers["Date"])
            modified = email.utils.parsedate_to_datetime(response.headers["Last-Modified"])
            return response.headers.get("ETag"), body, (now - modified).total_seconds()
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return None, b"", 0.0
        raise


def get(key: str) -> tuple[str | None, bytes]:
    """The object's ETag and bytes, or (None, b"") when it does not exist."""
    etag, body, _ = read(key)
    return etag, body


def put(key: str, body: bytes, *, etag: str | None, cache_control: str, content_type: str) -> bool:
    """Writes body while the object still has etag (None: while it does not exist)."""
    condition = {"if-match": etag} if etag else {"if-none-match": "*"}
    request = r2._build_signed_request(_target(key, cache_control, content_type), body, _now(), extra_headers=condition)
    try:
        with r2._open_signed_request(request, timeout=300) as response:
            response.read()
        return True
    except urllib.error.HTTPError as error:
        # 412: the condition failed; 409: R2 refused a concurrent write to the key.
        if error.code in (409, 412):
            return False
        raise


def delete(key: str) -> None:
    request = r2._build_signed_request(_target(key), b"", _now(), method="DELETE")
    try:
        with r2._open_signed_request(request, timeout=60) as response:
            response.read()
    except urllib.error.HTTPError as error:
        if error.code != 404:
            raise


def _lease(body: bytes) -> dict:
    try:
        lease = json.loads(body or b"{}")
    except ValueError:
        return {}
    return lease if isinstance(lease, dict) else {}


def _store(key: str, lease: dict, etag: str | None) -> bool:
    # A fresh nonce in every write: R2's ETag follows the bytes, so each renewal
    # changes it and a waiter that read the lease as expired cannot then take it.
    body = json.dumps({**lease, "nonce": time.time_ns()}).encode()
    return put(key, body, etag=etag, cache_control="no-store", content_type="application/json")


def transient(error: BaseException) -> bool:
    """An R2 error worth retrying: throttling, a server error, or a broken connection."""
    if isinstance(error, urllib.error.HTTPError):
        return error.code in (408, 425, 429) or error.code >= 500
    return isinstance(error, (urllib.error.URLError, OSError, http.client.HTTPException))


def _ttl(lease: dict) -> float:
    """The TTL the lease's own writer chose; a waiter never judges it by its own."""
    try:
        ttl = float(lease["ttl"])
    except (KeyError, TypeError, ValueError):
        return LEGACY_TTL
    return ttl if ttl > 0 else LEGACY_TTL


def _mine(lease: dict, owner: str, token: str | None) -> bool:
    return (lease.get("owner") == owner and not lease.get("released")
            and (token is None or lease.get("token") == token))


def lock(key: str, owner: str, ttl: int, wait: int, clock=time.monotonic, sleep=time.sleep,
         token: str | None = None, log=lambda message: print(message, file=sys.stderr)) -> bool:
    """Takes the lease; False when the wait runs out. Writes {"owner", "token", "ttl"}: the
    token is this attempt's own, so a PUT that reached R2 but lost its response reads back as
    ours, and every waiter judges expiry by the record's ttl, not by its own."""
    token = token or secrets.token_hex(8)
    record = {"owner": owner, "token": token, "ttl": ttl}
    deadline = clock() + wait
    while True:
        try:
            etag, body, age = read(key)
            lease = _lease(body)
            if etag is not None and _mine(lease, owner, token):
                # An earlier PUT of this attempt landed and its response was lost. It may be
                # near or past its TTL by now: rewrite it (a fresh Last-Modified and ETag)
                # while it still holds the bytes read, before reporting it held.
                if _store(key, record, etag):
                    return True
            else:
                free = etag is None or lease.get("released") or age > _ttl(lease)
                if free and _store(key, record, etag):
                    return True
        except Exception as error:  # noqa: BLE001 - only transient errors are retried
            if not transient(error):
                raise
            log(f"r2_cas lock: transient R2 error, retrying: {error}")
        if clock() >= deadline:
            return False
        sleep(POLL)


def holds(key: str, owner: str) -> bool:
    etag, body, _ = read(key)
    lease = _lease(body)
    return etag is not None and _mine(lease, owner, None)


def renew(key: str, owner: str, token: str | None) -> bool:
    """Rewrites the lease (a new nonce, so a new Last-Modified and ETag) while this
    attempt holds it; False once it does not."""
    etag, body, _ = read(key)
    lease = _lease(body)
    if etag is None or not _mine(lease, owner, token):
        return False
    renewed = {"owner": owner, "token": lease.get("token")}
    if "ttl" in lease:
        renewed["ttl"] = lease["ttl"]
    if _store(key, renewed, etag):
        return True
    return holds(key, owner)  # lost the write to a release or a taker: read again


def _alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def runner_worker_pid(pid: int | None = None) -> int | None:
    """The GitHub Actions Runner.Worker process this one descends from, or None."""
    pid = pid or os.getpid()
    for _ in range(64):
        try:
            out = subprocess.run(["ps", "-o", "ppid=", "-o", "args=", "-p", str(pid)],
                                 capture_output=True, text=True, timeout=10, check=False).stdout.strip()
        except (OSError, subprocess.SubprocessError):
            return None
        if not out:
            return None
        ppid, _, args = out.partition(" ")
        if "Runner.Worker" in args and pid != os.getpid():
            return pid
        try:
            pid = int(ppid)
        except ValueError:
            return None
        if pid <= 1:
            return None
    return None


def heartbeat(key: str, owner: str, token: str | None, every: int, max_hold: int, worker: int | None = None,
              clock=time.monotonic, sleep=time.sleep, alive=_alive, log=lambda message: None) -> str:
    """Renews the lease every `every` seconds. Returns why it stopped. A failed
    renewal is retried on the next beat; the TTL spans several beats."""
    stop_at = clock() + max_hold
    while True:
        sleep(every)
        if clock() >= stop_at:
            return "max hold reached"
        if worker is not None and not alive(worker):
            return "the job's Runner.Worker exited"
        try:
            if not renew(key, owner, token):
                return "the lease is no longer this attempt's"
        except Exception as error:  # noqa: BLE001 - keep beating through R2 errors
            log(f"renew failed, retrying next beat: {error}")


def start_heartbeat(key: str, owner: str, token: str, every: int, max_hold: int, pid_file: str) -> int:
    worker = runner_worker_pid()
    command = [sys.executable, os.path.abspath(__file__), "heartbeat", "--key", key, "--owner", owner,
               "--token", token, "--every", str(every), "--max-hold", str(max_hold)]
    if worker is not None:
        command += ["--worker", str(worker)]
    log_path = Path(pid_file).with_suffix(".log")
    with open(log_path, "ab") as log_file:
        # Its own session and no shared pipes, so the step that starts it can finish.
        process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=log_file, stderr=log_file,
                                   start_new_session=True)
    Path(pid_file).write_text(str(process.pid))
    return process.pid


def stop_heartbeat(pid_file: str) -> None:
    path = Path(pid_file)
    try:
        pid = int(path.read_text())
    except (OSError, ValueError):
        return
    try:
        os.kill(pid, signal.SIGTERM)  # the heartbeat this job started
    except ProcessLookupError:
        pass
    path.unlink(missing_ok=True)


def unlock(key: str, owner: str) -> bool:
    """True when this call released the lease; False when there was nothing to release."""
    etag, body, _ = read(key)
    lease = _lease(body)
    if etag is None or not _mine(lease, owner, None):
        return False
    if _store(key, {"owner": owner, "token": lease.get("token"), "released": True}, etag):
        return True
    # Lost a race with this job's own heartbeat (a new ETag); read again.
    return unlock(key, owner)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    g = sub.add_parser("get")
    g.add_argument("--key", required=True)
    g.add_argument("--out", required=True)
    p = sub.add_parser("put")
    p.add_argument("--key", required=True)
    p.add_argument("--file", required=True)
    p.add_argument("--cache-control", required=True)
    p.add_argument("--content-type", default="application/octet-stream")
    cond = p.add_mutually_exclusive_group(required=True)
    cond.add_argument("--if-match")
    cond.add_argument("--if-absent", action="store_true")
    dl = sub.add_parser("delete")
    dl.add_argument("--key", required=True)
    lk = sub.add_parser("lock")
    lk.add_argument("--key", required=True)
    lk.add_argument("--owner", required=True)
    lk.add_argument("--ttl", type=int, required=True)
    lk.add_argument("--wait", type=int, required=True)
    lk.add_argument("--renew-every", type=int)
    lk.add_argument("--max-hold", type=int)
    lk.add_argument("--pid-file")
    hb = sub.add_parser("heartbeat")
    hb.add_argument("--key", required=True)
    hb.add_argument("--owner", required=True)
    hb.add_argument("--token")
    hb.add_argument("--every", type=int, required=True)
    hb.add_argument("--max-hold", type=int, required=True)
    hb.add_argument("--worker", type=int)
    hd = sub.add_parser("holds")
    hd.add_argument("--key", required=True)
    hd.add_argument("--owner", required=True)
    ul = sub.add_parser("unlock")
    ul.add_argument("--key", required=True)
    ul.add_argument("--owner", required=True)
    ul.add_argument("--pid-file")
    args = parser.parse_args(argv)

    if args.command == "get":
        etag, body = get(args.key)
        Path(args.out).write_bytes(body)
        print(etag or "absent")
        return 0
    if args.command == "put":
        written = put(args.key, Path(args.file).read_bytes(), etag=None if args.if_absent else args.if_match,
                      cache_control=args.cache_control, content_type=args.content_type)
        return 0 if written else CONFLICT
    if args.command == "delete":
        delete(args.key)
        return 0
    if args.command == "lock":
        renewing = args.renew_every is not None
        if renewing and not (args.max_hold and args.pid_file):
            parser.error("--renew-every needs --max-hold and --pid-file")
        if renewing and not 0 < args.renew_every * 3 <= args.ttl:
            parser.error("--renew-every must leave at least three renewals inside --ttl")
        token = secrets.token_hex(8)
        if not lock(args.key, args.owner, args.ttl, args.wait, token=token):
            return CONFLICT
        if renewing:
            start_heartbeat(args.key, args.owner, token, args.renew_every, args.max_hold, args.pid_file)
        return 0
    if args.command == "heartbeat":
        def log(message: str) -> None:
            print(f"{time.strftime('%H:%M:%S')} {message}", flush=True)

        log(f"heartbeat for {args.key} every {args.every}s (worker {args.worker})")
        log("stopped: " + heartbeat(args.key, args.owner, args.token, args.every, args.max_hold, args.worker, log=log))
        return 0
    if args.command == "holds":
        return 0 if holds(args.key, args.owner) else CONFLICT
    if args.pid_file:
        stop_heartbeat(args.pid_file)
    return 0 if unlock(args.key, args.owner) else NOTHING_TO_RELEASE


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
