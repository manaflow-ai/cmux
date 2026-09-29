#!/usr/bin/env python3
"""Keep swift-package-tests' SwiftPM build directories on an owned Mac between jobs.

    owned_spm_scratch.py link WORKSPACE [STORE]
    owned_spm_scratch.py evict [STORE]

swift-package-tests runs `swift test --package-path <package>` for the
packages a change selects. On an owned Mac (a glaeda runner) the workspace is
reused, but actions/checkout cleans it (`git clean -ffdx`), so every job
deleted each package's `.build` and built the package and its dependencies from
nothing: 206 to 594 MB per package on one mini on 2026-09-26, 1,430 runner-minutes
a day across the minis. The checkout keeps the modification times of files it
did not change, so a kept `.build` rebuilds only what the change touched.

`link` points each package's `.build` (every Package.swift under Packages/*/*)
at STORE/spm-scratch/<fingerprint>/<package path>, outside
the workspace, where the clean cannot reach. The fingerprint hashes
`xcodebuild -version`, `swift -version` and the workspace path, so another
Xcode (an upgrade, or a pull request's CMUX_CI_XCODE_APP) or another runner's
workspace never reuses modules another compiler built for another path.

A scratch directory in use is held by a shared flock on
STORE/spm-scratch/<fingerprint>.lock: `link` starts a small holder process that
keeps it until the runner ends the job (the runner kills a job's leftover
processes), or HOLD_SECONDS at most, past the job's timeout, should the runner
die mid-job and leave it. Before linking, `link` keeps the whole mini's scratch
under MAX_BYTES, dropping the least recently used directories first, whatever
runner or Xcode left them, and skipping any another job holds. `link` touches
the lock file, so its time is the directory's last use, and a directory's size
is kept in <fingerprint>.size, measured again only once the directory was used
after it and no job holds it, so a link walks only what changed since.
A directory is dropped by renaming it to .trash-* first, so a half-deleted one
is never reused; the next run sweeps what a killed removal left. `evict` drops
every directory no job holds, for disk tooling and for
owned_build_state.py's `keep` when it runs out of space. Any error leaves the
package to build as before.
"""
from __future__ import annotations

import contextlib
import fcntl
import hashlib
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys

DEFAULT_STORE = Path("/Users/Shared/cmux-build-fleet/ci")
# For the whole mini: a full package selection keeps about 8 GiB per toolchain and workspace.
MAX_BYTES = 24 * 1024**3
SCRATCH = "spm-scratch"
TRASH = ".trash-"
HELD = "held"
# swift-package-tests' timeout-minutes is 60: a holder outliving it belongs to a job the runner lost.
HOLD_SECONDS = 65 * 60


def packages(workspace: Path) -> list[Path]:
    return [path.parent for path in sorted(workspace.glob("Packages/*/*/Package.swift"))]


def toolchain_fingerprint(workspace: Path) -> str:
    """The Xcode and Swift versions (DEVELOPER_DIR's) and the workspace path, hashed."""
    parts = ["spm-scratch-v1"]
    for command in (["xcodebuild", "-version"], ["swift", "-version"]):
        result = subprocess.run(command, capture_output=True, text=True, timeout=60, check=True)
        parts.append(result.stdout + result.stderr)
    parts.append(str(workspace))
    return hashlib.sha256("\n".join(parts).encode()).hexdigest()[:24]


def tree_bytes(root: Path) -> int:
    total = 0
    for base, _, files in os.walk(root):
        for name in files:
            with contextlib.suppress(OSError):
                total += Path(base, name).lstat().st_size
    return total


def lock_path(entry: Path) -> Path:
    return entry.with_name(entry.name + ".lock")


def size_path(entry: Path) -> Path:
    return entry.with_name(entry.name + ".size")


def mtime(path: Path) -> float | None:
    try:
        return path.stat().st_mtime
    except OSError:
        return None


def tree_stats(entry: Path) -> tuple[int, float]:
    """ENTRY's bytes and its last use (its lock file's time, which `link` touches).

    The size comes from ENTRY.size unless the directory was used after it was
    written; then it is measured again, and recorded only when no job holds the
    directory (a held one may still be growing)."""
    used = mtime(lock_path(entry)) or mtime(entry) or 0.0
    recorded = size_path(entry)
    measured = mtime(recorded)
    with contextlib.suppress(OSError, ValueError):
        if measured is not None and measured > used:  # a tie re-measures: coarse clocks
            return int(recorded.read_text()), used
    size = tree_bytes(entry)
    with contextlib.suppress(OSError), open(lock_path(entry), "a") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        staged = recorded.with_name(f"{recorded.name}.{os.getpid()}")
        staged.write_text(str(size))
        staged.replace(recorded)
    return size, used


