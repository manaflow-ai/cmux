#!/usr/bin/env python3
"""Keep compile admission's build state on an owned Mac between jobs.

    owned_build_state.py check STORE FINGERPRINT WORKSPACE [PACKAGE_STORE]
    owned_build_state.py adopt STORE DERIVED_DATA SOURCE
    owned_build_state.py record SOURCE DERIVED_DATA
    owned_build_state.py keep STORE DERIVED_DATA FINGERPRINT
    owned_build_state.py save STORE SOURCE_PACKAGES WORKSPACE [PACKAGE_STORE]
    owned_build_state.py prefer STORE WORKSPACE PREFIX REVISION [MAX_DISTANCE]

An owned Mac (a `glaeda-<class>-xcode-<version>` runner, pr_runner_pool.py)
outlives the job, but ci-macos.yml compile admission was written for
ephemeral runners: it restores the SwiftPM cache, downloads and adopts the
nightly DerivedData seed, and compiles into a DerivedData it deleted first.
On cmux11s that was 25 minutes (run 36048804178): 3.7 of cache restore, about
3 of seed, 14 of compile.

This keeps two things under STORE (CMUX_OWNED_STATE_ROOT,
/Users/Shared/cmux-build-fleet/ci by default) instead:

- `derived-data`: the admission DerivedData, stamped with the canonical
  fingerprint (Xcode build, canonical paths, file-system mode). Builds run
  with FileSystemMode=checksum-only (compile-app-host-test-product.sh), but
  swift-driver still decides what to recompile by modification time, so the
  kept DerivedData also carries the input times it was built against (below).
- `source-packages`: the resolved `.ci-source-packages`, so the resolve
  fetches what changed instead of restoring the whole cache. It is not
  handed to the resolve as an exact hit: that would change the Resolve step,
  which is part of the product key (product_input_identity.py). Packages hold
  no absolute build paths, so they live in PACKAGE_STORE, one per Mac, which
  every compile slot shares (STORE is per slot, ci-macos.yml's build-slot).

Neither is ever taken out of the store: `check` and `adopt` hand the job an
APFS clone. A job that is cancelled or fails therefore leaves the last good
state for the next one. When they were moved out instead, a cancelled or
failed admission left its Mac cold, and the next job paid about 190 s of seed
download, up to 240 s of SwiftPM cache restore and often a longer compile
(jobs 107916039092 and 107916686710 on 2026-09-25). The clone costs about
10 s, the same as `keep`'s.

`check` runs before the caches: it drops a DerivedData that grew past
MAX_DERIVED_BYTES and clones the packages into the workspace, where the
resolve step picks them up. A DerivedData stamped for another fingerprint is
not warm but stays: a rerun of an older merge commit (another STATE_VERSION
or recipe) must not throw away the state every current job uses, and the
next successful `keep` replaces it anyway. Its `warm` output tells the
workflow to skip the SwiftPM cache restore and the seed. `adopt` runs where
the seed would: the resolve step has just recreated the DerivedData, so it
clones the kept one in and replays the input times recorded in it, as the
seed's adopt does (seed_derived_data.py). Each job
copies a fresh source tree into the canonical root, so without the replay
every file is newer than the kept build and the whole `cmux` module
recompiles: 2629 SwiftCompile tasks, 386 s, in job 107904138254, against
50 s after a distance-0 seed in job 107906033416. `record` runs just before
the compile on every owned job, warm or seeded, so the DerivedData it keeps
always carries the times that compile saw. It deletes the old record first:
a stale one could age an input back to a time the kept build never saw, and
swift-driver misses a changed file whose time is older. A failed record
means a full rebuild, never a missed one. The record has its own file
(RECORD), never the seed's MANIFEST, and the stamp carries STATE_VERSION, so
a DerivedData kept from a seeded job before `record` existed is dropped
rather than replayed with the seed's times. `keep` runs right after a
successful compile and clones the DerivedData as Xcode left it: the steps
after it stage package frameworks into Build/Products and rewrite the
xctestruns, which a later build must not start from (seed-derived-data.yml
saves its seed before them for the same reason). A failed or cancelled
compile keeps nothing, so the store still holds the state it started from.
`save` runs last, always, and replaces the kept packages with the job's.

A warm Mac is not always the cheapest start. Its kept DerivedData is the
previous pull request's build, so the compile undoes that diff as well as
building this one: warm compiles took 365 to 428 s on 2026-09-25, against 50
to 160 s from a seed a few commits behind. `prefer` runs on a warm Mac when
CI_OWNED_PREFER_SEED is set and says whether the seed should replace the kept
DerivedData. It digests the workspace once and counts the inputs each would
rebuild: those whose content differs from the kept RECORD, and from the
seed's MANIFEST when this Mac keeps that seed (seed_derived_data.py
CMUX_SEED_LOCAL_CACHE). Both are a local clone, so the one with fewer changed
inputs wins. A seed this Mac does not keep costs a download of about 190 s,
so it wins only within MAX_DISTANCE commits, and only when MAX_DISTANCE is
given. A kept DerivedData without a record replays nothing and rebuilds the
whole `cmux` module, so any seed beats it. Every error keeps the warm path.

Clones are APFS clones: the canonical root (/private/tmp/cmux-ci) and STORE
sit on the same volume, so nothing is copied. Kept state is replaced by
renaming the new copy into place after the old one is out of the way, so an
interrupted job leaves either the old state, the new one, or none, never one
inside the other. One job at a time touches a slot's STORE, because glaeda
grants a slot's compile token to one job. Two slots can clone PACKAGE_STORE
while one saves; a clone that loses that race is usually a package miss, and
at worst hands the resolve an incomplete checkout that it fetches again. Nothing here uploads anything: a pull request run on an owned Mac never
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

sys.path.insert(0, str(Path(__file__).resolve().parent))
import seed_derived_data as seed  # noqa: E402

STAMP = "stamp.json"
DERIVED = "derived-data"
PACKAGES = "source-packages"
# A full DerivedData of every admission scheme is about 12 GB after UNREAD is
# dropped. Past this it is carrying stale products; start over from the seed.
MAX_DERIVED_BYTES = 40 * 1024**3
# Written by every build and read by none (seed_derived_data.UNREAD).
UNREAD = ("Logs", "Index.noindex")
# The owned record, apart from the seed's MANIFEST: a DerivedData adopted from
# a seed still carries the seed's record, whose times belong to the seed's
# source, not to what this Mac last compiled.
RECORD = "cmux-owned-input-mtimes.json"
# Appended to the canonical fingerprint in every stamp. A DerivedData kept
# before `record` existed may hold only a seed's record, so bumping this
# discards every older kept DerivedData instead of trusting it.
STATE_VERSION = "owned-rec1"


def stamped(fingerprint: str) -> str:
    return f"{fingerprint}-{STATE_VERSION}" if fingerprint else ""


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


def clear(path: Path) -> None:
    """Remove path or fail: a leftover would swallow the next move into it."""
    if path.exists() or path.is_symlink():
        aside = path.with_name(f".{path.name}.discard-{os.getpid()}")
        path.rename(aside)
        remove(aside)
    if path.exists() or path.is_symlink():
        raise RuntimeError(f"could not clear {path}")


def move(source: Path, destination: Path) -> None:
    """A rename where the volume allows it, else a copy (shutil.move)."""
    clear(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.move(str(source), str(destination))


def clone(source: Path, destination: Path) -> None:
    """An APFS clone of a directory tree, falling back to a copy."""
    clear(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    if subprocess.run(["cp", "-cR", str(source), str(destination)], capture_output=True).returncode != 0:
        remove(destination)
        shutil.copytree(source, destination, symlinks=True)


def check(store: Path, fingerprint: str, workspace: Path, package_store: Path | None = None) -> dict[str, str]:
    store.mkdir(parents=True, exist_ok=True)
    stamp = read_stamp(store)
    result = {"warm": "false", "packages": "false"}
    derived = store / DERIVED
    if not derived.is_dir():
        result["reason"] = "no kept DerivedData"
    elif not fingerprint or stamp.get("fingerprint") != stamped(fingerprint):
        # Kept for the jobs it matches; the next successful keep replaces it.
        result["reason"] = "kept DerivedData is for another Xcode or layout"
    else:
        size = tree_bytes(derived)
        result["bytes"] = str(size)
        if size > MAX_DERIVED_BYTES:
            clear(derived)
            result["reason"] = f"kept DerivedData grew to {size} bytes"
        else:
            result["warm"] = "true"
            result["reason"] = "kept DerivedData matches"
    packages = (package_store or store) / PACKAGES
    if packages.is_dir():
        destination = workspace / ".ci-source-packages"
        try:
            clone(packages, destination)
        except (OSError, RuntimeError, shutil.Error) as error:
            # A save on another slot replaced them mid-clone: resolve from the cache.
            remove(destination)
            result["packages_error"] = f"{type(error).__name__}: {error}"[:200]
        else:
            result["packages"] = "true"
    return result


def adopt(store: Path, derived: Path, source: Path) -> dict[str, str]:
    kept = store / DERIVED
    if not kept.is_dir():
        return {"hit": "false", "reason": "no kept DerivedData"}
    # A clone, not a move: a cancelled or failed compile keeps nothing, and
    # the store must still hold this state for the next job.
    clone(kept, derived)
    result = {"hit": "true", "replayed": "false"}
    # Only the owned record: a seed's record describes the seed's source.
    manifest = derived / RECORD
    if not manifest.is_file():
        result["reason"] = "kept DerivedData has no input record"
    else:
        try:
            unchanged, changed = seed.warm.replay(source, json.loads(manifest.read_text()))
        except (OSError, ValueError) as error:
            # A replay cut short can only rebuild more (seed_derived_data.py).
            result["reason"] = f"{type(error).__name__}: {error}"[:200]
        else:
            result.update(replayed="true", unchanged_inputs=str(unchanged), changed_inputs=str(changed))
    if sys.platform == "darwin":
        # The source tree is a fresh copy, so every input has a new inode;
        # without this llbuild reruns every task whose files merely moved.
        # The workflow deletes the default again after the compile.
        subprocess.run(
            ["defaults", "write", "com.apple.dt.XCBuild", "IgnoreFileSystemDeviceInodeChanges", "-bool", "YES"],
            check=True,
        )
    return result


def record(source: Path, derived: Path) -> dict[str, str]:
    """Record the input times this compile sees, for the next job's adopt."""
    manifest = derived / RECORD
    if manifest.is_file() or manifest.is_symlink():
        manifest.unlink()
    recorded = seed.warm.record(source)
    derived.mkdir(parents=True, exist_ok=True)
    incoming = derived / f".{RECORD}.incoming"
    incoming.write_text(json.dumps(recorded, sort_keys=True))
    incoming.rename(manifest)
    return {"recorded": "true", "inputs": str(len(recorded))}


