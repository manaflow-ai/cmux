#!/usr/bin/env python3
"""Keep compile admission's build state on an owned Mac between jobs.

    owned_build_state.py check STORE FINGERPRINT WORKSPACE [PACKAGE_STORE]
    owned_build_state.py adopt STORE DERIVED_DATA SOURCE
    owned_build_state.py record SOURCE DERIVED_DATA
    owned_build_state.py keep STORE DERIVED_DATA FINGERPRINT [MERGED_ONTO [PR_NUMBER]]
    owned_build_state.py save STORE SOURCE_PACKAGES WORKSPACE [PACKAGE_STORE]
    owned_build_state.py prefer STORE WORKSPACE PREFIX REVISION [MAX_DISTANCE]
    owned_build_state.py warm-keys STORE RUNNER POOL [FINGERPRINT]

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
  needs no cache restore. The resolve stamps them with the Package.resolved
  it resolved, and a matching stamp resolves offline
  (compile-app-host-test-product.sh `resolve`); otherwise it fetches what
  changed. Packages hold
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
MANIFEST of every seed in this commit's history that this Mac keeps
(seed_derived_data.py CMUX_SEED_LOCAL_CACHE, as many as the disk holds). All are a local
clone, so the one with the fewest changed inputs wins, and the adopt that
follows clones exactly that seed (CMUX_SEED_EXACT). A seed this Mac does not
keep costs a download of about 250 s, worth about DOWNLOAD_INPUTS changed
inputs, so it wins only when GitHub's compare of its commit with the checkout
lists that many fewer files than the kept build changed, at most MAX_DISTANCE
commits back, and only when MAX_DISTANCE is given. A commit count alone says
little: main takes about 25 merges an hour and a seed about 15 minutes, so the
newest seed is usually 5 to 8 commits behind. A start that changes at most
DOWNLOAD_INPUTS inputs never pays for a download, and when the compare bumps
a submodule (the counts no longer compare) only a seed
UNKNOWN_ESTIMATE_DISTANCE commits behind is downloaded. A kept DerivedData
without a record replays nothing and rebuilds the whole `cmux` module, so any
seed beats it. Every error keeps the warm path.

The count alone misleads when a local package's source changed (Packages/,
vendor/, Examples/): every `cmux` file imports those modules and recompiles,
whether 19 or 1,000 inputs changed. On 2026-09-25 three warm jobs cloned a
kept seed 9 to 20 commits behind because it had fewer changed inputs than the
kept DerivedData, and compiled for 533 to 958 s. In two of them the seed sat
behind a package change that a nearer bucket seed had already built (jobs
108004619872, 107981633810). So a start that recompiles the app loses
to one that does not, and when both the kept DerivedData and the kept seed
would, a nearer bucket seed wins at any distance if GitHub's compare of its
commit with the checkout shows no package source change: its download (about
250 s on a mini) costs less than recompiling the app (365 to 1,053 s).

`keep` also stamps MERGED_ONTO, the main commit the kept build merged onto,
and `warm-keys` prints the main commits this Mac starts from cheaply, for the
queue janitor to route a later admission merging onto one of them to this
runner (owned_warm_state.py, pr_runner_pool.py warm affinity):

    {"runner": "<RUNNER>", "pool": "<POOL>", "keys": ["<sha12>", ...]}

The kept build's merge base comes first, when its stamp matches FINGERPRINT,
then `pr-<n>` for the pull request it built (`keep`'s PR_NUMBER, so a re-push
goes back to its previous push's build), then the same two keys of the mini's
other canonical roots, then, on a mini with a single root, the commits of the
seeds this Mac keeps for FINGERPRINT (CMUX_SEED_LOCAL_CACHE, set only when
CI_OWNED_PREFER_SEED lets `prefer` clone them), most recently used first,
MAX_WARM_KEYS in all. It never fails: anything it cannot read leaves that key
out.

The other roots count because a job's root follows glaeda's free token, not
the runner: the janitor records the keys against the runner that ran
admission, and glaeda-cmux-runner-hook gives a routed admission the root
whose stamp is warm for it. Root k>1 keeps its state in STORE/cmux-ci-<k>
(ci-macos.yml build-slot), root 1 in STORE itself. Another root's fingerprint
includes its root (compile-app-host-test-product.sh), so its stamp is checked
by STATE_VERSION only. Seeds are left out once the mini has a second root
(any STORE/cmux-ci-<k>): each root keeps its own seeds for its own
fingerprint, and the hook routes by stamps only, so a routed admission lands
on its runner's own root (or any free one), not on the root that listed the
seed. A seed key recorded against the runner would send it there to miss.

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

import contextlib
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
# The keys owned_warm_state.py keeps per runner (its MAX_KEYS).
MAX_WARM_KEYS = 8
# The second and later canonical roots' stores, beside the first root's.
ROOT_STORE_PREFIX = "cmux-ci-"
SEED_KEY_PREFIX = "admission-derived-data-v1-"


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
    if fingerprint and os.environ.get("RUNNER_OS") and os.environ.get("RUNNER_ARCH"):
        # Which seeds this root adopts, for seed_derived_data.py `prefetch`
        # to fetch ahead while the Mac is idle. Best effort.
        source = {
            "prefix": f"admission-derived-data-v1-{os.environ['RUNNER_OS']}-{os.environ['RUNNER_ARCH']}-{fingerprint}-",
            "runner_os": os.environ["RUNNER_OS"],
            "runner_arch": os.environ["RUNNER_ARCH"],
            "public_url": os.environ.get("CI_CACHE_R2_PUBLIC_URL", ""),
        }
        try:
            incoming = store / f".{seed.SEED_SOURCE}.{os.getpid()}"
            incoming.write_text(json.dumps(source) + "\n")
            incoming.rename(store / seed.SEED_SOURCE)
        except OSError:
            pass
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


def warm_key(commit: str | None) -> str:
    """A commit's warm key (its first 12 hex digits), or "" (pr_runner_pool.warm_key)."""
    key = (commit or "").strip().lower()[:12]
    return key if len(key) == 12 and all(char in "0123456789abcdef" for char in key) else ""


