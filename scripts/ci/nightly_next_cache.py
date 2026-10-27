#!/usr/bin/env python3
"""NEXT compiler/source caches from fresh cold builds, never DerivedData products.

The v1 namespace has no legacy entries. Only a fresh, empty nightly-next push
may save, and the workflow also refuses saves after any restore. Compiler CAS
entries carry their own content/dependency keys; the outer prefix separates
macOS, SDK, compiler and workspace identities. Package entries use an exact
lockfile/layout key. Neither cache is evidence of a clean product build.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import subprocess

import dev_release_product_reuse as reuse
import nightly_build_state as state
import nightly_release_product_reuse as product


def digest(value: object) -> str:
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


def empty(path: Path) -> bool:
    return not path.is_symlink() and (not path.exists() or (path.is_dir() and not any(path.iterdir())))


def plan(root: Path, env: dict[str, str], identity: dict[str, str], packages: str) -> dict[str, str]:
    derived, spm = root / 'build-universal', root / '.spm-cache'
    restore = not state.owned(env.get('RUNNER_NAME', '')) and empty(derived) and empty(spm)
    clean = (restore and not reuse.clean_builder(product.builder(env, derived))
             and env.get('GITHUB_EVENT_NAME') == 'push'
             and env.get('GITHUB_REF') == 'refs/heads/nightly-next')
    return {'prefix': 'next-clean-compilation-v1-' + digest({**identity, 'workspace': str(root.resolve()),
                                                          'packages': packages}) + '-',
            'spm_key': 'next-clean-spm-v1-' + digest({'toolchain': identity, 'packages': packages}),
            'restore': str(restore).lower(), 'clean': str(clean).lower()}


def main() -> None:
    def run(*args: str) -> str:
        return subprocess.check_output(args, text=True, timeout=30).strip()

    root = Path.cwd()
    identity = {'xcode': run('xcodebuild', '-version'),
                'sdk': run('xcrun', '--sdk', 'macosx', '--show-sdk-version') + ' ' +
                       run('xcrun', '--sdk', 'macosx', '--show-sdk-build-version'),
                'macos': run('sw_vers', '-productVersion'), 'macos_build': run('sw_vers', '-buildVersion'),
                'arch': run('uname', '-m'), 'developer_dir': run('xcode-select', '-p')}
    packages = digest({p: (root / p).read_text() for p in (
        'cmux.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved',
        'scripts/ci/swiftpm-cache-layout')})
    for key, value in plan(root, dict(os.environ), identity, packages).items():
        print(f'{key}={value}')


if __name__ == '__main__':
    main()
