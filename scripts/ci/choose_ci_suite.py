#!/usr/bin/env python3
"""Decide whether a CI run gets the full macOS suite or only compile admission.

The full suite (app-host shards, package tests, the lag build, the Release
build) is what proves a change. Compile admission is the cheap check that a
push still builds. With a merge queue the full suite runs on the commit that
will land, so running it on every push as well spends most Mac time on commits
that never merge.

The answer is "full" unless everything says otherwise: only a pull_request
event, under the compile-only policy, without the opt-in label, gets less.
"""

from __future__ import annotations

import argparse
import sys
from collections.abc import Iterable

COMPILE_ONLY_POLICY = "compile-only"
FULL_SUITE_LABEL = "full-ci"


def wants_full_suite(event_name: str, pull_request_policy: str, labels: Iterable[str] | None) -> bool:
    """`labels` is None when they could not be read, which keeps the full suite."""
    if event_name != "pull_request":
        return True
    if pull_request_policy.strip() != COMPILE_ONLY_POLICY:
        return True
    if labels is None:
        return True
    return FULL_SUITE_LABEL in {label.strip() for label in labels}


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--event-name", required=True)
    parser.add_argument("--pull-request-policy", default="")
    parser.add_argument("--labels-file", help="one label per line; omit when labels could not be read")
    parser.add_argument("--github-output")
    args = parser.parse_args(argv)

    labels = None
    if args.labels_file:
        with open(args.labels_file, encoding="utf-8") as handle:
            labels = handle.read().splitlines()

    full = wants_full_suite(args.event_name, args.pull_request_policy, labels)
    line = f"full_suite={'true' if full else 'false'}"
    print(line)
    if args.github_output:
        with open(args.github_output, "a", encoding="utf-8") as handle:
            handle.write(line + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
