#!/usr/bin/env python3

import argparse
import signal
import shlex
import subprocess
import sys
from pathlib import Path

# Run as a script, this directory is already first on sys.path; loaded through
# importlib (as tests do), it is not.
sys.path.insert(0, str(Path(__file__).resolve().parent))

from ci_process_tree import terminate  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Run a command with a deadline and terminate its process tree on timeout."
    )
    parser.add_argument("--timeout-seconds", type=int, required=True)
    parser.add_argument(
        "--foreground",
        action="store_true",
        help="Inherit stdin and the controlling terminal for interactive commands.",
    )
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if args.timeout_seconds <= 0:
        parser.error("--timeout-seconds must be positive")
    if not command:
        parser.error("a command is required after --")

    process = subprocess.Popen(
        command,
        stdin=None if args.foreground else subprocess.DEVNULL,
        start_new_session=not args.foreground,
    )

    def handle_signal(signum: int, _frame: object) -> None:
        # GitHub Actions sends SIGINT first and escalates to SIGTERM while
        # cancelling a step. Python's default SIGTERM action exits immediately,
        # which used to orphan detached SwiftPM helpers. Reap the complete tree
        # before leaving so cancellation stays within the runner grace period.
        # A second cancellation signal must not recurse while cleaning up.
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        terminate(process)
        raise SystemExit(128 + signum)

    signal.signal(signal.SIGINT, handle_signal)
    signal.signal(signal.SIGTERM, handle_signal)
    try:
        return process.wait(timeout=args.timeout_seconds)
    except subprocess.TimeoutExpired:
        # Interactive broker arguments may contain private routing details.
        description = command[0] if args.foreground else shlex.join(command)
        print(
            f"::error::command timed out after {args.timeout_seconds}s: {description}",
            file=sys.stderr,
            flush=True,
        )
        # The whole tree, not just the process group: swiftpm-testing-helper
        # runs in its own group and would otherwise outlive the timeout.
        terminate(process)
        return 124


if __name__ == "__main__":
    raise SystemExit(main())
