#!/usr/bin/env python3
"""A pull request's red `cargo test` run, judged per test: a flake, the base's red, or the change's own.

cmux-tui-spec.yml's `acpmux tests` job runs acpmux's lib tests and hub_integration on every pull request that
touches acpmux. Before it, those suites ran only in Fast checks and the fleet, so #27921 and #27868 landed red tests
and base stayed red for hours (2026-10-30). When the head's run is red, the job runs each failing test again alone
on the head (the retry) and on the merge parent (the base), then asks this script:

    cargo_test_verdict.py failed HEAD.log
        prints the head's failing test names, one per line, for the retry and the base replay.
    cargo_test_verdict.py judge --head HEAD.log [--retry RETRY.log] [--base BASE.log] [--job NAME]
        prints GitHub annotations and exits 0 when no red is the change's own, 1 when one is.

The verdict:
- A test that failed on the head and passed when run again alone is a flake: it warns.
- The rest are judged by scripts/ci/test_reds.py, the one per-test classifier for "red on the base, so not ours":
  a test the base fails too warns as a base red; a test that passes or does not exist on the base, a crash
  (signal, abort) and a cut-short run (a test binary that printed no `test result:`) are the change's own red.
- A red run that names no failing test (a compile error) is the change's own red.
"""
from __future__ import annotations

import argparse
import importlib.util
import re
import sys
from pathlib import Path

_spec = importlib.util.spec_from_file_location("test_reds", Path(__file__).with_name("test_reds.py"))
test_reds = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(test_reds)

PASSED = re.compile(r"^test (\S+) \.\.\. ok$")
FAILED_LINE = re.compile(r"^test (\S+) \.\.\. FAILED$")


def read_text(path: Path | None) -> str | None:
    if path is None or not path.exists():
        return None
    return path.read_text(errors="replace")


def failed_names(log: str) -> list[str]:
    return sorted(test_reds.read(log).failed)


def passed_names(log: str | None) -> set[str]:
    if not log:
        return set()
    return {m.group(1) for line in test_reds.lines_of(log) for m in [PASSED.match(line)] if m}


def without_failures(log: str, names: set[str]) -> str:
    """The head's log with the FAILED lines of NAMES taken out: its crashes and cut-short binaries still count."""
    raw = log.splitlines()
    return "\n".join(line for line, text in zip(raw, test_reds.lines_of(log))
                     if not ((match := FAILED_LINE.match(text)) and match.group(1) in names))


def judge(head: str | None, retry: str | None, base: str | None, job: str) -> tuple[bool, list[str]]:
    """(own, annotations): own is True when a red is the change's own."""
    if head is None or not head.strip():
        return True, [f"::error title={job}::the head's test log is missing or empty, so no test can be judged"]
    found = test_reds.read(head)
    flaky = found.failed & passed_names(retry)
    notes = [f"::warning title={job} (flaky)::{name} failed, then passed run again alone" for name in sorted(flaky)]
    if not found.failed and not found.crashes and not found.truncated:
        return True, notes + [f"::error title={job}::cargo test failed and named no failing test (a compile error?); "
                              "see the step's log"]
    verdict = test_reds.classify(without_failures(head, flaky), base, job, "the merge base")
    if verdict is None:
        # Every failing test was a flake.
        return False, notes
    if verdict.own:
        return True, notes + [f"::error title={job}::{reason}" for reason in verdict.reasons]
    return False, notes + [f"::warning title={job} (base red)::{name} fails on the merge base too"
                           for name in verdict.shared]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    failed = sub.add_parser("failed", help="print the failing test names of a cargo test log")
    failed.add_argument("log", type=Path)
    one = sub.add_parser("judge", help="judge a red head run against its retry and the base replay")
    one.add_argument("--head", required=True, type=Path)
    one.add_argument("--retry", type=Path)
    one.add_argument("--base", type=Path)
    one.add_argument("--job", default="cargo test")
    args = parser.parse_args(argv)
    if args.command == "failed":
        print("\n".join(failed_names(args.log.read_text(errors="replace"))))
        return 0
    own, notes = judge(read_text(args.head), read_text(args.retry), read_text(args.base), args.job)
    for note in notes:
        print(note)
    print(f"{args.job}: " + ("a red is the change's own" if own else "no red is the change's own"))
    return 1 if own else 0


if __name__ == "__main__":
    sys.exit(main())
