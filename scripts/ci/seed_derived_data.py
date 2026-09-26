#!/usr/bin/env python3
"""Let pull-request compile admission build incrementally from the nightly seed.

    seed_derived_data.py record SOURCE DERIVED_DATA
    seed_derived_data.py prune DERIVED_DATA
    seed_derived_data.py start DERIVED_DATA PREFIX REVISION
    seed_derived_data.py adopt SOURCE DERIVED_DATA PREFIX REVISION
    seed_derived_data.py scope PREFIX
    seed_derived_data.py prefetch STORE REVISION
    seed_derived_data.py keep DERIVED_DATA KEY [PREFIX]

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

`start` picks that seed and begins its download in a detached process, so it
overlaps the package resolve that must finish before `adopt` can replay input
times. `adopt` with the same PREFIX and REVISION reuses the pick and waits for
the download instead of downloading again; without a matching `start` it picks
and downloads itself.

A seed also serves only the machine width it was built at. Swift Build
passes the runner's CPU count to every swift-driver invocation as -j<n>, so
a seed built on 12 vCPU reran all 94 SwiftDriver tasks and re-emitted 62
modules on a 6 vCPU admission at seed distance 0 (run 36043267820). Keys
therefore carry the width, `<PREFIX>j<n>-<revision>`: `scope` prints the
prefix a saver writes under, and `start` and `adopt` take the unscoped
PREFIX, prefer their own width, and fall back to another width's seed,
which still beats a cold build.

An owned Mac downloads a seed at about a third of Blacksmith's speed (about
190 s against 64 s on 2026-09-25). With CMUX_SEED_LOCAL_CACHE set, `adopt`
clones the seed it just restored into that directory, keeping as many as the
disk holds (prune_local), and `start` and `adopt` clone an exact key from there instead of
downloading it. A clone shares blocks on APFS, so it costs seconds.
owned_build_state.py `prefer` reads the same cache. The cache is this Mac's
own state, like its kept DerivedData: nothing in it is uploaded.

A job's own download still costs it those 190 s whenever the Mac has not seen
the seed yet, and the newest seed moves with every main push. So an idle
owned Mac fetches ahead: `prefetch` reads the seed prefix the last owned job
on that root recorded (SEED_SOURCE in STORE, written by owned_build_state.py
`check`), finds REVISION's nearest seed of this width, and downloads it into
STORE/seeds when it is not there yet. It runs outside any job, from glaeda on
the Mac, with no credentials: the bucket is publicly readable, and REVISION's
history comes from a local git directory (CMUX_SEED_GIT_DIR) instead of the
GitHub API. Nothing a job is cloning is pruned under it: `adopt` touches the
seed before cloning, and the prune spares seeds touched in the last
PRUNE_GRACE_SECONDS.

Only jobs holding the bucket credentials can write R2 objects or pointers, and
only the main-branch seeder is given them, so a pull request can read the seed
but never replace it.
"""
from __future__ import annotations

