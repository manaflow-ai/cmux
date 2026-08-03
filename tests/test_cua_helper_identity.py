#!/usr/bin/env python3
"""Regression checks for the single branded Computer Use TCC identity."""

from __future__ import annotations

import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
BUILD_SCRIPT = ROOT / "scripts" / "build-cua-driver.sh"


def helper_id(host_id: str) -> str:
    completed = subprocess.run(
        [str(BUILD_SCRIPT), "--print-helper-id", host_id],
        check=True,
        capture_output=True,
        text=True,
    )
    return completed.stdout.strip()


def main() -> int:
    first_tag = helper_id("com.cmuxterm.app.debug.first-tag")
    second_tag = helper_id("com.cmuxterm.app.debug.second-tag")
    assert first_tag == "com.cmuxterm.app.debug.computer-use"
    assert second_tag == first_tag
    assert helper_id("com.cmuxterm.app") == "com.cmuxterm.app.computer-use"
    print("PASS: tagged builds share one branded Computer Use helper identity")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
