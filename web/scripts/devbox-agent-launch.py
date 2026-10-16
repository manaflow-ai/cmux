#!/usr/bin/env python3
"""Wait for a coding agent's ready composer on a real PTY, then reap its process group."""

import argparse
import errno
import fcntl
import os
import pty
import re
import selectors
import signal
import struct
import sys
import termios
import time


class LaunchCancelled(Exception):
    """Cancellation must propagate through selectors, which absorbs InterruptedError."""


def verify_launch(command, ready, forbidden, timeout):
    """Read PTY output until readiness, an exit, cancellation, or the deadline."""
    child, master = pty.fork()
    if child == 0:
        os.chdir(os.environ["HOME"])
        os.execvpe("/bin/bash", ["bash", "-lc", command], os.environ)
    fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 140, 0, 0))
    deadline = time.monotonic() + timeout
    output = b""
    ansi = re.compile(r"\x1b\][^\x07]*(?:\x07|\x1b\\)|\x1b\[[0-?]*[ -/]*[@-~]")

    def cancelled(signum, _frame):
        raise LaunchCancelled("agent launch cancelled by signal %s" % signum)

    previous = {sig: signal.signal(sig, cancelled) for sig in (signal.SIGTERM, signal.SIGINT)}
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(master, selectors.EVENT_READ)
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0 or not selector.select(remaining):
                    raise TimeoutError("agent did not reach its composer within %s s" % timeout)
                try:
                    chunk = os.read(master, 65536)
                except OSError as error:
                    if error.errno != errno.EIO:
                        raise
                    chunk = b""
                if not chunk:
                    raise RuntimeError("agent exited before reaching its composer")
                sys.stdout.buffer.write(chunk)
                sys.stdout.buffer.flush()
                output = (output + chunk)[-262144:]
                text = ansi.sub("", output.decode("utf-8", errors="replace"))
                if forbidden and re.search(forbidden, text, re.IGNORECASE):
                    raise RuntimeError("first-run gate still up")
                if ready in text:
                    return
    finally:
        # The child owns this process group (pty.fork creates its session).
        # Reap only after signalling so the PID cannot be reused during cleanup.
        for sig, handler in previous.items():
            signal.signal(sig, signal.SIG_IGN)
        try:
            os.killpg(child, signal.SIGKILL)
        except ProcessLookupError:
            pass
        os.close(master)
        os.waitpid(child, 0)
        for sig, handler in previous.items():
            signal.signal(sig, handler)


def main():
    """Expose the supervisor as a guest-side verifier command."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--command", required=True)
    parser.add_argument("--ready", required=True)
    parser.add_argument("--forbidden", default="")
    parser.add_argument("--label", default="agent-launch")
    parser.add_argument("--timeout", type=float, default=90)
    args = parser.parse_args()
    try:
        verify_launch(args.command, args.ready, args.forbidden, args.timeout)
    except (RuntimeError, TimeoutError, LaunchCancelled) as error:
        print("\n%s: %s" % (args.label, error), file=sys.stderr)
        return 1
    print("\n%s-ok" % args.label)
    return 0


if __name__ == "__main__":
    sys.exit(main())
