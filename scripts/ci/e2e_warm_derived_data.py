#!/usr/bin/env python3
"""Let a build start from adopted DerivedData (seed_derived_data.py).

    e2e_warm_derived_data.py record WORKSPACE MANIFEST
    e2e_warm_derived_data.py replay WORKSPACE MANIFEST

The compiled product archive carries Build/Products only. Without the build
database and intermediates next to it, xcodebuild cannot tell what is already
built, so a revision that changes one test file recompiles the whole app host:
691 of the 735 seconds `build-for-testing` spends is the app scheme.

Xcode decides what to rebuild from modification times, and a fresh checkout
stamps every file with the checkout time. `record` writes the content digest
and modification time of every build input before a compile. `replay` restores
the recorded time only onto files whose content is byte-identical, so an
unchanged file looks as old as the build that consumed it, and stamps every
other file with the current time. A changed file cannot keep an old time: files
unpacked from an archive (GhosttyKit, SwiftPM binary artifacts) carry the
archive's times, which may predate the producer's build. Correctness never depends on how close
the adopted DerivedData is to this revision; distance only costs compile time.

A time derived from content alone (no manifest) would be unsafe. llbuild
compares stat info for equality, but swift-driver treats a clang header or
module as changed only when it is newer than the last build's start, or with
explicit modules than the module it built, and hashing does not change that.
On Xcode 26.6 a header edited to an older time reran SwiftDriver and still
built with the old header value, with explicit modules on and off; stamped
now, it rebuilt. A time and size shared by two contents also
kept the stale product. Canary: manaflow-ai/cmux actions run 36023385114.

Directories are inputs too. Xcode signs a folder input such as
`Assets.xcassets` by the times of everything in it, the directories included,
so a checkout-time directory reruns the asset catalog, regenerates
`GeneratedAssetSymbols.swift` and recompiles every `cmuxTests` file: 241 s
against 50 s for an app source edit, measured on #14235. `record` also keeps
each directory's time under `<path>/`, beside a digest of its entry names, and
`replay` restores it only where those names are unchanged. Every file in it
still carries its own replayed time, so a changed file inside keeps the folder
out of date.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import sys

# Never walk into build outputs or git metadata: they are not inputs, and
# DerivedData lives inside the workspace on every runner pool.
SKIPPED_DIRECTORIES = frozenset({".git", "DerivedData"})


def digest(path: Path) -> str:
    checksum = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            checksum.update(block)
    return checksum.hexdigest()


def inputs(workspace: Path):
    for root, directories, files in os.walk(workspace):
        directories[:] = sorted(d for d in directories if d not in SKIPPED_DIRECTORIES)
        for name in sorted(files):
            path = Path(root, name)
            if path.is_symlink() or not path.is_file():
                continue
            yield path.relative_to(workspace).as_posix(), path


def directories(workspace: Path):
    """Each directory `inputs` walks, keyed `<path>/` (the workspace is `./`)."""
    for root, children, _ in os.walk(workspace):
        children[:] = sorted(
            d for d in children if d not in SKIPPED_DIRECTORIES and not Path(root, d).is_symlink()
        )
        path = Path(root)
        if path.is_symlink():
            continue
        yield path.relative_to(workspace).as_posix() + "/", path


def listing(path: Path) -> str:
    """Digest of a directory's entry names, which is what moves its time."""
    return hashlib.sha256("\n".join(sorted(os.listdir(path))).encode()).hexdigest()


def record(workspace: Path) -> dict[str, list]:
    recorded = {
        relative: [digest(path), path.stat().st_mtime_ns]
        for relative, path in inputs(workspace)
    }
    for key, path in directories(workspace):
        recorded[key] = [listing(path), path.stat().st_mtime_ns]
    return recorded


def replay(workspace: Path, recorded: dict[str, list]) -> tuple[int, int]:
    """Replay recorded times; the counts are files only.

    A manifest recorded before directories were kept has no `<path>/` keys,
    and its directories keep the checkout time, as they always did.
    """
    restored = changed = 0
    for relative, path in inputs(workspace):
        entry = recorded.get(relative)
        if entry is None or entry[0] != digest(path):
            os.utime(path)
            changed += 1
            continue
        os.utime(path, ns=(entry[1], entry[1]))
        restored += 1
    # Setting a file's time never moves its directory's, so order is free.
    for key, path in directories(workspace):
        entry = recorded.get(key)
        if entry is not None and entry[0] == listing(path):
            os.utime(path, ns=(entry[1], entry[1]))
    return restored, changed


def main(argv: list[str]) -> int:
    if len(argv) == 4 and argv[1] in {"record", "replay"}:
        workspace, manifest = Path(argv[2]).resolve(), Path(argv[3])
        if argv[1] == "record":
            manifest.write_text(json.dumps(record(workspace), sort_keys=True))
            print(f"Recorded {len(json.loads(manifest.read_text()))} build inputs")
        else:
            restored, changed = replay(workspace, json.loads(manifest.read_text()))
            print(f"Replayed {restored} unchanged inputs; {changed} changed or new")
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