def keep(store: Path, derived: Path, fingerprint: str) -> dict[str, str]:
    """Clone a just-compiled DerivedData into STORE, stamped with its fingerprint."""
    if not fingerprint or not derived.is_dir():
        return {"kept": "false", "reason": "no fingerprint or no DerivedData"}
    store.mkdir(parents=True, exist_ok=True)
    incoming = store / f".{DERIVED}.incoming"
    clone(derived, incoming)
    # A seed's record is never replayed here (adopt reads RECORD only).
    for name in (*UNREAD, seed.MANIFEST):
        remove(incoming / name)
    stamp = read_stamp(store)
    stamp.pop("fingerprint", None)
    write_stamp(store, stamp)
    clear(store / DERIVED)
    incoming.rename(store / DERIVED)
    stamp["fingerprint"] = stamped(fingerprint)
    write_stamp(store, stamp)
    return {"kept": "true"}


def save(store: Path, source_packages: Path, workspace: Path, package_store: Path | None = None) -> dict[str, str]:
    package_store = package_store or store
    package_store.mkdir(parents=True, exist_ok=True)
    # Leftovers of a save that was cancelled or lost a rename race to
    # another slot, and a slot's own packages from before PACKAGE_STORE.
    for stale in package_store.glob(f".{PACKAGES}.*"):
        remove(stale)
    if package_store != store:
        remove(store / PACKAGES)
    # The resolve moved the packages into the canonical tree; a job that
    # stopped before it left them where check put them. A job with neither
    # leaves the kept packages as they are.
    for packages in (source_packages, workspace / ".ci-source-packages"):
        if packages.is_dir():
            incoming = package_store / f".{PACKAGES}.incoming-{os.getpid()}"
            move(packages, incoming)
            try:
                clear(package_store / PACKAGES)
                incoming.rename(package_store / PACKAGES)
            except (OSError, RuntimeError):
                # Another slot saved first; its packages are as good.
                remove(incoming)
                return {"packages": "false", "reason": "another slot saved at the same time"}
            return {"packages": "true"}
    return {"packages": "false"}


