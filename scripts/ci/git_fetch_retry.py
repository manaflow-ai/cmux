#!/usr/bin/env python3
"""Run one git network command with a time limit per try, a low-speed abort and bounded retries.

The warm nightly-next builder fetches each build commit into a kept clone. On
2026-10-27 run 40466772597 attempt 2 hung in
`git fetch origin <sha>` from 07:34:51 to 08:36:35 (62 min), then died with
"early EOF / fetch-pack: invalid index-pack output" (exit 128), and the
nightly died with it. A single git call had no time limit of its own, so the
job's 150-minute budget was the only bound.

Each try here:
- runs git with `http.lowSpeedLimit`/`http.lowSpeedTime` (a transfer under
  LOW_SPEED_BYTES per second for LOW_SPEED_SECONDS is aborted by git itself);
- is killed, with its whole process group, after `--timeout` seconds;
- on failure removes what a killed fetch leaves in the repository (and in
  each submodule's git dir): `objects/pack/tmp_*` partial packs and
  `shallow.lock`, `index.lock` and `*.lock` ref locks older than the try.
Then it waits BACKOFF_SECONDS[n] and tries again, up to `--tries` times.

Before each try of a `submodule update`, a submodule checkout whose `.git` file
names a git dir that is gone (or has no HEAD) is removed, with that half-made
git dir, so the update clones it again. A reused workspace can lose
`.git/modules` while its submodule checkouts stay: on 2026-10-28 the warm
nightly-next builder failed three tries in a row with `fatal: could not get a
repository handle for submodule 'ghostty'`, then `fatal: not a git repository:
ghostty/../.git/modules/ghostty`.

    git_fetch_retry.py [--tries 3] [--timeout S] [--repo DIR] -- git ARGS...

Exits with the last try's status (124 for a timeout).
"""

from __future__ import annotations

import argparse
import os
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path
from typing import Callable, Sequence

# git aborts a transfer slower than this many bytes per second for LOW_SPEED_SECONDS.
LOW_SPEED_BYTES = 1024
LOW_SPEED_SECONDS = 60
# Seconds to wait before try 2 and try 3.
BACKOFF_SECONDS = (10, 30)
TIMEOUT_EXIT = 124
# Seconds between SIGTERM and SIGKILL for a try's process group.
KILL_GRACE_SECONDS = 10


def low_speed_command(command: Sequence[str]) -> list[str]:
    """`command` with git's low-speed abort set, right after `git`."""
    command = list(command)
    if not command or Path(command[0]).name != "git":
        raise ValueError(f"not a git command: {command!r}")
    return [command[0], "-c", f"http.lowSpeedLimit={LOW_SPEED_BYTES}", "-c", f"http.lowSpeedTime={LOW_SPEED_SECONDS}",
            *command[1:]]


def git_dirs(repo: Path) -> list[Path]:
    """The repository's git dir and every submodule git dir under it (.git/modules/...)."""
    root = repo / ".git"
    if not root.is_dir():
        return []
    found = [root]
    modules = root / "modules"
    if modules.is_dir():
        found += sorted(path.parent for path in modules.rglob("HEAD") if (path.parent / "objects").is_dir())
    return found


def clean_partial(repo: Path, since: float, log: Callable[[str], None] = print) -> list[Path]:
    """Delete partial packs and locks a failed try left (anything older than `since` is not ours, except tmp packs)."""
    removed: list[Path] = []
    for git_dir in git_dirs(repo):
        candidates = list((git_dir / "objects" / "pack").glob("tmp_*"))
        candidates += list((git_dir / "objects").glob("incoming-*"))
        for name in ("shallow.lock", "index.lock", "HEAD.lock", "FETCH_HEAD.lock", "packed-refs.lock",
                     "config.lock", "config.worktree.lock"):
            candidates.append(git_dir / name)
        candidates += list((git_dir / "refs").rglob("*.lock")) if (git_dir / "refs").is_dir() else []
        for path in candidates:
            try:
                stat = path.lstat()
            except FileNotFoundError:
                continue
            # A lock older than the try belongs to someone else (or an earlier job's crash, which
            # the job's own stale-lock step handles); a tmp pack is never read, so any can go.
            if path.name.endswith(".lock") and stat.st_mtime < since:
                continue
            try:
                if path.is_dir() and not path.is_symlink():
                    for child in sorted(path.rglob("*"), reverse=True):
                        child.rmdir() if child.is_dir() and not child.is_symlink() else child.unlink()
                    path.rmdir()
                else:
                    path.unlink()
                removed.append(path)
            except OSError as error:
                log(f"git_fetch_retry: could not remove {path}: {error}")
    for path in removed:
        log(f"git_fetch_retry: removed {path}")
    return removed