def keep(store: Path, derived: Path, fingerprint: str, merged_onto: str = "", pr_number: str = "") -> dict[str, str]:
    """Clone a just-compiled DerivedData into STORE, stamped with its fingerprint and merge base."""
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
    stamp.pop("merged_onto", None)
    stamp.pop("pr", None)
    write_stamp(store, stamp)
    clear(store / DERIVED)
    incoming.rename(store / DERIVED)
    stamp["fingerprint"] = stamped(fingerprint)
    if warm_key(merged_onto):
        stamp["merged_onto"] = merged_onto.strip().lower()
    if pr_key(pr_number):
        stamp["pr"] = int(pr_number.strip())
    write_stamp(store, stamp)
    return {"kept": "true"}


def pr_key(number: object) -> str:
    """Pull request NUMBER's warm key, `pr-<n>`, or ""."""
    text = str(number if number is not None else "").strip()
    return f"pr-{int(text)}" if text.isdigit() and 0 < int(text) < 10**9 else ""


def stamp_keys(store: Path, fingerprint: str) -> list[str]:
    """The kept build's keys (merge base, pull request) when its stamp matches FINGERPRINT.

    An empty FINGERPRINT checks STATE_VERSION only (another root's stamp).
    """
    stamp = read_stamp(store)
    kept = str(stamp.get("fingerprint") or "")
    if not (store / DERIVED).is_dir() or not kept.endswith(f"-{STATE_VERSION}"):
        return []
    if fingerprint and kept != stamped(fingerprint):
        return []
    return [warm_key(str(stamp.get("merged_onto") or "")), pr_key(stamp.get("pr"))]


def other_root_stores(store: Path) -> list[Path]:
    """The mini's other canonical roots' stores (STORE is root 1's, or STORE/../cmux-ci-<k>)."""
    def is_root(path: Path) -> bool:
        suffix = path.name[len(ROOT_STORE_PREFIX):]
        return path.name.startswith(ROOT_STORE_PREFIX) and suffix.isdigit() and len(suffix) <= 2
    base = store.parent if is_root(store) else store
    try:
        roots = [base, *sorted(path for path in base.iterdir() if is_root(path))]
    except OSError:
        roots = [base]
    return [path for path in roots if path != store]


