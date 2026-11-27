#!/usr/bin/env python3
"""Check that a SourcePackages directory holds every binary artifact its packages need, and resolve again if not.

xcodebuild reads binary targets (Iroh, Sentry-Dynamic, WebRTC) from the absolute paths SwiftPM wrote into
SourcePackages/workspace-state.json. A SourcePackages tree copied from another directory keeps those paths, so a
build reads the artifacts of the tree it was copied from. The nightly host build root's tree was seeded from one
runner slot's (nightly_build_state.py seed_packages), and when that slot's own tree lost its artifacts every slot
of the Mac failed with "There is no XCFramework found at .../cmux7s-mac-mini-glaeda-nightly-only-2/.../
SourcePackages/artifacts/iroh-ffi/Iroh/Iroh.xcframework" (run 43304572615, runner -5).

Before the build this lists every binary artifact the packages in play declare, read from their Package.swift
files rather than from workspace-state.json (the seed drops that file, and Package.resolved pins only remote
packages): the local packages the Xcode project references (--xcodeproj) and every local package they reach by
`.package(path:)`, the checkout of each pin in Package.resolved (or every checkout under SOURCE_PACKAGES/checkouts
when no pin is read), and any dependency workspace-state.json still names. A `.binaryTarget(name:, url:)` (or a
`path:` to a .zip) is expected at SOURCE_PACKAGES/artifacts/<identity>/<name>/<name>.xcframework, where identity is
the package directory's lowercased name (artifacts/{iroh-ffi/Iroh, cmuxvncwebrtc/WebRTC, cmuxnext/CCmuxAppFFI}); a
`.binaryTarget(name:, path:)` to an xcframework is expected in the package's own tree. A manifest that declares one
target in more than one way takes one of them when SwiftPM evaluates it (iroh-ffi: `path:` where a locally built
xcframework is in the checkout, else the release zip by `url:`), so such a target is in place when one of its
places holds it, and a missing one is asked for where a resolve puts it. It also checks every artifact
workspace-state.json records. One that is missing, or recorded outside SOURCE_PACKAGES/artifacts, drops
workspace-state.json and artifacts/ (the checkouts stay, so nothing is cloned again) and runs RESOLVE_CMD
(`xcodebuild -resolvePackageDependencies` with the build's -clonedSourcePackagesDirPath), then checks again.

Usage: spm_artifact_preflight.py SOURCE_PACKAGES [--resolved PACKAGE_RESOLVED]... [--xcodeproj XCODEPROJ]...
       [--package PACKAGE_DIR]... [-- RESOLVE_CMD...]
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
# A binary target: its name, `url` or `path`, and the path when it is a string literal. A `url:` one (or a `path:` to a
# .zip) is unpacked into artifacts/; a `path:` to an xcframework stays in the package's own tree.
BINARY_TARGET = re.compile(r'\.binaryTarget\(\s*name:\s*"([^"]+)"\s*,\s*(url|path):\s*(?:"([^"]*)")?')
# A local package dependency, `.package(path: "../X")` or `.package(name: "X", path: "../X")`.
LOCAL_PACKAGE = re.compile(r'\.package\(\s*(?:name:\s*"[^"]*"\s*,\s*)?path:\s*"([^"]+)"')
# A local package an Xcode project references: `relativePath = Packages/macOS/CmuxNext;` in its
# XCLocalSwiftPackageReference.
XCODE_LOCAL_PACKAGE = re.compile(
    r'isa\s*=\s*XCLocalSwiftPackageReference;[^}]*?relativePath\s*=\s*("(?:[^"\\]|\\.)*"|[^;\s]+);', re.S)


def read_json(path: Path) -> dict:
    try:
        data = json.loads(path.read_text())
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def manifest(package_dir: Path) -> str:
    try:
        return (package_dir / 'Package.swift').read_text()
    except OSError:
        return ''


def strip_comments(text: str) -> str:
    text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
    # Whole-line comments only: a trailing `//` match would cut a URL ("https://...") in half.
    return re.sub(r'(?m)^\s*//.*$', '', text)


def binary_targets(package_dir: Path) -> list[tuple[str, str, str]]:
    """(name, 'url' or 'path', literal path or '') of each binary target the package's manifest declares."""
    return BINARY_TARGET.findall(strip_comments(manifest(package_dir)))


def local_dependencies(package_dir: Path) -> list[Path]:
    return [(package_dir / path).resolve() for path in LOCAL_PACKAGE.findall(strip_comments(manifest(package_dir)))]


def xcode_local_packages(xcodeproj: Path) -> list[Path]:
    try:
        text = (xcodeproj / 'project.pbxproj').read_text()
    except OSError:
        return []
    return [(xcodeproj.parent / path.strip('"')).resolve() for path in XCODE_LOCAL_PACKAGE.findall(text)]