def module_dirs(repo: Path) -> set[Path]:
    """Every directory under .git/modules that is a submodule git dir or a half-made one.

    A git dir's own subdirectories (objects, refs, ...) are not listed; a nested submodule's git dir
    is (.git/modules/<a>/modules/<b>).
    """
    found: set[Path] = set()

    def walk(modules: Path) -> None:
        if not modules.is_dir():
            return
        for entry in sorted(modules.iterdir()):
            if not entry.is_dir() or entry.is_symlink():
                continue
            found.add(entry)
            if (entry / "HEAD").exists() or (entry / "objects").is_dir():
                walk(entry / "modules")
            else:
                # A name with a slash (a submodule at a/b) nests plain directories.
                walk(entry)

    walk(repo / ".git" / "modules")
    return found


def gitmodules_paths(gitmodules: Path) -> list[str]:
    """The `path` of every submodule a .gitmodules file declares."""
    try:
        listing = subprocess.run(["git", "config", "-f", str(gitmodules), "--get-regexp", r"^submodule\..*\.path$"],
                                 capture_output=True, text=True, timeout=30).stdout
    except (OSError, subprocess.SubprocessError):
        return []
    return [path for _, _, path in (line.partition(" ") for line in listing.splitlines()) if path]


def submodule_worktrees(repo: Path, depth: int = 8) -> list[Path]:
    """Submodule worktrees from .gitmodules, recursively (as `submodule update --recursive` makes them)."""
    paths: list[Path] = []
    if depth <= 0:
        return paths
    for path in gitmodules_paths(repo / ".gitmodules"):
        top = repo / path
        paths.append(top)
        paths.extend(submodule_worktrees(top, depth - 1))
    return paths


def remove_tree(path: Path) -> None:
    if path.is_symlink() or path.is_file():
        path.unlink()
    elif path.is_dir():
        shutil.rmtree(path)


def clean_new_modules(repo: Path, before: set[Path], log: Callable[[str], None] = print) -> list[Path]:
    """Remove submodule git dirs a failed try created, and the worktrees that point at them.

    A killed clone leaves a half-made .git/modules/<name> (often with no HEAD) and a worktree whose
    .git file points at it; `submodule update --init --force` does not repair either, so the next
    try would fail. Only what did not exist before the try is removed.
    """
    new = sorted(module_dirs(repo) - before, key=lambda path: len(path.parts))
    removed: list[Path] = []
    # Worktrees first, for every new git dir or a descendant of one (a submodule at a/b makes
    # both .git/modules/a and .git/modules/a/b), so no worktree is left pointing at a deleted dir.
    new_resolved = [git_dir.resolve() for git_dir in new]
    for worktree in submodule_worktrees(repo):
        marker = worktree / ".git"
        if not marker.is_file():
            continue
        target = marker.read_text(errors="replace").strip().removeprefix("gitdir:").strip()
        points_at = (worktree / target).resolve() if not Path(target).is_absolute() else Path(target).resolve()
        if any(points_at == git_dir or git_dir in points_at.parents for git_dir in new_resolved):
            try:
                remove_tree(worktree)
                removed.append(worktree)
            except OSError as error:
                log(f"git_fetch_retry: could not remove {worktree}: {error}")
    for git_dir in new:
        if any(parent in removed for parent in git_dir.parents):
            continue
        try:
            remove_tree(git_dir)
            removed.append(git_dir)
        except OSError as error:
            log(f"git_fetch_retry: could not remove {git_dir}: {error}")
    for path in removed:
        log(f"git_fetch_retry: removed {path} (made by the failed try)")
    return removed


