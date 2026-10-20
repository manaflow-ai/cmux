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

`cache-dir NAME` names a directory beside them for another content-addressed
source cache (for example the third-party notices' crates, one directory per
crate name and version, extracted only after its sha256 matched Cargo.lock).
It prints nothing on any other runner, so the caller keeps its per-job cache.
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


def cache_dir(home: Path, runner: str, name: str) -> Path | None:
    """A per-runner directory that outlives the job, only on a trusted NEXT worker."""
    if not owned(runner) or re.fullmatch(r'[a-z0-9][a-z0-9-]*', name) is None:
        return None
    return home / STATE_ROOT / runner / 'caches' / name


def main(argv: list[str]) -> int:
    if len(argv) == 3 and argv[1] == 'cache-dir':
        path = cache_dir(Path.home(), os.environ.get('RUNNER_NAME', ''), argv[2])
        if path is not None:
            path.mkdir(parents=True, exist_ok=True)
            print(path)
        return 0
    workspace = Path(os.environ.get('GITHUB_WORKSPACE', '.')).resolve()
    if len(argv) == 3 and argv[1] == 'prepare':
        runner = os.environ.get('RUNNER_NAME', '')
        if owned(runner) and argv[2] == 'nightly-next':
            toolchain = os.environ.get('DEVELOPER_DIR', '') + '\n'
            toolchain += subprocess.check_output(['xcodebuild', '-version'], text=True)
            toolchain += subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-build-version'], text=True)
            prepare(workspace, Path.home(), runner, argv[2], toolchain)
        return 0
    print('usage: nightly_build_state.py prepare TRACK | cache-dir NAME', file=sys.stderr)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv))
