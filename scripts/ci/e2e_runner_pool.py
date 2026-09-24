#!/usr/bin/env python3
"""Pick the macOS pool an E2E run lands on.

test-e2e.yml and scripts/ci/dispatch-focused-test.py both call this, so a
workflow started from the Actions UI, `gh workflow run`, or run-e2e.sh puts
the same commit on the same pool. In-flight reuse, the failed-selector refusal
and the compiled-product contract all match on that runner label.

`runner: auto` means `vars.MACOS_RUNNER_TESTS` when it names a pool, else
the free 6vcpu macOS 26 pool. When that resolves to the 6vcpu pool, half of
all commits run on the 12vcpu pool instead. The split is keyed on the commit
(odd last hex digit goes large), not drawn at random, so every dispatch at one
commit lands on one pool. `vars.CI_E2E_LARGE_POOL_SPLIT == '0'` turns the
split off. An explicit runner, or a variable naming any other pool, is never
rerouted.
"""
from __future__ import annotations

import argparse
import re
import sys

SMALL_RUNNER = "blacksmith-6vcpu-macos-26"
LARGE_RUNNER = "blacksmith-12vcpu-macos-26"
# The repository variable that turns the split off when set to "0".
SPLIT_VARIABLE = "CI_E2E_LARGE_POOL_SPLIT"
COMMIT = re.compile(r"[0-9a-f]{40}")


def split_enabled(value: str | None) -> bool:
    """Whether the large-pool split is on. Unset or anything but "0" is on."""
    return (value or "").strip() != "0"


def routed_runner(commit: str, default: str | None, split: bool = True) -> str | None:
    """The pool an unpinned run at `commit` lands on, given what auto means.

    Only the free default is split. A repository variable naming any other
    pool is an admin decision, and it wins unchanged. None stays None: a
    caller that could not establish the default must not act on a guess.
    """
    if split and default == SMALL_RUNNER and int(commit[-1], 16) % 2:
        return LARGE_RUNNER
    return default


def resolve(requested: str | None, variable: str | None, split: str | None, commit: str) -> str:
    """The runner label for a workflow run, from its inputs and variables."""
    if not COMMIT.fullmatch(commit):
        raise ValueError(f"expected a full lowercase commit SHA, got {commit!r}")
    requested = (requested or "").strip()
    if requested and requested != "auto":
        return requested
    default = (variable or "").strip() or SMALL_RUNNER
    return routed_runner(commit, default, split_enabled(split))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--commit", required=True, help="resolved 40-character commit SHA")
    parser.add_argument("--requested", default="", help="the workflow's runner input")
    parser.add_argument("--variable", default="", help="vars.MACOS_RUNNER_TESTS")
    parser.add_argument("--split", default="", help=f"vars.{SPLIT_VARIABLE}")
    args = parser.parse_args(argv)
    try:
        print(resolve(args.requested, args.variable, args.split, args.commit))
    except ValueError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
