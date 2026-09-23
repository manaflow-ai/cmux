#!/usr/bin/env python3
"""Bounded local build admission for standalone contributor reloads."""
import fcntl
import json
import os
from pathlib import Path
import sys
import time


def notice(message):
    data = (message + '\n').encode()
    # stderr is the saved build log; fd 4 is the original terminal. Write both.
    os.write(2, data)
    try:
        if os.fstat(4) != os.fstat(2):
            os.write(4, data)
    except OSError:
        pass


def acquire(root, concurrency, wait_seconds):
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    start = time.monotonic()
    deadline = start + wait_seconds
    next_notice = start
    while True:
        now = time.monotonic()
        if now >= deadline:
            raise TimeoutError(f'timed out after {wait_seconds}s waiting for a local xcodebuild slot; '
                               f'compilation has not started. Inspect lock owners under {root}; '
                               'team builds must use cmux-ci. Do not delete active lock files.')
        for slot in range(1, concurrency + 1):
            path = root / f'slot-{slot}.lock'
            fd = os.open(path, os.O_CREAT | os.O_RDWR, 0o600)
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                os.close(fd)
                continue
            except BaseException:
                os.close(fd)
                raise
            try:
                # The executing compiler owns the same descriptor. No forked
                # waiters can survive cancellation or retain another slot.
                os.set_inheritable(fd, True)
                record = json.dumps({'pid': os.getpid(), 'slot': slot, 'started_at': time.time()}) + '\n'
                os.ftruncate(fd, 0)
                os.write(fd, record.encode())
                notice(f'==> xcodebuild slot {slot}/{concurrency} acquired after {time.monotonic() - start:.1f}s')
                return fd
            except BaseException:
                os.close(fd)
                raise
        now = time.monotonic()
        if now >= next_notice:
            notice(f'==> Waiting for local xcodebuild admission: compilation has not started; '
                   f'{now - start:.0f}s elapsed, {max(0, deadline - now):.0f}s remaining; '
                   f'all {concurrency} slots busy ({root})')
            next_notice = now + 15
        time.sleep(min(0.25, max(0, deadline - time.monotonic())))


def main(argv):
    if len(argv) < 4:
        notice('usage: xcodebuild-slot.py LOCK_DIR CONCURRENCY WAIT_SECONDS COMMAND [ARGS...]')
        return 2
    try:
        concurrency, wait_seconds = int(argv[1]), int(argv[2])
        if concurrency <= 0 or wait_seconds <= 0:
            raise ValueError('concurrency and wait seconds must be positive')
        fd = acquire(Path(argv[0]), concurrency, wait_seconds)
    except TimeoutError as exc:
        notice(f'error: {exc}')
        return 124
    except (ValueError, OSError) as exc:
        notice(f'error: local build admission failed: {exc}')
        return 2
    try:
        os.execvp(argv[3], argv[3:])
    except OSError as exc:
        os.close(fd)
        notice(f'error: exec: {exc}')
        return 127


if __name__ == '__main__':
    raise SystemExit(main(sys.argv[1:]))