def gitfile_target(worktree: Path) -> Path | None:
    """The git dir a submodule checkout's `.git` file names, or None when `.git` is not such a file."""
    marker = worktree / ".git"
    if marker.is_symlink() or not marker.is_file():
        return None
    try:
        text = marker.read_text(errors="replace").strip()
    except OSError:
        return None
    if not text.startswith("gitdir:"):
        return None
    target = Path(text.removeprefix("gitdir:").strip())
    return target if target.is_absolute() else worktree / target  # not normalized: the OS walks it as git does


def inside(path: Path, root: Path) -> bool:
    """Whether `path` is strictly under `root` with no symlink on the way (root itself included)."""
    if root.is_symlink():
        return False
    try:
        rel = path.relative_to(root)
    except ValueError:
        return False
    if not rel.parts or ".." in rel.parts:
        return False
    walk = root
    for part in rel.parts:
        walk = walk / part
        if walk.is_symlink():
            return False
    return path.resolve() != root.resolve() and root.resolve() in path.resolve().parents


def drop_dangling_submodules(repo: Path, log: Callable[[str], None] = print,
                             only: Sequence[str] = ()) -> list[Path]:
    """Remove submodule checkouts whose `.git` file names a git dir that is gone or has no HEAD.

    `submodule update --init --force` cannot repair such a checkout ("could not get a repository
    handle", "not a git repository"); with the checkout gone it clones the submodule again. A
    half-made git dir it named is removed too when it is under this repository's own .git/modules.
    Only paths inside the repository with no symlink on the way are touched. Checkouts are visited
    top-down, so a nested one under a removed checkout is not visited. With `only`, just those top-level
    paths (and submodules inside them) are looked at.
    """
    removed: list[Path] = []
    repo = Path(os.path.abspath(repo))
    scopes = [repo / path for path in only]
    modules = repo / ".git" / "modules"
    own_modules = (repo / ".git").is_dir() and not (repo / ".git").is_symlink()
    for worktree in submodule_worktrees(repo):
        if any(parent in removed for parent in worktree.parents) or not inside(worktree, repo):
            continue
        if scopes and not any(worktree == scope or scope in worktree.parents for scope in scopes):
            continue
        target = gitfile_target(worktree)
        if target is None or (target / "HEAD").is_file():
            continue
        try:
            remove_tree(worktree)
            worktree.mkdir(parents=True, exist_ok=True)  # as a fresh checkout leaves an uninitialized submodule
            removed.append(worktree)
            # the git dir as git reaches it (symlinks followed), and only under the real .git/modules
            real = Path(os.path.realpath(target))
            if own_modules and not modules.is_symlink() and modules.is_dir() and real.is_dir() \
                    and modules.resolve() in real.parents:
                remove_tree(real)
        except OSError as error:
            log(f"git_fetch_retry: could not remove {worktree}: {error}")
            continue
        log(f"git_fetch_retry: removed {worktree}: its .git names {target}, which is gone (the update clones it)")
    return removed


# `git` options and `submodule update` options that take their value as the next word.
GIT_VALUE_OPTIONS = frozenset({"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path",
                               "--config-env", "--super-prefix"})
UPDATE_VALUE_OPTIONS = frozenset({"--reference", "--depth", "--jobs", "-j", "--filter"})


