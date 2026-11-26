#!/usr/bin/env python3
"""Keep the SwiftPM build directories of CI's Swift jobs on an owned Mac between jobs.

    owned_spm_scratch.py link WORKSPACE [STORE]
    owned_spm_scratch.py lease WORKSPACE [STORE]
    owned_spm_scratch.py evict [STORE]
    owned_spm_scratch.py drop-bundles BUILD
    owned_spm_scratch.py seeded

With CMUX_FAST_TIER_OWNED_SEED=1 (cmux-next.yml's fast tier, unless vars.CI_FAST_TIER_OWNED_SEED is "0"),
`lease` first holds the mini's seed root (seed_lease): the workspace path the R2 base seed is built at,
/Users/runner/_work/cmux/cmux, so the fast tier restores the seed there as Blacksmith does and builds only
what differs from the base. It prints `root=` and `seed=1`; `seeded` then records the warm start.
While another job holds that root it tries the second one, /Users/runner/_work/cmux-2/cmux, seeded at that path
too, on a mini with the disk to keep both (second_seed_fits; vars.CI_FAST_TIER_SECOND_SEED_ROOT "0" turns it off).

swift-package-tests, swift-test and fast-tier run `swift build` for the packages
a change selects. On an owned Mac (a glaeda runner) the workspace is reused, but
actions/checkout cleans it (`git clean -ffdx`), so every job deleted each
package's `.build` and built the package and its dependencies from nothing: 206
to 594 MB per package on one mini on 2026-09-26, 1,430 runner-minutes a day
across the minis. The checkout keeps the modification times of files it did not
change, so a kept `.build` rebuilds only what the change touched.

`link` points each package's `.build` (every Package.swift under Packages/*/*)
at STORE/spm-scratch/<fingerprint>/<package path>, outside
the workspace, where the clean cannot reach. The fingerprint hashes
`xcodebuild -version`, `swift -version`, the workspace path and the vendored
bonsplit commit, so a build against another bonsplit is never reused, and another
Xcode (an upgrade, or a pull request's CMUX_CI_XCODE_APP) or another runner's
workspace never reuses modules another compiler built for another path.

`lease` (fast-tier) shares one build between the mini's runner slots instead.
SwiftPM's build records absolute source paths, so a `.build` built in one
slot's workspace is no warmer than nothing in another's, and with 10 to 13
slots a mini kept one or two of them: about half of fast-tier's jobs started
cold (an LRU replay of the job logs, 2026-10-30). A shared root is a directory
STORE/spm-scratch/<fingerprint of root k> whose `src` is a mirror of the job's
checkout at a path every slot shares. `lease` holds the lowest-numbered root no
other job holds, exclusively, for the job; mirrors the checkout into it, keeping
the time of every file whose content the root already has, so SwiftPM rebuilds
only what differs from the last build there, on any slot; links the root's
packages as `link` does; and prints `root=<src>` to $GITHUB_OUTPUT, where the job
then builds and tests. A new root is made only when every root is busy and the
disk has room for one above the reserve; otherwise the job links its own
workspace as before. A root's sources and builds are one directory, so prune,
`evict` and glaeda-disk's SwiftPM family treat it like any other.

Who writes a kept build: the minis run only this repository's pull requests and
pushes (never a fork's), and a slot's own build was already reused by the next
pull request on that slot, so a root shared by the slots trusts the same
writers. The mirror makes the sources the job's own; what it reuses is objects
SwiftPM judges up to date, as on one slot.

A scratch directory in use is held by a flock on STORE/spm-scratch/<fingerprint>.lock
(shared for `link`, exclusive for a leased root): a small holder process keeps it
until the runner ends the job (the runner kills a job's leftover processes), or
HOLD_SECONDS at most, past the job's timeout, should the runner die mid-job and
leave it. Before linking, both keep the whole mini's scratch within the free
space above glaeda's reserve (scratch_cap: the manifest's disk.min_free_gib plus
disk.job_growth_gib), dropping the least recently used directories first,
whatever runner or Xcode left them, and skipping any another job holds; a mini
with more free disk keeps more, and glaeda-disk's pressure pass evicts it like
any cache before then. The lock file's time is the directory's last use, and a
directory's size is kept in <fingerprint>.size, measured again only once the
directory was used after it and no job holds it, so a link walks only what changed since.
A directory is dropped by renaming it to .trash-* first, so a half-deleted one
is never reused; the next run sweeps what a killed removal left. `evict` drops
every directory no job holds, for disk tooling and for
owned_build_state.py's `keep` when it runs out of space. Any error leaves the
package to build as before.

`link` also removes the kept resource bundles (<triple>/<config>/*.bundle).
SwiftPM copies a target's resources into its bundle but never deletes one the
current tree no longer has, so a kept bundle carried a String Catalog from
another branch's job into the next job on the same runner, and
compile-string-catalogs.sh then compiled a file that is not in the checkout
(cmux#26961, 2026-10-29: "MiscHandlers.xcstrings: error: Missing required key
'version'" from a branch that moved the catalog). The bundles are copies of
the sources, so SwiftPM copies them again in seconds; compiled modules stay.
`drop-bundles` does the same for a build restored from elsewhere: the GUI jobs on
Blacksmith (cmux-next.yml swift-test, daemon-test, generated-files) restore the base's
fast-tier seed, which can hold a catalog this checkout removed.

`link` and `lease` also say whether the job starts warm: one line in the log and, in
$RUNNER_TEMP/glaeda-warm-start.json (cmux-warm-start/v1), the state ("warm": a
kept build at the path the job builds at; "cold": nothing kept), the kept bytes and why a cold
start was cold ("evicted": this fingerprint's directory was pruned; "never
built": an earlier job linked it but built nothing; "new fingerprint": none was
ever kept on this mini for this toolchain, bonsplit and workspace; "first on
host": the mini keeps no scratch yet; "roots busy": every shared root was in
use and the job's own workspace had nothing kept; "link failed: ..."). glaeda's runner hook
copies the file into the job's record in glaeda-cmux-jobs.jsonl as
"warm_start", which the fleet dashboard counts per job class.
"""
from __future__ import annotations

