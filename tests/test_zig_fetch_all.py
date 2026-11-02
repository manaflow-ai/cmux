#!/usr/bin/env python3
"""zig-fetch-all.sh retries `zig build --fetch=all` until the fetch succeeds, a bounded number of times.

nightly-next run 40656489166 failed twice when a reset connection failed zig's single fetch of every
Ghostty package (its zig package cache had been evicted). The script runs a fake `zig` that fails a
given number of times, then succeeds.
"""
from __future__ import annotations

import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "cmux-next" / "zig-fetch-all.sh"

FAKE_ZIG = """#!/bin/sh
# Records each call's arguments and directory; fails until $FAKE_ZIG_FAILURES calls were made.
echo "$PWD $*" >> "$FAKE_ZIG_LOG"
calls=$(wc -l < "$FAKE_ZIG_LOG")
[ "$calls" -gt "$FAKE_ZIG_FAILURES" ] || { echo "error: HTTP response read failure: ConnectionResetByPeer" >&2; exit 1; }
"""


def run(failures: int, attempts: int) -> tuple[subprocess.CompletedProcess[str], list[str], Path]:
    tmp = Path(tempfile.mkdtemp())
    bin_dir, project, log = tmp / "bin", tmp / "project", tmp / "zig.log"
    bin_dir.mkdir()
    project.mkdir()
    zig = bin_dir / "zig"
    zig.write_text(FAKE_ZIG)
    zig.chmod(0o755)
    env = {**os.environ, "PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}", "FAKE_ZIG_LOG": str(log),
           "FAKE_ZIG_FAILURES": str(failures), "CMUX_ZIG_FETCH_ATTEMPTS": str(attempts),
           "CMUX_ZIG_FETCH_BACKOFF_S": "0", "CMUX_ZIG_FETCH_TIMEOUT_S": "30"}
    result = subprocess.run(["bash", str(SCRIPT), str(project)], env=env, capture_output=True, text=True, timeout=60)
    calls = log.read_text().splitlines() if log.exists() else []
    return result, calls, project


def test_a_fetch_that_succeeds_at_once_runs_once() -> None:
    result, calls, project = run(failures=0, attempts=5)
    assert result.returncode == 0, result.stderr
    assert len(calls) == 1
    where, args = calls[0].split(" ", 1)
    assert Path(where).resolve() == project.resolve() and args == "build --fetch=all"


def test_reset_connections_are_retried_until_the_fetch_succeeds() -> None:
    result, calls, _ = run(failures=2, attempts=5)
    assert result.returncode == 0, result.stderr
    assert len(calls) == 3
    assert "failed (attempt 2 of 5)" in result.stderr


def test_a_fetch_that_keeps_failing_stops_after_the_last_attempt() -> None:
    result, calls, _ = run(failures=99, attempts=3)
    assert result.returncode == 1
    assert len(calls) == 3
    assert "failed 3 times" in result.stderr


def main() -> int:
    tests = [value for name, value in globals().items() if name.startswith("test_")]
    for test in tests:
        test()
    print(f"PASS: {len(tests)} zig-fetch-all tests")
    return 0


if __name__ == "__main__":
    sys.exit(main())
