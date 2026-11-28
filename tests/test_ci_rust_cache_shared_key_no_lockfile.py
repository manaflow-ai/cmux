#!/usr/bin/env python3
"""No Swatinem/rust-cache `shared-key` hashes a Cargo.lock.

rust-cache builds its key as `v0-rust-<shared-key>[-<env hash>]-<lockfile hash>` and, when that
exact key misses, restores the newest entry under `v0-rust-<shared-key>[-<env hash>]`. A lockfile
hash inside `shared-key` moves that fallback prefix too, so every lockfile change finds nothing
and builds from scratch. On 2026-11-23 the post-merge batch 45277968169 ran acpmux tests with
"No cache found": the bench step's build took 20 minutes and the test step stopped at the job's
40-minute cap, still compiling. Key `shared-key` on the toolchain only; rust-cache adds the
lockfile hash itself.
"""

from __future__ import annotations

import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
RUST_CACHE = "swatinem/rust-cache@"


def steps(doc: object):
    if isinstance(doc, dict):
        if str(doc.get("uses", "")).lower().startswith(RUST_CACHE):
            yield doc
        for value in doc.values():
            yield from steps(value)
    elif isinstance(doc, list):
        for value in doc:
            yield from steps(value)


def offenders(root: Path = ROOT) -> list[str]:
    found = []
    files = sorted((root / ".github/workflows").glob("*.y*ml")) + sorted(
        (root / ".github/actions").rglob("action.y*ml")
    )
    for path in files:
        doc = yaml.safe_load(path.read_text(encoding="utf-8"))
        for step in steps(doc):
            key = str((step.get("with") or {}).get("shared-key", ""))
            if "Cargo.lock" in key:
                found.append(f"{path.relative_to(root)}: {step.get('name', step['uses'])}: {key}")
    return found


def self_test() -> None:
    bad = {"uses": "Swatinem/rust-cache@abc", "with": {"shared-key": "x-${{ hashFiles('a/Cargo.lock') }}"}}
    good = {"uses": "Swatinem/rust-cache@abc", "with": {"shared-key": "x-${{ hashFiles('a/rust-toolchain.toml') }}"}}
    assert [s["with"]["shared-key"] for s in steps({"jobs": {"j": {"steps": [bad, good]}}})] == [
        bad["with"]["shared-key"],
        good["with"]["shared-key"],
    ]


def main() -> int:
    self_test()
    found = offenders()
    if found:
        print("rust-cache shared-key hashes Cargo.lock, which leaves no fallback cache on a lockfile change:")
        for line in found:
            print(f"  {line}")
        return 1
    print("ok: no rust-cache shared-key hashes Cargo.lock")
    return 0


if __name__ == "__main__":
    sys.exit(main())
