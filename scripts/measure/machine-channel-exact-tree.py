#!/usr/bin/env python3
"""Could a build made before a merge be that merge's machine channel build? Over the newest N first-parent
merges into feat-cmux-next: which changed the v2 tree key (scripts/ci/cmux_tui_tree_key.py), and for each such
merge, how far its PR head was behind base, how many base commits between the head's merge-base and the
merge's parent moved the key, whether the head's key equals the merge's (the only case
scripts/ci/cmux_machine_channel_pr_head.py reuses), and the key moves per minute on base.

A pre-merge build reaches the merge only if no base commit moves the key between the build's start and the
merge. At R key moves per minute and a build of B minutes, the chance is about exp(-R*B) (printed).

Reads git only (no GitHub calls): `git fetch origin refs/pull/N/head` for each key-changing merge.

Run (in a cmux checkout with origin/feat-cmux-next fetched):
  scripts/measure/machine-channel-exact-tree.py --merges 30 [--build-min 14]

Readings, 2026-11-28: 01:15-01:37Z, 30 merges, 10 moved the key; 01:35-01:54Z, 30 merges, 8 moved it (0.42/min).
0 of 16 distinct key-moving heads matched their merge. Heads were 8-360 commits behind (median about 60), with
3-94 key moves on base since their merge-base (median about 14). P(no move during a 14-min build) is 0.0026,
and about 0.28 even for a 3-min build: a pre-merge build of the exact tree needs the key-moving merges serialized.
"""

from __future__ import annotations

import argparse
import math
import re
import statistics
import subprocess
import sys
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BASE = "origin/feat-cmux-next"
_keys: dict[str, str] = {}


def git(*args: str) -> str:
    return subprocess.run(["git", "-C", str(ROOT), *args], text=True, capture_output=True).stdout.strip()


def key(rev: str) -> str:
    if rev not in _keys:
        _keys[rev] = subprocess.run(
            [sys.executable, str(ROOT / "scripts/ci/cmux_tui_tree_key.py"), "--version", "v2", rev],
            text=True, capture_output=True,
        ).stdout.strip()
    return _keys[rev]


def moved(rev: str) -> bool:
    """Whether first-parent commit REV changed the key."""
    return key(rev) != key(f"{rev}^1") if git("rev-parse", f"{rev}^1") else False


def pr_head(subject: str) -> str:
    m = re.search(r"\(#(\d+)\)$", subject)
    if not m:
        return ""
    if subprocess.run(["git", "-C", str(ROOT), "fetch", "-q", "origin", f"refs/pull/{m[1]}/head"],
                      capture_output=True).returncode:
        return ""
    return git("rev-parse", "FETCH_HEAD")


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--merges", type=int, default=30)
    ap.add_argument("--build-min", type=float, default=14.0, help="minutes from build start to artifacts")
    args = ap.parse_args(argv)
    rows = [line.split(" ", 2) for line in git("log", "--first-parent", "--format=%H %cI %s", BASE,
                                                 f"-{args.merges}").splitlines()]
    changed, behinds, base_moves, matched = 0, [], [], 0
    for sha, when, subject in rows:
        parent = git("rev-parse", f"{sha}^1")
        if key(sha) == key(parent):
            continue
        changed += 1
        head = pr_head(subject)
        if not head:
            print(f"{sha[:12]} moved the key; no PR head")
            continue
        mb = git("merge-base", head, parent)
        span = git("rev-list", "--first-parent", f"{mb}..{parent}").split()
        moves = sum(moved(c) for c in span)
        hit = key(head) == key(sha)
        matched += hit
        behinds.append(len(span))
        base_moves.append(moves)
        print(f"{sha[:12]} {when} behind={len(span)} base_key_moves={moves} head_matches={'y' if hit else 'n'}")
    t = [datetime.fromisoformat(r[1]) for r in rows]
    minutes = max((max(t) - min(t)).total_seconds() / 60, 1e-9)
    rate = changed / minutes
    print(f"\n{len(rows)} merges over {minutes:.1f} min; {changed} moved the key ({rate:.2f}/min)")
    if behinds:
        print(f"heads matched their merge: {matched} of {len(behinds)}; behind median {statistics.median(behinds):g} "
              f"(range {min(behinds)}-{max(behinds)}); base key moves median {statistics.median(base_moves):g} "
              f"(range {min(base_moves)}-{max(base_moves)})")
    print(f"P(no key move during a {args.build_min:g}-min pre-merge build) ~ {math.exp(-rate * args.build_min):.4f}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
