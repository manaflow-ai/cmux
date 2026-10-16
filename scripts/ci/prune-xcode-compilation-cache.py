#!/usr/bin/env python3
"""Drop Xcode compilation cache generations that the CAS no longer reads."""

from __future__ import annotations

import argparse
import fcntl
import re
import shutil
from pathlib import Path

# Xcode's compilation cache is LLVM's UnifiedOnDiskCache. Each CAS directory
# (`builtin`, `generic`, ...) chains generations named `v<version>.<n>`: the
# highest `n` is the primary store, the one before it is the upstream store
# the primary faults objects in from, and anything older is garbage that the
# CAS deletes at its next collection (UnifiedOnDiskCache::collectGarbage keeps
# the newest two directories). When a build ends with the primary above half
# of COMPILATION_CACHE_LIMIT_SIZE the CAS starts a new empty primary, so a
# warm build leaves the previous upstream behind as a dead generation that
# doubles the directory until the next collection. Pruning it here, before
# the directory is measured and uploaded, mirrors that collection exactly.
GENERATION_PATTERN = re.compile(r"^v(\d+)\.(\d+)$")
LIVE_GENERATIONS = 2
LOCK_FILENAME = "lock"


def display_path(path: Path) -> str:
    try:
        return str(path.relative_to(Path.cwd()))
    except ValueError:
        return str(path)


def allocated_kib(path: Path) -> int:
    """Return the allocated size of a tree in KiB, like `du -sk`."""
    total_bytes = 0
    for entry in [path, *path.rglob("*")]:
        try:
            info = entry.lstat()
        except OSError:
            continue
        total_bytes += getattr(info, "st_blocks", 0) * 512
    return total_bytes // 1024


def split_generations(cas_dir: Path) -> tuple[list[Path], list[Path]]:
    """Return (live, stale) generation directories of a CAS directory.

    Generations sort numerically within a version chain, so `v1.10` is newer
    than `v1.9`. The newest two of every chain are live; the rest are stale.
    Raises OSError when the directory cannot be listed.
    """
    chains: dict[int, list[tuple[int, Path]]] = {}
    for child in cas_dir.iterdir():
        match = GENERATION_PATTERN.match(child.name)
        if match is None or child.is_symlink() or not child.is_dir():
            continue
        chains.setdefault(int(match.group(1)), []).append((int(match.group(2)), child))
    live: list[Path] = []
    stale: list[Path] = []
    for chain in chains.values():
        chain.sort()
        stale.extend(path for _, path in chain[:-LIVE_GENERATIONS])
        live.extend(path for _, path in chain[-LIVE_GENERATIONS:])
    return live, stale


class CASInUse(Exception):
    """Raised when another process still holds the CAS directory lock."""


def prune_cas_dir(cas_dir: Path) -> tuple[list[Path], list[tuple[Path, int]]]:
    """Remove every generation but the newest two, holding the CAS lock.

    Returns (live, removed) where removed pairs each deleted generation with
    the KiB it occupied. Only generations selected for removal are measured;
    the live ones are left to the caller's single `du` over the whole cache.
    A directory without a `lock` file is not a CAS directory the toolchain has
    opened and is left untouched.
    """
    lock_path = cas_dir / LOCK_FILENAME
    if not lock_path.is_file():
        # Every CAS directory the toolchain has opened carries a `lock` file.
        # Without one there is nothing to lock, so nothing may be deleted.
        live, stale = split_generations(cas_dir)
        if live or stale:
            print(f"{display_path(cas_dir)}: no CAS lock file; leaving it alone")
        return [], []
    with lock_path.open("rb") as lock_file:
        try:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as error:
            raise CASInUse(str(error)) from error
        try:
            live, stale = split_generations(cas_dir)
            removed: list[tuple[Path, int]] = []
            for generation in stale:
                size_kib = allocated_kib(generation)
                try:
                    shutil.rmtree(generation)
                except OSError as error:
                    # Pruning is an optimisation; never fail the build over it.
                    print(f"{display_path(generation)}: could not remove ({error}); keeping it")
                    live.append(generation)
                    continue
                removed.append((generation, size_kib))
            return live, removed
        finally:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Remove dead Xcode compilation cache generations after a build so "
            "the cached directory holds only the primary and upstream stores "
            "the CAS still reads. Run it after xcodebuild has exited."
        )
    )
    parser.add_argument(
        "cache_dir",
        type=Path,
        help="Xcode CompilationCache.noindex directory (under the derived data path)",
    )
    args = parser.parse_args()

    cache_dir = args.cache_dir.resolve()
    if not cache_dir.is_dir():
        print(f"no Xcode compilation cache at {display_path(cache_dir)}; nothing to prune")
        return 0

    removed_count = 0
    removed_kib = 0
    cas_dirs = sorted(
        child for child in cache_dir.iterdir() if child.is_dir() and not child.is_symlink()
    )
    for cas_dir in cas_dirs:
        try:
            live, removed = prune_cas_dir(cas_dir)
        except CASInUse as error:
            print(f"{display_path(cas_dir)}: still in use ({error}); leaving its generations alone")
            continue
        except OSError as error:
            # Unlistable or vanished directory: skip it, keep walking. The
            # bound step measures whatever is left, as it did before pruning.
            print(f"{display_path(cas_dir)}: could not inspect ({error}); leaving it alone")
            continue
        if not live and not removed:
            continue
        live_summary = ", ".join(path.name for path in live)
        removed_summary = ", ".join(f"{path.name} ({kib} KiB)" for path, kib in removed)
        print(f"{display_path(cas_dir)}: kept {live_summary}; removed {removed_summary or 'nothing'}")
        removed_count += len(removed)
        removed_kib += sum(kib for _, kib in removed)

    if removed_count == 0:
        print("no stale Xcode compilation cache generations found")
    else:
        print(
            f"removed {removed_count} stale Xcode compilation cache generation(s), "
            f"{removed_kib} KiB"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
