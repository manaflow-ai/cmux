#!/usr/bin/env python3
"""Fast-track pull requests: a change that can only touch prose, docs, plans, skills or tests gets the fast gates.

    fast_track.py explain FILE...      whether these changed paths are a fast-track change, and why (offline)
    fast_track.py check FILE_LIST      exit 0 when the newline-separated paths in FILE_LIST are fast-track
                                       (and CMUX_FAST_TRACK is not 0), else 1: for a workflow `if`
    fast_track.py history [N]          over feat-cmux-next's last N first-parent merges (default 22000): the share
                                       that is fast-track, and the fix or revert commits that name one

Leo (ask c-d8a1a12ebb): "there's of course the hail mary that i've been alluding to for a while, of running
fuller suites in batches every now and then. there must surely be some changes which can get the fast track
route. like a nexus card."

A fast-track pull request runs only its fast gates (the router's `draft` callees, which are the cheap tier, and
the guard steps of tooling-tests that need no diff). Its fuller suites run where every merge already runs them
after it lands: cmux-next guards' push run (tooling-tests at the tip, coalesced), the post-merge batch
(.github/post-merge-batch.json, bisected by scripts/ci/post_merge_batch.py when a job turns red) and the base
tier. A red there names its commit range, so a fast-track commit that turned the base red is attributed to its
merge, not to the next pull request.

The class is risk_tier.py's own: every changed path is `low` for a reason that is not product code: docs or copy,
docs/plans/skills, or a test or fixture (risk_tier.RULES). Nothing a rule names `high` or `normal` is ever
fast-track, so a workflow, a script, a lockfile or any source file keeps the full gates. 30 days of
feat-cmux-next (2026-10-25..11-24, `history`): 22,300 merges, 2,864 (12.8%) fast-track; of 180 fix or revert
commits naming an earlier merge, 9 name a fast-track one (5.0%): the class lands 12.8% of merges and takes
5.0% of the blame, with no named revert of a docs-only change.

Switches: vars.CMUX_FAST_TRACK=0 (passed in as $CMUX_FAST_TRACK) gives every pull request the full gates again;
the `full-ci` label does the same for one pull request. Stdlib only, Python 3.9.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import risk_tier  # noqa: E402

# risk_tier.RULES reasons a fast-track path may carry (all of them tier `low`).
REASONS = ("docs or copy", "docs, plans or skills", "test")


def classify(files):
    """(is_fast, reason) for a list of changed paths. An empty or unknown list is never fast-track."""
    if not files:
        return False, "no changed files read: full gates"
    for path in files:
        tier, reason = risk_tier.classify_path(path)
        if tier != "low" or reason not in REASONS:
            return False, f"{path} is {tier} ({reason}): full gates"
    return True, f"{len(files)} changed path(s), all low-risk docs, plans, skills, copy or tests"


def enabled(env=None):
    return str((env if env is not None else os.environ).get("CMUX_FAST_TRACK", "1")).strip() != "0"


def read_list(path):
    return [line for line in Path(path).read_text(encoding="utf-8").split("\n") if line]


def _merges(limit):
    out = subprocess.run(["git", "log", "origin/feat-cmux-next", "--first-parent", "-n", str(limit), "--name-only",
                          "--format=@@%H%x09%s"], capture_output=True, text=True, check=True).stdout
    merges = {}
    for chunk in out.split("@@")[1:]:
        lines = chunk.strip("\n").split("\n")
        sha, _, subject = lines[0].partition("\t")
        merges[sha] = (subject, [f for f in lines[1:] if f])
    return merges


def history(limit):
    merges = _merges(limit)
    number = {}
    for sha, (subject, _) in merges.items():
        m = re.search(r"\(#(\d+)\)$", subject)
        if m:
            number[m.group(1)] = sha
    fast = {sha for sha, (_, files) in merges.items() if classify(files)[0]}
    word = re.compile(r"\b(fix|revert|unbreak|restore|repair)\b", re.I)
    named = fast_named = 0
    for sha, (subject, _) in merges.items():
        if not word.search(subject):
            continue
        for n in set(re.findall(r"#(\d+)", subject)):
            if n in number and number[n] != sha:
                named += 1
                fast_named += number[n] in fast
    print(f"merges {len(merges)}, fast-track {len(fast)} ({100 * len(fast) / max(len(merges), 1):.1f}%)")
    print(f"fix or revert commits naming an earlier merge: {named}, naming a fast-track one: {fast_named}")
    return 0


def main(argv):
    mode = argv[0] if argv else ""
    if mode == "explain" and len(argv) > 1:
        fast, why = classify(argv[1:])
        print(f"{'FAST-TRACK' if fast else 'full'}: {why}")
        return 0
    if mode == "check" and len(argv) == 2:
        if not enabled():
            return 1
        try:
            return 0 if classify(read_list(argv[1]))[0] else 1
        except OSError:
            return 1
    if mode == "history":
        return history(int(argv[1]) if len(argv) > 1 else 22000)
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
