#!/usr/bin/env python3
"""cargo_target_strip.py TARGET_DIR (--cargo-metadata FILE | --workspace-crates NAME...) [--keep NAME...] : keep only third-party build output.

The fast tier's cargo target dir goes to R2 (scripts/ci/r2-cache.sh) so a runner outside Blacksmith restores
compiled dependencies instead of rebuilding about 495 crates. What a later commit rebuilds anyway is dropped
first, as Swatinem/rust-cache's cleanup does: the workspace's own crates (their deps/, .fingerprint/ and build/
entries), incremental state, and the top-level binaries of each profile dir. A dependency's artifacts stay.

Workspace names come from `cargo metadata --no-deps` (the workflow passes its JSON, or the names, so this script
needs no cargo).
--workspace-crates are package and library names: every entry of theirs goes. --workspace-binaries are the
test, bench, bin and example target names: only their executables in deps/ go. Such a name may equal a
third-party crate's (cmux-tailnet-local's tests/http.rs is `http`, acpmux-team-space's tests/digest.rs is
`digest`), and matching it on every entry deleted the third-party http and digest, so a restore rebuilt them
and their 24 dependents. --keep names workspace packages whose output stays: ghostty-vt-sys, whose build
script's zig build of libghostty-vt took 24 minutes of a 30-minute job. The workflow records source mtimes
next to it (scripts/blacksmith-testbox-source-mtimes.py) so cargo reuses it on an unchanged ghostty-next.
"""

from __future__ import annotations

import argparse
import json
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
    """target/<profile>, target/<triple>/<profile> and target/groups/<n>/<triple>/<profile>: every directory with a .fingerprint child."""
    return sorted({p.parent for depth in range(5) for p in target.glob("*/" * depth + ".fingerprint")})


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


BINARY_KINDS = {"test", "bench", "bin", "example"}


def metadata_names(path: Path) -> tuple[list[str], list[str]]:
    """(package and library target names, test/bench/bin/example target names) from `cargo metadata --no-deps`."""
    packages = json.loads(path.read_text(encoding="utf-8"))["packages"]
    crates = {p["name"] for p in packages}
    binaries: set[str] = set()
    for package in packages:
        for target in package["targets"]:
            (binaries if BINARY_KINDS & set(target["kind"]) else crates).add(target["name"])
    return sorted(crates), sorted(binaries)


def is_executable(entry: Path) -> bool:
    """A test, bench or bin target's binary: `http-0a1b2c`, no extension (a library's files all have one)."""
    return entry.is_file() and not entry.is_symlink() and "." not in entry.name


def strip(target: Path, crates: set[str], binaries: set[str] | None = None, keep: set[str] | None = None) -> tuple[int, int]:
    crates = crates - (keep or set())
    binaries = (binaries or set()) - crates - (keep or set())
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
                name = stem(entry.name)
                if name in crates or (sub == "deps" and name in binaries and is_executable(entry)):
                    freed += remove(entry)
                    removed += 1
    return removed, freed


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("target", type=Path)
    names = parser.add_mutually_exclusive_group(required=True)
    names.add_argument("--cargo-metadata", type=Path)
    names.add_argument("--workspace-crates", nargs="+")
    parser.add_argument("--workspace-binaries", nargs="*", default=[])
    parser.add_argument("--keep", nargs="*", default=[])
    args = parser.parse_args(argv)
    if not args.target.is_dir():
        print(f"cargo_target_strip: {args.target} is not a directory; nothing to strip")
        return 0
    crates, binaries = args.workspace_crates, args.workspace_binaries
    if args.cargo_metadata is not None:
        crates, more = metadata_names(args.cargo_metadata)
        binaries = binaries + more
    removed, freed = strip(args.target, normalized(crates), normalized(binaries), normalized(args.keep))
    print(f"cargo_target_strip: removed {removed} workspace entries, {freed / 2**20:.0f} MiB")
    return 0


if __name__ == "__main__":
    sys.exit(main())
