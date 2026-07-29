#!/usr/bin/env python3

import argparse
import os
import shlex
import signal
import subprocess
import sys


def terminate_process_group(process: subprocess.Popen) -> None:
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=5)
        return
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        return
    process.wait()


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Run a command with a deadline and terminate its process group on timeout."
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
        terminate_process_group(process)
        return 124
    except KeyboardInterrupt:
        terminate_process_group(process)
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