# Not build inputs of the compile, and not present at every recording.
UNCOMPARED = (".ci-source-packages/", "GhosttyKit.xcframework/")


def changed_inputs(current: dict[str, list], recorded: dict[str, list]) -> int:
    """Files whose content differs between two records, or that only one has."""
    def files(entries: dict[str, list]) -> dict[str, str]:
        return {
            path: entry[0] for path, entry in entries.items()
            if not path.endswith("/") and not path.startswith(UNCOMPARED) and isinstance(entry, list) and entry
        }
    now, then = files(current), files(recorded)
    return sum(1 for path in now.keys() | then.keys() if now.get(path) != then.get(path))


def prefer(store: Path, workspace: Path, prefix: str, revision: str, max_distance: int | None) -> dict[str, str]:
    """Whether a seed should replace this warm Mac's kept DerivedData."""
    result = {"prefer": "false"}
    exact, distance = seed.locate(prefix, revision)
    if distance is None:
        result["reason"] = "no seed in this commit's history"
        return result
    local = seed.cached(exact)
    result.update(seed_key=exact, seed_distance=str(distance), local="true" if local else "false")
    manifest = store / DERIVED / RECORD
    if not manifest.is_file():
        result.update(prefer="true", reason="kept DerivedData has no input record")
        return result
    current = seed.warm.record(workspace)
    kept_changed = changed_inputs(current, json.loads(manifest.read_text()))
    result["kept_changed"] = str(kept_changed)
    if local:
        seed_changed = changed_inputs(current, json.loads((local / seed.MANIFEST).read_text()))
        result["seed_changed"] = str(seed_changed)
        if seed_changed < kept_changed:
            result.update(prefer="true", reason="this Mac keeps a seed with fewer changed inputs")
        else:
            result["reason"] = "the kept DerivedData has no more changed inputs than the seed"
    elif max_distance is not None and distance <= max_distance and kept_changed > 0:
        result.update(prefer="true", reason=f"seed {distance} commits behind, within {max_distance}")
    else:
        result["reason"] = "the seed is not on this Mac and not near enough to download"
    return result


