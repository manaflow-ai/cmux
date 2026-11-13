#!/usr/bin/env python3
"""Check that a SourcePackages directory holds every binary artifact its packages need, and resolve again if not.

xcodebuild reads binary targets (Iroh, Sentry-Dynamic, WebRTC) from the absolute paths SwiftPM wrote into
SourcePackages/workspace-state.json. A SourcePackages tree copied from another directory keeps those paths, so a
build reads the artifacts of the tree it was copied from. The nightly host build root's tree was seeded from one
runner slot's (nightly_build_state.py seed_packages), and when that slot's own tree lost its artifacts every slot
of the Mac failed with "There is no XCFramework found at .../cmux7s-mac-mini-glaeda-nightly-only-2/.../
SourcePackages/artifacts/iroh-ffi/Iroh/Iroh.xcframework" (run 43304572615, runner -5).

Before the build this lists every binary artifact the resolved packages declare (a `.binaryTarget(name:, url:)` in
the Package.swift of each dependency in workspace-state.json and each pin in Package.resolved) and every artifact
workspace-state.json records. One that is missing, or recorded outside SOURCE_PACKAGES/artifacts, drops
workspace-state.json and artifacts/ (the checkouts stay, so nothing is cloned again) and runs RESOLVE_CMD
(`xcodebuild -resolvePackageDependencies` with the build's -clonedSourcePackagesDirPath), then checks again.

Usage: spm_artifact_preflight.py SOURCE_PACKAGES [--resolved PACKAGE_RESOLVED]... [-- RESOLVE_CMD...]
Exit 0 when every artifact is in place (after a resolve if one was needed), 1 when one is still missing.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time

STATE = 'workspace-state.json'
# A remote binary target (`url:`); a `path:` one lives in the package's own tree, not in artifacts/.
BINARY_TARGET = re.compile(r'\.binaryTarget\(\s*name:\s*"([^"]+)"\s*,\s*url:')


def read_json(path: Path) -> dict:
    try:
        data = json.loads(path.read_text())
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def binary_targets(package_dir: Path) -> list[str]:
    try:
        text = (package_dir / 'Package.swift').read_text()
    except OSError:
        return []
    return BINARY_TARGET.findall(text)


def checkout_name(location: str) -> str:
    name = location.rstrip('/').rsplit('/', 1)[-1]
    return name[:-4] if name.endswith('.git') else name


def expected_artifacts(source_packages: Path, resolved_files: list[Path]) -> dict[Path, str]:
    """Every artifact xcframework the resolved packages need, mapped to why it is expected."""
    expected: dict[Path, str] = {}
    artifacts = source_packages / 'artifacts'
    packages: list[tuple[str, Path]] = []
    state = read_json(source_packages / STATE).get('object') or {}
    for dependency in state.get('dependencies') or []:
        ref = dependency.get('packageRef') or {}
        identity = str(ref.get('identity') or '').lower()
        if not identity:
            continue
        if ref.get('kind') in ('fileSystem', 'root'):
            packages.append((identity, Path(str(ref.get('location') or ''))))
        else:
            packages.append((identity, source_packages / 'checkouts' / str(dependency.get('subpath') or identity)))
    for resolved in resolved_files:
        for pin in read_json(resolved).get('pins') or []:
            identity = str(pin.get('identity') or '').lower()
            location = str(pin.get('location') or '')
            if identity and location:
                packages.append((identity, source_packages / 'checkouts' / checkout_name(location)))
    for identity, package_dir in packages:
        for target in binary_targets(package_dir):
            expected.setdefault(artifacts / identity / target / f'{target}.xcframework',
                                f'{identity} declares binary target {target}')
    return expected


def problems(source_packages: Path, resolved_files: list[Path], needed: dict[Path, str] | None = None) -> list[str]:
    """Why the binary artifacts here cannot be built from, or [] when every one is in place. NEEDED adds
    artifacts expected before a resolve, so one that a resolve did not bring back still counts."""
    found: list[str] = []
    artifacts = (source_packages / 'artifacts').resolve()
    state = read_json(source_packages / STATE).get('object') or {}
    for artifact in state.get('artifacts') or []:
        recorded = Path(str(artifact.get('path') or ''))
        if not recorded.is_absolute():
            continue
        if artifacts not in recorded.resolve().parents:
            found.append(f'{STATE} records {recorded}, outside {artifacts}')
        elif not recorded.is_dir():
            found.append(f'{STATE} records {recorded}, which is missing')
    expected = {**(needed or {}), **expected_artifacts(source_packages, resolved_files)}
    for path, why in sorted(expected.items()):
        if not path.is_dir():
            found.append(f'{path} is missing ({why})')
    return found


def remove(path: Path) -> None:
    if path.is_symlink() or path.is_file():
        path.unlink()
    elif path.is_dir():
        stale = path.with_name(f'{path.name}.stale.{os.getpid()}.{time.time_ns()}')
        path.rename(stale)
        shutil.rmtree(stale, ignore_errors=True)


def drop_artifact_state(source_packages: Path) -> None:
    """Forget the resolved artifacts so the next resolve fetches them again; the checkouts stay."""
    remove(source_packages / STATE)
    remove(source_packages / 'artifacts')


def main(argv: list[str]) -> int:
    resolve_cmd: list[str] = []
    if '--' in argv:
        index = argv.index('--')
        argv, resolve_cmd = argv[:index], argv[index + 1:]
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('source_packages', type=Path)
    parser.add_argument('--resolved', type=Path, action='append', default=[])
    args = parser.parse_args(argv)
    source_packages: Path = args.source_packages
    if not source_packages.is_dir():
        print(f'Swift package artifacts: {source_packages} does not exist yet; the build resolves it')
        return 0
    found = problems(source_packages, args.resolved)
    if not found:
        print(f'Swift package artifacts: every binary artifact is in place under {source_packages}')
        return 0
    for problem in found:
        print(f'::warning title=Swift package artifacts::{problem}')
    needed = expected_artifacts(source_packages, args.resolved)
    drop_artifact_state(source_packages)
    if not resolve_cmd:
        print('Swift package artifacts: dropped the artifact state; the build resolves it again')
        return 0
    print(f'Swift package artifacts: resolving again: {" ".join(resolve_cmd)}', flush=True)
    status = subprocess.run(resolve_cmd).returncode
    still = problems(source_packages, args.resolved, needed)
    if status != 0 or still:
        for problem in still:
            print(f'::error title=Swift package artifacts::{problem}')
        print(f'::error title=Swift package artifacts::resolve exited {status}; binary artifacts still missing'
              if status else '::error title=Swift package artifacts::binary artifacts still missing after a resolve')
        return 1
    print('Swift package artifacts: every binary artifact is in place after the resolve')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
