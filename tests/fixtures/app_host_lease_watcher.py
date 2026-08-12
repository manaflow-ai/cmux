#!/usr/bin/env python3
"""Portable app-host lease watcher for the Linux workflow guard."""

import fcntl
import os
import signal
import stat


def fail(reason):
    raise SystemExit("FAIL: portable app-host lease watcher: " + reason)


def main():
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    environment = os.environ
    receipt_directory = environment.get("CMUX_APP_HOST_RECEIPT_DIR", "")
    lease_path = environment.get("CMUX_APP_HOST_ATTEMPT_LEASE", "")
    key = environment.get("CMUX_APP_HOST_KEY", "")
    if not receipt_directory or not lease_path or len(key) != 12:
        fail("required identity is incomplete")

    lease_descriptor = os.open(
        lease_path,
        os.O_RDWR | os.O_CLOEXEC | os.O_NOFOLLOW,
    )
    lease_metadata = os.fstat(lease_descriptor)
    if (
        not stat.S_ISREG(lease_metadata.st_mode)
        or stat.S_IMODE(lease_metadata.st_mode) != 0o600
        or lease_metadata.st_uid != os.getuid()
    ):
        fail("attempt lease identity is invalid")
    try:
        fcntl.lockf(lease_descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        pass
    else:
        fail("attempt lease has no live holder")

    pid = os.getpid()
    executable = os.path.realpath(__file__)
    receipt_path = os.path.join(receipt_directory, "app-host-%d.receipt" % pid)
    temporary_path = os.path.join(
        receipt_directory,
        ".app-host-%d.receipt.tmp" % pid,
    )
    receipt_descriptor = os.open(
        temporary_path,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW,
        0o600,
    )
    receipt = (
        "version=3\n"
        "key=%s\n"
        "pid=%d\n"
        "executable=%s\n"
        "receipt_fd=%d\n"
        "lease=%s\n"
        "lease_fd=%d\n"
        % (
            key,
            pid,
            executable,
            receipt_descriptor,
            lease_path,
            lease_descriptor,
        )
    ).encode()
    offset = 0
    while offset < len(receipt):
        offset += os.write(receipt_descriptor, receipt[offset:])
    os.fsync(receipt_descriptor)
    os.replace(temporary_path, receipt_path)

    while True:
        try:
            fcntl.lockf(lease_descriptor, fcntl.LOCK_EX)
            break
        except InterruptedError:
            continue
    os._exit(0)


if __name__ == "__main__":
    main()
