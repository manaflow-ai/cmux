#!/usr/bin/env python3
"""Transport one run's macOS Debug Swift test/runtime products, never compiler caches.

The build command is `swift build --build-tests` in Packages/macOS/CmuxNext.
Restore validates the producer digest and full source/toolchain/profile identity
before relocating runtime source paths and re-signing modified Mach-O products.
An unavailable or incompatible artifact is an error, never a second build.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import io
import json
import os
import platform
import posixpath
import shutil
import subprocess
import tarfile
import tempfile
from pathlib import Path

PACKAGE = 'Packages/macOS/CmuxNext'
MANIFEST = '.cmux-shared-swift-products.json'
PROFILE = 'macos-debug-unfiltered-build-tests-v1'

spec = importlib.util.spec_from_file_location('fleet_products', Path(__file__).with_name('fleet-test-products.py'))
fleet = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fleet)


def read(*args: str, cwd: Path) -> str:
    return subprocess.check_output(args, cwd=cwd, text=True, timeout=60).strip()


def identity(root: Path) -> dict:
    flags = {key: os.environ.get(key, '') for key in ('CMUX_LIVE_CODE_BUILD', 'CMUX_SWIFTPM_TARGET_LINUX')}
    if any(value == '1' for value in flags.values()):
        raise ValueError('shared products require the normal macOS package graph')
    return {
        'version': 1, 'profile': PROFILE, 'package': PACKAGE,
        'sha': read('git', 'rev-parse', 'HEAD', cwd=root),
        'tree': read('git', 'rev-parse', 'HEAD^{tree}', cwd=root),
        'run': os.environ['GITHUB_RUN_ID'],
        'repository': os.environ['GITHUB_REPOSITORY'],
        'xcode': read('xcodebuild', '-version', cwd=root),
        'swift': read('swift', '-version', cwd=root),
        'sdk': read('xcrun', '--sdk', 'macosx', '--show-sdk-build-version', cwd=root),
        # Test bundles link XCTest/Testing at this absolute installation path.
        'developer': os.environ.get('DEVELOPER_DIR') or read('xcode-select', '-p', cwd=root),
        'architecture': platform.machine(), 'flags': flags,
    }


def validate(receipt: dict, expected: dict) -> None:
    for key, value in expected.items():
        if receipt.get(key) != value:
            raise ValueError(f'shared Swift products {key} mismatch')
    if receipt.get('profile') != PROFILE or receipt.get('package') != PACKAGE:
        raise ValueError('unexpected shared Swift product profile')
    for field in ('source_root', 'build_root'):
        if not isinstance(receipt.get(field), str) or not receipt[field].startswith('/'):
            raise ValueError(f'invalid producer {field}')


def digest(path: Path) -> str:
    result = hashlib.sha256()
    with path.open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            result.update(chunk)
    return result.hexdigest()


def runtime_entries(build: Path) -> list[str]:
    # SwiftPM describes test binaries in description.json; executables are also
    # needed by the action/settings generators. Object files and modules are
    # compiler caches, not runtime products, and are deliberately not shipped.
    entries = sorted(p.name for p in build.iterdir() if (
        p.suffix in ('.xctest', '.bundle', '.framework', '.dylib')
        or (p.is_file() and not p.is_symlink())
    ))
    if not any(name.endswith('.xctest') for name in entries):
        raise ValueError('build produced no XCTest bundle')
    if 'description.json' not in entries:
        raise ValueError('build produced no SwiftPM description')
    return entries


def checked_members(tar: tarfile.TarFile, entries: list[str]) -> list[tarfile.TarInfo]:
    if not entries or any(not n or '/' in n or n in ('.', '..', MANIFEST) for n in entries):
        raise ValueError('invalid product entries')
    allowed = set(entries) | {MANIFEST}
    members = tar.getmembers()
    names = set()
    links = set()
    for member in members:
        name = member.name
        if (name in names or name.startswith('/') or '..' in name.split('/')
                or name.split('/')[0] not in allowed):
            raise ValueError(f'unsafe product path: {name}')
        names.add(name)
        if member.issym():
            target = posixpath.normpath(posixpath.join(posixpath.dirname(name), member.linkname))
            if member.linkname.startswith('/') or target.split('/')[0] not in allowed or target.startswith('../'):
                raise ValueError(f'unsafe product symlink: {name}')
            links.add(name)
        elif not (member.isfile() or member.isdir()):
            raise ValueError(f'unsupported product member: {name}')
    for name in names:
        parts = name.split('/')
        if any('/'.join(parts[:i]) in links for i in range(1, len(parts))):
            raise ValueError(f'product nested under symlink: {name}')
    if not set(entries).issubset(names):
        raise ValueError('incomplete products archive')
    return members


def pack(root: Path, archive: Path, current: dict) -> None:
    build = root / PACKAGE / '.build' / (current['architecture'] + '-apple-macosx') / 'debug'
    entries = runtime_entries(build)
    receipt = {**current, 'source_root': str(root.resolve()), 'producer_attempt': os.environ['GITHUB_RUN_ATTEMPT'], 'entries': entries, 'build_root': str(build.resolve())}
    archive.parent.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive, 'w:gz') as tar:
        data = json.dumps(receipt, sort_keys=True).encode()
        member = tarfile.TarInfo(MANIFEST)
        member.size = len(data)
        tar.addfile(member, io.BytesIO(data))
        for name in entries:
            tar.add(build / name, arcname=name)
    # Validate our own runtime closure, including framework symlinks, before upload.
    with tarfile.open(archive) as tar:
        checked_members(tar, entries)
    with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
        output.write(f'artifact_name=cmux-swift-products-{current["run"]}-{receipt["producer_attempt"]}\n')
        output.write(f'sha256={digest(archive)}\n')


def restore(root: Path, archive: Path, sha256: str, current: dict) -> None:
    if len(sha256) != 64 or digest(archive) != sha256:
        raise ValueError('shared Swift products archive digest mismatch')
    with tempfile.TemporaryDirectory(prefix='cmux-swift-products-') as tmp:
        stage = Path(tmp)
        with tarfile.open(archive) as tar:
            first = tar.next()
            if first is None or first.name != MANIFEST or not first.isfile() or first.size > 1024 * 1024:
                raise ValueError('missing shared Swift products manifest')
            receipt = json.load(tar.extractfile(first))
            validate(receipt, current)
            members = checked_members(tar, receipt['entries'])
            extra = {'filter': 'tar'} if hasattr(tarfile, 'tar_filter') else {}
            tar.extractall(stage, members=members, **extra)
        build_root = root / PACKAGE / '.build'
        build = build_root / (current['architecture'] + '-apple-macosx') / 'debug'
        link = build_root / 'debug'
        if link.exists() and not link.is_symlink():
            raise ValueError('SwiftPM debug path is not its expected product symlink')
        build.mkdir(parents=True, exist_ok=True)
        alias = fleet.alias_for(receipt['source_root'], root)
        edited, machos = fleet.relocate(stage, receipt['source_root'].encode(), alias.encode())
        # Owned Mac jobs can compile through a .build symlink into their warm
        # scratch directory. Bundle.module embeds that physical build path too.
        if not receipt['build_root'].startswith(receipt['source_root'] + '/'):
            build_alias = fleet.alias_for(receipt['build_root'], build.resolve())
            build_edited, build_machos = fleet.relocate(stage, receipt['build_root'].encode(), build_alias.encode())
            edited += build_edited
            machos.extend(build_machos)
        for target in sorted({fleet.bundle_of(p, stage) for p in machos}):
            subprocess.run(['/usr/bin/codesign', '--force', '--deep', '--sign', '-', str(target)], check=True)
        for name in receipt['entries']:
            dest = build / name
            if dest.is_symlink() or dest.is_file():
                dest.unlink()
            elif dest.exists():
                shutil.rmtree(dest)
            shutil.move(str(stage / name), str(dest))
        if link.is_symlink():
            link.unlink()
        if not link.exists():
            link.symlink_to(f'{current["architecture"]}-apple-macosx/debug')
        with open(os.environ["GITHUB_OUTPUT"], "a") as output:
            output.write("restored=true\n")
        print(f'SHARED_SWIFT_PRODUCTS sha={current["sha"]} producer_attempt={receipt["producer_attempt"]} entries={len(receipt["entries"])} relocated={edited} compiled=0')


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=('pack', 'restore'))
    parser.add_argument('--archive', type=Path, required=True)
    parser.add_argument('--sha256', default='')
    args = parser.parse_args()
    root = Path(read('git', 'rev-parse', '--show-toplevel', cwd=Path.cwd())).resolve()
    current = identity(root)
    if args.mode == 'pack':
        pack(root, args.archive, current)
    else:
        restore(root, args.archive, args.sha256, current)


if __name__ == '__main__':
    main()
