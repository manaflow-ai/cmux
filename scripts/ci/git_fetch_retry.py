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

    git_fetch_retry.py [--tries 3] [--timeout S] [--repo DIR] -- git ARGS...

Exits with the last try's status (124 for a timeout).
"""

from __future__ import annotations

import argparse
import os
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
        for name in ("shallow.lock", "index.lock", "HEAD.lock", "FETCH_HEAD.lock", "packed-refs.lock"):
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
        status = runner(command, timeout)
        if status == 0:
            if attempt > 1:
                log(f"git_fetch_retry: try {attempt} of {tries} succeeded")
            return 0
        reason = f"timed out after {round(timeout)} s" if status == TIMEOUT_EXIT else f"exited {status}"
        log(f"::warning title=git fetch retry::try {attempt} of {tries} {reason}: {' '.join(command)}")
        clean_partial(repo, started - 1, log)
        if attempt < tries:
            sleep(BACKOFF_SECONDS[min(attempt - 1, len(BACKOFF_SECONDS) - 1)])
    return status


def main(argv: Sequence[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--tries", type=int, default=3)
    parser.add_argument("--timeout", type=float, required=True, help="seconds per try")
    parser.add_argument("--repo", type=Path, default=Path("."))
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if args.tries < 1 or args.timeout <= 0 or not command:
        parser.error("need --tries >= 1, --timeout > 0 and a git command after --")
    return run(command, tries=args.tries, timeout=args.timeout, repo=args.repo.resolve())


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
