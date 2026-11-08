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
each new tip on it. Every runner of the dedicated nightly-only minis (`<host>-glaeda-nightly-only-K`) does
the same through the Mac's host build root (below). An incremental build is a real compile of every changed file. It
starts clean (CLEAN_REASONS) when:
- the last build on it did not finish (no `mark-built` after `prepare`);
- the key changed: the toolchain (Xcode, SDK, DEVELOPER_DIR) or a lockfile, toolchain
  pin or submodule commit (KEY_PATHS). A Cargo.lock is not one: the Release build's cargo
  phases (Build Diff Sidecar, Bundle optchat-chief, Bundle cmux-mobile-host) list their lockfiles
  as inputs and build separate executables into Resources/bin, so Xcode reruns them and cargo
  rebuilds incrementally; the Rust the Swift code links is a pinned binary (Package.swift,
  Package.resolved); and the nightly bundles cmux-tui after the build (CMUX_NEXT_TUI_MODE=deferred). Three of the last five builder runs started clean on a
  cmux-tui Cargo.lock change alone;
- a file that shapes modules or linking changed since the last built commit
  (STRUCTURE_PATHS: Package.swift, *.pbxproj, *.xcconfig, *.modulemap, ...), or an
  import or include line was added or removed in a source file. That is the case the
  2026-10-18 audit found: objects that were not recompiled after an import set changed
  kept stale autolink and force-load data;
- the downloads a build embeds by pin (CEF, GhosttyKit) changed: their manifests and
  scripts are in KEY_PATHS, the GhosttyKit pin is the ghostty submodule commit;
- CLEAN_EVERY incremental builds ran since the last clean one.

One build root per host (prepare-host, finish-host). Xcode's compilation cache keys hold the
absolute source, DerivedData and package checkout paths, so a kept DerivedData and cache per
runner slot gave each slot its own keys: two slots per Mac built every other or every fourth tip
each, their entries pushed each other out of the one size-capped CAS, and an incremental build
compared against that slot's last build several tips back. The Release build step
(app-host-build-root.sh) therefore builds from HOST_ROOT/src, a clone of the checkout, into
HOST_ROOT/DerivedData with the packages in HOST_ROOT/SourcePackages, under a flock that is never
waited for; a held lock builds on the slot's own state as before. The clean rules are the same
ones, judged against the host's last build. The paths are the same on every nightly Mac, so the
keys match across them too.
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
from typing import Mapping

STATE_ROOT = 'Library/Caches/cmux-nightly-next'
# Measured over 199 consecutive nightly-next promotions (2026-10-24..27): 84 changed no
# KEY_PATHS or STRUCTURE_PATHS file and no import line, so about 58% of builds start clean
# on their own and a run of more than 10 incremental builds is rare (0.42^10). CLEAN_EVERY
# bounds that tail anyway: every 10th build is clean (a clean one, then at most 9 incremental).
CLEAN_EVERY = 10
INCREMENTAL_STATE = 'incremental.json'
KEY_PATHS = re.compile(r'(^|/)(Package\.resolved|build\.zig\.zon|rust-toolchain(\.toml)?|\.xcode-version'
                       r'|cef-manifest\.json|ensure-cef\.sh|ensure-remote-browser-host\.sh|download-prebuilt-ghosttykit\.sh'
                       r'|nightly-swift-defines\.sh|run-xcodebuild-with-diagnostics\.sh|fleet-compilation-cache\.sh'
                       r'|app-build-release\.sh|app-host-build-root\.sh|compilation-cache\.sh)$')
# The build's own settings: the Release build step's text (its xcodebuild settings and how it forms
# OTHER_SWIFT_FLAGS) and the decide outputs it reads (BUILD_SETTINGS in the environment of the
# prepare step). A change to either is a clean build: objects compiled under other -D flags,
# architectures or settings are never reused.
BUILD_WORKFLOW = '.github/workflows/nightly.yml'
BUILD_STEP = '      - name: Build nightly app (Release)\n'
BUILD_SETTINGS = ('SWIFT_IMPORT_FLAGS', 'IMPORT_VARIANT', 'EMPTY_BROWSER_SOURCES', 'NIGHTLY_COMPILE_ARCHS',
                  'CHANNEL_ICON_NAME', 'NIGHTLY_FAST_BUILD')
