#!/usr/bin/env python3
"""Check that the bundled Codex compatibility patch matches its pinned source."""

from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
BUILD_SCRIPT = ROOT / "scripts" / "build-cmux-cua.sh"
PATCH = ROOT / "scripts" / "cmux-cua-codex-delivery-mode.patch"


def pinned_sha() -> str:
    match = re.search(
        r'^CMUX_CUA_PINNED_SHA="([0-9a-f]{40})"$',
        BUILD_SCRIPT.read_text(),
        re.MULTILINE,
    )
    if match is None:
        raise AssertionError("build script does not expose a pinned cmux-cua revision")
    return match.group(1)


def main() -> int:
    source = os.environ.get("CMUX_CUA_SRC")
    if not source:
        print("SKIP: set CMUX_CUA_SRC to a clean pinned cmux-cua checkout")
        return 0
    if not PATCH.is_file():
        raise AssertionError(f"missing bundled cmux-cua patch: {PATCH}")

    source_root = Path(source).resolve()
    revision = subprocess.run(
        ["git", "-C", str(source_root), "rev-parse", "HEAD"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    expected = pinned_sha()
    if revision != expected:
        raise AssertionError(f"CMUX_CUA_SRC is {revision}, expected pinned {expected}")

    check = subprocess.run(
        ["git", "-C", str(source_root), "apply", "--check", str(PATCH)],
        capture_output=True,
        text=True,
    )
    if check.returncode:
        raise AssertionError(
            "bundled Codex delivery-mode patch does not apply to the pinned source:\n"
            + (check.stderr or check.stdout)
        )
    print(f"PASS: cmux-cua Codex delivery-mode patch applies to {revision}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        raise SystemExit(1)