def warm_keys(store: Path, runner: str, pool: str, fingerprint: str = "") -> dict[str, object]:
    """The main commits and pull requests this Mac starts from cheaply, as owned_warm_state.py reads them."""
    found: list[str] = stamp_keys(store, fingerprint)
    others = other_root_stores(store)
    for other in others:
        found.extend(stamp_keys(other, ""))
    # A seed sits in one root's store, and glaeda routes by stamps only: on a
    # mini with more than one root, a routed admission may start at another
    # root, whose store lacks the seed and whose fingerprint rules it out.
    cache = None if others else seed.local_cache()
    seeds: list[tuple[float, str]] = []
    try:
        entries = list(cache.iterdir()) if cache is not None and cache.is_dir() else []
    except OSError:
        entries = []
    for entry in entries:
        name = entry.name
        if (not name.startswith(SEED_KEY_PREFIX) or (fingerprint and f"-{fingerprint}-j" not in name)
                or seed.cached(name) is None):
            continue
        try:
            seeds.append((entry.stat().st_mtime, warm_key(name.rsplit("-", 1)[-1])))
        except OSError:
            continue
    found.extend(key for _, key in sorted(seeds, reverse=True))
    keys: list[str] = []
    for key in found:
        if key and key not in keys:
            keys.append(key)
    return {"runner": runner, "pool": pool, "keys": keys[:MAX_WARM_KEYS]}


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
# Local Swift packages the app target imports. A changed source in any of them
# changes a module the `cmux` target imports, so every `cmux` file recompiles
# (2,300 to 2,700 SwiftCompile tasks, 365 to 1,053 s on an owned mini on
# 2026-09-25), however few inputs changed: 115 changed inputs cost 958 s in
# job 108004619872, 19 changed app inputs 222 s in job 107986723124.
PACKAGE_SOURCES = ("Packages/", "vendor/", "Examples/")
# GitHub's compare API lists at most this many files; a longer diff is unknown.
COMPARE_FILE_LIMIT = 300
# A download costs about 250 s on a mini, about what this many changed app
# inputs cost to recompile, so a downloaded seed must change this many fewer.
DOWNLOAD_INPUTS = 150
# Without GitHub's compare, a downloaded seed is taken only this near: a bare
# commit count says nothing about what changed in between.
UNKNOWN_ESTIMATE_DISTANCE = 2


def changed_paths(current: dict[str, list], recorded: dict[str, list]) -> set[str]:
    """Files whose content differs between two records, or that only one has."""
    def files(entries: dict[str, list]) -> dict[str, str]:
        return {
            path: entry[0] for path, entry in entries.items()
            if not path.endswith("/") and not path.startswith(UNCOMPARED) and isinstance(entry, list) and entry
        }
    now, then = files(current), files(recorded)
    return {path for path in now.keys() | then.keys() if now.get(path) != then.get(path)}


def changed_inputs(current: dict[str, list], recorded: dict[str, list]) -> int:
    return len(changed_paths(current, recorded))


def rebuilds_app(paths) -> bool:
    """Whether these changed files recompile the whole `cmux` module.

    A package's Tests/ are not built by the app's schemes, so they do not count.
    """
    return any(
        path.startswith(PACKAGE_SOURCES) and path.endswith(".swift") and "/Tests/" not in path
        for path in paths
    )


def cost(paths: set[str]) -> tuple[bool, int]:
    """What a start with these changed inputs compiles: an app rebuild first, then the count."""
    return rebuilds_app(paths), len(paths)


def bucket_compare(key: str, workspace: Path) -> list[str] | None:
    """The files that differ between KEY's revision and the checkout, per GitHub.

    None when GitHub cannot say (no repository, an error, or a diff past the
    compare API's file limit).
    """
    files: list[str] | None = None
    repository = os.environ.get("GITHUB_REPOSITORY", "")
    if repository:
        try:
            head = subprocess.run(["git", "-C", str(workspace), "rev-parse", "HEAD"],
                                  check=True, capture_output=True, text=True, timeout=30).stdout.strip()
            files = json.loads(subprocess.run(
                ["gh", "api", f"repos/{repository}/compare/{key.rsplit('-', 1)[-1]}...{head}",
                 "--jq", "[.files[]? | .filename, (.previous_filename // empty)]"],
                check=True, capture_output=True, text=True, timeout=60,
            ).stdout)
        except (OSError, subprocess.SubprocessError, ValueError):
            files = None
        if files is not None and len(files) >= COMPARE_FILE_LIMIT:
            files = None
    return files


def bucket_seed_rebuilds_app(key: str, workspace: Path) -> bool | None:
    """Whether the commits from KEY's revision to the checkout change a package source.

    None when GitHub cannot say (no repository, an error, or a diff past the
    compare API's file limit); the caller then treats the seed as no better.
    """
    return files_rebuild_app(bucket_compare(key, workspace), workspace)


def files_rebuild_app(files: list[str] | None, workspace: Path) -> bool | None:
    """Whether a GitHub compare's FILES change a package source; None if unknown."""
    if files is None:
        return None
    # A submodule bump (vendor/bonsplit) is listed as the bare submodule
    # path, while the local records see the .swift files under it.
    if rebuilds_app(files):
        return True
    bumped = [path for path in files if path.startswith(PACKAGE_SOURCES)]
    return bool(bumped) and not submodules(workspace).isdisjoint(bumped)


