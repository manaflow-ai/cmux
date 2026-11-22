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
import subprocess
import sys

# Never walk into build outputs or git metadata: they are not inputs, and
# DerivedData lives inside the workspace on every runner pool.
SKIPPED_DIRECTORIES = frozenset({".git", "DerivedData"})
GIT_LOCATION_VARIABLES = frozenset({"GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE"})


def git_environment() -> dict[str, str]:
    return {
        name: value
        for name, value in os.environ.items()
        if name not in GIT_LOCATION_VARIABLES
    }


def digest(path: Path) -> str:
    checksum = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            checksum.update(block)
    return checksum.hexdigest()


def tracked_paths(workspace: Path) -> set[str] | None:
    try:
        repository = subprocess.run(
            ["git", "-C", str(workspace), "rev-parse", "--show-toplevel"],
            check=True,
            capture_output=True,
            env=git_environment(),
        ).stdout.strip()
        if Path(os.fsdecode(repository)).resolve() != workspace.resolve():
            return None
        output = subprocess.run(
            ["git", "-C", str(workspace), "ls-files", "--cached", "--recurse-submodules", "-z"],
            check=True,
            capture_output=True,
            env=git_environment(),
        ).stdout
    except (OSError, subprocess.CalledProcessError):
        return None
    paths = {os.fsdecode(path) for path in output.split(b"\0") if path}
    packages = workspace / ".ci-source-packages"
    if packages.is_dir():
        paths.update(
            path.relative_to(workspace).as_posix()
            for path in packages.rglob("*")
            if path.is_file() and not path.is_symlink()
        )
    for relative in tuple(paths):
        parts = relative.split("/")
        paths.update("/".join(parts[:index]) + "/" for index in range(1, len(parts)))
    paths.add("./")
    return paths


def inputs(workspace: Path, included_paths: set[str] | None = None):
    if included_paths is None:
        included_paths = tracked_paths(workspace)
    for root, directories, files in os.walk(workspace):
        directories[:] = sorted(d for d in directories if d not in SKIPPED_DIRECTORIES)
        for name in sorted(files):
            path = Path(root, name)
            if path.is_symlink() or not path.is_file():
                continue
            relative = path.relative_to(workspace).as_posix()
            if included_paths is not None and relative not in included_paths:
                continue
            yield relative, path


def directories(workspace: Path, included_paths: set[str] | None = None):
    """Each directory `inputs` walks, keyed `<path>/` (the workspace is `./`)."""
    if included_paths is None:
        included_paths = tracked_paths(workspace)
    for root, children, _ in os.walk(workspace):
        children[:] = sorted(
            d for d in children
            if d not in SKIPPED_DIRECTORIES
            and not Path(root, d).is_symlink()
            and (included_paths is None
                 or Path(root, d).relative_to(workspace).as_posix() + "/" in included_paths)
        )
        path = Path(root)
        if path.is_symlink():
            continue
        relative = path.relative_to(workspace).as_posix() + "/"
        if included_paths is not None and relative not in included_paths:
            children[:] = []
            continue
        yield relative, path


def listing(path: Path, workspace: Path | None = None, included_paths: set[str] | None = None) -> str:
    """Digest of a directory's entry names, which is what moves its time."""
    names = os.listdir(path)
    if workspace is not None and included_paths is not None:
        names = [
            name for name in names
            if path.joinpath(name).relative_to(workspace).as_posix() in included_paths
            or path.joinpath(name).relative_to(workspace).as_posix() + "/" in included_paths
        ]
    return hashlib.sha256("\n".join(sorted(names)).encode()).hexdigest()


def record(workspace: Path) -> dict[str, list]:
    included_paths = tracked_paths(workspace)
    recorded = {
        relative: [digest(path), path.stat().st_mtime_ns]
        for relative, path in inputs(workspace, included_paths)
    }
    for key, path in directories(workspace, included_paths):
        recorded[key] = [listing(path, workspace, included_paths), path.stat().st_mtime_ns]
    return recorded


def replay(workspace: Path, recorded: dict[str, list]) -> tuple[int, int]:
    """Replay recorded times; the counts are files only.

    A manifest recorded before directories were kept has no `<path>/` keys,
    and its directories keep the checkout time, as they always did.
    """
    restored = changed = 0
    included_paths = tracked_paths(workspace)
    for relative, path in inputs(workspace, included_paths):
        entry = recorded.get(relative)
        if entry is None or entry[0] != digest(path):
            os.utime(path)
            changed += 1
            continue
        os.utime(path, ns=(entry[1], entry[1]))
        restored += 1
    # Setting a file's time never moves its directory's, so order is free.
    for key, path in directories(workspace, included_paths):
        entry = recorded.get(key)
        if entry is not None and entry[0] == listing(path, workspace, included_paths):
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