import contextlib
import fcntl
import hashlib
import itertools
import json
import os
from pathlib import Path
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import unicodedata
from typing import Mapping

DEFAULT_STORE = Path("/Users/Shared/cmux-build-fleet/ci")
# glaeda's mini-fleet manifest on the mini (glaeda-cmux-runner installs it) and the keys of its disk
# section the reserve adds, with glaeda's defaults for a host without one.
FLEET_MANIFESTS = (Path.home() / "glaeda-runner/mini-fleet.json", Path.home() / ".config/glaeda/mini-fleet.json")
GLAEDA_DISK_DEFAULTS = {"min_free_gib": 30, "job_growth_gib": 20}
SHARED_SOURCE = "src"
SCRATCH = "spm-scratch"
TRASH = ".trash-"
# The lock new shared roots are admitted under (not a root's lock: no .lock suffix).
ADMISSION = ".admission"
# What a new shared root is admitted for before any root on the mini is measured: one fast-tier build plus
# its mirrored source (11.6 GiB + 1.8 GiB per root, `du` of spm-scratch on a mini, 2026-10-30), rounded up.
# A measured root larger than this is used instead.
ROOT_BYTES_UNMEASURED = 14 * 1024**3
HELD = "held"
# swift-package-tests' timeout-minutes is 60: a holder outliving it belongs to a job the runner lost.
HOLD_SECONDS = 65 * 60
WARM_START_FILE = "glaeda-warm-start.json"
WARM_START_SCHEMA = "cmux-warm-start/v1"


def packages(workspace: Path) -> list[Path]:
    """Every Packages/*/*/Package.swift's directory, except one reached through a link: a tracked link
    (Packages/macOS -> elsewhere) must not have its target's .build replaced."""
    found = []
    for manifest in sorted(workspace.glob("Packages/*/*/Package.swift")):
        package = manifest.parent
        parts = package.relative_to(workspace).parts
        if not any((workspace.joinpath(*parts[:depth])).is_symlink() for depth in range(1, len(parts) + 1)):
            found.append(package)
    return found


def bonsplit_commit(workspace: Path) -> str:
    """The vendored bonsplit commit the checkout records, or "" when it has none.

    Many packages compile against bonsplit, and SwiftPM's modification-time
    check does not notice a submodule that moved to other sources whose files
    are older than the kept build, so a scratch directory is per bonsplit
    commit: an object built against one bonsplit never links against another.
    """
    try:
        result = subprocess.run(
            ["git", "-C", str(workspace), "rev-parse", "HEAD:vendor/bonsplit"],
            capture_output=True, text=True, timeout=60, check=True,
        )
    except (OSError, subprocess.SubprocessError):
        return ""
    return result.stdout.strip()


def toolchain_parts(workspace: Path) -> tuple[str, str, str]:
    """The Xcode and Swift versions (DEVELOPER_DIR's) and the vendored bonsplit commit."""
    versions = []
    for command in (["xcodebuild", "-version"], ["swift", "-version"]):
        result = subprocess.run(command, capture_output=True, text=True, timeout=60, check=True)
        versions.append(result.stdout + result.stderr)
    return versions[0], versions[1], bonsplit_commit(workspace)


def fingerprint(parts: tuple[str, str, str], place: str) -> str:
    xcode, swift, bonsplit = parts
    return hashlib.sha256("\n".join(["spm-scratch-v1", xcode, swift, place, bonsplit]).encode()).hexdigest()[:24]


def toolchain_fingerprint(workspace: Path) -> str:
    """The Xcode and Swift versions, the workspace path and the vendored bonsplit commit, hashed."""
    return fingerprint(toolchain_parts(workspace), str(workspace))


def shared_fingerprint(parts: tuple[str, str, str], k: int) -> str:
    """Shared root K's directory: as toolchain_fingerprint, with the root's number in place of the
    workspace path (the root builds from its own source, inside the directory)."""
    return fingerprint(parts, f"shared-root-{k}")


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
        return [path for path in scratch.iterdir()
                if path.is_dir() and not path.is_symlink() and not path.name.startswith(TRASH)]
    except OSError:
        return []


def disk_reserve_bytes(manifests: tuple[Path, ...] = FLEET_MANIFESTS) -> int:
    """The free space the scratch leaves the mini: glaeda's runner floor (disk.min_free_gib, under which
    every job is refused) plus what one admitted job may still write (disk.job_growth_gib), from the
    glaeda mini-fleet manifest on the host (defaults.disk, then the host's overrides.disk)."""
    floor, growth = disk_limits_gib(manifests)
    return int((floor + growth) * 1024**3)