# An import or include line added or removed in a source file: the import set changes, the audited
# case for stale autolink and force-load data in objects that were not recompiled. A changed
# conditional-compilation line (#if, #elseif, #else, #endif, #ifdef, #ifndef, #elif) counts too: it can
# switch an unchanged import line in or out.
IMPORT_SOURCES = ('*.swift', '*.h', '*.hh', '*.hpp', '*.hxx', '*.inc', '*.def', '*.m', '*.mm', '*.c', '*.cc',
                  '*.cpp', '*.cxx', '*.modulemap', '*.apinotes')
IMPORT_LINE = re.compile(r'^[+-](?![+-]).*\bimport\s|^[+-]\s*#\s*(import|include|include_next)\b'
                         r'|^[+-]\s*@import\b'
                         r'|^[+-](?![+-])\s*#\s*(if|ifdef|ifndef|elif|elseif|else|endif)\b')
STRUCTURE_PATHS = re.compile(r'(^|/)(Package\.swift|[^/]+\.pbxproj|[^/]+\.xcconfig|[^/]+\.modulemap'
                             r'|[^/]+\.xcscheme|[^/]+\.entitlements|[^/]+\.xcfilelist)$')
# Top-level trees the Release app build never reads (no project or package in it references them), so
# a change there leaves the kept DerivedData valid.
OUTSIDE_APP_BUILD = ('Prototypes/',)
# A Swift package's Tests/ tree holds its test targets and the support targets only they link
# (tests/test_nightly_build_state.py checks every Package.swift for that). The Release build of the
# app scheme compiles none of them, so an import or a structure line there leaves the kept
# DerivedData valid: run 41570134320 compiled clean for 562 s on an import change in
# Packages/Shared/CmuxMessagesLab/Tests/MessagesLabHomeTests/HomeAgentMessageAvatarTests.swift.
PACKAGE_TESTS = re.compile(r'^Packages/[^/]+/[^/]+/Tests/')
PACKAGE_TESTS_GLOB = ':(exclude,glob)Packages/*/*/Tests/**'


def outside_app_build(name: str) -> bool:
    return name.startswith(OUTSIDE_APP_BUILD) or PACKAGE_TESTS.match(name) is not None
NOTICES_CACHE = 'notices-crates'
NOTICES_CACHE_MAX_BYTES = 8 << 30


def owned(runner: str) -> bool:
    # A Glaeda mini runner (<member>-glaeda[-K]) or the dedicated nightly-next
    # builder (cmux22-nightly-next, plans/cmux-next/nightly-builder-DESIGN.md),
    # whose admission hook runs only this build. Without it the dedicated
    # builder compiled every head cold (425 cache misses, xcodebuild 505 s
    # against 254 s on cmux15, run 39396919366).
    return re.fullmatch(r'[a-zA-Z0-9._-]+-(?:glaeda(?:-[0-9]+)?|nightly-next)', runner) is not None


def nightly_only(runner: str) -> bool:
    """A runner of the dedicated nightly-only M4 Pro minis (<member>-glaeda-nightly-only-K)."""
    return re.fullmatch(r'[a-zA-Z0-9._-]+-glaeda-nightly-only-[0-9]+', runner) is not None


def dedicated(runner: str) -> bool:
    """The dedicated nightly-next builder's runner (its hand-made or glaeda-managed name), or any runner of the
    nightly-only minis. Those took the warm path only through a builder label the picker offered after reading
    the runners, and that read failed (HTTP 403, the routing App's spent budget) in four of six nightly-next runs
    (41586556429, 41570134320, ...): each restored the compilation cache and Swift packages from R2 (280-320 s)
    and compiled cold. Every nightly-only slot now builds in the Mac's one host build root
    (app-host-build-root.sh, under a never-waited lock), so a mini still holds one kept DerivedData, whichever
    slot builds; a slot keeps its own only after a build that overlapped another on the same Mac, and its next
    host-root build deletes it (finish_host)."""
    return re.fullmatch(r'[a-zA-Z0-9._-]+-nightly-next', runner) is not None or nightly_only(runner)