import contextlib
import json
import os
from pathlib import Path
import platform
import shutil
import signal
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
import urllib.error
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
# The widths seed-derived-data.yml seeds at: 12 on the 12 vCPU macOS 26 pool,
# 6 on the 6 vCPU macOS 26 and macOS 15 pools, 14 on the trusted owned mini
# (M4 Pro) that seeds for the owned std pool. The macOS 15 seeds carry their
# own Xcode in the key's fingerprint, so a width is shared, never a seed.
# Fallbacks go in this order after a runner's own width.
SEEDED_JOB_WIDTHS = (12, 6, 14)
USER_AGENT = "cmux-ci-seed-derived-data"
# Seeds each canonical root keeps in its CMUX_SEED_LOCAL_CACHE (roots do not
# share seeds: the keys carry the root). The disk is there to use: a kept seed
# clones in 14 to 42 s where a download takes 180 to 280 s, and main moves 5 to
# 8 commits per seed, so every seed within ANCESTOR_LIMIT commits of a job's
# base can be its cheapest start. Keep up to LOCAL_KEEP per root, and drop the
# oldest seeds on the whole Mac, whichever root holds them, while free space is
# under LOCAL_KEEP_MIN_FREE_BYTES: the admission floor (25 + 25 GiB per slot,
# 125 GiB at 4 slots) plus one cold compile (up to 36 GiB) and one seed
# download (about 8 GB). That is also above glaeda-disk's pressure trigger
# (15% of the disk, capped at 150 GiB). Each root keeps its newest
# LOCAL_KEEP_LOW_DISK whatever the disk says.
LOCAL_KEEP = 48
LOCAL_KEEP_LOW_DISK = 2
LOCAL_KEEP_MIN_FREE_BYTES = 170 * 1024**3
# Seeds are APFS clones of DerivedData that jobs also clone, so deleting one
# may free little. Under pressure, stop once a delete frees less than this.
PRUNE_MIN_FREED_BYTES = 1024**3
# A seed touched this recently may be mid-clone by a job; the prune spares it.
PRUNE_GRACE_SECONDS = 600
# owned_build_state.py `check` records here which seeds this root adopts.
SEED_SOURCE = "seed-source.json"
# Shorter than the adopt step's 8-minute timeout, so adopt stops the detached
# download itself rather than leaving it pulling a seed through the compile.
FETCH_WAIT_SECONDS = 420
DETACHED: list[subprocess.Popen] = []


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
    directories = sum(key.endswith("/") for key in recorded)
    print(f"Recorded {len(recorded) - directories} build inputs and {directories} directories under {source}")


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
    git_dir = os.environ.get("CMUX_SEED_GIT_DIR", "")
    if not repository and git_dir:
        try:
            listed = subprocess.run(
                ["git", "-C", git_dir, "rev-list", "--first-parent", f"--max-count={ANCESTOR_LIMIT}", revision],
                check=True, capture_output=True, text=True, timeout=60,
            ).stdout.split()
        except (OSError, subprocess.SubprocessError) as error:
            print(f"seed: ancestors of {revision} unknown ({type(error).__name__}); trying it alone")
            return [revision]
        return [revision] + [sha for sha in listed if sha != revision]
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
        # The CDN answers urllib's default User-Agent with 403, which would
        # read as "no seed" for every key.
        request = urllib.request.Request(
            f"{base}/{namespace}/objects/{key}.{extension}", method="HEAD", headers={"User-Agent": USER_AGENT},
        )
        try:
            with urllib.request.urlopen(request, timeout=15) as response:
                if response.status == 200:
                    return True
        except Exception:  # noqa: BLE001 - any failure is a miss for this key
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


def swift_jobs() -> int:
    """The -j Swift Build gives swift-driver here: the active CPU count."""
    override = os.environ.get("CMUX_SEED_SWIFT_JOBS")
    return int(override) if override else os.sysconf("SC_NPROCESSORS_ONLN")


def scoped(prefix: str, jobs: int | None = None) -> str:
    return f"{prefix}j{jobs or swift_jobs()}-"


def locate(prefix: str, revision: str) -> tuple[str, int | None]:
    """The exact key to restore for REVISION, and its distance if a seed has it.

    PREFIX is unscoped. The nearest seed of this width wins; failing that,
    the nearest of another width, whose extra module work is still far less
    than a cold build.
    """
    revisions = lineage(revision)
    own = swift_jobs()
    for jobs in (own, *(width for width in SEEDED_JOB_WIDTHS if width != own)):
        found = nearest(scoped(prefix, jobs), revisions)
        if found:
            return found
    return scoped(prefix, own) + revision, None


def beside(derived: Path, suffix: str) -> Path:
    return derived.with_name(derived.name + suffix)


def clear_download(derived: Path) -> None:
    shutil.rmtree(beside(derived, ".seed"), ignore_errors=True)
    for suffix in (".seed.outputs", ".seed.ticket", ".seed.result", ".seed.result.partial", ".seed.log"):
        beside(derived, suffix).unlink(missing_ok=True)