def disk_limits_gib(manifests: tuple[Path, ...] = FLEET_MANIFESTS) -> tuple[float, float]:
    """(disk.min_free_gib, disk.job_growth_gib) of the host's glaeda manifest, glaeda's defaults when unread."""
    disk: dict[str, object] = dict(GLAEDA_DISK_DEFAULTS)
    for manifest in manifests:
        try:
            data = json.loads(manifest.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        layers = [data.get("defaults", {}).get("disk", {})]
        hosts = data.get("hosts")
        if isinstance(hosts, dict) and len(hosts) == 1:  # a mini's copy names only itself
            layers.append(next(iter(hosts.values())).get("overrides", {}).get("disk", {}))
        for layer in layers:
            if isinstance(layer, dict):
                disk.update({key: value for key, value in layer.items() if key in GLAEDA_DISK_DEFAULTS})
        break
    limits = []
    for key in GLAEDA_DISK_DEFAULTS:
        value = disk[key]
        limits.append(float(value) if isinstance(value, (int, float)) and not isinstance(value, bool) and value >= 0
                      else float(GLAEDA_DISK_DEFAULTS[key]))
    return limits[0], limits[1]


def free_bytes(path: Path) -> int:
    return shutil.disk_usage(path).free


def scratch_cap(scratch: Path, total: int, room: int = 0) -> int:
    """The bytes the mini's scratch may keep: what it holds plus the free space above the reserve,
    less ROOM to make for a new directory. Never a fixed size: a mini with free disk keeps more."""
    return max(0, total + free_bytes(scratch) - disk_reserve_bytes() - room)


def prune(scratch: Path, max_bytes: int | None = None, sizes: dict[str, int] | None = None,
          room: int = 0) -> list[str]:
    """Drop the least recently used directories no job holds until the mini's scratch fits MAX_BYTES
    (default scratch_cap: the free space above glaeda's floor, less ROOM). SIZES, when given, gets every
    directory's bytes by name (before any drop)."""
    sweep_trash(scratch)
    stats = {entry: tree_stats(entry) for entry in entries(scratch)}
    if sizes is not None:
        sizes.update({entry.name: size for entry, (size, _) in stats.items()})
    total = sum(size for size, _ in stats.values())
    if max_bytes is None:
        max_bytes = scratch_cap(scratch, total, room)
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


def hold(lock: Path, fd: int | None = None) -> subprocess.Popen[str]:
    """Start a process holding a shared lock on LOCK until it is killed (the runner's orphan cleanup at job end).
    With FD, an open descriptor of LOCK that already holds it (exclusively, for a shared root), the process
    keeps that descriptor's lock instead: flock belongs to the open file, which the holder inherits."""
    argv = [sys.executable, str(Path(__file__).resolve()), "hold", str(lock)]
    if fd is not None:
        argv = [*argv[:2], "keep", str(fd)]
    holder = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                              text=True, start_new_session=True, pass_fds=() if fd is None else (fd,))
    if holder.stdout is None or holder.stdout.readline().strip() != HELD:
        try:
            os.killpg(holder.pid, signal.SIGKILL)  # its whole group: it leads one (start_new_session)
        except (ProcessLookupError, PermissionError):
            pass
        raise OSError(f"could not hold {lock}")
    holder.stdout.close()
    HOLDERS.append(holder)
    return holder


def drop_resource_bundles(build: Path) -> list[Path]:
    """Remove the resource bundles in a kept BUILD's products folders (<triple>/<config>/*.bundle,
    beside the description.json SwiftPM writes there), so the next build copies only the resources
    the checkout has."""
    dropped = []

    def real_dirs(path: Path) -> list[Path]:
        # Never through a link: a kept build's <triple> or <config> that links elsewhere holds no bundle of ours.
        try:
            with os.scandir(path) as listed:
                return sorted(Path(entry.path) for entry in listed if entry.is_dir(follow_symlinks=False))
        except OSError:
            return []
    if build.is_symlink():
        return dropped
    for triple in real_dirs(build):
        for config in real_dirs(triple):
            description = config / "description.json"
            if not (description.is_file() and not description.is_symlink()):
                continue
            for bundle in real_dirs(config):
                if bundle.suffix == ".bundle":
                    shutil.rmtree(bundle, ignore_errors=True)
                    dropped.append(bundle)
    return dropped


def write_warm_start(state: str, kept_bytes: int, reason: str, environ: Mapping[str, str] = os.environ) -> Path | None:
    """Leave this job's warm-start verdict in $RUNNER_TEMP for glaeda's runner hook (observation only)."""
    temp = environ.get("RUNNER_TEMP", "")
    if not temp:
        return None
    payload = {"schema": WARM_START_SCHEMA, "run_id": environ.get("GITHUB_RUN_ID", ""),
               "run_attempt": environ.get("GITHUB_RUN_ATTEMPT", ""), "source": "spm_scratch",
               "state": state, "bytes": max(0, int(kept_bytes)), "reason": reason[:200]}
    path = Path(temp) / WARM_START_FILE
    with contextlib.suppress(OSError):
        staged = path.with_name(f"{path.name}.{os.getpid()}")
        staged.write_text(json.dumps(payload, sort_keys=True) + "\n", encoding="utf-8")
        staged.replace(path)
        return path
    return None


def kept_build(target_root: Path) -> bool:
    """Whether a package directory holds a build SwiftPM planned (<package>/<triple>/<config>/description.json),
    not just the empty folders an earlier link made."""
    return any(target_root.glob("*/*/*/description.json"))


def warm_start(scratch_existed: bool, lock_existed: bool, kept: bool, existed: bool = False) -> tuple[str, str]:
    """(state, reason) for a job whose directory was KEPT (or only EXISTED, unbuilt) or not, read before `link`
    creates anything."""
    if kept:
        return "warm", "kept"
    if existed:
        return "cold", "never built"  # an earlier job linked it and built nothing (it failed or was cancelled first)
    if lock_existed:
        return "cold", "evicted"  # drop() removes the directory and its .size, never its lock
    return "cold", "new fingerprint" if scratch_existed else "first on host"


def no_link_at(entry: Path) -> None:
    """Only this script makes scratch directories: a link or a file at ENTRY's path is removed, never followed."""
    if entry.is_symlink() or (entry.exists() and not entry.is_dir()):
        entry.unlink()