def keeps_state(runner: str) -> bool:
    return owned(runner) or dedicated(runner)


def git(workspace: Path, *args: str) -> str:
    return subprocess.run(['git', '-C', str(workspace), *args], check=True, capture_output=True, text=True).stdout


def build_step(workspace: Path) -> str:
    """The Release build step's text in the workflow at HEAD, or the whole workflow when the step
    cannot be found (so a renamed step is a clean build, never a missed change)."""
    text = git(workspace, 'show', f'HEAD:{BUILD_WORKFLOW}')
    start = text.find(BUILD_STEP)
    if start < 0 or text.find(BUILD_STEP, start + 1) >= 0:
        return text
    end = text.find('\n      - name: ', start + len(BUILD_STEP))
    return text[start:] if end < 0 else text[start:end]


def input_key(workspace: Path, toolchain: str, env: Mapping[str, str] | None = None) -> str:
    """The toolchain, the build's settings (build_step and BUILD_SETTINGS) and every lockfile,
    toolchain pin and submodule commit at HEAD."""
    env = os.environ if env is None else env
    settings = [f'{name}={env.get(name, "")}' for name in BUILD_SETTINGS]
    pins = [hashlib.sha256(build_step(workspace).encode()).hexdigest(), *settings]
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
    changed = next((name for name in names
                    if STRUCTURE_PATHS.search(name) and not outside_app_build(name)), '')
    if changed:
        return changed
    try:
        diff = git(workspace, 'diff', '-U0', '--no-renames', since, 'HEAD', '--', *IMPORT_SOURCES,
                   *(f':(exclude){tree}' for tree in OUTSIDE_APP_BUILD), PACKAGE_TESTS_GLOB)
    except subprocess.CalledProcessError:
        return None
    current = ''
    for line in diff.splitlines():
        if line.startswith('+++ b/'):
            current = line[6:]
        elif IMPORT_LINE.search(line):
            return f'an import or a conditional-compilation line in {current or "a source file"}'
    return ''


def checkpoint_complete(state: dict) -> bool:
    """Whether the kept state has every field, each of its type: key and sha strings, built a bool and
    since_clean a non-negative count. Anything else is a clean build."""
    count = state.get('since_clean')
    return (isinstance(state.get('key'), str) and isinstance(state.get('sha'), str)
            and isinstance(state.get('built'), bool)
            and isinstance(count, int) and not isinstance(count, bool) and count >= 0)


def since_clean(state: dict) -> int:
    """The state's count of incremental builds since a clean one (0 when it is not a complete checkpoint)."""
    return state['since_clean'] if checkpoint_complete(state) else 0


def read_state(state_file: Path) -> dict:
    """The kept build state, or {} when it is missing, unreadable or not a JSON object (a clean build)."""
    try:
        state = json.loads(state_file.read_text())
    except (OSError, ValueError):
        return {}
    return state if isinstance(state, dict) else {}


def clean_reason(state: dict, key: str, workspace: Path) -> str:
    """Why this build must start clean, or '' to build incrementally."""
    if not state:
        return 'no earlier build on this builder'
    if not checkpoint_complete(state):
        return 'the kept build state is malformed'
    if state['built'] is not True:
        return 'the last build did not finish'
    if state.get('key') != key:
        return 'the toolchain, a lockfile or a submodule changed'
    changed = structure_changed(workspace, str(state.get('sha') or ''))
    if changed is None:
        return 'the last built commit cannot be compared'
    if changed:
        return f'{changed} changed (module or link structure)'
    if since_clean(state) + 1 >= CLEAN_EVERY:
        return f'every {CLEAN_EVERY}th build is clean ({CLEAN_EVERY - 1} incremental since the last clean one)'
    return ''


