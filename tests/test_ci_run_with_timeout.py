#!/usr/bin/env python3
"""Behavioral guard for scripts/ci/run_with_timeout.py."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "scripts" / "ci" / "run_with_timeout.py"


def test_command_passes_through_success() -> None:
    result = subprocess.run(
        [
            sys.executable,
            str(HELPER),
            "--timeout",
            "5",
            "--",
            sys.executable,
            "-c",
            "print('ok')",
        ],
        check=False,
        text=True,
        capture_output=True,
        timeout=10,
    )

    assert result.returncode == 0
    assert result.stdout.strip() == "ok"


def test_command_times_out_and_returns_124() -> None:
    result = subprocess.run(
        [
            sys.executable,
            str(HELPER),
            "--timeout",
            "0.2",
            "--",
            sys.executable,
            "-c",
            "import time; time.sleep(10)",
        ],
        check=False,
        text=True,
        capture_output=True,
        timeout=5,
    )

    assert result.returncode == 124
    assert "Timed out after 0.2s:" in result.stderr


def main() -> int:
    test_command_passes_through_success()
    test_command_times_out_and_returns_124()
    print("PASS: command timeout helper streams output and terminates hung commands")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
