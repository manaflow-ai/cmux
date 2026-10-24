#!/usr/bin/env python3
"""Run one trusted CI command with a capacity lease and an atomic receipt."""
import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import fcntl
import json
import math
import os
from pathlib import Path
import signal
import stat
import subprocess
import sys
import tempfile
import threading
import time
import uuid


class CapacityUnavailable(Exception):
    pass


def utc_now():
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds")


def number(value):
    result = float(value)
    if not math.isfinite(result) or result < 0:
        raise argparse.ArgumentTypeError("use a finite, nonnegative number")
    return result


def private_file(path):
    fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o022:
        os.close(fd)
        raise ValueError("capacity files must be owned by this user and not writable by others")
    return os.fdopen(fd, "r+")


@contextmanager
def claim(pool, slots):
    pool.mkdir(parents=True, mode=0o700, exist_ok=True)
    info = pool.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o022:
        raise ValueError("capacity directory must be owned by this user and not writable by others")
    with private_file(pool / "capacity") as config:
        try:
            fcntl.flock(config, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise CapacityUnavailable("capacity configuration is busy; retry later") from exc
        saved = config.read().strip()
        if saved and saved != str(slots):
            raise ValueError("slot count differs from this capacity directory; use its configured count")
        if not saved:
            config.write(str(slots))
            config.flush()
            os.fsync(config.fileno())
    for slot in range(slots):
        lease = private_file(pool / f"slot-{slot}")
        try:
            fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            lease.close()
            continue
        try:
            yield slot
        finally:
            lease.close()  # OS locks also release if this runner crashes.
        return
    raise CapacityUnavailable("all capacity slots are occupied; retry later")


def signal_group(process, signum):
    if process is not None:
        try:
            os.killpg(process.pid, signum)
        except ProcessLookupError:
            pass


def execute(command, timeout):
    process = None
    interrupted = None
    watchdog = None

    def interrupt(signum, _frame):
        nonlocal interrupted, watchdog
        interrupted = signum
        if process is not None:
            signal_group(process, signal.SIGTERM)
            if watchdog is None:
                watchdog = threading.Timer(2, signal_group, (process, signal.SIGKILL))
                watchdog.daemon = True
                watchdog.start()

    previous = {sig: signal.signal(sig, interrupt) for sig in (signal.SIGINT, signal.SIGTERM)}
    try:
        process = subprocess.Popen(command, start_new_session=True)
        if interrupted is not None:
            interrupt(interrupted, None)
        try:
            code = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            signal_group(process, signal.SIGTERM)
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                signal_group(process, signal.SIGKILL)
                process.wait()
            return "timed_out", 124
        if interrupted is not None:
            return "cancelled", 128 + interrupted
        return ("passed" if code == 0 else "failed"), (code if code >= 0 else 128 - code)
    finally:
        if watchdog is not None:
            watchdog.cancel()
            watchdog.join()
        # Check commands must not leave servers or background children in their group.
        signal_group(process, signal.SIGKILL)
        if process is not None:
            process.wait()
        for sig, handler in previous.items():
            signal.signal(sig, handler)


def write_receipt(path, receipt):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".cmux-ci-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as output:
            json.dump(receipt, output, indent=2, allow_nan=False)
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--label", required=True, help="non-secret check name for the receipt")
    parser.add_argument("--receipt", required=True, type=Path)
    parser.add_argument("--pool", required=True, type=Path, help="private directory shared by callers")
    parser.add_argument("--slots", type=int, default=1)
    parser.add_argument("--timeout", type=number, default=1800, help="execution deadline in seconds")
    parser.add_argument("--rate-usd", type=number, help="optional estimated execution cost per hour")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command or not 1 <= args.slots <= 256 or args.timeout <= 0:
        parser.error("pass a command, 1–256 slots, and a positive timeout")
    receipt = {"schema": "cmux.ci.receipt.v1", "run_id": str(uuid.uuid4()), "label": args.label,
               "requested_at": utc_now(), "started_at": None, "completed_at": None,
               "status": "error", "exit_code": 125, "slot": None, "slots": args.slots,
               "queue_ms": None, "run_ms": 0, "estimated_cost_usd": None}
    requested = time.monotonic()
    started = None
    try:
        with claim(args.pool, args.slots) as slot:
            started = time.monotonic()
            receipt.update(slot=slot, started_at=utc_now(), queue_ms=round((started - requested) * 1000))
            receipt["status"], receipt["exit_code"] = execute(command, args.timeout)
    except CapacityUnavailable as exc:
        receipt.update(status="capacity_unavailable", exit_code=75)
        print(f"cmux-ci-run: {exc}", file=sys.stderr)
    except ValueError as exc:
        print(f"cmux-ci-run: {exc}", file=sys.stderr)
    except OSError as exc:
        # OS errors can contain command arguments or paths; keep the public receipt minimal.
        print(f"cmux-ci-run: {type(exc).__name__}; command could not run", file=sys.stderr)
    finally:
        receipt["completed_at"] = utc_now()
        receipt["run_ms"] = round((time.monotonic() - started) * 1000) if started else 0
        if args.rate_usd is not None:
            receipt["estimated_cost_usd"] = round(args.rate_usd * receipt["run_ms"] / 3_600_000, 8)
        write_receipt(args.receipt, receipt)
    print(f"cmux-ci-run: {receipt['status']}; receipt: {args.receipt}", file=sys.stderr)
    return receipt["exit_code"]


if __name__ == "__main__":
    sys.exit(main())