def submodules(workspace: Path) -> set[str]:
    """The submodule paths .gitmodules declares, or none if it cannot be read."""
    try:
        listed = subprocess.run(
            ["git", "config", "-f", str(workspace / ".gitmodules"), "--get-regexp", r"\.path$"],
            check=True, capture_output=True, text=True, timeout=30,
        ).stdout
    except (OSError, subprocess.SubprocessError):
        return set()
    return {line.split(None, 1)[1].strip() for line in listed.splitlines() if len(line.split(None, 1)) == 2}


def kept_seeds(prefix: str, revision: str) -> list[tuple[str, int]]:
    """Every seed in REVISION's history that this Mac keeps, nearest first, with its distance.

    The nearest seed in the bucket moves with every main push that reseeds, so
    a warm Mac that never downloads would rarely keep that exact one. The
    nearest one it keeps is not always the cheapest either: one behind a
    package change recompiles the app, an older one before it may not.
    """
    widths = (seed.swift_jobs(), *(width for width in seed.SEEDED_JOB_WIDTHS if width != seed.swift_jobs()))
    found = []
    for distance, commit in enumerate(seed.lineage(revision)):
        for jobs in widths:
            key = seed.scoped(prefix, jobs) + commit
            if seed.cached(key):
                found.append((key, distance))
    return found


def best_kept_seed(prefix: str, revision: str, current: dict) -> tuple[str, int, tuple[bool, int] | None] | None:
    """The kept seed that compiles least from CURRENT, nearest on a tie, and its cost.

    With an empty CURRENT (no kept record to digest against) the nearest wins
    and its cost is None.
    """
    best = None
    for key, distance in kept_seeds(prefix, revision):
        if not current:
            return key, distance, None
        try:
            manifest = json.loads((seed.cached(key) / seed.MANIFEST).read_text())
        except (OSError, TypeError, ValueError):
            continue
        seed_cost = cost(changed_paths(current, manifest))
        if best is None or seed_cost < best[2]:
            best = (key, distance, seed_cost)
    return best


