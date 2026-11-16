#!/usr/bin/env python3
"""The resource operation catalog has one source: cmux-tui/spec/resource-operations-v2.json.

Each of the seven high-level SDKs used to carry a `.cmux-resource-api.json`
descriptor: the catalog's protocol, its SHA-256 and every operation's class,
copied by a sync script. Nothing read them at run time, yet every catalog change
had to rewrite all seven, and two base reds (#23191, #34498) were a catalog
change that left the pasted hash stale. Whoever needs the protocol, a class or
the hash now reads or computes it from the catalog.

This check fails when a copy comes back, so the catalog stays the only place:
  - any tracked file named `.cmux-resource-api.json`;
  - any tracked file other than the catalog with the catalog's exact bytes;
  - any tracked file that pastes the catalog's SHA-256 (of its bytes, or of its
    canonical JSON, the form the descriptors used).

Exit 0 when the catalog is the only source, 1 naming each copy otherwise.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
from pathlib import Path


CATALOG = "cmux-tui/spec/resource-operations-v2.json"
RETIRED_DESCRIPTOR = ".cmux-resource-api.json"


def catalog_digests(raw: bytes) -> tuple[str, str]:
    """The SHA-256 of the catalog's bytes and of its canonical JSON."""
    canonical = json.dumps(
        json.loads(raw), sort_keys=True, separators=(",", ":"), ensure_ascii=False
    ).encode()
    return hashlib.sha256(raw).hexdigest(), hashlib.sha256(canonical).hexdigest()


def _git(root: Path, *arguments: str) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(["git", "-C", str(root), *arguments], capture_output=True, check=False)


def copies(root: Path) -> list[str]:
    """Every problem, one line each; empty when the catalog is the only source."""
    catalog = root / CATALOG
    if not catalog.is_file():
        return [f"{CATALOG} is missing"]
    raw = catalog.read_bytes()
    problems: list[str] = []

    listed = _git(root, "ls-files", "-z", "-s")
    if listed.returncode != 0:
        return [f"git ls-files failed: {listed.stderr.decode(errors='replace').strip()}"]
    catalog_blob = _git(root, "hash-object", "--", CATALOG).stdout.decode().strip()
    for entry in listed.stdout.split(b"\0"):
        if not entry:
            continue
        meta, _, path_bytes = entry.partition(b"\t")
        path = path_bytes.decode(errors="replace")
        blob = meta.split()[1].decode()
        if Path(path).name == RETIRED_DESCRIPTOR:
            problems.append(
                f"{path}: a copy of the catalog's descriptor; read {CATALOG} instead"
            )
        elif path != CATALOG and blob == catalog_blob:
            problems.append(f"{path}: a byte copy of {CATALOG}; read the catalog instead")

    file_sha, canonical_sha = catalog_digests(raw)
    grep = _git(root, "grep", "-l", "-z", "-F", "-e", file_sha, "-e", canonical_sha)
    if grep.returncode not in (0, 1):
        problems.append(f"git grep failed: {grep.stderr.decode(errors='replace').strip()}")
    for path in filter(None, grep.stdout.decode(errors="replace").split("\0")):
        if Path(path).name == RETIRED_DESCRIPTOR:
            continue  # already named above
        problems.append(
            f"{path}: pastes the SHA-256 of {CATALOG}; compute it from the catalog instead"
        )
    return sorted(problems)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--root",
        type=Path,
        default=Path(__file__).resolve().parents[2],
        help="the repository root (a git checkout)",
    )
    arguments = parser.parse_args(argv)
    problems = copies(arguments.root)
    for problem in problems:
        print(f"check-catalog-single-source: {problem}", file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