def package_store(argv: list[str]) -> Path | None:
    return Path(argv[5]) if len(argv) == 6 and argv[5] else None


def main(argv: list[str]) -> int:
    if len(argv) in (5, 6) and argv[1] == "check":
        write_outputs(check(Path(argv[2]), argv[3], Path(argv[4]), package_store(argv)))
        return 0
    if len(argv) == 5 and argv[1] == "adopt":
        write_outputs(adopt(Path(argv[2]), Path(argv[3]), Path(argv[4]).resolve()))
        return 0
    if len(argv) == 4 and argv[1] == "record":
        write_outputs(record(Path(argv[2]).resolve(), Path(argv[3])))
        return 0
    if len(argv) == 5 and argv[1] == "keep":
        write_outputs(keep(Path(argv[2]), Path(argv[3]), argv[4]))
        return 0
    if len(argv) in (5, 6) and argv[1] == "save":
        write_outputs(save(Path(argv[2]), Path(argv[3]), Path(argv[4]), package_store(argv)))
        return 0
    if len(argv) in (6, 7) and argv[1] == "prefer":
        max_distance = int(argv[6]) if len(argv) == 7 and argv[6].isdigit() else None
        try:
            result = prefer(Path(argv[2]), Path(argv[3]).resolve(), argv[4], argv[5], max_distance)
        except Exception as error:  # noqa: BLE001 - any doubt keeps the warm path
            result = {"prefer": "false", "reason": f"{type(error).__name__}: {error}"[:200]}
        write_outputs(result)
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
