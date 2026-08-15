#!/usr/bin/env python3
"""Run the phase-one local session catalog behavior smoke on a build host."""

from __future__ import annotations

import pathlib
import subprocess


def main() -> int:
    root = pathlib.Path(__file__).resolve().parents[1]
    completed = subprocess.run(
        [
            "cargo",
            "test",
            "--locked",
            "-p",
            "cmux-tui-core",
            "--test",
            "session_catalog",
        ],
        cwd=root,
        check=False,
    )
    return completed.returncode


if __name__ == "__main__":
    raise SystemExit(main())
