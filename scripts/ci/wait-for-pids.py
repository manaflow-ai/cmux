#!/usr/bin/env python3
"""Wait for external processes to emit an exit event on macOS.

The cleanup caller owns identity revalidation; this helper only supplies a
real process-exit signal for the TERM grace period.  PIDs that cannot be
registered (for example, because another account owns them) are returned so
the caller can revalidate and escalate with the appropriate privileges.
"""

from __future__ import annotations

import argparse
import errno
import os
import select
import sys
import time


def _is_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def wait_for_pids(pids: list[int], timeout: float) -> list[int]:
    pending = {pid for pid in pids if pid > 1}
    if not pending:
        return []
    if timeout <= 0 or not hasattr(select, "kqueue"):
        return sorted(pid for pid in pending if _is_alive(pid))

    kqueue = select.kqueue()
    registered: set[int] = set()
    for pid in tuple(pending):
        try:
            kqueue.control(
                [
                    select.kevent(
                        pid,
                        filter=select.KQ_FILTER_PROC,
                        flags=select.KQ_EV_ADD | select.KQ_EV_ONESHOT,
                        fflags=select.KQ_NOTE_EXIT,
                    )
                ],
                0,
                0,
            )
            registered.add(pid)
        except OSError as error:
            if error.errno == errno.ESRCH:
                pending.discard(pid)
            elif error.errno in (errno.EACCES, errno.EPERM):
                if not _is_alive(pid):
                    pending.discard(pid)
            else:
                raise

    deadline = time.monotonic() + timeout
    while registered:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        try:
            events = kqueue.control([], len(registered), remaining)
        except OSError as error:
            if error.errno == errno.EINTR:
                continue
            if error.errno == errno.ESRCH:
                break
            raise
        if not events:
            break
        for event in events:
            pid = int(event.ident)
            registered.discard(pid)
            pending.discard(pid)
    return sorted(pending)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--timeout", type=float, required=True)
    parser.add_argument("pids", nargs="*", type=int)
    args = parser.parse_args(argv)
    if args.timeout < 0:
        parser.error("--timeout must be non-negative")
    pids = args.pids
    if not pids:
        raw_pids = os.environ.get("CMUX_WAIT_PIDS", "")
        try:
            pids = [int(raw) for raw in raw_pids.split()]
        except ValueError:
            parser.error("CMUX_WAIT_PIDS must contain numeric process IDs")
    for pid in wait_for_pids(pids, args.timeout):
        print(pid)
    return 0


if __name__ == "__main__":
    sys.exit(main())
