#!/usr/bin/env python3
"""Run a command under a fresh pseudo-terminal and copy its output to stdout.

Why this exists rather than `/usr/bin/script -q /dev/null <cmd>`:

`script` copies terminal settings from the tty it inherits, so it needs one. Run from an
interactive pane it works; run from a background job, a CI step, or anything whose stdin is a
pipe or socket, it aborts with

    script: tcgetattr/ioctl: Operation not supported on socket

and the command never starts. That failure is easy to misread as the command producing no
output, which is exactly what an ET transport looks like when it is genuinely broken — so the
harness that used `script` reported six confident findings about a transport that had never
connected.

This allocates its own pty instead of borrowing one, so it behaves the same interactively and
headless. The child gets the pty as its controlling terminal, which is what ET requires: given a
plain pipe it produces no output at all.

Usage:  pty-run.py [--timeout SECONDS] -- command [args...]
Exit code is the command's, 124 on timeout (matching timeout(1)), 126 if it could not be run.
"""

import argparse
import errno
import os
import pty
import select
import signal
import sys
import time


def main() -> int:
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("--timeout", type=float, default=0.0)
    ap.add_argument("command", nargs=argparse.REMAINDER)
    args = ap.parse_args()

    argv = args.command
    if argv and argv[0] == "--":
        argv = argv[1:]
    if not argv:
        sys.stderr.write("pty-run.py: no command given\n")
        return 126

    pid, master = pty.fork()
    if pid == 0:
        # Child. pty.fork has already made the slave our controlling terminal and wired it to
        # stdin/stdout/stderr, so the command sees a real tty on all three.
        try:
            os.execvp(argv[0], argv)
        except OSError as exc:
            sys.stderr.write(f"pty-run.py: cannot run {argv[0]}: {exc}\n")
            os._exit(126)

    deadline = time.monotonic() + args.timeout if args.timeout > 0 else None
    # Only relay stdin if we actually have one; a closed fd 0 would make select() raise.
    try:
        os.fstat(0)
        stdin_open = True
    except OSError:
        stdin_open = False
    out = sys.stdout.buffer
    timed_out = False

    try:
        while True:
            budget = None
            if deadline is not None:
                budget = deadline - time.monotonic()
                if budget <= 0:
                    timed_out = True
                    break
            # Watch the parent's stdin too, and relay it to the child.
            #
            # Without this the wrapper is a one-way pipe: the child's output comes back, but nothing
            # typed by a human ever reaches it. `script -q` relays stdin by design, so swapping it
            # for this helper silently broke every interactive prompt — a 2FA passcode went into
            # THIS process's stdin and was never forwarded, so the child waited forever for a
            # credential that could not arrive. That looked exactly like the remote transport
            # stalling, and was diagnosed as such more than once.
            watch = [master]
            if stdin_open:
                watch.append(0)
            readable, _, _ = select.select(watch, [], [], budget if budget else 1.0)
            if 0 in readable:
                try:
                    data = os.read(0, 65536)
                except OSError:
                    data = b""
                if data:
                    os.write(master, data)
                else:
                    # EOF on our stdin: stop watching it, but keep relaying the child's output.
                    stdin_open = False
            if master not in readable:
                # No data this slice. If the child is gone, drain and finish.
                waited, _ = os.waitpid(pid, os.WNOHANG)
                if waited == pid:
                    break
                continue
            try:
                chunk = os.read(master, 65536)
            except OSError as exc:
                # EIO is the normal end of a pty when the child closes the slave.
                if exc.errno in (errno.EIO, errno.EBADF):
                    break
                raise
            if not chunk:
                break
            out.write(chunk)
            out.flush()
    finally:
        os.close(master)

    if timed_out:
        # Same escalation as timeout(1): ask, then insist.
        for sig in (signal.SIGTERM, signal.SIGKILL):
            try:
                os.kill(pid, sig)
            except ProcessLookupError:
                break
            for _ in range(20):
                waited, _ = os.waitpid(pid, os.WNOHANG)
                if waited == pid:
                    return 124
                time.sleep(0.05)
        return 124

    try:
        _, status = os.waitpid(pid, 0)
    except ChildProcessError:
        return 0
    if os.WIFSIGNALED(status):
        return 128 + os.WTERMSIG(status)
    return os.WEXITSTATUS(status)


if __name__ == "__main__":
    sys.exit(main())
