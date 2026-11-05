#!/usr/bin/env python3
"""Fail only on the guard steps a change turns red; report the base's own reds as warnings.

    guards_new_reds.py [--label NAME] [--flaky FILE] [--head-rerun FILE] HEAD_RESULTS BASE_RESULTS
    guards_new_reds.py --new-files [--flaky FILE] HEAD_RESULTS BASE_RESULTS
    guards_new_reds.py [--label NAME] --tip HEAD_RESULTS
    guards_new_reds.py --red-steps HEAD_RESULTS

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

--new-files prints, one a line, the file of each red this compare would charge to the change (the part of a
webview test name before " > "), and exits 0. ci-web.yml re-runs those files alone on the head.

--head-rerun names that re-run's results (webviews_test_results.py, {name: passed}). A red the change would be
charged with that explicitly passed there (or whose whole file passed), alone, is a warning (kind `flaky`), never the change's: the head shard
retries a red file alone and counts its pass, but only while its retry budget lasts, so a late red on a long
shard was never retried. #27710 (run 41525196343) went red on three gallery-frame timeouts its head shards had no
budget left to retry; the base push after it merged passed all three. A file that fails again, or is missing from
the re-run, stays the change's.

--red-steps prints, one a line, each step red on the head (a red "<step> :: <check>" names its step), and exits 0.
cmux-next-guards.yml re-runs only those steps on the base (run_ci_guards.py --step): a step green on the head is never
charged to the change whatever the base says, so running it there too bought nothing. With release-notary in the
compare, the full base pass doubled the job (about 9 minutes a pass, run 42001286004).

--tip judges a branch tip on its own (cmux-next-guards.yml, a push to feat-cmux-next that touches what the guards
read): there is no base to compare with, so every red step fails. A push judged only against the previous tip stays
green while a red persists: the guard profile was red on 18 steps of feat-cmux-next, unseen, until #31366.

Each red step is also printed as one plain line, `<label> red step (<kind>): <step>`, kind `new` (red on this
change), `base` (red on the base too), `flaky` (flaky on the base) or `tip`. GitHub drops an annotation's title from
the job log, so scripts/ci/base_red_excuse.py reads these lines to compare a pull request's red steps with a base
run's, step by step.
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


def test_file(step: str) -> str:
    return step.split(" > ", 1)[0]


def red_step_line(label: str, kind: str, step: str) -> str:
    return f"{label.lower()} red step ({kind}): {step}"


CHECK_SEPARATOR = " :: "  # run_ci_guards.py's "<step> :: <check>" entries


def red_steps(head: dict[str, bool]) -> list[str]:
    return sorted({step.split(CHECK_SEPARATOR, 1)[0] for step, ok in head.items() if not ok})


def main(argv: list[str]) -> int:
    if len(argv) == 2 and argv[0] == "--red-steps":
        for step in red_steps(load(argv[1]) or {}):
            print(step)
        return 0
    label, flaky, tip, new_files, rerun = "Guard", set(), False, False, None
    while argv and (argv[0] in ("--tip", "--new-files")
                    or (len(argv) > 2 and argv[0] in ("--label", "--flaky", "--head-rerun"))):
        if argv[0] == "--tip":
            tip, argv = True, argv[1:]
            continue
        if argv[0] == "--new-files":
            new_files, argv = True, argv[1:]
            continue
        if argv[0] == "--label":
            label = argv[1]
        elif argv[0] == "--flaky":
            flaky = flaky_names(argv[1])
        else:
            rerun = load(argv[1]) or {}
        argv = argv[2:]
    if len(argv) != (1 if tip else 2):
        print(__doc__, file=sys.stderr)
        return 2
    head = load(argv[0])
    if head is None and new_files:
        return 0
    if head is None:
        print(f"::error title={label} results missing::no head results in {argv[0]}")
        return 1
    if tip:
        red = sorted(step for step, ok in head.items() if not ok)
        for step in red:
            print(f"::error title={label} red at the tip::{step}")
        for step in red:
            print(red_step_line(label, "tip", step))
        print(f"{len(red)} {label.lower()} steps red at the tip")
        return 1 if red else 0
    base = load(argv[1])
    if base is None:
        print(f"no base results in {argv[1]}: every red step counts as this change's")
        base = {}
    red = sorted(step for step, ok in head.items() if not ok and base.get(step, True))
    new = [step for step in red if step not in flaky]
    flaked = [step for step in red if step in flaky]
    if new_files:
        for file in sorted({test_file(step) for step in new}):
            print(file)
        return 0
    def passed_in_rerun(step: str) -> bool:
        if not rerun:
            return False
        # Newer result files include named outcomes for a failed file.  Respect an
        # explicit test result first so a named failure cannot be hidden by the
        # legacy whole-file pass fallback.
        if step in rerun:
            return rerun[step] is True
        return rerun.get(test_file(step)) is True

    passed_again = [step for step in new if passed_in_rerun(step)]
    new = [step for step in new if step not in passed_again]
    flaked = sorted(flaked + passed_again)
    old = sorted(step for step, ok in head.items() if not ok and base.get(step) is False)
    fixed = sorted(step for step, ok in head.items() if ok and base.get(step) is False)
    for step in old:
        print(f"::warning title={label} red on the base too::{step}")
    for step in flaked:
        where = "passed again alone on the head" if step in passed_again else "flaky on the base"
        print(f"::warning title={label} {where}::{step}")
    for step in new:
        print(f"::error title={label} red on this change::{step}")
    for kind, steps in (("new", new), ("base", old), ("flaky", flaked)):
        for step in steps:
            print(red_step_line(label, kind, step))
    if fixed:
        print("fixed by this change: " + "; ".join(fixed))
    print(f"{len(new)} {label.lower()} steps red on this change, {len(old)} red on the base too, "
          f"{len(flaked)} flaky on the base, {len(fixed)} fixed")
    if passed_again:
        print(f"{len(passed_again)} of the flaky passed again when re-run alone on the head")
    return 1 if new else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