def link(workspace: Path, store: Path, runner: str, fingerprint: str | None = None,
         verdict: dict[str, object] | None = None) -> list[str]:
    """VERDICT, when given, gets the warm-start state, reason and kept bytes."""
    if "-glaeda" not in runner or not store.is_dir():
        return []
    scratch = store / SCRATCH
    scratch_existed = scratch.is_dir() and any(scratch.iterdir())
    scratch.mkdir(parents=True, exist_ok=True)
    target_root = scratch / (fingerprint or toolchain_fingerprint(workspace))
    lock_existed = lock_path(target_root).exists()
    sizes: dict[str, int] = {}
    with open(lock_path(target_root), "a") as own:
        # Held from here, so prune skips this job's directory; the holder keeps it for the job.
        fcntl.flock(own, fcntl.LOCK_SH)
        no_link_at(target_root)
        existed, kept = target_root.is_dir(), kept_build(target_root)
        os.utime(lock_path(target_root))  # its last use, for prune's order
        prune(scratch, sizes=sizes)
        hold(lock_path(target_root))
    if verdict is not None:
        state, reason = warm_start(scratch_existed, lock_existed, kept, existed)
        verdict.update(state=state, reason=reason, bytes=sizes.get(target_root.name, 0) if kept else 0)
    return link_packages(workspace, target_root)


def link_packages(workspace: Path, target_root: Path, strict: bool = False) -> list[str]:
    """Point each package's .build in WORKSPACE at its directory in TARGET_ROOT, dropping kept resource bundles.
    STRICT (a shared root) raises on a package it cannot link, so the job falls back to its own workspace."""
    linked = []
    for package in packages(workspace):
        relative = package.relative_to(workspace).as_posix()
        target = target_root / relative.replace("/", "__")
        build = package / ".build"
        try:
            no_link_at(target)
            target.mkdir(parents=True, exist_ok=True)
            drop_resource_bundles(target)
            if build.is_symlink():
                build.unlink()
            elif build.exists():
                shutil.rmtree(build)
            build.symlink_to(target, target_is_directory=True)
            linked.append(relative)
        except OSError as error:
            if strict:
                raise
            print(f"{relative}: not linked ({error})")
    return linked


def same_file(source: Path, target: Path, size: int) -> bool:
    try:
        if target.lstat().st_size != size or target.is_symlink():
            return False
        with open(source, "rb") as left, open(target, "rb") as right:
            while True:
                block = left.read(1 << 20)
                if block != right.read(1 << 20):
                    return False
                if not block:
                    return True
    except OSError:
        return False


def source_files(workspace: Path) -> list[str]:
    """What a shared root mirrors: the checkout's tracked and untracked (not ignored) files, and .git."""
    listed = subprocess.run(["git", "-C", str(workspace), "ls-files", "-z", "--cached", "--others",
                             "--exclude-standard"], capture_output=True, timeout=120, check=True).stdout
    names = dict.fromkeys(os.fsdecode(name) for name in listed.split(b"\0") if name)
    git = workspace / ".git"
    for base, dirs, files in os.walk(git):
        for name in files:
            names[os.path.relpath(os.path.join(base, name), workspace)] = None
    return list(names)


def fold(name: str) -> str:
    return unicodedata.normalize("NFC", name).casefold()


def respell(path: Path, listings: dict[str, set[str]]) -> None:
    """Give PATH's entry the spelling PATH asks for. On a case-insensitive disk (APFS on the minis) a
    checkout that renamed Foo.swift to foo.swift finds the root's old entry under the new name, and the
    cleanup walk, which lists the entry's real spelling, would then delete it. An entry whose name differs
    only in case (or Unicode normalization) and that is the same file as PATH is renamed to PATH's
    spelling; on a case-sensitive disk the two names are two files and nothing is renamed. LISTINGS caches
    each directory's names for this mirror."""
    parent, name = str(path.parent), path.name
    names = listings.get(parent)
    if names is None:
        try:
            names = set(os.listdir(parent))
        except FileNotFoundError:
            return
        listings[parent] = names
    if name in names:
        return
    try:
        wanted = os.lstat(path)
    except FileNotFoundError:
        names.add(name)  # made from here on with this spelling
        return
    for other in sorted(names):
        if other == name or fold(other) != fold(name):
            continue
        with contextlib.suppress(FileNotFoundError):
            info = os.lstat(os.path.join(parent, other))
            if (info.st_dev, info.st_ino) == (wanted.st_dev, wanted.st_ino):
                os.rename(os.path.join(parent, other), path)
                names.discard(other)
                break
    names.add(name)


def real_directory(source: Path, relative: str, made: set[str], listings: dict[str, set[str]] | None = None) -> None:
    """Make SOURCE/RELATIVE and every directory between it and SOURCE a real directory. A link (to a directory
    or anywhere else, inside the root or outside it) or a file in the way is removed and replaced, never
    followed: the last checkout's link at a path that is now a directory must not take this checkout's
    writes. MADE remembers the directories already checked in this mirror."""
    path, walked = source, ""
    for part in Path(relative).parts:
        walked = f"{walked}/{part}" if walked else part
        path = path / part
        if walked in made:
            continue
        if listings is not None:
            respell(path, listings)
        try:
            info = path.lstat()
        except FileNotFoundError:
            path.mkdir()
        else:
            if not stat.S_ISDIR(info.st_mode):  # lstat: a link to a directory is a link here
                path.unlink()
                path.mkdir()
        made.add(walked)


def copy_into(origin: Path, target: Path, mode: int) -> None:
    """Replace TARGET with a copy of ORIGIN (mode MODE). The copy is staged in a file this call creates
    exclusively (O_EXCL never opens an existing path, a link included) and written and chmodded through
    its descriptor, so no path the checkout may name takes the write; a failed copy leaves no staged file."""
    fd, staged = tempfile.mkstemp(prefix=f".{target.name}.", suffix=".mirror", dir=target.parent)
    try:
        with os.fdopen(fd, "wb") as out, open(origin, "rb") as source:
            shutil.copyfileobj(source, out, 1 << 20)
            os.fchmod(out.fileno(), mode)
        os.replace(staged, target)
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(staged)
        raise


