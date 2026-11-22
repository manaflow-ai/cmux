#!/usr/bin/env python3
"""cargo_target_strip.py TARGET_DIR --workspace-crates NAME... : keep only third-party build output.

The fast tier's cargo target dir goes to R2 (scripts/ci/r2-cache.sh) so a runner outside Blacksmith restores
compiled dependencies instead of rebuilding about 495 crates. What a later commit rebuilds anyway is dropped
first, as Swatinem/rust-cache's cleanup does: the workspace's own crates (their deps/, .fingerprint/ and build/
entries), incremental state, and the top-level binaries of each profile dir. A dependency's artifacts stay.

Workspace names come from `cargo metadata --no-deps` (package names and target names, `-` or `_`); the
workflow passes them so this script needs no cargo.
"""

from __future__ import annotations

import argparse
import shutil
import sys
from pathlib import Path


def normalized(names: list[str]) -> set[str]:
    out: set[str] = set()
    for name in names:
        out.add(name.replace("-", "_"))
    return out


def stem(entry: str) -> str:
    """`libcmux_json-0a1b2c.rlib` -> `cmux_json`; `cmux-json-0a1b2c` -> `cmux_json`."""
    # Only a library file carries rustc's `lib` prefix; a fingerprint or build dir (`libc-99bb`) does not.
    is_library = entry.rsplit(".", 1)[-1] in {"rlib", "rmeta", "so", "a"} and "." in entry
    name = entry[3:] if is_library and entry.startswith("lib") else entry
    head = name.split(".", 1)[0]
    if "-" in head:
        head = head.rsplit("-", 1)[0]
    return head.replace("-", "_")


def profile_dirs(target: Path) -> list[Path]:
    """target/<profile> and target/<triple>/<profile>: every directory with a .fingerprint child."""
    return sorted({p.parent for p in target.glob(".fingerprint")} | {p.parent for p in target.glob("*/.fingerprint")}
                  | {p.parent for p in target.glob("*/*/.fingerprint")})


def remove(path: Path) -> int:
    try:
        size = sum(f.stat().st_size for f in path.rglob("*") if f.is_file()) if path.is_dir() else path.stat().st_size
    except OSError:
        size = 0
    if path.is_dir() and not path.is_symlink():
        shutil.rmtree(path, ignore_errors=True)
    else:
        path.unlink(missing_ok=True)
    return size


def strip(target: Path, crates: set[str]) -> tuple[int, int]:
    removed = freed = 0
    for profile in profile_dirs(target):
        for child in list(profile.iterdir()):
            if child.is_file() or child.is_symlink():
                # Top-level outputs (binaries, .d files, rlibs a later build relinks) are workspace products.
                freed += remove(child)
                removed += 1
            elif child.name in {"incremental", "examples"}:
                freed += remove(child)
                removed += 1
        for sub in (".fingerprint", "build", "deps"):
            folder = profile / sub
            if not folder.is_dir():
                continue
            for entry in list(folder.iterdir()):
                if stem(entry.name) in crates:
                    freed += remove(entry)
                    removed += 1
    return removed, freed


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("target", type=Path)
    parser.add_argument("--workspace-crates", nargs="+", required=True)
    args = parser.parse_args(argv)
    if not args.target.is_dir():
        print(f"cargo_target_strip: {args.target} is not a directory; nothing to strip")
        return 0
    removed, freed = strip(args.target, normalized(args.workspace_crates))
    print(f"cargo_target_strip: removed {removed} workspace entries, {freed / 2**20:.0f} MiB")
    return 0


if __name__ == "__main__":
    sys.exit(main())
