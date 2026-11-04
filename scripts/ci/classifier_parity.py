#!/usr/bin/env python3
"""Fail when main's base-red classifier differs from feat-cmux-next's, the canonical copy.

The base-red classifier (scripts/ci/base_red_excuse.py and the test_reds parsers it loads) judges every red the
landers and gh-merge-green are asked to excuse, for every base. The landers already run feat-cmux-next's copy for
every base, so main's copy has to be the same bytes or main's gh-merge-green and the landers can give two verdicts
for one red (2026-11-04: main's copy refused a red that feat-cmux-next's excused). A classifier change lands on
feat-cmux-next first and is then copied to main unchanged.

Compared byte for byte (SHARED). Not compared, on purpose:
- scripts/ci/base_red_rollups.json: derived from each branch's own workflows (`base_red_excuse.py --write-rollups`).
- scripts/ci/main_fix_evidence.py: each branch's GitHub reader; main's also serves gh-merge-green's main-fix
  validator. The classifier needs only its Refused, job_for, latest_checks and GitHub (json with per_page).
- tests: a test of a branch's own gh-merge-green differs where gh-merge-green differs.

    classifier_parity.py [--ref origin/feat-cmux-next] [--root DIR]

Exits 0 when every shared file matches, 1 when one differs or is missing on one side, 2 when REF is unreadable.
"""
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

SHARED = (
    "scripts/ci/base_red_excuse.py",
    "scripts/ci/test_reds.py",
    "scripts/ci/webviews_test_results.py",
)
CANONICAL = "origin/feat-cmux-next"


def at_ref(root: Path, ref: str, path: str) -> bytes | None:
    """PATH's bytes at REF, or None when REF has no such file."""
    result = subprocess.run(["git", "-C", str(root), "cat-file", "blob", f"{ref}:{path}"], capture_output=True)
    return result.stdout if result.returncode == 0 else None


def differences(root: Path, ref: str) -> list[str]:
    found = []
    for path in SHARED:
        here = root / path
        mine = here.read_bytes() if here.is_file() else None
        theirs = at_ref(root, ref, path)
        if mine is None and theirs is None:
            found.append(f"{path}: on neither side")
        elif mine is None:
            found.append(f"{path}: on {ref}, missing here")
        elif theirs is None:
            found.append(f"{path}: here, missing on {ref}")
        elif mine != theirs:
            found.append(f"{path}: differs from {ref} (git diff {ref} -- {path})")
    return found


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--ref", default=CANONICAL, help=f"the canonical copy's ref (default {CANONICAL})")
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[2])
    args = parser.parse_args(argv)
    if subprocess.run(["git", "-C", str(args.root), "rev-parse", "--verify", "--quiet", f"{args.ref}^{{commit}}"],
                      capture_output=True).returncode:
        print(f"::error title=Classifier parity::{args.ref} is not readable here; fetch it first", file=sys.stderr)
        return 2
    found = differences(args.root, args.ref)
    for line in found:
        print(f"::error title=Classifier parity::{line}", file=sys.stderr)
    if found:
        print(f"Copy the classifier from {args.ref} unchanged (git checkout {args.ref} -- {' '.join(SHARED)}); "
              "a change lands on feat-cmux-next first.", file=sys.stderr)
        return 1
    print(f"classifier parity: {len(SHARED)} files match {args.ref}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