def raise_error(error: OSError) -> None:
    raise error


def mirror(workspace: Path, source: Path) -> dict[str, int]:
    """Make SOURCE hold exactly WORKSPACE's files (source_files). A file whose content SOURCE already has
    keeps its time there, so SwiftPM rebuilds only what changed; every other file is written now, so it
    is newer than any build. Package .build links are left alone. Raises on any error: a half mirror
    is never built (the next lease mirrors again)."""
    copied = removed = kept = 0
    wanted: set[str] = set()
    with contextlib.suppress(FileNotFoundError):
        if not stat.S_ISDIR(source.lstat().st_mode):
            source.unlink()  # a link or a file where the root's source belongs is never followed
    source.mkdir(exist_ok=True)
    made: set[str] = set()
    listings: dict[str, set[str]] = {}
    for name in source_files(workspace):
        origin, target = workspace / name, source / name
        try:
            info = origin.lstat()
        except FileNotFoundError:
            continue  # listed but deleted (a .git file that moved under the walk, a removed tracked file)
        if not (stat.S_ISREG(info.st_mode) or stat.S_ISLNK(info.st_mode)):
            continue  # a submodule gitlink: the job checks out no submodule
        wanted.add(name)
        # Before reading or writing TARGET: every directory above it in SOURCE is a real one.
        real_directory(source, os.path.dirname(name), made, listings)
        respell(target, listings)
        if stat.S_ISLNK(info.st_mode):
            link_to = os.readlink(origin)
            if target.is_symlink() and os.readlink(target) == link_to:
                kept += 1
                continue
            if target.is_dir() and not target.is_symlink():
                shutil.rmtree(target)
            target.unlink(missing_ok=True)
            target.symlink_to(link_to)
            copied += 1
            continue
        if same_file(origin, target, info.st_size):
            if stat.S_IMODE(target.lstat().st_mode) != stat.S_IMODE(info.st_mode):
                os.chmod(target, stat.S_IMODE(info.st_mode))
            kept += 1
            continue
        if target.is_dir() and not target.is_symlink():
            shutil.rmtree(target)
        copy_into(origin, target, stat.S_IMODE(info.st_mode))
        copied += 1
    parents = {str(Path(name).parent) for name in wanted}
    parents |= {str(parent) for name in parents for parent in Path(name).parents}
    # A directory the walk cannot read would keep its stale files: raise, and the job falls back.
    for base, dirs, files in os.walk(source, topdown=True, onerror=raise_error):
        relative = os.path.relpath(base, source)
        relative = "" if relative == "." else relative
        for name in list(dirs):
            path = os.path.join(relative, name) if relative else name
            if name == ".build" and os.path.exists(os.path.join(base, "Package.swift")):
                dirs.remove(name)  # a package's kept build link
            elif os.path.islink(os.path.join(base, name)):
                dirs.remove(name)  # a link to a directory is a file here: never walked into
                if path not in wanted:
                    os.unlink(os.path.join(base, name))
                    removed += 1
            elif path not in parents:
                dirs.remove(name)
                full = source / path
                full.unlink() if full.is_symlink() else shutil.rmtree(full)
                removed += 1
        for name in files:
            path = os.path.join(relative, name) if relative else name
            if path not in wanted:
                (source / path).unlink()
                removed += 1
    return {"copied": copied, "kept": kept, "removed": removed}


def unbuilt_and_held(entry: Path) -> bool:
    """Whether ENTRY is a root a job holds and has not built yet: room it will still take."""
    if kept_build(entry):
        return False
    try:
        with open(lock_path(entry), "a") as handle:
            fcntl.flock(handle, fcntl.LOCK_SH | fcntl.LOCK_NB)
    except BlockingIOError:
        return True
    except OSError:
        return False
    return False


