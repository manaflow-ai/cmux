#!/usr/bin/env python3
"""Check that the bundled cmux-cua patch series applies to its pinned source.

build-cmux-cua.sh applies every patch in CMUX_CUA_PATCH_RELATIVE_PATHS, in
order, to the pinned checkout. With CMUX_CUA_SRC set to a clean pinned checkout
this applies the whole series to a scratch copy of it (or confirms the series
is already applied there), so a patch that only applies on top of an earlier
one is checked the way the build uses it.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
BUILD_SCRIPT = ROOT / "scripts" / "build-cmux-cua.sh"


def pinned_sha() -> str:
    match = re.search(
        r'^CMUX_CUA_PINNED_SHA="([0-9a-f]{40})"$',
        BUILD_SCRIPT.read_text(),
        re.MULTILINE,
    )
    if match is None:
        raise AssertionError("build script does not expose a pinned cmux-cua revision")
    return match.group(1)


def patch_series() -> list[Path]:
    block = re.search(
        r"^CMUX_CUA_PATCH_RELATIVE_PATHS=\(\n(.*?)^\)$",
        BUILD_SCRIPT.read_text(),
        re.MULTILINE | re.DOTALL,
    )
    if block is None:
        raise AssertionError("build script does not list CMUX_CUA_PATCH_RELATIVE_PATHS")
    paths = [ROOT / p for p in re.findall(r'^\s*"([^"]+)"$', block.group(1), re.MULTILINE)]
    if not paths:
        raise AssertionError("CMUX_CUA_PATCH_RELATIVE_PATHS is empty")
    for path in paths:
        if not path.is_file():
            raise AssertionError(f"missing bundled cmux-cua patch: {path}")
    return paths


def git_apply(root: Path, patch: Path, *flags: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", "-C", str(root), "apply", *flags, str(patch)],
        check=False,
        capture_output=True,
        text=True,
    )


def main() -> int:
    series = patch_series()
    source = os.environ.get("CMUX_CUA_SRC")
    if not source:
        print("SKIP: set CMUX_CUA_SRC to a clean pinned cmux-cua checkout")
        return 0

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

    with tempfile.TemporaryDirectory(prefix="cmux-cua-patch-series-") as scratch:
        work = Path(scratch) / "src"
        shutil.copytree(source_root, work, symlinks=True)
        for patch in series:
            forward = git_apply(work, patch)
            if forward.returncode == 0:
                print(f"PASS: {patch.name} applies to {revision}")
                continue
            reverse = git_apply(work, patch, "--reverse", "--check")
            if reverse.returncode:
                raise AssertionError(
                    f"bundled {patch.name} does not apply to the pinned source:\n"
                    + (forward.stderr or forward.stdout)
                    + (reverse.stderr or reverse.stdout)
                )
            print(f"PASS: {patch.name} is already applied to {revision}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        raise SystemExit(1)
