#!/usr/bin/env python3
"""Build generated Swift bindings and an XCFramework in a controller Mac job.

XcodeBuildMCP has no XCFramework packaging operation; xcodebuild is used only
for this packaging step. App and simulator builds use the normal fleet tooling.
"""
import argparse
import fcntl
import hashlib
import json
from pathlib import Path
import os
import platform
import plistlib
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
RECEIPT_LAYOUT_VERSION = 2


def run(*args, env):
    subprocess.run(args, cwd=ROOT, env=env, check=True)


def create_framework(
    stage: Path,
    identifier: str,
    library: Path,
    header: Path,
    *,
    versioned: bool,
) -> Path:
    """Create a framework with the bundle layout required by its platform.

    macOS framework bundles may be versioned. iOS framework bundles are
    shallow, and Xcode's framework loader expects their binary and metadata at
    the framework root. Keeping this choice explicit also prevents a future
    slice from inheriting the macOS layout by accident.
    """
    framework = stage / identifier / 'CmuxV3NativeFFI.framework'
    contents = framework / 'Versions' / 'A' if versioned else framework
    headers_dir = contents / 'Headers'
    modules_dir = contents / 'Modules'
    resources_dir = contents / 'Resources' if versioned else None
    headers_dir.mkdir(parents=True)
    modules_dir.mkdir()
    if resources_dir is not None:
        resources_dir.mkdir()
    shutil.copy2(header, headers_dir / 'CmuxV3NativeFFI.h')
    (modules_dir / 'module.modulemap').write_text(
        'framework module CmuxV3NativeFFI {\n'
        '  umbrella header "CmuxV3NativeFFI.h"\n'
        '  export *\n'
        '  module * { export * }\n'
        '}\n'
    )
    info = {
        'CFBundleDevelopmentRegion': 'en',
        'CFBundleExecutable': 'CmuxV3NativeFFI',
        'CFBundleIdentifier': 'dev.cmux.CmuxV3NativeFFI',
        'CFBundleInfoDictionaryVersion': '6.0',
        'CFBundleName': 'CmuxV3NativeFFI',
        'CFBundlePackageType': 'FMWK',
        'CFBundleShortVersionString': '1.0',
        'CFBundleVersion': '1',
    }
    if versioned:
        assert resources_dir is not None
        (resources_dir / 'Info.plist').write_bytes(plistlib.dumps(info))
    else:
        (framework / 'Info.plist').write_bytes(plistlib.dumps(info))
    shutil.copy2(library, contents / 'CmuxV3NativeFFI')
    if versioned:
        (framework / 'Versions' / 'Current').symlink_to('A')
        for name in ('Headers', 'Modules', 'Resources', 'CmuxV3NativeFFI'):
            (framework / name).symlink_to(f'Versions/Current/{name}')
    return framework


def framework_binary_path(framework: Path, *, versioned: bool) -> Path:
    """Return the physical binary path for install_name_tool."""
    contents = framework / 'Versions' / 'A' if versioned else framework
    return contents / 'CmuxV3NativeFFI'


def framework_install_name(*, versioned: bool) -> str:
    """Return the install name matching the framework's public bundle path."""
    suffix = '/Versions/A' if versioned else ''
    return f'@rpath/CmuxV3NativeFFI.framework{suffix}/CmuxV3NativeFFI'


def copy_artifact(source: Path, destination: Path) -> None:
    """Copy an XCFramework without dereferencing framework symlinks."""
    if destination.is_symlink():
        destination.unlink()
    elif destination.exists():
        shutil.rmtree(destination)
    shutil.copytree(source, destination, symlinks=True)


def artifact_manifest(package: Path, roots: list[Path]) -> dict[str, dict[str, str]]:
    """Hash regular files and record symlink targets for receipt validation."""
    files: dict[str, str] = {}
    symlinks: dict[str, str] = {}
    for root in roots:
        paths = [root, *root.rglob('*')]
        for path in sorted(paths):
            relative = str(path.relative_to(package))
            if path.is_symlink():
                symlinks[relative] = os.readlink(path)
            elif path.is_file():
                files[relative] = hashlib.sha256(path.read_bytes()).hexdigest()
    return {'files': files, 'symlinks': symlinks}


