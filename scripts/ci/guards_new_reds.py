#!/usr/bin/env python3
"""Fail only on the guard steps a change turns red; report the base's own reds as warnings.

    guards_new_reds.py [--label NAME] [--flaky FILE] [--base-again FILE]... [--head-rerun FILE] HEAD_RESULTS BASE_RESULTS
    guards_new_reds.py --new-files [--flaky FILE] [--base-again FILE]... HEAD_RESULTS BASE_RESULTS
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

--base-again names the results of another replay on the base (webviews_test_results.py, {name: passed}); give it once
per replay. A red the first replay passed that another one fails by name is a warning (kind `flaky`), never the
change's: the base both passed and failed it. cmux#41254 (run 43006460063) was charged with the webkit stream-row
overlap test because attempt 2's one base replay passed it (overlapFrames 0); attempt 3's failed it (overlapFrames 1).
A file red without naming the test (a timeout) says nothing about it; a missing or unreadable file names nothing.
Only a first replay that passed the test (by name, or its whole file) makes a later failure a flake: with no first
result, or a first replay that timed out, the red stays the change's.
ci-web.yml replays the files of the reds a compare would still charge, at most two more times (its base_again).

--new-files prints, one a line, the file of each red this compare would charge to the change (the part of a
webview test name before " > "), and exits 0. ci-web.yml re-runs those files alone on the head.

--head-rerun names that re-run's results (webviews_test_results.py, {name: passed}). A red the change would be
charged with that explicitly passed there (or whose whole file passed), alone, is a warning (kind `flaky`), never the change's: the head shard
retries a red file alone and counts its pass, but only while its retry budget lasts, so a late red on a long
shard was never retried. #27710 (run 41525196343) went red on three gallery-frame timeouts its head shards had no
budget left to retry; the base push after it merged passed all three. A file that fails again, or is missing from
the re-run, stays the change's.

A file-level red (`FILE: false`: the file timed out, or failed without naming a test) that the base has no
file-level entry for is red on the base too when every test the head names red in that file is red on the base,
and there is at least one. The base side is often per-test only (the history's known verdicts, or a replay whose
file failed by name), so `FILE` alone reads as passed there. Then a file the base's own slow reds push past its hard
limit was charged to the change: transcript-block-sideways-scrollbar.test.ts timed out on base and head alike, its
four 60 s gallery waits all red on the base, and only the file's own line was called new (#41217, #41246, #41204).
A base file-level pass (`FILE: true`) still makes the head's file red the change's.

A step red on both sides is the base's only when its head failure names nothing the base's does not (cmux#41458):
run_ci_guards.py --results writes each red step's output beside the results (`<results>.failures.json`), and a head
failure that names a test, file or item the base failure does not (#41351's new unwired test in "Validate every
workflow guard is wired", already red on the base for two others, job 130668132153) is the change's. Run-to-run
noise (numbers, temp paths, shas) is left out. When the head has that output and either side has none for the step,
it cannot be told, and the step is the change's. Results without it (the webview tests) compare by name.

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
import re
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


def explained_files(head: dict[str, bool], base: dict[str, bool]) -> set[str]:
    """Head file-level reds the base's own reds explain: the base has no file-level entry for the file, and every
    test the head names red in it (at least one) is red on the base."""
    named: dict[str, list[str]] = {}
    for step, ok in head.items():
        if not ok and " > " in step:
            named.setdefault(test_file(step), []).append(step)
    return {
        step
        for step, ok in head.items()
        if not ok
        and " > " not in step
        and CHECK_SEPARATOR not in step
        and step not in base
        and named.get(step)
        and all(base.get(name) is False for name in named[step])
    }


def load_failures(results: str) -> dict[str, list[str]] | None:
    """run_ci_guards.py's red steps' output lines beside RESULTS ({step: [line]}), or None when it wrote none."""
    try:
        found = json.loads(Path(results + ".failures.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    if not isinstance(found, dict):
        return None
    return {str(k): [str(line) for line in v] for k, v in found.items() if isinstance(v, list)}


# What a failure names, without what differs from run to run: temp paths, shas and hex ids, then every number.
_TEMP = re.compile(r"(?:/tmp|/var/folders)/\S*|\btmp[\w-]{4,}")
_HEX = re.compile(r"\b(?=[0-9a-f]*[0-9])(?=[0-9a-f]*[a-f])[0-9a-f]{7,}\b")
_NUMBER = re.compile(r"\d+")
_NAME = re.compile(r"[A-Za-z_<][\w./<>:-]*")


def failure_names(lines: list[str]) -> set[str]:
    """The names a red step's output holds (paths, tests, items), order and run-to-run noise aside."""
    names: set[str] = set()
    for line in lines:
        line = _NUMBER.sub("0", _HEX.sub("<hex>", _TEMP.sub("<tmp>", line)))
        names.update(name.strip(".:-") for name in _NAME.findall(line))
    names.discard("")
    return names


