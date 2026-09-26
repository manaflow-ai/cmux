#!/usr/bin/env python3
"""Keep swift-package-tests' SwiftPM build directories on an owned Mac between jobs.

    owned_spm_scratch.py link WORKSPACE [STORE]

swift-package-tests runs `swift test --package-path <package>` for the
packages a change selects. On an owned Mac (a glaeda runner) the workspace is
reused, but actions/checkout cleans it (`git clean -ffdx`), so every job
deleted each package's `.build` and built the package and its dependencies from
nothing: 206 to 594 MB per package on cmux11s on 2026-09-26, 1,430 runner-minutes
a day across the minis. The checkout keeps the modification times of files it
did not change, so a kept `.build` rebuilds only what the change touched.

`link` points each package's `.build` (every Package.swift under Packages/*/*
and vendor/bonsplit) at STORE/spm-scratch/<runner>/<package path>, outside the
workspace, where the clean cannot reach. The directory is per runner: each
runner has its own workspace path, which SwiftPM bakes into its build, and runs
one job at a time. A runner's directories beyond MAX_BYTES are dropped, least
recently used first, before linking. Anything else (another runner, a missing
store) changes nothing, and any error leaves the package to build as before.
"""
from __future__ import annotations

import os
from pathlib import Path
import shutil
import sys

DEFAULT_STORE = Path("/Users/Shared/cmux-build-fleet/ci")
MAX_BYTES = 12 * 1024**3
SCRATCH = "spm-scratch"


def packages(workspace: Path) -> list[Path]:
    found = [path.parent for path in sorted(workspace.glob("Packages/*/*/Package.swift"))]
    bonsplit = workspace / "vendor/bonsplit"
    if (bonsplit / "Package.swift").is_file():
        found.append(bonsplit)
    return found


def tree_bytes(root: Path) -> int:
    total = 0
    for base, _, files in os.walk(root):
        for name in files:
            try:
                total += Path(base, name).lstat().st_size
            except OSError:
                pass
    return total


def prune(scratch: Path, max_bytes: int = MAX_BYTES) -> None:
    """Drop the least recently used package directories until the runner's scratch fits MAX_BYTES."""
    try:
        entries = [(entry.stat().st_mtime, entry) for entry in scratch.iterdir() if entry.is_dir()]
    except OSError:
        return
    sizes = {entry: tree_bytes(entry) for _, entry in entries}
    total = sum(sizes.values())
    for _, entry in sorted(entries):
        if total <= max_bytes:
            break
        shutil.rmtree(entry, ignore_errors=True)
        total -= sizes[entry]


def link(workspace: Path, store: Path, runner: str) -> list[str]:
    if "-glaeda" not in runner or not store.is_dir():
        return []
    scratch = store / SCRATCH / runner
    scratch.mkdir(parents=True, exist_ok=True)
    prune(scratch)
    linked = []
    for package in packages(workspace):
        relative = package.relative_to(workspace).as_posix()
        target = scratch / relative.replace("/", "__")
        build = package / ".build"
        try:
            target.mkdir(parents=True, exist_ok=True)
            os.utime(target)  # recently used: the prune keeps it
            if build.is_symlink():
                build.unlink()
            elif build.exists():
                shutil.rmtree(build)
            build.symlink_to(target, target_is_directory=True)
            linked.append(relative)
        except OSError as error:
            print(f"{relative}: not linked ({error})")
    return linked


def main(argv: list[str]) -> int:
    if len(argv) in (3, 4) and argv[1] == "link":
        store = Path(argv[3]) if len(argv) == 4 else DEFAULT_STORE
        try:
            linked = link(Path(argv[2]).resolve(), store, os.environ.get("RUNNER_NAME", ""))
        except OSError as error:  # a kept build is an optimization only
            print(f"owned SwiftPM scratch: skipped ({error})")
            return 0
        print(f"owned SwiftPM scratch: {len(linked)} packages keep their .build between jobs")
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