def receipt_matches(package: Path, receipt: dict, stamp: str) -> bool:
    if receipt.get('layout') != RECEIPT_LAYOUT_VERSION or receipt.get('source') != stamp:
        return False
    roots = [
        package / 'Native' / 'CmuxV3NativeFFI.xcframework',
        package / 'Sources' / 'CmuxV3Native' / 'CmuxV3Native.swift',
    ]
    if not all(root.exists() for root in roots):
        return False
    manifest = artifact_manifest(package, roots)
    return (
        bool(manifest['files'])
        and receipt.get('files') == manifest['files']
        and receipt.get('symlinks') == manifest['symlinks']
    )


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--package', type=Path, required=True)
    p.add_argument('--target-dir', type=Path, required=True)
    p.add_argument('--mac-only', action='store_true', help='Host proof only; not an iOS artifact')
    p.add_argument('--release', action='store_true')
    p.add_argument('--if-stale', action='store_true', help='Reuse only artifacts matching these sources and file hashes')
    args = p.parse_args()
    package = args.package.resolve()
    target = args.target_dir.resolve()
    package.mkdir(parents=True, exist_ok=True)
    lock = (package/'.native-build.lock').open('a')
    fcntl.flock(lock, fcntl.LOCK_EX)
    digest = hashlib.sha256()
    inputs = [ROOT/'Cargo.toml', ROOT/'Cargo.lock', ROOT/'rust-toolchain.toml', Path(__file__).resolve()]
    inputs += sorted(p for p in (ROOT/'crates').rglob('*') if p.suffix in {'.rs', '.toml'})
    for source in inputs:
        digest.update(str(source.relative_to(ROOT)).encode())
        digest.update(source.read_bytes())
    digest.update(json.dumps([args.mac_only, args.release]).encode())
    digest.update(platform.machine().encode())
    digest.update(subprocess.check_output(['xcodebuild', '-version']))
    stamp = digest.hexdigest()
    receipt_path = package/'Native'/'receipt.json'
    if args.if_stale and receipt_path.is_file():
        receipt = json.loads(receipt_path.read_text())
        if receipt_matches(package, receipt, stamp):
            print('Native artifact matches source and content hashes')
            return
    env = dict(os.environ, CARGO_TARGET_DIR=str(target), MACOSX_DEPLOYMENT_TARGET='14.0', IPHONEOS_DEPLOYMENT_TARGET='17.0')
    profile = 'release' if args.release else 'debug'
    mode = ['--release'] if args.release else []
    run('cargo', 'build', '-p', 'cmux-v3-ffi', '--locked', *mode, env=env)
    package.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='v3-apple-') as tmp:
        stage = Path(tmp)
        generated = stage/'generated'
        run('cargo', 'run', '-p', 'cmux-v3-ffi', '--locked', '--features', 'bindgen', '--bin', 'uniffi-bindgen', '--',
            'generate', '--library', str(target/profile/'libcmux_v3_ffi.dylib'), '--language', 'swift',
            '--out-dir', str(generated), '--config', str(ROOT/'crates/ffi/uniffi.toml'), env=env)
        headers = stage/'headers'
        headers.mkdir()
        shutil.copy2(generated/'CmuxV3NativeFFI.h', headers)
        shutil.copy2(generated/'CmuxV3NativeFFI.modulemap', headers/'module.modulemap')
        libraries = [('macos-arm64_x86_64', target/profile/'libcmux_v3_ffi.dylib')]
        if not args.mac_only:
            triples = ['aarch64-apple-darwin','x86_64-apple-darwin','aarch64-apple-ios','aarch64-apple-ios-sim']
            run('rustup', 'target', 'add', '--toolchain', '1.98.1', *triples, env=env)
            for triple in triples:
                run('cargo', 'build', '-p', 'cmux-v3-ffi', '--locked', '--target', triple, *mode, env=env)
            mac = stage/'macos'/'libcmux_v3_ffi.dylib'
            mac.parent.mkdir()
            run('lipo', '-create', *(str(target/t/profile/'libcmux_v3_ffi.dylib') for t in triples[:2]), '-output', str(mac), env=env)
            libraries = [
                ('macos-arm64_x86_64', mac),
                ('ios-arm64', target/triples[2]/profile/'libcmux_v3_ffi.dylib'),
                ('ios-arm64-simulator', target/triples[3]/profile/'libcmux_v3_ffi.dylib'),
            ]
        output = stage/'CmuxV3NativeFFI.xcframework'
        frameworks = []
        for identifier, library in libraries:
            versioned = identifier.startswith('macos-')
            framework = create_framework(
                stage,
                identifier,
                library,
                headers/'CmuxV3NativeFFI.h',
                versioned=versioned,
            )
            install_name_tool = subprocess.check_output(
                ['xcrun', '--find', 'install_name_tool'], text=True
            ).strip()
            run(
                install_name_tool,
                '-id',
                framework_install_name(versioned=versioned),
                str(framework_binary_path(framework, versioned=versioned)),
                env=env,
            )
            frameworks.append(framework)
        command = ['xcodebuild', '-create-xcframework']
        for framework in frameworks:
            command += ['-framework', str(framework)]
        run(*command, '-output', str(output), env=env)
        manifest = output/'Info.plist'
        if not manifest.is_file():
            raise RuntimeError('XCFramework did not contain Info.plist')
        # Source and binary come from this same build; generated checksum guards
        # reject accidental binding/library version mismatches at runtime.
        native = package/'Native'
        native.mkdir(exist_ok=True)
        destination = native/output.name
        copy_artifact(output, destination)
        sources = package/'Sources'/'CmuxV3Native'
        sources.mkdir(parents=True, exist_ok=True)
        shutil.copy2(generated/'CmuxV3Native.swift', sources)
        manifest = artifact_manifest(package, [destination, sources/'CmuxV3Native.swift'])
        receipt_path.write_text(json.dumps({'source': stamp, 'layout': RECEIPT_LAYOUT_VERSION, **manifest}, indent=2)+'\n')
    print('Built', destination, 'macOS only' if args.mac_only else 'macOS + iOS + simulator')


if __name__ == '__main__': main()
