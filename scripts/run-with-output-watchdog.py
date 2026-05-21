#!/usr/bin/env python3
"""Run a command while failing if it stops producing output for too long."""

from __future__ import annotations

import argparse
import fcntl
import os
import selectors
import signal
import subprocess
import sys
import time
from pathlib import Path


def set_nonblocking(fd: int) -> None:
    flags = fcntl.fcntl(fd, fcntl.F_GETFL)
    fcntl.fcntl(fd, fcntl.F_SETFL, flags | os.O_NONBLOCK)


def write_chunk(log_file, chunk: bytes) -> None:
    sys.stdout.buffer.write(chunk)
    sys.stdout.buffer.flush()
    log_file.write(chunk)
    log_file.flush()


def terminate_process_group(process: subprocess.Popen[bytes]) -> None:
    try:
        pgid = os.getpgid(process.pid)
    except ProcessLookupError:
        return

    for sig, grace_seconds in ((signal.SIGTERM, 10), (signal.SIGKILL, 0)):
        try:
            os.killpg(pgid, sig)
        except ProcessLookupError:
            return
        if grace_seconds == 0:
            return
        deadline = time.monotonic() + grace_seconds
        while time.monotonic() < deadline:
            if process.poll() is not None:
                return
            time.sleep(0.2)


def run(command: list[str], idle_timeout: float, log_path: Path) -> int:
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with log_path.open("wb") as log_file:
        process = subprocess.Popen(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            bufsize=0,
            preexec_fn=os.setsid,
        )
        assert process.stdout is not None
        stdout_fd = process.stdout.fileno()
        set_nonblocking(stdout_fd)

        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ)
        last_output = time.monotonic()

        while True:
            events = selector.select(timeout=1.0)
            if events:
                for key, _ in events:
                    try:
                        chunk = os.read(key.fileobj.fileno(), 65536)
                    except BlockingIOError:
                        continue
                    if chunk:
                        last_output = time.monotonic()
                        write_chunk(log_file, chunk)
                    else:
                        selector.unregister(key.fileobj)

            if process.poll() is not None:
                while True:
                    try:
                        chunk = os.read(stdout_fd, 65536)
                    except BlockingIOError:
                        break
                    if not chunk:
                        break
                    write_chunk(log_file, chunk)
                return process.returncode or 0

            idle_for = time.monotonic() - last_output
            if idle_for >= idle_timeout:
                message = (
                    f"\nerror: command produced no output for {idle_for:.0f}s; "
                    f"terminating process group for: {' '.join(command)}\n"
                ).encode()
                write_chunk(log_file, message)
                terminate_process_group(process)
                return 124


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--idle-timeout", type=float, required=True)
    parser.add_argument("--log-file", type=Path, required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()

    command = args.command
    if command and command[0] == "--":
        command = command[1:]
    if not command:
        parser.error("missing command after --")

    return run(command, args.idle_timeout, args.log_file)


if __name__ == "__main__":
    raise SystemExit(main())