def lease(workspace: Path, store: Path, runner: str, verdict: dict[str, object] | None = None,
          fingerprints: list[str] | None = None) -> Path | None:
    """Lease one of the mini's shared roots for this job and mirror WORKSPACE into its source: the
    directory whose source tree and package builds every runner slot on the mini uses in turn, so a job
    builds at the path the last job on any slot built at. Returns the root's source path, or None when no
    root is free and the disk has no room for another (the caller then links WORKSPACE as before).

    A root is held exclusively by its <fingerprint>.lock (a holder keeps it for the job), so two jobs never
    build in one root; glaeda-disk and prune see it held. Roots are numbered and a job takes the lowest free
    one, so the mini keeps as many as jobs ran at once, as far as free disk above the reserve allows.
    FINGERPRINTS (tests) names root k's directory instead of shared_fingerprint(..., k)."""
    if "-glaeda" not in runner or not store.is_dir():
        return None
    scratch = store / SCRATCH
    scratch_existed = scratch.is_dir() and any(scratch.iterdir())
    scratch.mkdir(parents=True, exist_ok=True)
    known = entries(scratch)
    # Root k exists only if roots 0..k-1 were busy when it was made, and a lock file outlives its directory
    # (drop keeps it), so every root that exists, or that another job is making now, is numbered below
    # the count of directories and lock files: no root is stranded above the scan.
    locks = sum(1 for path in scratch.glob("*.lock"))
    count = len(fingerprints) if fingerprints is not None else len(known) + locks + 1

    parts = toolchain_parts(workspace) if fingerprints is None else ("", "", "")

    def root(k: int) -> Path:
        return scratch / (fingerprints[k] if fingerprints is not None else shared_fingerprint(parts, k))

    existing = [root(k) for k in range(count) if root(k).is_dir() and not root(k).is_symlink()]

    def new_roots():
        # Not bounded by the scan above: another job may take root k (or make it) after the scan and
        # before our lock, so the numbers go on until a lock is ours or the disk has no room. Each held
        # lock is a live job, so this ends after at most as many roots as jobs run at once.
        k = 0
        while fingerprints is None or k < len(fingerprints):
            candidate = root(k)
            if candidate not in existing:
                yield candidate
            k += 1

    sizes: dict[str, int] = {}
    held: tuple[Path, int] | None = None
    estimate: int | None = None
    made = False

    def take(target: Path) -> int | None:
        """TARGET's lock, exclusively, or None when another job holds it."""
        fd = os.open(lock_path(target), os.O_RDWR | os.O_CREAT, 0o644)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            os.close(fd)
            return None  # another job builds there
        except OSError:
            os.close(fd)
            raise  # locks do not work here: the caller links its own workspace
        return fd

    # Every root that exists, lowest first; then new ones in order while the disk has room for one.
    # A root another job holds or is making (its lock taken) is passed over, never waited for.
    for target in itertools.chain(existing, new_roots()):
        lock_existed = lock_path(target).exists()
        if not target.is_symlink() and target.is_dir():
            fd = take(target)
            if fd is None:
                continue
            if not target.is_symlink() and target.is_dir():
                held = (target, fd)  # drop() renames a root only under its lock: ours now, it stays
                break
            os.close(fd)  # pruned between the scan and the lock: making it again goes through admission
        # A new root is admitted under one scratch-wide lock, each against the free disk left after the
        # roots other jobs made and have not built yet, so jobs starting together never make more roots
        # than the disk above the reserve can hold.
        with open(scratch / ADMISSION, "a") as admission:
            fcntl.flock(admission, fcntl.LOCK_EX)
            if estimate is None:
                # The largest root measured, and never less than a whole build: a store with no root yet, or
                # only partly built ones, must not admit roots for zero bytes.
                estimate = max([ROOT_BYTES_UNMEASURED, *(size for size, _ in (tree_stats(entry) for entry in known))])
                prune(scratch, sizes=sizes, room=estimate)
            pending = sum(1 for entry in entries(scratch) if entry != target and unbuilt_and_held(entry))
            if free_bytes(scratch) - disk_reserve_bytes() - pending * estimate < estimate:
                break
            fd = take(target)
            if fd is None:
                continue
            no_link_at(target)
            made = not target.is_dir()
            target.mkdir(exist_ok=True)  # under the admission lock: the next job counts it as pending
        held = (target, fd)
        break
    if held is None:
        return None
    target, fd = held
    try:
        no_link_at(target)
        existed, kept = target.is_dir() and not made, kept_build(target)
        os.utime(lock_path(target))
        prune(scratch, sizes=sizes)
        target.mkdir(exist_ok=True)
        hold(lock_path(target), fd=fd)
    finally:
        os.close(fd)  # the holder keeps the lock from here
    source = target / SHARED_SOURCE
    source.mkdir(exist_ok=True)
    mirror(workspace, source)
    link_packages(source, target, strict=True)
    if verdict is not None:
        state, reason = warm_start(scratch_existed, lock_existed, kept, existed)
        verdict.update(state=state, reason=reason, bytes=sizes.get(target.name, 0) if kept else 0)
    return source


# The fast tier's base-seed root on an owned mini. cmux-next-fast-tier-seed.yml builds the fast tier's
# Swift packages on Blacksmith at this workspace path every 30 minutes and saves the build to R2, and the
# fast tier on Blacksmith restores it and replays its input times: 6.9 min for a head whose owned-mini
# run was cancelled at 20. SwiftPM's build records absolute paths, so the seed is warm only
# at this path; the same Xcode build makes the same key (fast-tier-cache-key.sh). On the minis the
# shared roots above were warm on 3% of fast-tier jobs in 48 h to 2026-11-18 (cmux#44271): the light
# 228 GiB minis rest at 32-48 GiB free and the lease's reserve never admitted a root there.
SEED_WORKSPACE = Path("/Users/runner/_work/cmux/cmux")
# The second seed root, tried only while another fast-tier job holds the first: of 15 fast-tier jobs that
# started cold and hit the 60-minute cap in 6 h to 01Z 2026-11-23, 7 found the one seed root held by another
# fast-tier job, which came free 12 to 60 minutes later (controller timing records, ci-three-pushes-per-pr).
# SwiftPM's build records absolute paths, so it has its own seed: cmux-next-fast-tier-seed.yml builds one at
# this path too (its blacksmith-root2 pool). vars.CI_FAST_TIER_SECOND_SEED_ROOT "0" turns it off.
SECOND_SEED_WORKSPACE = Path("/Users/runner/_work/cmux-2/cmux")
SECOND_SEED_SETTING = "CMUX_FAST_TIER_SECOND_SEED_ROOT"  # "0" from cmux-next.yml when the variable is "0"
SEED_LOCK = ".cmux-seed-root.lock"
# Provisioning writes this in the seed root's parent. The nightly-next builder's runner works in
# /Users/runner/_work/cmux/cmux too, so the directory alone does not make the path ours.
SEED_MARKER = ".cmux-seed-root"
SEED_SETTING = "CMUX_FAST_TIER_OWNED_SEED"  # "1" from cmux-next.yml unless vars.CI_FAST_TIER_OWNED_SEED is "0"
# The seed's CmuxNext and CmuxHomeRender builds (15 GiB `du` in seed job 134522053219), rounded up.
SEED_BYTES_ESTIMATE = 16 * 1024**3
SEED_BUILDS = ("Packages/macOS/CmuxNext/.build", "Packages/Shared/CmuxHomeRender/.build")


