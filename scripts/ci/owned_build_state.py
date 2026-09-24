#!/usr/bin/env python3
"""Keep compile admission's build state on an owned Mac between jobs.

    owned_build_state.py check STORE FINGERPRINT RESOLVED GHOSTTY WORKSPACE
    owned_build_state.py adopt STORE DERIVED_DATA
    owned_build_state.py save STORE DERIVED_DATA SOURCE_PACKAGES FINGERPRINT RESOLVED GHOSTTY WORKSPACE COMPILED

An owned Mac (a `glaeda-<class>-xcode-<version>` runner, pr_runner_pool.py)
outlives the job, but ci-macos.yml compile admission was written for
ephemeral runners: it restores the SwiftPM cache, downloads and adopts the
nightly DerivedData seed, and compiles into a DerivedData it deleted first.
On cmux11s that was 25 minutes (run 36048804178): 3.7 of cache restore, about
3 of seed, 14 of compile.

This keeps three things under STORE (CMUX_OWNED_STATE_ROOT,
/Users/Shared/cmux-build-fleet/ci by default) instead:

- `derived-data`: the admission DerivedData, stamped with the canonical
  fingerprint (Xcode build, canonical paths, file-system mode). Builds run
  with FileSystemMode=checksum-only (compile-app-host-test-product.sh), so
  Xcode compares input contents, not times: a fresh copy of the source into
  the canonical tree rebuilds only what changed since the last job here.
- `source-packages`: the resolved `.ci-source-packages`, stamped with the
  Package.resolved hash, so an unchanged pin set resolves offline.
- `ghosttykit/<revision>`: the GhosttyKit.xcframework for a ghostty revision.

`check` runs before the caches: it drops a DerivedData whose stamp does not
match or that grew past MAX_DERIVED_BYTES, and moves the packages and
GhosttyKit into the workspace, where the existing steps pick them up. Its
`warm` output tells the workflow to skip the SwiftPM cache restore and the
seed. `adopt` runs where the seed would: the resolve step has just recreated
the DerivedData, so it swaps the kept one in. `save` runs last, always: it
moves the DerivedData back only after a successful compile (a failed or
cancelled one may be half-written), and the packages whenever they resolved.

Moves are renames: the canonical root (/private/tmp/cmux-ci) and STORE sit
on the same APFS volume, so nothing is copied. One job at a time touches
STORE, because glaeda's job-started hook holds the host lock for the whole
job. Nothing here uploads anything: a pull request run on an owned Mac never
writes a shared cache or seed, only this Mac's own state, and fork pull
requests never reach an owned pool.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

STAMP = "stamp.json"
DERIVED = "derived-data"
PACKAGES = "source-packages"
GHOSTTYKIT = "ghosttykit"
# A full DerivedData of every admission scheme is about 12 GB after UNREAD is
# dropped. Past this it is carrying stale products; start over from the seed.
MAX_DERIVED_BYTES = 40 * 1024**3
# Written by every build and read by none (seed_derived_data.UNREAD).
UNREAD = ("Logs", "Index.noindex")
KEEP_GHOSTTYKIT_REVISIONS = 2


def write_outputs(result: dict[str, str]) -> None:
    print(json.dumps(result, sort_keys=True))
    if "GITHUB_OUTPUT" in os.environ:
        with open(os.environ["GITHUB_OUTPUT"], "a") as handle:
            for name, value in result.items():
                handle.write(f"{name}={value}\n")


def tree_bytes(root: Path) -> int:
    total = 0
    for base, _, files in os.walk(root):
        for name in files:
            path = Path(base, name)
            if not path.is_symlink():
                try:
                    total += path.stat().st_size
                except OSError:
                    pass
    return total


def read_stamp(store: Path) -> dict[str, str]:
    try:
        stamp = json.loads((store / STAMP).read_text())
    except (OSError, ValueError):
        return {}
    return stamp if isinstance(stamp, dict) else {}


def write_stamp(store: Path, stamp: dict[str, str]) -> None:
    (store / STAMP).write_text(json.dumps(stamp, sort_keys=True))


def remove(path: Path) -> None:
    if path.is_symlink() or path.is_file():
        path.unlink()
    elif path.exists():
        shutil.rmtree(path, ignore_errors=True)


def move(source: Path, destination: Path) -> None:
    """A rename where the volume allows it, else a copy (shutil.move)."""
    remove(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.move(str(source), str(destination))


def clone(source: Path, destination: Path) -> None:
    """An APFS clone of a directory tree, falling back to a copy."""
    remove(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    if subprocess.run(["cp", "-cR", str(source), str(destination)], capture_output=True).returncode != 0:
        remove(destination)
        shutil.copytree(source, destination, symlinks=True)


def check(store: Path, fingerprint: str, resolved: str, ghostty: str, workspace: Path) -> dict[str, str]:
    store.mkdir(parents=True, exist_ok=True)
    stamp = read_stamp(store)
    result = {"warm": "false", "packages": "false", "packages_exact": "false", "ghosttykit": "false"}
    derived = store / DERIVED
    if not derived.is_dir():
        result["reason"] = "no kept DerivedData"
    elif not fingerprint or stamp.get("fingerprint") != fingerprint:
        remove(derived)
        result["reason"] = "kept DerivedData is for another Xcode or layout"
    else:
        size = tree_bytes(derived)
        result["bytes"] = str(size)
        if size > MAX_DERIVED_BYTES:
            remove(derived)
            result["reason"] = f"kept DerivedData grew to {size} bytes"
        else:
            result["warm"] = "true"
            result["reason"] = "kept DerivedData matches"
    packages = store / PACKAGES
    if packages.is_dir():
        move(packages, workspace / ".ci-source-packages")
        result["packages"] = "true"
        result["packages_exact"] = "true" if resolved and stamp.get("resolved") == resolved else "false"
    kit = store / GHOSTTYKIT / ghostty / "GhosttyKit.xcframework"
    if ghostty and kit.is_dir():
        clone(kit, workspace / "GhosttyKit.xcframework")
        result["ghosttykit"] = "true"
    return result


def adopt(store: Path, derived: Path) -> dict[str, str]:
    kept = store / DERIVED
    if not kept.is_dir():
        return {"hit": "false", "reason": "no kept DerivedData"}
    move(kept, derived)
    if sys.platform == "darwin":
        # The source tree is a fresh copy, so every input has a new inode;
        # without this llbuild reruns every task whose files merely moved.
        # The workflow deletes the default again after the compile.
        subprocess.run(
            ["defaults", "write", "com.apple.dt.XCBuild", "IgnoreFileSystemDeviceInodeChanges", "-bool", "YES"],
            check=True,
        )
    return {"hit": "true"}


def save(store: Path, derived: Path, source_packages: Path, fingerprint: str, resolved: str,
         ghostty: str, workspace: Path, compiled: bool) -> dict[str, str]:
    store.mkdir(parents=True, exist_ok=True)
    stamp = read_stamp(store)
    result = {"derived_data": "false", "packages": "false", "ghosttykit": "false"}
    if compiled and fingerprint and derived.is_dir():
        for name in UNREAD:
            remove(derived / name)
        move(derived, store / DERIVED)
        stamp["fingerprint"] = fingerprint
        result["derived_data"] = "true"
    else:
        # Half-written or unstamped state is worse than a seed; start over.
        remove(store / DERIVED)
        remove(derived)
        stamp.pop("fingerprint", None)
    if source_packages.is_dir():
        move(source_packages, store / PACKAGES)
        stamp["resolved"] = resolved
        result["packages"] = "true"
    kit = workspace / "GhosttyKit.xcframework"
    kits = store / GHOSTTYKIT
    if ghostty and kit.is_dir() and not (kits / ghostty / "GhosttyKit.xcframework").is_dir():
        clone(kit, kits / ghostty / "GhosttyKit.xcframework")
        result["ghosttykit"] = "true"
    if kits.is_dir():
        revisions = sorted((path for path in kits.iterdir() if path.is_dir()),
                           key=lambda path: path.stat().st_mtime, reverse=True)
        for old in revisions[KEEP_GHOSTTYKIT_REVISIONS:]:
            remove(old)
    write_stamp(store, stamp)
    return result


def main(argv: list[str]) -> int:
    if len(argv) == 7 and argv[1] == "check":
        write_outputs(check(Path(argv[2]), argv[3], argv[4], argv[5], Path(argv[6])))
        return 0
    if len(argv) == 4 and argv[1] == "adopt":
        write_outputs(adopt(Path(argv[2]), Path(argv[3])))
        return 0
    if len(argv) == 10 and argv[1] == "save":
        write_outputs(save(Path(argv[2]), Path(argv[3]), Path(argv[4]), argv[5], argv[6], argv[7],
                           Path(argv[8]), argv[9] == "true"))
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