def drop(entry: Path) -> bool:
    """Remove ENTRY unless a job holds its lock: rename it to .trash-* under an exclusive lock, then delete it."""
    try:
        handle = open(lock_path(entry), "a")
    except OSError:
        return False
    with handle:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            return False  # a job uses it
        aside = entry.with_name(f"{TRASH}{entry.name}-{os.getpid()}")
        try:
            entry.rename(aside)
        except OSError:
            return False
        with contextlib.suppress(OSError):
            size_path(entry).unlink()
    shutil.rmtree(aside, ignore_errors=True)
    return True


def sweep_trash(scratch: Path) -> None:
    with contextlib.suppress(OSError):
        for path in scratch.iterdir():
            if path.name.startswith(TRASH):
                shutil.rmtree(path, ignore_errors=True)


def entries(scratch: Path) -> list[Path]:
    try:
        return [path for path in scratch.iterdir() if path.is_dir() and not path.name.startswith(TRASH)]
    except OSError:
        return []


def prune(scratch: Path, max_bytes: int = MAX_BYTES) -> list[str]:
    """Drop the least recently used directories no job holds until the mini's scratch fits MAX_BYTES."""
    sweep_trash(scratch)
    stats = {entry: tree_stats(entry) for entry in entries(scratch)}
    total = sum(size for size, _ in stats.values())
    dropped = []
    for entry in sorted(stats, key=lambda entry: stats[entry][1]):
        if total <= max_bytes:
            break
        if drop(entry):
            total -= stats[entry][0]
            dropped.append(entry.name)
    return dropped


def evict(store: Path = DEFAULT_STORE) -> list[str]:
    """Drop every scratch directory no job holds; returns their paths."""
    scratch = store / SCRATCH
    sweep_trash(scratch)
    return [str(entry) for entry in entries(scratch) if drop(entry)]


# The holders this process started (tests stop them).
HOLDERS: list[subprocess.Popen[str]] = []


def hold(lock: Path) -> subprocess.Popen[str]:
    """Start a process holding a shared lock on LOCK until it is killed (the runner's orphan cleanup at job end)."""
    holder = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "hold", str(lock)],
                              stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                              text=True, start_new_session=True)
    if holder.stdout is None or holder.stdout.readline().strip() != HELD:
        holder.kill()
        raise OSError(f"could not hold {lock}")
    holder.stdout.close()
    HOLDERS.append(holder)
    return holder


def link(workspace: Path, store: Path, runner: str, fingerprint: str | None = None) -> list[str]:
    if "-glaeda" not in runner or not store.is_dir():
        return []
    scratch = store / SCRATCH
    scratch.mkdir(parents=True, exist_ok=True)
    target_root = scratch / (fingerprint or toolchain_fingerprint(workspace))
    with open(lock_path(target_root), "a") as own:
        # Held from here, so prune skips this job's directory; the holder keeps it for the job.
        fcntl.flock(own, fcntl.LOCK_SH)
        os.utime(lock_path(target_root))  # its last use, for prune's order
        prune(scratch)
        hold(lock_path(target_root))
    linked = []
    for package in packages(workspace):
        relative = package.relative_to(workspace).as_posix()
        target = target_root / relative.replace("/", "__")
        build = package / ".build"
        try:
            target.mkdir(parents=True, exist_ok=True)
            if build.is_symlink():
                build.unlink()
            elif build.exists():
                shutil.rmtree(build)
            build.symlink_to(target, target_is_directory=True)
            linked.append(relative)
        except OSError as error:
            print(f"{relative}: not linked ({error})")
    return linked


def main(argv: list[str]) -> int:
    if len(argv) == 3 and argv[1] == "hold":
        handle = open(argv[2], "a")
        fcntl.flock(handle, fcntl.LOCK_SH)
        print(HELD, flush=True)
        # Bounded: a runner that dies mid-job never kills its leftovers, and the lock would last until reboot.
        signal.alarm(HOLD_SECONDS)
        while True:
            signal.pause()
    if len(argv) in (3, 4) and argv[1] == "link":
        store = Path(argv[3]) if len(argv) == 4 else DEFAULT_STORE
        try:
            linked = link(Path(argv[2]).resolve(), store, os.environ.get("RUNNER_NAME", ""))
        except (OSError, subprocess.SubprocessError) as error:  # a kept build is an optimization only
            print(f"owned SwiftPM scratch: skipped ({error})")
            return 0
        print(f"owned SwiftPM scratch: {len(linked)} packages keep their .build between jobs")
        return 0
    if len(argv) in (2, 3) and argv[1] == "evict":
        for path in evict(Path(argv[2]) if len(argv) == 3 else DEFAULT_STORE):
            print(path)
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
