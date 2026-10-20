#!/usr/bin/env python3
"""Keep NEXT's package checkouts and compilation cache on a trusted worker, never its build state.

An incremental Xcode build can keep stale autolink and force-load data in
objects it did not recompile after an import set changed, and those objects
then link into the shipped app. So every shipped build starts from an empty
DerivedData with its inputs at their checkout times. Only the package
checkouts (source, no build output) and Xcode's compilation cache stay,
outside the workspace, scoped to the runner, source path and toolchain. The
compilation cache is content-keyed (each key includes the job's explicit
module dependencies), so a hit replays exactly what a cold compile of the same
inputs produces; it is the warm state main restores from R2 (hq-25), kept on
the dedicated worker's disk instead. Earlier revisions of this script also
kept DerivedData there and replayed old input times; prepare deletes that state.

The worker also keeps the crate sources that the third-party notices read
(CMUX_NEXT_NOTICES_CACHE, about 1,100 crates that each job otherwise downloads
again, about 3 minutes). A crates.io version never changes, fetch_crates.py
checks each download against Cargo.lock's sha256 and writes it under a
partial name first, and the notices read them as text. The checkouts where
the notices run cargo are not kept.
"""
from __future__ import annotations

import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time

STATE_ROOT = 'Library/Caches/cmux-nightly-next'
NOTICES_CACHE = 'notices-crates'
NOTICES_CACHE_MAX_BYTES = 8 << 30


def owned(runner: str) -> bool:
    return re.fullmatch(r'[a-zA-Z0-9._-]+-glaeda(?:-[0-9]+)?', runner) is not None


def remove(path: Path) -> None:
    """Delete a file, link or tree; a leftover writer cannot refill it after the rename."""
    if not (path.exists() or path.is_symlink()):
        return
    if path.is_symlink() or path.is_file():
        path.unlink()
        return
    stale = path.with_name(f'{path.name}.stale.{os.getpid()}.{time.time_ns()}')
    path.rename(stale)
    shutil.rmtree(stale, ignore_errors=True)


def link(path: Path, target: Path) -> None:
    target.mkdir(parents=True, exist_ok=True)
    if path.is_symlink() and path.resolve() == target.resolve():
        return
    remove(path)
    path.symlink_to(target, target_is_directory=True)


def tree_bytes(path: Path) -> int:
    total = 0
    for parent, _, files in os.walk(path):
        for name in files:
            try:
                total += os.lstat(os.path.join(parent, name)).st_size
            except OSError:
                pass
    return total


def notices_cache(home: Path, runner: str) -> Path:
    """The kept notices crate sources, emptied once they pass the size bound."""
    cache = home / STATE_ROOT / runner / NOTICES_CACHE
    if cache.is_dir() and tree_bytes(cache) > NOTICES_CACHE_MAX_BYTES:
        remove(cache)
    # Keep only the crate sources fetch_crates.py writes (registry/ and git/),
    # which the notices read as text. The iroh-ffi, cmux-cua and cmux-tui
    # checkouts are where generate-third-party-notices.sh runs cargo, so
    # each job checks them out again: a file another job planted there
    # (a .cargo/config.toml) never runs in this one.
    if cache.is_dir():
        for entry in sorted(cache.iterdir()):
            if entry.name not in ('registry', 'git') or not entry.is_dir() or entry.is_symlink():
                remove(entry)
    # Directories an interrupted fetch left; fetch_crates.py starts them again.
    for pattern in ('registry/src/*/*.partial', 'git/checkouts/*/*.partial'):
        for partial in sorted(cache.glob(pattern)):
            remove(partial)
    cache.mkdir(parents=True, exist_ok=True)
    return cache


def prepare(workspace: Path, home: Path, runner: str, track: str, toolchain: str) -> bool:
    if not owned(runner) or track != 'nightly-next':
        return False
    runner_state = home / STATE_ROOT / runner
    derived = workspace / 'build-universal'
    remove(derived)
    # Every identity of this runner: a toolchain or path change must not leave
    # an older build database behind for a later revision to link back.
    for retained in sorted(runner_state.glob('*/DerivedData*')):
        remove(retained)
    derived.mkdir()
    identity = hashlib.sha256(f'{workspace.resolve()}\n{toolchain}'.encode()).hexdigest()[:32]
    link(workspace / '.spm-cache', runner_state / identity / 'SourcePackages')
    link(derived / 'CompilationCache.noindex', runner_state / identity / 'CompilationCache')
    print(f'NEXT Release build starts from empty DerivedData; package checkouts and compilation cache: {runner_state / identity}')
    return True


def main(argv: list[str]) -> int:
    workspace = Path(os.environ.get('GITHUB_WORKSPACE', '.')).resolve()
    if len(argv) == 3 and argv[1] == 'prepare':
        runner = os.environ.get('RUNNER_NAME', '')
        if owned(runner) and argv[2] == 'nightly-next':
            toolchain = os.environ.get('DEVELOPER_DIR', '') + '\n'
            toolchain += subprocess.check_output(['xcodebuild', '-version'], text=True)
            toolchain += subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-build-version'], text=True)
            if prepare(workspace, Path.home(), runner, argv[2], toolchain):
                cache = notices_cache(Path.home(), runner)
                print(f'NEXT third-party notices read crate sources kept in {cache}')
                github_env = os.environ.get('GITHUB_ENV')
                if github_env:
                    with open(github_env, 'a', encoding='utf-8') as env:
                        env.write(f'CMUX_NEXT_NOTICES_CACHE={cache}\n')
        return 0
    print('usage: nightly_build_state.py prepare TRACK', file=sys.stderr)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv))
