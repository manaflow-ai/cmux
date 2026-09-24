#!/usr/bin/env python3
"""Let pull-request compile admission build incrementally from the nightly seed.

    seed_derived_data.py record SOURCE DERIVED_DATA
    seed_derived_data.py prune DERIVED_DATA
    seed_derived_data.py start DERIVED_DATA PREFIX REVISION
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

`start` picks that seed and begins its download in a detached process, so it
overlaps the package resolve that must finish before `adopt` can replay input
times. `adopt` with the same PREFIX and REVISION reuses the pick and waits for
the download instead of downloading again; without a matching `start` it picks
and downloads itself.

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
USER_AGENT = "cmux-ci-seed-derived-data"
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


def locate(prefix: str, revision: str) -> tuple[str, int | None]:
    """The exact key to restore for REVISION, and its distance if a seed has it."""
    found = nearest(prefix, lineage(revision))
    return found if found else (prefix + revision, None)


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


def start(derived: Path, exact: str, prefix: str, revision: str = "", distance: int | None = None) -> None:
    """Download the seed in a process that outlives the calling step.

    Its output goes to a file, not the step's pipes, so the runner does not
    wait for it at the end of the step. `adopt` prints that file.
    """
    clear_download(derived)
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
        clear_download(derived)


def main(argv: list[str]) -> int:
    if len(argv) == 4 and argv[1] == "record":
        record(Path(argv[2]).resolve(), Path(argv[3]))
        return 0
    if len(argv) == 3 and argv[1] == "prune":
        write_outputs(prune(Path(argv[2])))
        return 0
    if len(argv) == 5 and argv[1] == "start":
        prefix, revision = argv[3], argv[4]
        exact, distance = locate(prefix, revision)
        start(Path(argv[2]), exact, prefix, revision, distance)
        return 0
    if len(argv) == 5 and argv[1] == "fetch":
        fetch_detached(Path(argv[2]), argv[3], argv[4])
        return 0
    if len(argv) == 6 and argv[1] == "adopt":
        source, derived = Path(argv[2]).resolve(), Path(argv[3])
        prefix, revision = argv[4], argv[5]
        try:
            exact, distance = picked(derived, prefix, revision) or locate(prefix, revision)
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