def fetch(derived: Path, exact: str, prefix: str) -> str:
    """Restore the seed into the staging directory; return the matched key, or ''."""
    staging, outputs = beside(derived, ".seed"), beside(derived, ".seed.outputs")
    shutil.rmtree(staging, ignore_errors=True)
    outputs.unlink(missing_ok=True)
    subprocess.run(
        ["bash", str(os.environ.get("CMUX_R2_CACHE_SCRIPT", R2_CACHE)), "restore", str(staging), exact, prefix],
        check=True, env={**os.environ, "GITHUB_OUTPUT": str(outputs)},
    )
    restored = dict(
        line.split("=", 1) for line in outputs.read_text().splitlines() if "=" in line
    ) if outputs.exists() else {}
    outputs.unlink(missing_ok=True)
    return restored.get("cache-matched-key", "")


def fetch_detached(derived: Path, exact: str, prefix: str) -> None:
    """The detached half of `start`: download, then record how it ended."""
    try:
        result = {"status": 0, "key": fetch(derived, exact, prefix)}
    except Exception as error:  # noqa: BLE001 - adopt turns this into a cold build
        result = {"status": 1, "error": f"{type(error).__name__}: {error}"[:200]}
    partial = beside(derived, ".seed.result.partial")
    partial.write_text(json.dumps(result))
    partial.rename(beside(derived, ".seed.result"))


def local_cache() -> Path | None:
    value = os.environ.get("CMUX_SEED_LOCAL_CACHE", "")
    return Path(value) if value else None


def cached(key: str) -> Path | None:
    """This Mac's copy of seed KEY, when it has a complete one."""
    cache = local_cache()
    if cache is None or not key or "/" in key or key.startswith("."):
        return None
    copy = cache / key
    return copy if (copy / MANIFEST).is_file() else None


def clone_tree(source: Path, destination: Path) -> None:
    """An APFS clone of a directory tree, falling back to a copy."""
    shutil.rmtree(destination, ignore_errors=True)
    destination.parent.mkdir(parents=True, exist_ok=True)
    if subprocess.run(["cp", "-cR", str(source), str(destination)], capture_output=True).returncode != 0:
        shutil.rmtree(destination, ignore_errors=True)
        shutil.copytree(source, destination, symlinks=True)


def age(path: Path) -> float:
    """Seconds since PATH was touched; 0 when another process just moved it away."""
    try:
        return time.time() - path.stat().st_mtime
    except OSError:
        return 0.0


def free_bytes(cache: Path) -> int:
    """Free space on CACHE's volume; 0 when it cannot be read, so the prune stays conservative."""
    try:
        return shutil.disk_usage(cache).free
    except OSError:
        return 0


def seed_caches(cache: Path) -> list[Path]:
    """Every root's seed cache on this Mac, CACHE first.

    Root 1 keeps STATE/seeds and root N STATE/cmux-ci-N/seeds, and they share
    one disk, so a short disk prunes the oldest seed of any root.
    """
    state = cache.parent.parent if cache.parent.name.startswith("cmux-ci-") else cache.parent
    found = [cache]
    for other in [state / "seeds", *sorted(state.glob("cmux-ci-*/seeds"))]:
        if other.is_dir() and other.resolve() != cache.resolve():
            found.append(other)
    return found


def prune_local(cache: Path, spare: Path | None = None) -> None:
    """Drop each root's seeds past LOCAL_KEEP, then the Mac's oldest while the disk is short.

    Every root keeps its newest LOCAL_KEEP_LOW_DISK. A seed touched in the last
    PRUNE_GRACE_SECONDS (a job may be cloning it) and SPARE always stay.
    """
    candidates = []
    for root in seed_caches(cache):
        try:
            entries = [entry for entry in root.iterdir() if entry.is_dir() and not entry.name.startswith(".")]
        except OSError:
            continue
        newest_first = sorted(entries, key=age)
        for index, entry in enumerate(newest_first):
            if index < LOCAL_KEEP_LOW_DISK or entry == spare or age(entry) <= PRUNE_GRACE_SECONDS:
                continue
            if index >= LOCAL_KEEP:
                shutil.rmtree(entry, ignore_errors=True)
            else:
                candidates.append(entry)
    for entry in sorted(candidates, key=age, reverse=True):  # oldest first, across roots
        before = free_bytes(cache)
        if before >= LOCAL_KEEP_MIN_FREE_BYTES:
            break
        shutil.rmtree(entry, ignore_errors=True)
        if free_bytes(cache) - before < PRUNE_MIN_FREED_BYTES:
            break


