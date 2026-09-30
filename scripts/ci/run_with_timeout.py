#!/usr/bin/env python3

import argparse
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
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if args.timeout_seconds <= 0:
        parser.error("--timeout-seconds must be positive")
    if not command:
        parser.error("a command is required after --")

    process = subprocess.Popen(
        command,
        stdin=subprocess.DEVNULL,
        start_new_session=True,
    )
    try:
        return process.wait(timeout=args.timeout_seconds)
    except subprocess.TimeoutExpired:
        print(
            f"::error::command timed out after {args.timeout_seconds}s: {shlex.join(command)}",
            file=sys.stderr,
            flush=True,
        )
        # The whole tree, not just the process group: swiftpm-testing-helper
        # runs in its own group and would otherwise outlive the timeout.
        terminate(process)
        return 124
    except KeyboardInterrupt:
        terminate(process)
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
