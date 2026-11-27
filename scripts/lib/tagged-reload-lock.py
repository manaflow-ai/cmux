#!/usr/bin/env python3
"""Keep each tagged reload's cleanup, build, and launch in one exclusive lease."""

import fcntl
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile


def main() -> int:
    tag, script, *arguments = sys.argv[1:]
    lock_directory = Path(tempfile.gettempdir()) / f"cmux-reload-tags-{os.getuid()}"
    lock_directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    with (lock_directory / f"{tag}.lock").open("a") as lease:
        try:
            fcntl.flock(lease.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print(f"==> Waiting for the active reload of tag {tag}...", flush=True)
            fcntl.flock(lease.fileno(), fcntl.LOCK_EX)

        # Only this supervisor owns the lease. Build services and the launched
        # app must not inherit it and keep later reloads locked indefinitely.
        environment = os.environ.copy()
        environment["CMUX_RELOAD_TAG_LOCK_OWNER"] = str(os.getpid())
        child = None
        pending_signals = []

        def forward_signal(number, _frame):
            if child is None:
                pending_signals.append(number)
                return
            try:
                os.killpg(child.pid, number)
            except ProcessLookupError:
                pass

        for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            signal.signal(number, forward_signal)
        child = subprocess.Popen(
            ["bash", script, *arguments],
            env=environment,
            start_new_session=True,
            close_fds=True,
        )
        for number in pending_signals:
            forward_signal(number, None)
        result = child.wait()
        return result if result >= 0 else 128 - result


if __name__ == "__main__":
    raise SystemExit(main())