def seed_fits(free: int, kept: int, floor_gib: float, growth_gib: float, footprint: int) -> bool:
    """Whether a seed of FOOTPRINT bytes fits a mini with FREE bytes free, KEPT of them already held by the
    last seed job's build (the restore replaces it). glaeda admitted this job against its floor plus its
    growth, and a cold build would write the same bytes, so the seed needs room above the floor only for
    what exceeds one job's growth: not the lease's floor + growth + a whole root (about 67 GiB)."""
    return free + kept >= int(floor_gib * 1024**3) + max(0, footprint - int(growth_gib * 1024**3))


def second_seed_fits(free: int, kept: int, floor_gib: float, growth_gib: float, footprint: int) -> bool:
    """Whether a mini has the disk for a second seed root: its build stays after the job, beside the first
    root's, so it needs room above glaeda's floor for itself and still for the next job's growth."""
    return free + kept >= int((floor_gib + growth_gib) * 1024**3) + footprint


# The off switch for make_seed_room: "0" leaves the scratch alone and the seed root falls through on room as
# before (cmux-next.yml sets it from vars.CI_SPM_SCRATCH_SEED_EVICT).
SEED_EVICT_SETTING = "CMUX_SPM_SCRATCH_SEED_EVICT"


def in_use(entry: Path) -> bool:
    """Whether a job holds ENTRY's lock now (shared or exclusive); drop checks again under its own lock."""
    try:
        with open(lock_path(entry), "a") as handle:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return True
    return False


def same_volume(a: Path, b: Path) -> bool:
    try:
        return a.stat().st_dev == b.stat().st_dev
    except OSError:
        return False


def free_needed(fits, kept: int, floor_gib: float, growth_gib: float, footprint: int) -> int:
    """The least free space at which FITS (a seed root's room check: seed_fits, second_seed_fits) passes."""
    high = 1
    while not fits(high, kept, floor_gib, growth_gib, footprint):
        high *= 2
    low = 0
    while low < high:
        mid = (low + high) // 2
        if fits(mid, kept, floor_gib, growth_gib, footprint):
            high = mid
        else:
            low = mid + 1
    return low


def make_seed_room(parent: Path, scratch: Path, kept: int, floor_gib: float, growth_gib: float, footprint: int,
                   environ: Mapping[str, str] = os.environ, fits=None) -> list[str]:
    """Drop the least recently used SwiftPM scratch directories no job holds until the seed root fits by its own
    test (FITS, seed_fits by default: glaeda's floor plus what the seed needs past one job's growth), and no further. The bound is
    that admission's threshold, not a size: a mini with room keeps all its scratch. The seed root fell through on
    room on 8 fast-tier jobs (three minis at 15.4, 48.4 and 56.2 GiB free, 2026-11-23) while
    one of them held 31 GiB of scratch. A directory a job holds (its lock, shared or exclusive) is never dropped
    (drop). Off: CMUX_SPM_SCRATCH_SEED_EVICT=0. Returns the dropped directories' names."""
    if environ.get(SEED_EVICT_SETTING, "1") == "0" or not scratch.is_dir() or not same_volume(parent, scratch):
        return []
    short = free_needed(fits or seed_fits, kept, floor_gib, growth_gib, footprint) - free_bytes(parent)
    if short <= 0:
        return []
    stats = {entry: tree_stats(entry) for entry in entries(scratch)}
    if sum(size for entry, (size, _) in stats.items() if not in_use(entry)) < short:
        return []  # dropping all of it would still leave the seed no room: keep the scratch warm
    sizes: dict[str, int] = {}
    total = sum(size for size, _ in stats.values())
    dropped = prune(scratch, max_bytes=max(0, total - short), sizes=sizes)
    freed = sum(sizes.get(name, 0) for name in dropped)
    if dropped:
        print(f"owned SwiftPM scratch: dropped {len(dropped)} least recently used scratch directories "
              f"({freed / 1024**3:.1f} GiB) to make room for the seed root ({short / 1024**3:.1f} GiB short)")
    return dropped