def keep_local(cache: Path, incoming: Path, key: str) -> None:
    """Rename INCOMING into the cache as KEY, then prune the oldest (prune_local).

    A complete copy of KEY that appeared meanwhile (a job stashed it during a
    prefetch) stays: a job may be cloning it, so INCOMING goes instead.
    """
    if cached(key):
        shutil.rmtree(incoming, ignore_errors=True)
        with contextlib.suppress(OSError):
            os.utime(cache / key)
    else:
        shutil.rmtree(cache / key, ignore_errors=True)
        incoming.rename(cache / key)
        os.utime(cache / key)
    for stale in cache.glob(".*.incoming-*"):
        if stale != incoming and age(stale) > PRUNE_GRACE_SECONDS:
            shutil.rmtree(stale, ignore_errors=True)
    prune_local(cache, spare=cache / key)


def stash(derived: Path, key: str) -> None:
    """Keep a copy of the seed just adopted, and prune the oldest (prune_local)."""
    cache = local_cache()
    if cache is None or not key or "/" in key or key.startswith(".") or cached(key):
        return
    incoming = cache / f".{key}.incoming-{os.getpid()}"
    clone_tree(derived, incoming)
    keep_local(cache, incoming, key)


def record_source(store: Path, prefix: str) -> None:
    """Write STORE's SEED_SOURCE for `prefetch`: the unscoped seed prefix this root adopts. Best effort."""
    if not prefix.startswith("admission-derived-data-v1-"):
        return
    source = {"prefix": prefix, "runner_os": os.environ.get("RUNNER_OS", ""),
              "runner_arch": os.environ.get("RUNNER_ARCH", ""),
              "public_url": os.environ.get("CI_CACHE_R2_PUBLIC_URL", "")}
    with contextlib.suppress(OSError):
        store.mkdir(parents=True, exist_ok=True)
        incoming = store / f".{SEED_SOURCE}.{os.getpid()}"
        incoming.write_text(json.dumps(source) + "\n")
        incoming.rename(store / SEED_SOURCE)


def prefetch(store: Path, revision: str) -> dict[str, object]:
    """Download REVISION's nearest seed of this width into STORE/seeds, unless it is there."""
    try:
        source = json.loads((store / SEED_SOURCE).read_text())
    except (OSError, ValueError):
        return {"fetched": "false", "reason": "no owned job has recorded a seed prefix here"}
    prefix = source.get("prefix", "")
    if not isinstance(prefix, str) or not prefix.startswith("admission-derived-data-v1-"):
        return {"fetched": "false", "reason": "recorded seed prefix is invalid"}
    for name, value in (("RUNNER_OS", source.get("runner_os")), ("RUNNER_ARCH", source.get("runner_arch")),
                        ("CI_CACHE_R2_PUBLIC_URL", source.get("public_url"))):
        if isinstance(value, str) and value:
            os.environ.setdefault(name, value)
    cache = store / "seeds"
    os.environ["CMUX_SEED_LOCAL_CACHE"] = str(cache)
    found = nearest(scoped(prefix), lineage(revision))
    if found is None:
        return {"fetched": "false", "reason": "no seed of this width in REVISION's history"}
    key, distance = found
    if cached(key):
        # Nothing new lands, but a job may have filled the disk since: prune.
        prune_local(cache, spare=cache / key)
        return {"fetched": "false", "reason": "already kept", "key": key, "distance": distance}
    cache.mkdir(parents=True, exist_ok=True)
    incoming = cache / f".{key}.incoming-{os.getpid()}"
    started = time.monotonic()
    try:
        matched = fetch(incoming, key, key)
        if matched != key or not (beside(incoming, ".seed") / MANIFEST).is_file():
            return {"fetched": "false", "reason": "download did not complete", "key": key}
        beside(incoming, ".seed").rename(incoming)
        keep_local(cache, incoming, key)
    finally:
        shutil.rmtree(incoming, ignore_errors=True)
        clear_download(incoming)
    return {"fetched": "true", "key": key, "distance": distance, "seconds": f"{time.monotonic() - started:.1f}"}


