#!/usr/bin/env python3
"""Fail only on the guard steps a change turns red; report the base's own reds as warnings.

    guards_new_reds.py [--label NAME] [--flaky FILE] HEAD_RESULTS BASE_RESULTS

Each file is run_ci_guards.py --results output ({step name: passed}) from one runner: the head's
checkout run on the head, then on the base (--root). A step red on the head that passed on the
base, or is new, fails; a step red on both is a warning. Missing base results (an unreadable base)
make every head red the change's. A step that reports its own checks (run_ci_guards.py) adds one
"<step> :: <check>" entry per check, compared like any step: a check red on the base never masks a
different check red on the change, and a check the base has no entry for (a base from before the
step reported its checks) counts as the change's, so a step-level red on the base excuses nothing.

--label names what the annotations count (default: Guard); the webview tests use it with
webviews_test_results.py's per-test results.

--flaky names a file with one step a line (webviews_test_history.py flaky: the webview tests
whose verdict flipped by itself on recent base pushes). A red the base replay passed that is in
it is a warning, never the change's: one passing replay on the base proves nothing about a test
that fails now and then there. A missing or unreadable file lists nothing.
"""
from __future__ import annotations

import json
from pathlib import Path
import sys


def load(path: str) -> dict[str, bool] | None:
    try:
        found = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    return {str(k): bool(v) for k, v in found.items()} if isinstance(found, dict) else None


def flaky_names(path: str) -> set[str]:
    try:
        return {line.strip() for line in Path(path).read_text(encoding="utf-8").splitlines() if line.strip()}
    except OSError:
        return set()


def main(argv: list[str]) -> int:
    label, flaky = "Guard", set()
    while len(argv) > 2 and argv[0] in ("--label", "--flaky"):
        if argv[0] == "--label":
            label = argv[1]
        else:
            flaky = flaky_names(argv[1])
        argv = argv[2:]
    if len(argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    head, base = load(argv[0]), load(argv[1])
    if head is None:
        print(f"::error title={label} results missing::no head results in {argv[0]}")
        return 1
    if base is None:
        print(f"no base results in {argv[1]}: every red step counts as this change's")
        base = {}
    red = sorted(step for step, ok in head.items() if not ok and base.get(step, True))
    new = [step for step in red if step not in flaky]
    flaked = [step for step in red if step in flaky]
    old = sorted(step for step, ok in head.items() if not ok and base.get(step) is False)
    fixed = sorted(step for step, ok in head.items() if ok and base.get(step) is False)
    for step in old:
        print(f"::warning title={label} red on the base too::{step}")
    for step in flaked:
        print(f"::warning title={label} flaky on the base::{step}")
    for step in new:
        print(f"::error title={label} red on this change::{step}")
    if fixed:
        print("fixed by this change: " + "; ".join(fixed))
    print(f"{len(new)} {label.lower()} steps red on this change, {len(old)} red on the base too, "
          f"{len(flaked)} flaky on the base, {len(fixed)} fixed")
    return 1 if new else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
