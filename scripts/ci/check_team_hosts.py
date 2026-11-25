#!/usr/bin/env python3
"""No new hard-coded team host in cmux-tui or OptChat product code.

A team machine's name or tailnet address in product code sends every person's traffic to a
host they cannot reach and that is not theirs (2026-11-22: the open-source brains defaulted
to the team subrouter, cmux-lawrences-mac-mini:31415). A model gateway or router comes from
the person's own settings.

The check counts each pattern per tracked file under cmux-tui/ and Native/OptChat/ and
compares with scripts/ci/team-hosts-baseline.json: a file over its count, or a new file with
a match, fails. Tests (a tests/ dir, *_test.rs, tests.rs), fixtures, docs (*.md), the generated egress
host list (cmux-egress/hosts.txt, a copy of docs/privacy.md) and measure/eval tooling are exempt. A
#[cfg(test)] module inside a source file is not exempt: its count goes in the baseline. A count may
only go down: run with --update to write lower counts (it never raises one). The org name is
not a pattern: it is in hundreds of repository URLs.
"""
from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BASELINE = ROOT / "scripts/ci/team-hosts-baseline.json"
TREES = ("cmux-tui/", "Native/OptChat/")
PATTERN = re.compile(r"cmux-lawrences-mac-mini|tail137216|100\.89\.225\.106")
EXEMPT = re.compile(
    r"(^|/)(tests?|fixtures?|testdata|evals?|measure|examples)/|_tests?\.(rs|py)$|(^|/)tests\.rs$|^cmux-tui/crates/cmux-egress/hosts\.txt$|(^|/)test_[^/]*\.py$|\.md$"
)


def counts(root: Path = ROOT) -> dict[str, int]:
    out = subprocess.run(["git", "-C", str(root), "ls-files", "-z", "--", *TREES],
                         check=True, capture_output=True).stdout.decode().split("\0")
    found: dict[str, int] = {}
    for rel in filter(None, out):
        if EXEMPT.search(rel):
            continue
        try:
            text = (root / rel).read_text(errors="replace")
        except (OSError, UnicodeError):
            continue
        n = len(PATTERN.findall(text))
        if n:
            found[rel] = n
    return found


def problems(found: dict[str, int], baseline: dict[str, int]) -> list[str]:
    return [f"{rel}: {n} team host match(es), baseline {baseline.get(rel, 0)}"
            for rel, n in sorted(found.items()) if n > baseline.get(rel, 0)]


def main(argv: list[str]) -> int:
    baseline = json.loads(BASELINE.read_text()) if BASELINE.exists() else {}
    found = counts()
    if "--update" in argv:
        lowered = {rel: min(n, found.get(rel, 0)) for rel, n in baseline.items() if found.get(rel, 0)}
        BASELINE.write_text(json.dumps(dict(sorted(lowered.items())), indent=1) + "\n")
        return 0
    bad = problems(found, baseline)
    if bad:
        print("check_team_hosts: a team host is hard-coded in product code (read it from the person's settings):")
        for line in bad:
            print(f"  {line}")
        return 1
    print(f"check_team_hosts: ok ({sum(found.values())} known matches in {len(found)} files, none new)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
