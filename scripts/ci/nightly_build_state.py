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

The dedicated nightly-next builder is the one exception (Leo, 2026-10-27: "what if we
just dedicatd one, only, always, and it just incrementally... did the thing? clear its
stuff, etc"). Its runner (`<host>-nightly-next` or glaeda's `<host>-glaeda-nightly-next`)
runs only nightly-next's app build, so it keeps one DerivedData per identity and builds
each new tip on it. An incremental build is a real compile of every changed file. It
starts clean (CLEAN_REASONS) when:
- the last build on it did not finish (no `mark-built` after `prepare`);
- the key changed: the toolchain (Xcode, SDK, DEVELOPER_DIR) or any lockfile, toolchain
  pin or submodule commit (KEY_PATHS);
- a file that shapes modules or linking changed since the last built commit
  (STRUCTURE_PATHS: Package.swift, *.pbxproj, *.xcconfig, *.modulemap, ...), or an
  import or include line was added or removed in a source file. That is the case the
  2026-10-18 audit found: objects that were not recompiled after an import set changed
  kept stale autolink and force-load data;
- the downloads a build embeds by pin (CEF, GhosttyKit) changed: their manifests and
  scripts are in KEY_PATHS, the GhosttyKit pin is the ghostty submodule commit;
- CLEAN_EVERY incremental builds ran since the last clean one.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time

STATE_ROOT = 'Library/Caches/cmux-nightly-next'
# Measured over 199 consecutive nightly-next promotions (2026-10-24..27): 84 changed no
# KEY_PATHS or STRUCTURE_PATHS file and no import line, so about 58% of builds start clean
# on their own and a run of more than 10 incremental builds is rare (0.42^10). CLEAN_EVERY
# bounds that tail anyway: after 10 incremental builds the next one is clean.
CLEAN_EVERY = 10
INCREMENTAL_STATE = 'incremental.json'
KEY_PATHS = re.compile(r'(^|/)(Package\.resolved|Cargo\.lock|build\.zig\.zon|rust-toolchain(\.toml)?|\.xcode-version'
                       r'|cef-manifest\.json|ensure-cef\.sh|ensure-remote-browser-host\.sh|download-prebuilt-ghosttykit\.sh)$')
# An import or include line added or removed in a source file: the import set changes, the audited
# case for stale autolink and force-load data in objects that were not recompiled.
IMPORT_SOURCES = ('*.swift', '*.h', '*.m', '*.mm', '*.c', '*.cpp')
IMPORT_LINE = re.compile(r'^[+-](?![+-]).*\bimport\s|^[+-]\s*#\s*(import|include)\b')
STRUCTURE_PATHS = re.compile(r'(^|/)(Package\.swift|[^/]+\.pbxproj|[^/]+\.xcconfig|[^/]+\.modulemap'
                             r'|[^/]+\.xcscheme|[^/]+\.entitlements|[^/]+\.xcfilelist)$')
NOTICES_CACHE = 'notices-crates'
NOTICES_CACHE_MAX_BYTES = 8 << 30


def owned(runner: str) -> bool:
    # A Glaeda mini runner (<member>-glaeda[-K]) or the dedicated nightly-next
    # builder (cmux22-nightly-next, plans/cmux-next/nightly-builder-DESIGN.md),
    # whose admission hook runs only this build. Without it the dedicated
    # builder compiled every head cold (425 cache misses, xcodebuild 505 s
    # against 254 s on cmux15, run 39396919366).
    return re.fullmatch(r'[a-zA-Z0-9._-]+-(?:glaeda(?:-[0-9]+)?|nightly-next)', runner) is not None


def dedicated(runner: str) -> bool:
    """The dedicated nightly-next builder's runner (its hand-made or glaeda-managed name)."""
    return re.fullmatch(r'[a-zA-Z0-9._-]+-nightly-next', runner) is not None


def git(workspace: Path, *args: str) -> str:
    return subprocess.run(['git', '-C', str(workspace), *args], check=True, capture_output=True, text=True).stdout


def input_key(workspace: Path, toolchain: str) -> str:
    """The toolchain plus every lockfile, toolchain pin and submodule commit at HEAD."""
    pins = []
    for line in git(workspace, 'ls-tree', '-r', 'HEAD').splitlines():
        meta, _, path = line.partition('\t')
        mode, kind, obj = meta.split()
        if kind == 'commit' or KEY_PATHS.search(path):
            pins.append(f'{mode} {obj} {path}')
    return hashlib.sha256('\n'.join([toolchain, *sorted(pins)]).encode()).hexdigest()


def structure_changed(workspace: Path, since: str) -> str | None:
    """The first module- or link-shaping file changed between `since` and HEAD, '' if none,
    or None when `since` cannot be compared."""
    if not re.fullmatch(r'[0-9a-f]{40}', since or ''):
        return None
    try:
        names = git(workspace, 'diff', '--name-only', '--no-renames', since, 'HEAD').splitlines()
    except subprocess.CalledProcessError:
        return None
    changed = next((name for name in names if STRUCTURE_PATHS.search(name)), '')
    if changed:
        return changed
    try:
        diff = git(workspace, 'diff', '-U0', '--no-renames', since, 'HEAD', '--', *IMPORT_SOURCES)
    except subprocess.CalledProcessError:
        return None
    current = ''
    for line in diff.splitlines():
        if line.startswith('+++ b/'):
            current = line[6:]
        elif IMPORT_LINE.search(line):
            return f'an import in {current or "a source file"}'
    return ''


def clean_reason(state: dict, key: str, workspace: Path) -> str:
    """Why this build must start clean, or '' to build incrementally."""
    if not state:
        return 'no earlier build on this builder'
    if not state.get('built'):
        return 'the last build did not finish'
    if state.get('key') != key:
        return 'the toolchain, a lockfile or a submodule changed'
    changed = structure_changed(workspace, str(state.get('sha') or ''))
    if changed is None:
        return 'the last built commit cannot be compared'
    if changed:
        return f'{changed} changed (module or link structure)'
    if int(state.get('since_clean') or 0) >= CLEAN_EVERY:
        return f'{CLEAN_EVERY} incremental builds since the last clean one'
    return ''


def prepare_incremental(workspace: Path, runner_state: Path, identity: str, key: str) -> tuple[str, str]:
    """Link build-universal to the kept DerivedData; returns (mode, reason)."""
    kept = runner_state / identity
    state_file = kept / INCREMENTAL_STATE
    try:
        state = json.loads(state_file.read_text())
    except (OSError, ValueError):
        state = {}
    reason = clean_reason(state, key, workspace)
    # Another identity's DerivedData (an older toolchain or path) is never linked back.
    for retained in sorted(runner_state.glob('*/DerivedData*')):
        if retained.parent != kept:
            remove(retained)
    derived_data = kept / 'DerivedData'
    if reason:
        remove(derived_data)
    else:
        # Steps after the build add to and remove from the app bundle in Products (the OptChat
        # Chief, the notices, the Iroh stub). The bundle is rebuilt each time (link, copy, sign:
        # no compile), so nothing a step or an earlier tip put in it can ship again.
        for bundle in sorted((derived_data / 'Build' / 'Products').glob('*/*.app')):
            remove(bundle)
    derived_data.mkdir(parents=True, exist_ok=True)
    head = git(workspace, 'rev-parse', 'HEAD').strip()
    state = {'key': key, 'sha': head, 'built': False,
             'since_clean': 0 if reason else int(state.get('since_clean') or 0) + 1}
    kept.mkdir(parents=True, exist_ok=True)
    temporary = state_file.with_suffix('.tmp')
    temporary.write_text(json.dumps(state, sort_keys=True))
    temporary.replace(state_file)
    link(workspace / 'build-universal', derived_data)
    return ('clean', reason) if reason else ('incremental', f'{state["since_clean"]} since the last clean build')


def mark_built(workspace: Path, home: Path, runner: str) -> bool:
    """Record that the build prepared on this workspace finished, so the next one may build on it."""
    derived = workspace / 'build-universal'
    if not dedicated(runner) or not derived.is_symlink():
        return False
    state_file = derived.resolve().parent / INCREMENTAL_STATE
    if (home / STATE_ROOT / runner).resolve() not in state_file.parents:
        return False
    state = json.loads(state_file.read_text())
    state['built'] = True
    temporary = state_file.with_suffix('.tmp')
    temporary.write_text(json.dumps(state, sort_keys=True))
    temporary.replace(state_file)
    return True


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
    identity = hashlib.sha256(f'{workspace.resolve()}\n{toolchain}'.encode()).hexdigest()[:32]
    incremental = None
    if dedicated(runner):
        try:
            incremental = prepare_incremental(workspace, runner_state, identity, input_key(workspace, toolchain))
        except (OSError, ValueError, subprocess.CalledProcessError) as error:
            print(f'::warning title=NEXT Release build::kept DerivedData unusable ({error}); building from empty')
            remove(runner_state / identity / INCREMENTAL_STATE)
            remove(derived)
    if incremental:
        mode, why = incremental
        print(f'NEXT Release build: {mode} DerivedData ({why}) in {runner_state / identity}')
        if output := os.environ.get('GITHUB_OUTPUT'):
            with open(output, 'a', encoding='utf-8') as stream:
                stream.write(f'mode={mode}\n')
    else:
        # Every identity of this runner: a toolchain or path change must not leave
        # an older build database behind for a later revision to link back.
        for retained in sorted(runner_state.glob('*/DerivedData*')):
            remove(retained)
        derived.mkdir()
        print(f'NEXT Release build starts from empty DerivedData; package checkouts and compilation cache: {runner_state / identity}')
    link(workspace / '.spm-cache', runner_state / identity / 'SourcePackages')
    link(derived / 'CompilationCache.noindex', runner_state / identity / 'CompilationCache')
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
    if len(argv) == 2 and argv[1] == 'mark-built':
        if mark_built(workspace, Path.home(), os.environ.get('RUNNER_NAME', '')):
            print('NEXT Release build finished; the next build on this builder may build on its DerivedData')
        return 0
    print('usage: nightly_build_state.py prepare TRACK | mark-built', file=sys.stderr)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv))
