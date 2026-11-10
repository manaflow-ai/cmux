#!/usr/bin/env python3
"""Run a Rust test command (placeholder: no per-test deadline yet; the next commit adds it)."""

from __future__ import annotations

import subprocess
import sys

DEFAULT_SECONDS = 180
DEADLINE_EXIT = 124


class Tracker:
    """Placeholder: never reports a test as overdue."""

    def __init__(self, default_seconds: float = DEFAULT_SECONDS, slow: dict[str, float] | None = None) -> None:
        self.default_seconds = default_seconds

    def feed(self, text: str, *, now: float) -> None:
        pass

    def overdue(self, *, now: float):
        return None


def main(argv: list[str] | None = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    command = args[args.index("--") + 1:] if "--" in args else args
    return subprocess.run(command, check=False).returncode


if __name__ == "__main__":
    sys.exit(main())
