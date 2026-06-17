#!/usr/bin/env python3
"""Run a command with a wall-clock timeout while streaming its output."""

from __future__ import annotations

import argparse
import shlex
import subprocess
import sys


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--timeout", type=float, required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()

    command = args.command
    if command and command[0] == "--":
        command = command[1:]
    if not command:
        parser.error("command is required")

    process = subprocess.Popen(command)
    try:
        return process.wait(timeout=args.timeout)
    except subprocess.TimeoutExpired:
        print(
            f"Timed out after {args.timeout:g}s: {shlex.join(command)}",
            file=sys.stderr,
            flush=True,
        )
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
        return 124


if __name__ == "__main__":
    raise SystemExit(main())