def seed_lease(workspace: Path, seed_workspace: Path, runner: str,
               verdict: dict[str, object] | None = None, fits=seed_fits,
               store: Path = DEFAULT_STORE) -> Path | None:
    """Hold the mini's seed root for this job and mirror WORKSPACE into it; return it, or None to take the
    shared roots as before: not an owned runner, the root's parent not provisioned (the mini's user owns
    /Users/runner/_work/cmux and marks it with SEED_MARKER), another job holding it, or no room above
    glaeda's floor (seed_fits) even after make_seed_room dropped the idle SwiftPM scratch it may.
    The packages' .build stay real directories there: the job restores the seed into them."""
    if "-glaeda" not in runner or os.path.realpath(workspace) == os.path.realpath(seed_workspace):
        return None
    parent = seed_workspace.parent
    if (not parent.is_dir() or parent.is_symlink() or not os.access(parent, os.W_OK)
            or not (parent / SEED_MARKER).is_file()):
        return None
    fd = os.open(parent / SEED_LOCK, os.O_RDWR | os.O_CREAT, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        os.close(fd)
        return None
    try:
        kept = sum(tree_bytes(seed_workspace / build) for build in SEED_BUILDS)
        floor_gib, growth_gib = disk_limits_gib()
        footprint = max(SEED_BYTES_ESTIMATE, kept)
        if not fits(free_bytes(parent), kept, floor_gib, growth_gib, footprint):
            make_seed_room(parent, store / SCRATCH, kept, floor_gib, growth_gib, footprint, fits=fits)
        if not fits(free_bytes(parent), kept, floor_gib, growth_gib, footprint):
            os.close(fd)
            return None
        hold(parent / SEED_LOCK, fd=fd)
    except BaseException:
        release_holders()
        os.close(fd)
        raise
    os.close(fd)  # the holder keeps the lock from here
    with contextlib.suppress(FileNotFoundError):
        if seed_workspace.is_symlink() or not seed_workspace.is_dir():
            seed_workspace.unlink()
    seed_workspace.mkdir(exist_ok=True)
    mirror(workspace, seed_workspace)
    for package in packages(seed_workspace):
        build = package / ".build"
        if build.is_symlink():
            build.unlink()  # a real directory: the seed is restored into it
        else:
            drop_resource_bundles(build)  # the last job may have built another branch (cmux#26961)
    if verdict is not None:
        verdict.update(state="cold", reason="seed root", bytes=0)
    return seed_workspace


def seed_roots(environ: Mapping[str, str] = os.environ) -> list[tuple[Path, object]]:
    """The seed roots a fast-tier job tries, in order, each with its room check. CMUX_FAST_TIER_SEED_WORKSPACE
    names one root alone (tests)."""
    named = environ.get("CMUX_FAST_TIER_SEED_WORKSPACE")
    if named:
        return [(Path(named), seed_fits)]
    roots: list[tuple[Path, object]] = [(SEED_WORKSPACE, seed_fits)]
    if environ.get(SECOND_SEED_SETTING) != "0":
        roots.append((SECOND_SEED_WORKSPACE, second_seed_fits))
    return roots


def write_seeded(environ: Mapping[str, str] = os.environ) -> Path | None:
    """The fast tier restored the base seed into the seed root: this job starts seeded, not cold."""
    return write_warm_start("seeded", 0, "base seed", environ)


def release_holders() -> None:
    for holder in HOLDERS:
        try:
            os.killpg(holder.pid, signal.SIGKILL)  # its whole group: it leads one (start_new_session)
        except (ProcessLookupError, PermissionError):
            pass
        holder.wait()
    HOLDERS.clear()


def write_output(name: str, value: str, environ: Mapping[str, str] = os.environ) -> None:
    output = environ.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a", encoding="utf-8") as handle:
            handle.write(f"{name}={value}\n")


def report(verdict: dict[str, object]) -> None:
    kept_bytes = int(verdict["bytes"])  # type: ignore[call-overload]
    print(f"owned SwiftPM scratch: starts {verdict['state']} ({verdict['reason']}, "
          f"{kept_bytes / 1024**3:.1f} GiB kept)")
    write_warm_start(str(verdict["state"]), kept_bytes, str(verdict["reason"]))


def main(argv: list[str]) -> int:
    if len(argv) == 3 and argv[1] == "keep":
        os.fstat(int(argv[2]))  # the inherited descriptor holds the lock; keep it open
        print(HELD, flush=True)
        signal.alarm(HOLD_SECONDS)
        while True:
            signal.pause()
    if len(argv) in (3, 4) and argv[1] == "lease":
        workspace = Path(argv[2]).resolve()
        store = Path(argv[3]) if len(argv) == 4 else DEFAULT_STORE
        runner = os.environ.get("RUNNER_NAME", "")
        verdict = {}
        if os.environ.get(SEED_SETTING) == "1":
            seeded = None
            for seed, fits in seed_roots():
                try:
                    seeded = seed_lease(workspace, seed, runner, verdict=verdict, fits=fits, store=store)
                except (OSError, subprocess.SubprocessError) as error:
                    release_holders()
                    print(f"owned SwiftPM scratch: no seed root at {seed} ({error})")
                    seeded, verdict = None, {}
                if seeded is not None:
                    break
            if seeded is not None:
                write_output("root", str(seeded))
                write_output("seed", "1")
                print(f"owned SwiftPM scratch: building in the mini's seed root {seeded} (the base seed restores here)")
                report(verdict)
                return 0
            print("owned SwiftPM scratch: every seed root is busy, unprovisioned or has no room; taking a shared root")
            verdict = {}
        try:
            source = lease(workspace, store, runner, verdict=verdict)
        except (OSError, subprocess.SubprocessError) as error:
            release_holders()  # a root half mirrored is never built; the next lease mirrors it again
            print(f"owned SwiftPM scratch: no shared root ({error}); keeping this runner's own build")
            source, verdict = None, {}
        if source is not None:
            write_output("root", str(source))
            print(f"owned SwiftPM scratch: building in the mini's shared root {source}")
            report(verdict)
            return 0
        try:
            linked = link(workspace, store, runner, verdict=verdict)
        except (OSError, subprocess.SubprocessError) as error:
            print(f"owned SwiftPM scratch: skipped ({error})")
            write_warm_start("cold", 0, f"link failed: {error}")
            return 0
        print(f"owned SwiftPM scratch: {len(linked)} packages keep their .build between jobs")
        if verdict:
            if verdict["state"] == "cold":
                verdict["reason"] = "roots busy"
            report(verdict)
        return 0
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
        verdict: dict[str, object] = {}
        try:
            linked = link(Path(argv[2]).resolve(), store, os.environ.get("RUNNER_NAME", ""), verdict=verdict)
        except (OSError, subprocess.SubprocessError) as error:  # a kept build is an optimization only
            print(f"owned SwiftPM scratch: skipped ({error})")
            write_warm_start("cold", 0, f"link failed: {error}")
            return 0
        print(f"owned SwiftPM scratch: {len(linked)} packages keep their .build between jobs")
        if verdict:
            report(verdict)
        return 0
    if len(argv) == 2 and argv[1] == "seeded":
        write_seeded()
        print("owned SwiftPM scratch: the base seed was restored into the seed root (starts seeded)")
        return 0
    if len(argv) == 3 and argv[1] == "drop-bundles":
        dropped = drop_resource_bundles(Path(argv[2]))
        print(f"owned SwiftPM scratch: dropped {len(dropped)} resource bundles from {argv[2]}")
        return 0
    if len(argv) in (2, 3) and argv[1] == "evict":
        for path in evict(Path(argv[2]) if len(argv) == 3 else DEFAULT_STORE):
            print(path)
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
