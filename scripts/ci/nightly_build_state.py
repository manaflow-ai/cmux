#!/usr/bin/env python3
"""Retain NEXT's Release build database, packages and identical input mtimes.

Checkout may clean the workspace; state lives outside it, scoped to the runner,
source path and toolchain. Published bundles are still rebuilt and verified from
this revision. Only byte-identical inputs regain the time the prior build saw.
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

import e2e_warm_derived_data as warm

MANIFEST = 'cmux-nightly-inputs.json'
GENERATED_INPUTS = (
    'Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/Resources/agent-pane',
    'Packages/macOS/CmuxNext/Sources/CmuxNextPages/Resources/pages',
    'Packages/macOS/CmuxNext/Sources/CmuxNextAgentActivity/Resources/agent-activity',
    'Packages/macOS/CmuxNext/Sources/CmuxNextPalette/Resources/palette-ranker.js',
    'Resources/markdown-viewer/webviews-app',
    'GhosttyKit.xcframework',
)


def owned(runner: str) -> bool:
    return re.fullmatch(r'[a-zA-Z0-9._-]+-glaeda(?:-[0-9]+)?', runner) is not None


def link(path: Path, target: Path) -> None:
    target.mkdir(parents=True, exist_ok=True)
    if path.is_symlink() and path.resolve() == target.resolve():
        return
    if path.is_symlink() or path.is_file():
        path.unlink()
    elif path.exists():
        shutil.rmtree(path)
    path.symlink_to(target, target_is_directory=True)


def prepare(workspace: Path, home: Path, runner: str, track: str, toolchain: str) -> bool:
    if not owned(runner) or track != 'nightly-next':
        return False
    identity = hashlib.sha256(f'{workspace.resolve()}\n{toolchain}'.encode()).hexdigest()[:32]
    state = home / 'Library/Caches/cmux-nightly-next' / runner / identity
    link(workspace / 'build-universal', state / 'DerivedData')
    link(workspace / '.spm-cache', state / 'SourcePackages')
    if output := os.environ.get('GITHUB_OUTPUT'):
        with open(output, 'a') as stream:
            stream.write('enabled=true\n')
    print(f'Using persistent NEXT Release state: {state}')
    return True


def input_paths(workspace: Path) -> set[str]:
    included = warm.tracked_paths(workspace)
    if included is None:
        raise ValueError('nightly input state requires a Git checkout')
    for relative in GENERATED_INPUTS:
        root = workspace / relative
        paths = [root]
        if root.is_dir() and not root.is_symlink():
            paths.extend(root.rglob('*'))
        for path in paths:
            if path.is_symlink() or not path.exists():
                continue
            name = path.relative_to(workspace).as_posix()
            included.add(name + '/' if path.is_dir() else name)
            included.update('/'.join(name.split('/')[:i]) + '/' for i in range(1, len(name.split('/'))))
    return included


def snapshot(workspace: Path, included: set[str]) -> dict[str, list]:
    result = {}
    for relative in sorted(included):
        path = workspace / relative
        if path.is_symlink():
            continue
        if relative.endswith('/') and path.is_dir():
            result[relative] = [warm.listing(path, workspace, included), path.stat().st_mtime_ns]
        elif path.is_file():
            result[relative] = [warm.digest(path), path.stat().st_mtime_ns]
    return result


def inputs(workspace: Path, mode: str) -> None:
    derived = workspace / 'build-universal'
    # Hosted builds and classic NIGHTLY retain their existing cache behavior.
    if not derived.is_symlink() or not (workspace / '.spm-cache').is_symlink():
        return
    manifest = derived / MANIFEST
    included = input_paths(workspace)
    if mode == 'replay':
        try:
            recorded = json.loads(manifest.read_text()) if manifest.is_file() else {}
        except (OSError, ValueError):
            print('NEXT input manifest unavailable; dating all inputs now')
            recorded = {}
        restored = changed = 0
        for relative in sorted(included, key=lambda item: (item.endswith('/'), item)):
            path = workspace / relative
            if path.is_symlink() or not path.exists():
                continue
            entry = recorded.get(relative)
            digest = warm.listing(path, workspace, included) if relative.endswith('/') else warm.digest(path)
            if entry is not None and entry[0] == digest:
                os.utime(path, ns=(entry[1], entry[1]))
                restored += 1
            elif not relative.endswith('/'):
                os.utime(path)
                changed += 1
        print(f'Reused times for {restored} identical NEXT inputs; {changed} changed or new')
    if mode == 'record':
        temporary = manifest.with_suffix('.tmp')
        temporary.write_text(json.dumps(snapshot(workspace, included), sort_keys=True))
        temporary.replace(manifest)


def main(argv: list[str]) -> int:
    workspace = Path(os.environ.get('GITHUB_WORKSPACE', '.')).resolve()
    if len(argv) == 3 and argv[1] == 'prepare':
        runner = os.environ.get('RUNNER_NAME', '')
        if owned(runner) and argv[2] == 'nightly-next':
            toolchain = os.environ.get('DEVELOPER_DIR', '') + '\n'
            toolchain += subprocess.check_output(['xcodebuild', '-version'], text=True)
            toolchain += subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-build-version'], text=True)
            prepare(workspace, Path.home(), runner, argv[2], toolchain)
        return 0
    if len(argv) == 2 and argv[1] in {'replay', 'record'}:
        inputs(workspace, argv[1])
        return 0
    print('usage: nightly_build_state.py prepare TRACK | replay | record', file=sys.stderr)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv))
