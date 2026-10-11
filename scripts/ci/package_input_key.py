#!/usr/bin/env python3
"""Compute deterministic input keys for Swift package test results.

The key covers the package and every local path dependency that feeds it, plus
all shared inputs used by the package-test lane.  This first slice only emits
receipts; a later slice may use the key to skip a package after a recorded green
result.  Keeping the key calculation separate makes that cache policy auditable
and prevents an incomplete dependency graph from silently reusing a test.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path

from select_package_tests import GLOBAL_INPUTS, input_prefixes, package_dirs

VERSION = 1
EXCLUDED_PARTS = {".git", ".build", "DerivedData"}


def file_digest(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def gitlink_digest(root: Path, relative: str) -> str | None:
    """Return the recorded gitlink revision when a shared input is a submodule."""
    try:
        import subprocess

        result = subprocess.run(
            ["git", "-C", str(root), "rev-parse", f"HEAD:{relative}"],
            check=True, capture_output=True, text=True,
        )
    except (OSError, subprocess.CalledProcessError):
        return None
    return result.stdout.strip() or None


def iter_files(root: Path, relative_prefix: str) -> list[tuple[str, str]]:
    """List regular files under a tracked input prefix in stable order."""
    path = root / relative_prefix
    if path.is_file():
        return [(relative_prefix, file_digest(path))]
    if not path.exists():
        gitlink = gitlink_digest(root, relative_prefix)
        return [(relative_prefix, gitlink)] if gitlink else []
    files: list[tuple[str, str]] = []
    for candidate in sorted(path.rglob("*")):
        if not candidate.is_file() or any(part in EXCLUDED_PARTS for part in candidate.parts):
            continue
        relative = candidate.relative_to(root).as_posix()
        files.append((relative, file_digest(candidate)))
    return files


def package_receipt(root: Path, package: str, dirs: dict[str, str]) -> dict:
    if package not in dirs:
        raise SystemExit(f"package not found under Packages/*/: {package}")
    prefixes = sorted(input_prefixes(root, package, dirs))
    records: dict[str, str] = {}
    for prefix in prefixes:
        for relative, digest in iter_files(root, prefix):
            records[relative] = digest

    # These are the scripts, workflow and toolchain pins executed by the lane.
    # A missing optional input is omitted; the package manifest and sources are
    # never optional because they are covered by the package prefixes above.
    for relative in GLOBAL_INPUTS:
        # Gitlinks are inputs by revision, not by whatever files happen to be
        # populated in a developer's submodule checkout.
        if relative == "ghostty":
            digest = gitlink_digest(root, relative)
            if digest:
                records[relative] = digest
            continue
        for path, digest in iter_files(root, relative):
            records[path] = digest

    encoded = "".join(f"{path}\0{digest}\n" for path, digest in sorted(records.items()))
    key = hashlib.sha256(encoded.encode("utf-8")).hexdigest()
    return {
        "version": VERSION,
        "package": package,
        "key": key,
        "inputs": len(records),
        "input_sha256": hashlib.sha256(encoded.encode("utf-8")).hexdigest(),
        "paths": sorted(records),
    }


def receipts(root: Path, packages: list[str]) -> dict:
    dirs = package_dirs(root)
    return {
        "version": VERSION,
        "packages": [package_receipt(root, package, dirs) for package in packages],
    }


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", type=Path, default=Path.cwd())
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--package", action="append", dest="packages")
    group.add_argument("--packages-file", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args(argv)
    root = args.root.resolve()
    packages = args.packages
    if packages is None:
        packages = [line for line in args.packages_file.read_text(encoding="utf-8").splitlines() if line]
    receipt = receipts(root, list(dict.fromkeys(packages)))
    encoded = json.dumps(receipt, sort_keys=True, separators=(",", ":"))
    if args.output:
        args.output.write_text(encoded + "\n", encoding="utf-8")
    else:
        print(encoded)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(os.sys.argv[1:]))
