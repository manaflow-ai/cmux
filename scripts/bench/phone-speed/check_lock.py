"""Keep measured production dependencies identical to the application's lockfile."""
from __future__ import annotations

import sys
import tomllib
from pathlib import Path


def closure(packages: list[dict], root: str, root_dependencies: set[str] | None = None) -> set[tuple]:
    pending = [root]
    seen = set()
    while pending:
        reference = pending.pop()
        parts = reference.split()
        matches = [p for p in packages if p['name'] == parts[0]
                   and (len(parts) < 2 or p['version'] == parts[1])
                   and (len(parts) < 3 or p.get('source') == parts[2].strip('()'))]
        if len(matches) != 1:
            raise ValueError(f'ambiguous or absent locked dependency: {reference}')
        package = matches[0]
        identity = tuple(package.get(key, '') for key in ('name', 'version', 'source', 'checksum'))
        if identity not in seen:
            seen.add(identity)
            dependencies = package.get('dependencies', [])
            if package['name'] == root and root_dependencies is not None:
                dependencies = [d for d in dependencies if d.split()[0] in root_dependencies]
            pending.extend(dependencies)
    return seen


def runtime_names(manifest: dict) -> set[str]:
    names = set()
    for section in [manifest, *manifest.get('target', {}).values()]:
        for kind in ('dependencies', 'build-dependencies'):
            for alias, value in section.get(kind, {}).items():
                names.add(value.get('package', alias) if isinstance(value, dict) else alias)
    return names


def check(production: Path, harness: Path) -> None:
    locks = [tomllib.loads(path.read_text())['package'] for path in (production, harness)]
    manifest = production.parent / 'crates/cmux-terminal-projection/Cargo.toml'
    # A workspace lock includes the crate's test-only Ghostty oracle as well.
    runtime = runtime_names(tomllib.loads(manifest.read_text()))
    expected, measured = [closure(packages, 'cmux-terminal-projection', runtime) for packages in locks]
    if expected != measured:
        raise ValueError(f'production dependency drift: missing={expected - measured}, extra={measured - expected}')


if __name__ == '__main__':
    root = Path(__file__).resolve().parents[3]
    try:
        check(root / 'cmux-tui/Cargo.lock', Path(__file__).with_name('Cargo.lock'))
    except ValueError as error:
        sys.exit(str(error))
    print('phone-speed: production lock dependency closure matches')
