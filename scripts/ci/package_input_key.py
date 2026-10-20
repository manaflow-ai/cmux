#!/usr/bin/env python3
"""Key each Swift package's test inputs, so a pull request run can reuse an earlier pass.

A package's key hashes the git blobs (and gitlink revisions) at a commit of
everything select_package_tests.py says can change its tests: the package and
its path dependencies, their extra inputs, and the job's global inputs. Paths
the selector does not know to be unrelated go into every key too, since the
selector picks every package for them. `--extra name=value` adds what is not in
the tree, such as the Xcode the job tests with.

Reading the commit rather than the working tree keeps build products and
uncommitted edits out of the key.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
from pathlib import Path

from select_package_tests import GLOBAL_INPUTS, UNRELATED_PREFIXES, UNRELATED_SUFFIXES, input_prefixes, package_dirs, under

VERSION = 1


def tree_entries(root: Path, revision: str) -> dict[str, str]:
    """Path -> blob or gitlink id for every entry of `revision`'s tree."""
    output = subprocess.run(
        ["git", "-C", str(root), "ls-tree", "-r", "-z", "--full-tree", revision],
        check=True, capture_output=True, text=True,
    ).stdout
    entries = {}
    for record in output.split("\0"):
        if record:
            meta, _, path = record.partition("\t")
            entries[path] = meta.split()[2]
    return entries


def digest(*parts: object) -> str:
    return hashlib.sha256(json.dumps(parts, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def package_keys(root: Path, packages: list[str], extras: list[str], revision: str = "HEAD") -> dict[str, str]:
    dirs = package_dirs(root)
    missing = [name for name in packages if name not in dirs]
    if missing:
        raise SystemExit(f"package not found under Packages/*/: {', '.join(missing)}")
    entries = tree_entries(root, revision)
    prefixes = {name: input_prefixes(root, name, dirs) for name in dirs}
    known = set().union(*prefixes.values())
    shared = sorted(
        (path, oid) for path, oid in entries.items()
        if any(under(path, global_input.rstrip("/") + "/") or path == global_input for global_input in GLOBAL_INPUTS)
        or not (path.startswith("Packages/") or any(under(path, prefix) for prefix in known)
                or path.startswith(UNRELATED_PREFIXES) or path.endswith(UNRELATED_SUFFIXES))
    )
    shared_key = digest(VERSION, sorted(extras), shared)
    return {
        name: digest(shared_key, name, sorted(
            (path, oid) for path, oid in entries.items() if any(under(path, prefix) for prefix in prefixes[name])
        ))
        for name in packages
    }


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("--packages-file", type=Path, required=True)
    parser.add_argument("--extra", action="append", default=[], help="name=value outside the tree")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args(argv)
    packages = [line for line in args.packages_file.read_text(encoding="utf-8").splitlines() if line]
    keys = package_keys(args.root.resolve(), list(dict.fromkeys(packages)), args.extra)
    args.output.write_text(json.dumps(keys, sort_keys=True) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