def prefer(store: Path, workspace: Path, prefix: str, revision: str, max_distance: int | None) -> dict[str, str]:
    """Whether a seed should replace this warm Mac's kept DerivedData.

    `seed_key` and `local` tell seed_derived_data.py which kept seed to clone
    (CMUX_SEED_EXACT), so it adopts the seed compared here, not a newer one.
    """
    result = {"prefer": "false", "local": "false"}
    manifest = store / DERIVED / RECORD
    kept_record = json.loads(manifest.read_text()) if manifest.is_file() else None
    current = seed.warm.record(workspace) if kept_record is not None else {}
    kept_cost = cost(changed_paths(current, kept_record)) if kept_record is not None else None
    if kept_cost is not None:
        result.update(kept_changed=str(kept_cost[1]), kept_rebuilds_app=str(kept_cost[0]).lower())
    kept_seed = best_kept_seed(prefix, revision, current)
    best = kept_cost  # the cheapest start found so far
    local_distance = None
    if kept_seed:
        key, distance, seed_cost = kept_seed
        result.update(seed_key=key, seed_distance=str(distance), local="true")
        if kept_cost is None or seed_cost is None:
            touch_kept_seed(key)
            result.update(prefer="true", reason="kept DerivedData has no input record")
            return result
        result.update(seed_changed=str(seed_cost[1]), seed_rebuilds_app=str(seed_cost[0]).lower())
        if seed_cost < kept_cost:
            touch_kept_seed(key)
            result.update(prefer="true", reason="this Mac keeps a seed with fewer changed inputs")
            best, local_distance = seed_cost, distance
        else:
            result["reason"] = "the kept DerivedData has no more changed inputs than the seed this Mac keeps"
    if max_distance is None:
        result.setdefault("reason", "this Mac keeps no seed in this commit's history")
        return result
    exact, distance = seed.locate(prefix, revision)
    if distance is None:
        result.setdefault("reason", "no seed in this commit's history")
        return result
    downloaded = {"prefer": "true", "seed_key": exact, "seed_distance": str(distance), "local": "false"}
    if best is None:
        # A kept DerivedData without a record rebuilds the whole module, so
        # any seed up to MAX_DISTANCE beats it.
        if distance <= max_distance:
            result.update(downloaded, reason=f"seed {distance} commits behind, within {max_distance}; "
                                             "kept DerivedData has no input record")
        else:
            result.setdefault("reason", f"the nearest seed is {distance} commits behind, past {max_distance}")
        return result
    # One GitHub compare per decision: the files, and whether they recompile the app.
    asked: dict[str, object] = {}

    def compared() -> list[str] | None:
        if "files" not in asked:
            asked["files"] = bucket_compare(exact, workspace)
        return asked["files"]  # type: ignore[return-value]

    def seed_rebuilds_app() -> bool | None:
        if "app" not in asked:
            asked["app"] = (files_rebuild_app(compared(), workspace) if "files" in asked
                            else bucket_seed_rebuilds_app(exact, workspace))
        return asked["app"]  # type: ignore[return-value]

    start = "the seed this Mac keeps" if local_distance is not None else "the kept DerivedData"
    if best[0]:
        # A download (about 250 s on a mini) costs less than recompiling the
        # whole app (365 to 1,053 s on an owned mini on 2026-09-25), at any
        # distance, when GitHub's compare shows no package change.
        if seed_rebuilds_app() is False:
            result.update(downloaded, reason=f"{start} recompiles the app; the seed {distance} commits behind does not")
        else:
            result.setdefault("reason", f"{start} recompiles the app, and so may the seed {distance} commits behind")
        return result
    if best[1] <= DOWNLOAD_INPUTS:
        # A download costs about DOWNLOAD_INPUTS changed inputs of compile.
        result["reason"] = f"{start} changes {best[1]} inputs, too few to pay for a download"
        return result
    if distance > max_distance:
        result["reason"] = f"the nearest seed is {distance} commits behind, past {max_distance}"
        return result
    estimate = compare_estimate(compared(), workspace)
    if estimate is not None and seed_rebuilds_app() is False:
        # GitHub's compare says what the download would recompile, so weigh
        # it against the best start instead of trusting a commit count: main
        # moves 5 to 8 commits per seed, so a count of 2 almost never passed.
        if estimate + DOWNLOAD_INPUTS < best[1]:
            result.update(downloaded, seed_changed=str(estimate),
                          reason=f"the seed {distance} commits behind changes about {estimate} inputs, "
                                 f"{start} {best[1]}")
        else:
            result["reason"] = (f"the seed {distance} commits behind changes about {estimate} inputs, "
                                f"not enough fewer than {start}'s {best[1]} to pay for a download")
    elif estimate is None and distance <= UNKNOWN_ESTIMATE_DISTANCE and seed_rebuilds_app() is False:
        result.update(downloaded, reason=f"seed {distance} commits behind, within {UNKNOWN_ESTIMATE_DISTANCE}")
    elif seed_rebuilds_app() is not False:
        # A seed that would recompile the app never replaces a start that
        # would not; unknown counts as would.
        result["reason"] = f"the seed {distance} commits behind may recompile the app; {start} does not"
    else:
        result["reason"] = f"the seed {distance} commits behind is too far to download without GitHub's estimate"
    return result


def compare_estimate(files: list[str] | None, workspace: Path) -> int | None:
    """About how many inputs a downloaded seed recompiles: the files GitHub's
    compare lists. It overcounts docs and workflows, which only makes a
    download less likely. None when GitHub cannot say, or when the compare
    bumps a submodule: GitHub lists that as one path while the kept record
    counts every file under it, so the two counts do not compare.
    """
    if files is None:
        return None
    listed = set(files)
    if not submodules(workspace).isdisjoint(listed):
        return None
    return len(listed)


def touch_kept_seed(key: str) -> None:
    """Mark the chosen kept seed recent, so a concurrent prune spares it until adopt."""
    path = seed.cached(key)
    if path is not None:
        with contextlib.suppress(OSError):
            os.utime(path)


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
    if len(argv) in (5, 6, 7) and argv[1] == "keep":
        write_outputs(keep(Path(argv[2]), Path(argv[3]), argv[4], argv[5] if len(argv) >= 6 else "",
                           argv[6] if len(argv) == 7 else ""))
        return 0
    if len(argv) in (5, 6) and argv[1] == "warm-keys":
        # Only the document on stdout: the workflow uploads it as is.
        try:
            document = warm_keys(Path(argv[2]), argv[3], argv[4], argv[5] if len(argv) == 6 else "")
        except Exception:  # noqa: BLE001 - a key it cannot read is left out
            document = {"runner": argv[3], "pool": argv[4], "keys": []}
        print(json.dumps(document, separators=(",", ":")))
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
