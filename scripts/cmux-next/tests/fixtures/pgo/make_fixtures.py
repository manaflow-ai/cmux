#!/usr/bin/env python3
"""Writes the llvm-profdata text-format fixtures of test_pgo_scenarios.py: three profile runs, each with a launch
and a rest profile, as `run-scenarios.py --stage profile` collects them (one launch.profraw and one rest.profraw per
launch). `llvm-profdata merge` reads the text format as it reads a .profraw, so the merge test runs the real tool
on any OS. Run it again after changing FUNCTIONS: python3 -I scripts/cmux-next/tests/fixtures/pgo/make_fixtures.py

A name starts with its file, as a private Swift function's PGO name does; the text format reads a line that
starts with `$` as a bitmap record, so no fixture name starts with one.

Each function: (hash, launch entry counts of runs 1..3, rest entry counts of runs 1..3).
  main, launched   ran in every launch          -> in the launch list
  sometimes        ran in 2 of 3 launches       -> in the list (a majority)
  flakyLate        ran in 1 of 3 launches       -> not in the list; its rest counts stay in the merged profile
  restOnly         ran only after the launch    -> not in the list
  never            never ran                    -> not in the list
"""
import os

FUNCTIONS = {
    "main": (1001, (1, 1, 1), (0, 0, 0)),
    "/src/App.swift:$s4main8launchedyyF": (1002, (7, 9, 8), (2, 0, 1)),
    "Later.swift:$s4main9sometimesyyF": (1003, (3, 0, 2), (0, 5, 0)),
    "Later.swift:$s4main9flakyLateyyF": (1004, (0, 4, 0), (6, 6, 6)),
    "Rest.swift:$s4main8restOnlyyyF": (1005, (0, 0, 0), (11, 12, 13)),
    "Rest.swift:$s4main5neveryyF": (1006, (0, 0, 0), (0, 0, 0)),
}


def text_profile(run, phase):
    lines = []  # no header: front-end instrumentation, as Swift -profile-generate writes
    for name, (func_hash, launch, rest) in FUNCTIONS.items():
        entry = (launch if phase == "launch" else rest)[run]
        lines += [name, "# Func Hash:", str(func_hash), "# Num Counters:", "2", "# Counter Values:",
                  str(entry), str(entry // 2), ""]
    return "\n".join(lines)


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    for run in range(3):
        for phase in ("launch", "rest"):
            with open(os.path.join(here, f"run{run + 1}-{phase}.proftext"), "w") as out:
                out.write(text_profile(run, phase))


if __name__ == "__main__":
    main()
