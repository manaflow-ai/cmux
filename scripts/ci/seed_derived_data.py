#!/usr/bin/env python3
"""Let pull-request compile admission build incrementally from the nightly seed.

    seed_derived_data.py record SOURCE DERIVED_DATA
    seed_derived_data.py prune DERIVED_DATA
    seed_derived_data.py adopt SOURCE DERIVED_DATA PREFIX REVISION

nightly.yml `refresh-test-compilation-cache` already compiles main cold on the
runner, Xcode and canonical paths that ci-macos.yml compile admission uses.
`record` writes the content digest and modification time of every file in the
canonical source tree into that DerivedData before the build, and `prune`
drops the parts no later build reads, so the seeder can save it to R2.

A fresh checkout stamps every file with the checkout time, so a restored
DerivedData alone rebuilds everything. `adopt` restores the newest seed into a
staging directory, swaps it in only when it is complete, and then restores the
recorded time onto every byte-identical input. Changed and new inputs get the
current time, so Xcode rebuilds exactly what differs. A seed from an older main
costs compile time, never correctness.

That time is mostly distance, not the diff under test: a CmuxFoundation change
between the seed and the checkout recompiles every file of the `cmux` module.
So `adopt` takes the seed of REVISION, the commit being built on, or else of
its nearest ancestor that has one. It used to take the pull request event's
base.sha, which is not always the merge commit's parent, and then the newest
pointer, which records the last save rather than the latest commit: nightly's
cold seed of an older main held it while newer seeds sat unused. Every miss
or failure leaves the DerivedData the caller had, which is today's cold build.

Only jobs holding the bucket credentials can write R2 objects or pointers, and
only the main-branch seeder is given them, so a pull request can read the seed
but never replace it.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
import urllib.request

sys.path.insert(0, str(Path(__file__).resolve().parent))
import e2e_warm_derived_data as warm  # noqa: E402

MANIFEST = "cmux-seed-input-mtimes.json"
# Written by every build and read by none: the build log directory and the
# index store, which is not a declared task output.
UNREAD = ("Logs", "Index.noindex")
# Raw bytes; the archive is about a third of this. Larger means the restore
# costs more than the compile it saves.
MAX_RAW_BYTES = 12 * 1024**3
R2_CACHE = Path(__file__).resolve().parent / "r2-cache.sh"
# main seeds about one commit in ten, so fifty ancestors reach back several
# seeds; past that the newest pointer is as good as anything.
ANCESTOR_LIMIT = 50


def tree_bytes(root: Path) -> int:
    total = 0
    for base, _, files in os.walk(root):
        for name in files:
            path = Path(base, name)
            if not path.is_symlink():
                total += path.stat().st_size
    return total


def write_outputs(result: dict[str, object]) -> None:
    print(json.dumps(result, sort_keys=True))
    if "GITHUB_OUTPUT" in os.environ:
        with open(os.environ["GITHUB_OUTPUT"], "a") as handle:
            for name, value in result.items():
                handle.write(f"{name}={value}\n")


def record(source: Path, derived: Path) -> None:
    derived.mkdir(parents=True, exist_ok=True)
    recorded = warm.record(source)
    (derived / MANIFEST).write_text(json.dumps(recorded, sort_keys=True))
    print(f"Recorded {len(recorded)} build inputs under {source}")


def prune(derived: Path) -> dict[str, object]:
    if not (derived / MANIFEST).is_file():
        return {"save": "false", "reason": "no-input-manifest"}
    for name in UNREAD:
        shutil.rmtree(derived / name, ignore_errors=True)
    size = tree_bytes(derived)
    if size > MAX_RAW_BYTES:
        return {"save": "false", "reason": "too-large", "bytes": str(size)}
    return {"save": "true", "bytes": str(size)}


def lineage(revision: str) -> list[str]:
    """REVISION, then its ancestors newest first. Only REVISION if unknown."""
    repository = os.environ.get("GITHUB_REPOSITORY", "")
    if not repository:
        return [revision]
    try:
        listed = subprocess.run(
            ["gh", "api", f"repos/{repository}/commits?sha={revision}&per_page={ANCESTOR_LIMIT}", "--jq", ".[].sha"],
            check=True, capture_output=True, text=True, timeout=60,
        ).stdout.split()
    except (OSError, subprocess.SubprocessError) as error:
        print(f"seed: ancestors of {revision} unknown ({type(error).__name__}); trying it alone")
        return [revision]
    return [revision] + [sha for sha in listed if sha != revision]


def seed_exists(key: str) -> bool:
    """Whether the public bucket holds KEY, in the layout r2-cache.sh saves."""
    base = os.environ.get("CI_CACHE_R2_PUBLIC_URL", "").rstrip("/")
    if not base:
        return False
    namespace = f"v1/{os.environ.get('RUNNER_OS') or platform.system()}-{os.environ.get('RUNNER_ARCH') or platform.machine()}"
    for extension in ("tar.zst", "tar.gz"):
        request = urllib.request.Request(f"{base}/{namespace}/objects/{key}.{extension}", method="HEAD")
        try:
            with urllib.request.urlopen(request, timeout=15) as response:
                if response.status == 200:
                    return True
        except OSError:
            continue
    return False


def nearest(prefix: str, revisions: list[str], exists=None) -> tuple[str, int] | None:
    """The key of the first revision with a seed, and how far down the list it was."""
    keys = [prefix + revision for revision in revisions]
    with ThreadPoolExecutor(max_workers=16) as pool:
        found = list(pool.map(exists or seed_exists, keys))
    for distance, (key, hit) in enumerate(zip(keys, found)):
        if hit:
            return key, distance
    return None


def adopt(source: Path, derived: Path, exact: str, prefix: str) -> dict[str, object]:
    staging = derived.with_name(derived.name + ".seed")
    shutil.rmtree(staging, ignore_errors=True)
    started = time.monotonic()
    try:
        outputs = staging.with_name(staging.name + ".outputs")
        outputs.unlink(missing_ok=True)
        subprocess.run(
            ["bash", str(os.environ.get("CMUX_R2_CACHE_SCRIPT", R2_CACHE)), "restore", str(staging), exact, prefix],
            check=True, env={**os.environ, "GITHUB_OUTPUT": str(outputs)},
        )
        restored = dict(
            line.split("=", 1) for line in outputs.read_text().splitlines() if "=" in line
        ) if outputs.exists() else {}
        outputs.unlink(missing_ok=True)
        key = restored.get("cache-matched-key", "")
        if not key:
            return {"hit": "false", "reason": "no-seed"}
        manifest = staging / MANIFEST
        if not manifest.is_file():
            return {"hit": "false", "reason": "seed-without-input-manifest", "key": key}
        recorded = json.loads(manifest.read_text())
        shutil.rmtree(derived, ignore_errors=True)
        staging.rename(derived)
        unchanged, changed = warm.replay(source, recorded)
        if sys.platform == "darwin":
            # Both the checkout and the extracted DerivedData have new inodes;
            # without this llbuild reruns every task whose files merely moved.
            subprocess.run(
                ["defaults", "write", "com.apple.dt.XCBuild", "IgnoreFileSystemDeviceInodeChanges", "-bool", "YES"],
                check=True,
            )
        return {
            "hit": "true",
            "key": key,
            "unchanged_inputs": str(unchanged),
            "changed_inputs": str(changed),
            "seconds": f"{time.monotonic() - started:.1f}",
        }
    finally:
        shutil.rmtree(staging, ignore_errors=True)


def main(argv: list[str]) -> int:
    if len(argv) == 4 and argv[1] == "record":
        record(Path(argv[2]).resolve(), Path(argv[3]))
        return 0
    if len(argv) == 3 and argv[1] == "prune":
        write_outputs(prune(Path(argv[2])))
        return 0
    if len(argv) == 6 and argv[1] == "adopt":
        source, derived = Path(argv[2]).resolve(), Path(argv[3])
        prefix, revision = argv[4], argv[5]
        try:
            found = nearest(prefix, lineage(revision))
            exact, distance = found if found else (prefix + revision, None)
            result = adopt(source, derived, exact, prefix)
            if result.get("hit") == "true":
                # Commits between the seed and REVISION; empty means the
                # newest pointer supplied it.
                result["seed_distance"] = "" if distance is None or result["key"] != exact else str(distance)
        except Exception as error:  # noqa: BLE001 - every failure means a cold build
            # The swap happens only after a complete restore, so a failure
            # before it leaves the caller's DerivedData untouched. A replay
            # cut short is still safe: each input it reached is either
            # byte-identical at its recorded time or stamped now, and each it
            # did not reach keeps its checkout time, which is newer than the
            # seed. Either way Xcode can only rebuild more, never less.
            derived.mkdir(parents=True, exist_ok=True)
            result = {"hit": "false", "reason": f"{type(error).__name__}: {error}"[:200]}
        write_outputs(result)
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