def local_packages(roots: list[Path]) -> list[Path]:
    """ROOTS (package directories, or Xcode projects standing for their local package references) and every local
    package they reach by `.package(path:)`."""
    seen: list[Path] = []
    pending = [package_dir for root in roots
               for package_dir in (xcode_local_packages(root) if root.suffix == '.xcodeproj' else [root.resolve()])]
    while pending:
        package_dir = pending.pop(0)
        if package_dir in seen or not (package_dir / 'Package.swift').is_file():
            continue
        seen.append(package_dir)
        pending.extend(local_dependencies(package_dir))
    return seen


def checkout_name(location: str) -> str:
    name = location.rstrip('/').rsplit('/', 1)[-1]
    return name[:-4] if name.endswith('.git') else name


def expected_place(declared: dict[Path, str], artifacts: Path) -> Path:
    """Where one binary target's xcframework is expected, of the places its declarations name: the first that holds
    it; when none does, the one under ARTIFACTS, which a resolve fills (a place in a package's own tree it does
    not); else the first."""
    for place in declared:
        if place.is_dir():
            return place
    for place in declared:
        if artifacts in place.parents:
            return place
    return next(iter(declared))


def expected_artifacts(source_packages: Path, resolved_files: list[Path],
                       local_roots: list[Path] | None = None) -> dict[Path, str]:
    """Every binary target xcframework the packages in play need, mapped to why it is expected. LOCAL_ROOTS are
    local package directories or Xcode projects (read for their local package references)."""
    expected: dict[Path, str] = {}
    artifacts = source_packages / 'artifacts'
    packages: list[tuple[str, Path]] = [(package_dir.name.lower(), package_dir)
                                        for package_dir in local_packages(local_roots or [])]
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
    pinned = False
    for resolved in resolved_files:
        for pin in read_json(resolved).get('pins') or []:
            identity = str(pin.get('identity') or '').lower()
            location = str(pin.get('location') or '')
            if identity and location:
                pinned = True
                packages.append((identity, source_packages / 'checkouts' / checkout_name(location)))
    if not pinned:
        # No pin to go by: every checked-out remote package is in play.
        checkouts = source_packages / 'checkouts'
        if checkouts.is_dir():
            packages.extend((checkout.name.lower(), checkout) for checkout in sorted(checkouts.iterdir())
                            if (checkout / 'Package.swift').is_file())
    for identity, package_dir in packages:
        # One target name, each place a declaration of it puts the xcframework: more than one when the manifest
        # selects between declarations (see the module's text).
        places: dict[str, dict[Path, str]] = {}
        for target, kind, path in binary_targets(package_dir):
            if kind == 'path' and path and not path.endswith('.zip'):
                places.setdefault(target, {}).setdefault(
                    package_dir / path, f'{identity} declares binary target {target} at {path}')
            elif kind == 'url' or path:
                places.setdefault(target, {}).setdefault(
                    artifacts / identity / target / f'{target}.xcframework',
                    f'{identity} declares binary target {target}')
        for declared in places.values():
            place = expected_place(declared, artifacts)
            expected.setdefault(place, declared[place])
    return expected


def problems(source_packages: Path, resolved_files: list[Path], local_roots: list[Path] | None = None,
             needed: dict[Path, str] | None = None) -> list[str]:
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
    expected = {**(needed or {}), **expected_artifacts(source_packages, resolved_files, local_roots)}
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
    parser.add_argument('--xcodeproj', type=Path, action='append', default=[],
                        help='an Xcode project whose local package references are read')
    parser.add_argument('--package', type=Path, action='append', default=[], help='a local package directory')
    args = parser.parse_args(argv)
    source_packages: Path = args.source_packages
    roots = [*args.package, *args.xcodeproj]
    if not source_packages.is_dir():
        print(f'Swift package artifacts: {source_packages} does not exist yet; the build resolves it')
        return 0
    found = problems(source_packages, args.resolved, roots)
    if not found:
        print(f'Swift package artifacts: every binary artifact is in place under {source_packages}')
        return 0
    for problem in found:
        print(f'::warning title=Swift package artifacts::{problem}')
    needed = expected_artifacts(source_packages, args.resolved, roots)
    drop_artifact_state(source_packages)
    if not resolve_cmd:
        print('Swift package artifacts: dropped the artifact state; the build resolves it again')
        return 0
    print(f'Swift package artifacts: resolving again: {" ".join(resolve_cmd)}', flush=True)
    status = subprocess.run(resolve_cmd).returncode
    still = problems(source_packages, args.resolved, roots, needed)
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
