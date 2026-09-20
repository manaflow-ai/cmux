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


def run(*args, env):
    subprocess.run(args, cwd=ROOT, env=env, check=True)


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
        if receipt.get('source') == stamp and receipt.get('files') and all(
            (package/name).is_file() and hashlib.sha256((package/name).read_bytes()).hexdigest() == sha
            for name, sha in receipt['files'].items()
        ):
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
            framework = stage/identifier/'CmuxV3NativeFFI.framework'
            headers_dir = framework/'Headers'
            modules_dir = framework/'Modules'
            headers_dir.mkdir(parents=True)
            modules_dir.mkdir()
            shutil.copy2(headers/'CmuxV3NativeFFI.h', headers_dir/'CmuxV3NativeFFI.h')
            (modules_dir/'module.modulemap').write_text(
                'framework module CmuxV3NativeFFI {\n'
                '  umbrella header "CmuxV3NativeFFI.h"\n'
                '  export *\n'
                '  module * { export * }\n'
                '}\n'
            )
            (framework/'Info.plist').write_bytes(plistlib.dumps({
                'CFBundleDevelopmentRegion': 'en',
                'CFBundleExecutable': 'CmuxV3NativeFFI',
                'CFBundleIdentifier': 'dev.cmux.CmuxV3NativeFFI',
                'CFBundleInfoDictionaryVersion': '6.0',
                'CFBundleName': 'CmuxV3NativeFFI',
                'CFBundlePackageType': 'FMWK',
                'CFBundleShortVersionString': '1.0',
                'CFBundleVersion': '1',
            }))
            shutil.copy2(library, framework/'CmuxV3NativeFFI')
            install_name_tool = subprocess.check_output(
                ['xcrun', '--find', 'install_name_tool'], text=True
            ).strip()
            run(
                install_name_tool,
                '-id',
                '@rpath/CmuxV3NativeFFI.framework/CmuxV3NativeFFI',
                str(framework/'CmuxV3NativeFFI'),
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
        if destination.exists(): shutil.rmtree(destination)
        shutil.copytree(output, destination)
        sources = package/'Sources'/'CmuxV3Native'
        sources.mkdir(parents=True, exist_ok=True)
        shutil.copy2(generated/'CmuxV3Native.swift', sources)
        files = sorted(p for p in destination.rglob('*') if p.is_file()) + [sources/'CmuxV3Native.swift']
        receipt_path.write_text(json.dumps({'source': stamp, 'files': {
            str(p.relative_to(package)): hashlib.sha256(p.read_bytes()).hexdigest() for p in files
        }}, indent=2)+'\n')
    print('Built', destination, 'macOS only' if args.mac_only else 'macOS + iOS + simulator')


if __name__ == '__main__': main()