def main(argv: list[str]) -> int:
    if len(argv) == 2 and argv[0] == "--red-steps":
        for step in red_steps(load(argv[1]) or {}):
            print(step)
        return 0
    label, flaky, tip, new_files, rerun, again = "Guard", set(), False, False, None, []
    while argv and (argv[0] in ("--tip", "--new-files")
                    or (len(argv) > 2 and argv[0] in ("--label", "--flaky", "--head-rerun", "--base-again"))):
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
        elif argv[0] == "--base-again":
            again.append(load(argv[1]) or {})
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
        # Not on stdout under --new-files: ci-web.yml reads every stdout line there as a file to re-run.
        print(f"no base results in {argv[1]}: every red step counts as this change's",
              file=sys.stderr if new_files else sys.stdout)
        base = {}
    explained = explained_files(head, base)
    red = sorted(step for step, ok in head.items() if not ok and base.get(step, True) and step not in explained)
    # Another base replay that fails the step by name: the base passed and failed it, so it flakes there. Only when the
    # first replay passed it (by name, or its whole file): a missing first result, or a file that timed out there,
    # says nothing, and a later red alone would turn "no base result is the change's" into a pass (#41414 review).
    def first_passed(step: str) -> bool:
        return base[step] is True if step in base else base.get(test_file(step)) is True

    flapped = {step for step in red if first_passed(step) and any(found.get(step) is False for found in again)}
    new = [step for step in red if step not in flaky and step not in flapped]
    flaked = [step for step in red if step in flaky or step in flapped]
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
    old = sorted(step for step, ok in head.items() if not ok and (base.get(step) is False or step in explained))
    # A step red on both sides is the base's only when its head failure names nothing the base's does not
    # (cmux#41458). With the runner's failure output on the head, a step either side has none for cannot be told
    # apart, and is the change's. Results with no failure output (webview tests, named one test a line) keep the name.
    head_failures, base_failures = load_failures(argv[0]), load_failures(argv[1])
    named_new: dict[str, list[str]] = {}
    if head_failures is not None:
        for step in old:
            if CHECK_SEPARATOR in step:
                continue  # a check is its own item, compared by name
            if base_failures is None or step not in head_failures or step not in base_failures:
                named_new[step] = []
            else:
                extra = failure_names(head_failures[step]) - failure_names(base_failures[step])
                if extra:
                    named_new[step] = sorted(extra)
        old = [step for step in old if step not in named_new]
        new = sorted(new + list(named_new))
    fixed = sorted(step for step, ok in head.items() if ok and base.get(step) is False)
    for step in old:
        print(f"::warning title={label} red on the base too::{step}")
    for step in flaked:
        where = ("passed again alone on the head" if step in passed_again
                 else "passed and failed on the base's replays" if step in flapped and step not in flaky
                 else "flaky on the base")
        print(f"::warning title={label} {where}::{step}")
    for step in new:
        print(f"::error title={label} red on this change::{step}")
    for step, extra in named_new.items():
        print(f"{step}: red on the base too, but " + (
            "its head failure names what the base's does not: " + ", ".join(extra[:20])
            if extra else "its failures cannot be compared, so it is not excused"))
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