def prepare_incremental(workspace: Path, runner_state: Path, identity: str, key: str) -> tuple[str, str]:
    """Link build-universal to the kept DerivedData; returns (mode, reason)."""
    kept = runner_state / identity
    state_file = kept / INCREMENTAL_STATE
    state = read_state(state_file)
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
             'since_clean': 0 if reason else since_clean(state) + 1}
    kept.mkdir(parents=True, exist_ok=True)
    temporary = state_file.with_suffix('.tmp')
    temporary.write_text(json.dumps(state, sort_keys=True))
    temporary.replace(state_file)
    link(workspace / 'build-universal', derived_data)
    return ('clean', reason) if reason else ('incremental', f'{state["since_clean"]} since the last clean build')


def mark_built(workspace: Path, home: Path, runner: str) -> bool:
    """Record that the build prepared on this workspace finished, so the next one may build on it (the workflow
    step runs only when prepare chose a mode)."""
    derived = workspace / 'build-universal'
    if not dedicated(runner) or not derived.is_symlink():
        return False
    state_file = derived.resolve().parent / INCREMENTAL_STATE
    if (home / STATE_ROOT / runner).resolve() not in state_file.parents:
        return False
    state = read_state(state_file)
    if not checkpoint_complete(state):
        return False
    state['built'] = True
    temporary = state_file.with_suffix('.tmp')
    # Best effort: a write that fails leaves the checkpoint unfinished, so the next build is clean.
    try:
        temporary.write_text(json.dumps(state, sort_keys=True))
        temporary.replace(state_file)
    except OSError as error:
        print(f'::warning title=nightly build state::could not mark the build finished ({error}); '
              'the next build starts clean')
        return False
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
    if not keeps_state(runner) or track != 'nightly-next':
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


HOST_STATE = 'host-state.json'


def toolchain_identity() -> str:
    toolchain = os.environ.get('DEVELOPER_DIR', '') + '\n'
    toolchain += subprocess.check_output(['xcodebuild', '-version'], text=True)
    toolchain += subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-build-version'], text=True)
    return toolchain


def seed_packages(packages: Path, workspace: Path) -> None:
    """The host's package checkouts, seeded once from this slot's own (a clone, so nothing is fetched again)."""
    if packages.exists():
        return
    slot = workspace / '.spm-cache'
    if slot.is_dir():
        staging = packages.with_name(f'{packages.name}.seed.{os.getpid()}')
        remove(staging)
        try:
            import apfs_clone
            cloned = apfs_clone.clone_directory(slot.resolve(), staging)
        except (ImportError, OSError):
            cloned = False
        try:
            if not cloned:
                shutil.copytree(slot.resolve(), staging, symlinks=True)
            staging.replace(packages)
            return
        except OSError as error:
            print(f'::warning title=nightly host build root::package checkouts not seeded ({error})')
            remove(staging)
    packages.mkdir(parents=True, exist_ok=True)


def prepare_host(root: Path, workspace: Path, toolchain: str) -> tuple[str, str]:
    """Ready ROOT/DerivedData for the tree cloned into ROOT/src; returns (mode, reason). The caller
    holds ROOT's lock."""
    src = root / 'src'
    state_file = root / HOST_STATE
    state = read_state(state_file)
    key = input_key(src, toolchain)
    reason = clean_reason(state, key, src)
    derived_data = root / 'DerivedData'
    if reason:
        remove(derived_data)
    else:
        for bundle in sorted((derived_data / 'Build' / 'Products').glob('*/*.app')):
            remove(bundle)
    derived_data.mkdir(parents=True, exist_ok=True)
    # Without the fleet cache the CAS lives in DerivedData; keep it across clean builds.
    link(derived_data / 'CompilationCache.noindex', root / 'CompilationCache')
    seed_packages(root / 'SourcePackages', workspace)
    link(src / '.spm-cache', root / 'SourcePackages')
    remove(src / 'build-universal')
    head = git(src, 'rev-parse', 'HEAD').strip()
    state = {'key': key, 'sha': head, 'built': False, 'since_clean': 0 if reason else since_clean(state) + 1}
    temporary = state_file.with_suffix('.tmp')
    temporary.write_text(json.dumps(state, sort_keys=True))
    temporary.replace(state_file)
    return ('clean', reason) if reason else ('incremental', f'{state["since_clean"]} since the last clean build')