def start(derived: Path, exact: str, prefix: str, revision: str = "", distance: int | None = None) -> None:
    """Download the seed in a process that outlives the calling step.

    Its output goes to a file, not the step's pipes, so the runner does not
    wait for it at the end of the step. `adopt` prints that file. A seed this
    Mac keeps (CMUX_SEED_LOCAL_CACHE) needs no download: `adopt` clones it.
    """
    clear_download(derived)
    if cached(exact):
        print(f"This Mac keeps {exact}; adopt clones it instead of downloading")
        return
    derived.parent.mkdir(parents=True, exist_ok=True)
    with beside(derived, ".seed.log").open("w") as log:
        process = subprocess.Popen(
            [sys.executable, str(Path(__file__).resolve()), "fetch", str(derived), exact, prefix],
            stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
            start_new_session=True,
        )
    DETACHED.append(process)  # never waited on; kept so it is not reported as leaked
    beside(derived, ".seed.ticket").write_text(
        json.dumps({
            "exact": exact, "prefix": prefix, "revision": revision, "distance": distance,
            "pid": process.pid, "job": job_identity(),
        })
    )
    print(f"Downloading the DerivedData seed in the background (pid {process.pid})")


def running(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    # When the caller spawned it (tests), an exited download stays a zombie
    # that os.kill still reaches until it is reaped.
    try:
        reaped, _ = os.waitpid(pid, os.WNOHANG)
    except ChildProcessError:
        return True
    return reaped == 0


def job_identity() -> str:
    """Self-hosted runners reuse disks, so a ticket may outlive its job."""
    return "/".join(os.environ.get(name, "") for name in ("GITHUB_RUN_ID", "GITHUB_RUN_ATTEMPT", "GITHUB_JOB"))


def stop(pid: int) -> None:
    try:
        os.killpg(pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        return
    deadline = time.monotonic() + 10
    while running(pid) and time.monotonic() < deadline:
        time.sleep(0.1)


def picked(derived: Path, prefix: str, revision: str) -> tuple[str, int | None] | None:
    """The seed a `start` in this job picked for PREFIX and REVISION, if any."""
    try:
        ticket = json.loads(beside(derived, ".seed.ticket").read_text())
    except (OSError, ValueError):
        return None
    if ticket.get("job") != job_identity() or (ticket.get("prefix"), ticket.get("revision")) != (prefix, revision):
        return None
    return str(ticket["exact"]), ticket.get("distance")


def await_download(derived: Path, exact: str, prefix: str) -> str | None:
    """The key a `start` for these keys restored, or None when none was started."""
    ticket_path, result_path = beside(derived, ".seed.ticket"), beside(derived, ".seed.result")
    try:
        ticket = json.loads(ticket_path.read_text())
    except (OSError, ValueError):
        return None
    if ticket.get("job") != job_identity():
        # Left by an earlier job; its pid may name something else by now.
        clear_download(derived)
        return None
    if (ticket.get("exact"), ticket.get("prefix")) != (exact, prefix):
        # Stop it before downloading these keys into the same staging path.
        stop(int(ticket["pid"]))
        clear_download(derived)
        return None
    deadline = time.monotonic() + FETCH_WAIT_SECONDS
    while not result_path.exists():
        if not running(int(ticket["pid"])) and not result_path.exists():
            # Killed, say by a runner that reaps a step's processes when the
            # step ends. That says nothing about the seed; download it here.
            print("The background seed download exited without a result; downloading it now")
            clear_download(derived)
            return None
        if time.monotonic() > deadline:
            stop(int(ticket["pid"]))
            raise TimeoutError("the background seed download did not finish")
        time.sleep(0.2)
    log = beside(derived, ".seed.log")
    if log.exists():
        print(log.read_text(), end="")
    result = json.loads(result_path.read_text())
    if result.get("status") != 0:
        raise RuntimeError(result.get("error") or "the background seed download failed")
    return str(result.get("key", ""))


def adopt(source: Path, derived: Path, exact: str, prefix: str) -> dict[str, object]:
    staging = beside(derived, ".seed")
    started = time.monotonic()
    try:
        local = cached(exact)
        if local:
            # Nothing was started for it; a leftover ticket is another job's.
            clear_download(derived)
            os.utime(local)  # before the clone: the prune spares seeds touched just now
            clone_tree(local, staging)
            key = exact
        else:
            key = await_download(derived, exact, prefix)
            if key is None:
                key = fetch(derived, exact, prefix)
        if not key:
            return {"hit": "false", "reason": "no-seed"}
        manifest = staging / MANIFEST
        if not manifest.is_file():
            return {"hit": "false", "reason": "seed-without-input-manifest", "key": key}
        recorded = json.loads(manifest.read_text())
        shutil.rmtree(derived, ignore_errors=True)
        staging.rename(derived)
        stashed = "local" if local else "false"
        if not local and local_cache() is not None:
            try:
                stash(derived, key)
                stashed = "true"
            except (OSError, shutil.Error) as error:
                # The next job downloads it again; this one is unaffected.
                print(f"Could not keep the seed on this Mac: {error}")
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
            "local": stashed,
        }
    finally:
        clear_download(derived)


def chosen() -> tuple[str, int | None] | None:
    """The kept seed owned_build_state.py `prefer` compared (CMUX_SEED_EXACT), if this Mac still has it."""
    exact = os.environ.get("CMUX_SEED_EXACT", "")
    if not cached(exact):
        return None
    distance = os.environ.get("CMUX_SEED_DISTANCE", "")
    return exact, int(distance) if distance.isdigit() else None


def main(argv: list[str]) -> int:
    if len(argv) == 4 and argv[1] == "record":
        record(Path(argv[2]).resolve(), Path(argv[3]))
        return 0
    if len(argv) == 3 and argv[1] == "prune":
        write_outputs(prune(Path(argv[2])))
        return 0
    if len(argv) == 3 and argv[1] == "scope":
        print(scoped(argv[2]))
        return 0
    if len(argv) == 5 and argv[1] == "start":
        prefix, revision = argv[3], argv[4]
        exact, distance = chosen() or locate(prefix, revision)
        # The newest-pointer fallback stays within this width.
        start(Path(argv[2]), exact, scoped(prefix), revision, distance)
        return 0
    if len(argv) in (4, 5) and argv[1] == "keep":
        # The seed this job just built and saved: the next seed job on this Mac clones it instead of
        # downloading it back (seed-derived-data.yml on the trusted pool). A no-op without a local cache.
        try:
            stash(Path(argv[2]), argv[3])
        except (OSError, shutil.Error) as error:
            print(f"Could not keep the seed on this Mac: {error}")
        cache = local_cache()
        if len(argv) == 5 and cache is not None:
            # A seed the other trusted Mac builds in between is not kept here, and the next seed job
            # downloaded it (73 to 102 s against 16 to 20 s for a kept one, 2026-09-25). With the prefix
            # recorded, glaeda-seed-prefetch fetches main's newest seed into this cache between jobs,
            # as it does for compile admission's roots.
            record_source(cache.parent, argv[4])
        return 0
    if len(argv) == 4 and argv[1] == "prefetch":
        print(json.dumps(prefetch(Path(argv[2]), argv[3])))
        return 0
    if len(argv) == 5 and argv[1] == "fetch":
        fetch_detached(Path(argv[2]), argv[3], argv[4])
        return 0
    if len(argv) == 6 and argv[1] == "adopt":
        source, derived = Path(argv[2]).resolve(), Path(argv[3])
        prefix, revision = argv[4], argv[5]
        try:
            exact, distance = chosen() or picked(derived, scoped(prefix), revision) or locate(prefix, revision)
            result = adopt(source, derived, exact, scoped(prefix))
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