def submodule_update_paths(command: Sequence[str]) -> list[str] | None:
    """The paths a `git ... submodule update ...` command names (empty: every submodule), or None when the
    command is not a submodule update. Paths are positional, with or without a `--` before them."""
    words = list(command[1:])
    i = 0
    while i < len(words) and words[i].startswith("-"):  # git's own options
        i += 2 if words[i] in GIT_VALUE_OPTIONS else 1
    if words[i:i + 1] != ["submodule"]:
        return None
    i += 1
    while i < len(words) and words[i] in ("--quiet", "-q"):  # `git submodule --quiet update`
        i += 1
    if words[i:i + 1] != ["update"]:
        return None
    paths: list[str] = []
    rest = words[i + 1:]
    j = 0
    while j < len(rest):
        word = rest[j]
        if word == "--":
            paths += rest[j + 1:]
            break
        if word.startswith("-"):
            j += 2 if word in UPDATE_VALUE_OPTIONS else 1
            continue
        paths.append(word)
        j += 1
    return paths


def is_submodule_update(command: Sequence[str]) -> bool:
    return submodule_update_paths(command) is not None


def run_once(command: Sequence[str], timeout: float) -> int:
    """Run `command` in its own process group; kill the group after `timeout` seconds."""
    process = subprocess.Popen(list(command), start_new_session=True)
    try:
        return process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        pass
    # SIGTERM the whole group, give it a grace period, then SIGKILL whatever of the group is
    # left, whether or not the leader has exited: a child that ignored SIGTERM must not keep
    # writing into the repository while the cleanup and the next try run.
    signal_group(process.pid, signal.SIGTERM)
    try:
        process.wait(timeout=KILL_GRACE_SECONDS)
    except subprocess.TimeoutExpired:
        pass
    signal_group(process.pid, signal.SIGKILL)
    process.wait()
    deadline = time.monotonic() + KILL_GRACE_SECONDS
    while group_alive(process.pid) and time.monotonic() < deadline:
        time.sleep(0.1)
    return TIMEOUT_EXIT


def signal_group(pgid: int, sig: int) -> None:
    try:
        os.killpg(pgid, sig)
    except (ProcessLookupError, PermissionError):
        pass


def group_alive(pgid: int) -> bool:
    try:
        os.killpg(pgid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def run(command: Sequence[str], *, tries: int, timeout: float, repo: Path,
        runner: Callable[[Sequence[str], float], int] = run_once,
        sleep: Callable[[float], None] = time.sleep, clock: Callable[[], float] = time.time,
        log: Callable[[str], None] = print) -> int:
    command = low_speed_command(command)
    status = 1
    for attempt in range(1, tries + 1):
        started = clock()
        only = submodule_update_paths(command)
        if only is not None:  # an update of named paths drops only under those paths; with none, under all
            drop_dangling_submodules(repo, log, only=only)
        modules_before = module_dirs(repo)
        status = runner(command, timeout)
        if status == 0:
            if attempt > 1:
                log(f"git_fetch_retry: try {attempt} of {tries} succeeded")
            return 0
        reason = f"timed out after {round(timeout)} s" if status == TIMEOUT_EXIT else f"exited {status}"
        log(f"::warning title=git fetch retry::try {attempt} of {tries} {reason}: {' '.join(command)}")
        clean_partial(repo, started - 1, log)
        clean_new_modules(repo, modules_before, log)
        if attempt < tries:
            sleep(BACKOFF_SECONDS[min(attempt - 1, len(BACKOFF_SECONDS) - 1)])
    return status


def main(argv: Sequence[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--tries", type=int, default=3)
    parser.add_argument("--timeout", type=float, help="seconds per try (required with a command)")
    parser.add_argument("--repo", type=Path, default=Path("."))
    parser.add_argument("--drop-dangling-submodules", action="store_true",
                        help="only remove submodule checkouts whose git dir is gone, then exit")
    parser.add_argument("--only", action="append", default=[], metavar="PATH",
                        help="with --drop-dangling-submodules: only this submodule path (repeatable)")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    if args.drop_dangling_submodules:
        drop_dangling_submodules(args.repo, only=args.only)
        return 0
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if args.tries < 1 or args.timeout is None or args.timeout <= 0 or not command:
        parser.error("need --tries >= 1, --timeout > 0 and a git command after --")
    return run(command, tries=args.tries, timeout=args.timeout, repo=args.repo.resolve())


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