def finish_host(root: Path, workspace: Path, home: Path, runner: str) -> None:
    """After a successful build in ROOT: mark it built, and give the workspace its own clone of the
    products (later steps change the app bundle; the host's next build must not see that). The slot's
    own kept DerivedData is dropped: the host's replaces it, and a later fallback build starts clean."""
    state_file = root / HOST_STATE
    state = read_state(state_file)
    if checkpoint_complete(state):
        state['built'] = True
        temporary = state_file.with_suffix('.tmp')
        temporary.write_text(json.dumps(state, sort_keys=True))
        temporary.replace(state_file)
    derived = workspace / 'build-universal'
    if derived.is_symlink():
        slot = derived.resolve()
        if (home / STATE_ROOT / runner).resolve() in slot.parents:
            remove(slot.parent / INCREMENTAL_STATE)
            remove(slot)
    remove(derived)
    (derived / 'Build').mkdir(parents=True)
    source = root / 'DerivedData' / 'Build' / 'Products'
    target = derived / 'Build' / 'Products'
    try:
        import apfs_clone
        cloned = apfs_clone.clone_directory(source, target)
    except ImportError:
        cloned = False
    if not cloned:
        shutil.copytree(source, target, symlinks=True)


def main(argv: list[str]) -> int:
    workspace = Path(os.environ.get('GITHUB_WORKSPACE', '.')).resolve()
    if len(argv) == 3 and argv[1] == 'prepare':
        runner = os.environ.get('RUNNER_NAME', '')
        if keeps_state(runner) and argv[2] == 'nightly-next':
            if prepare(workspace, Path.home(), runner, argv[2], toolchain_identity()):
                cache = notices_cache(Path.home(), runner)
                print(f'NEXT third-party notices read crate sources kept in {cache}')
                github_env = os.environ.get('GITHUB_ENV')
                if github_env:
                    with open(github_env, 'a', encoding='utf-8') as env:
                        env.write(f'CMUX_NEXT_NOTICES_CACHE={cache}\n')
                        if dedicated(runner):
                            # The Release build step may take the host build root (app-host-build-root.sh).
                            env.write('CMUX_NIGHTLY_HOST_BUILD_ROOT=1\n')
        return 0
    if len(argv) == 3 and argv[1] == 'prepare-host':
        mode, why = prepare_host(Path(argv[2]), workspace, toolchain_identity())
        print(f'NEXT Release build: {mode} DerivedData ({why}) in {Path(argv[2]) / "DerivedData"} (host build root)')
        # This decides the build, not the slot's own prepare line above it in the log.
        if summary := os.environ.get('GITHUB_STEP_SUMMARY'):
            with open(summary, 'a', encoding='utf-8') as stream:
                stream.write(f'### NEXT Release build\n- DerivedData: {mode} ({why}), host build root\n')
        return 0
    if len(argv) == 3 and argv[1] == 'finish-host':
        finish_host(Path(argv[2]), workspace, Path.home(), os.environ.get('RUNNER_NAME', ''))
        return 0
    if len(argv) == 2 and argv[1] == 'mark-built':
        if mark_built(workspace, Path.home(), os.environ.get('RUNNER_NAME', '')):
            print('NEXT Release build finished; the next build on this builder may build on its DerivedData')
        return 0
    print('usage: nightly_build_state.py prepare TRACK | mark-built | prepare-host ROOT | finish-host ROOT', file=sys.stderr)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv))
