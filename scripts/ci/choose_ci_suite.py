#!/usr/bin/env python3
"""Select the full macOS suite policy or the reduced PR suite policy.

The full policy permits expensive app-host shards, package tests, lag builds,
and Release lanes, subject to each lane's path routing and dependencies.
The reduced policy still runs compile admission and independently routed tests;
it is not a request to skip all tests. `full-ci` explicitly opts into the broad
policy, not normal PR validation or a generic review/merge prerequisite. Choose
coverage appropriate to the change and verify which tests actually executed.

The answer is "full" unless everything says otherwise: only a pull_request
event, under the compile-only policy, without the opt-in label, gets less.

Compile admission cannot judge a change to the test suite itself: the tests
compile and are then not run. The policy's own justification is that "with a
merge queue the full suite runs on the commit that will land", so a pull
request that edits the app-host tests and skips the suite is only safe while
that queue is in the path. This module also reports whether the diff is one
that compile admission cannot judge, so CI can refuse to call such a run
green by default rather than silently skipping the only check that applies.
"""

from __future__ import annotations

import argparse
import json
import sys
from collections.abc import Iterable
from pathlib import Path

COMPILE_ONLY_POLICY = "compile-only"
FULL_SUITE_LABEL = "full-ci"
SUITE_OPT_OUT_LABEL = "no-full-ci"
UNIT_SUITE_LABEL = "unit-ci"

# Editing these runs no code under compile admission, which builds the test
# bundle and stops. Nothing else in a pull request observes them.
#
# They differ in what could observe them. `app-host unit tests` runs cmuxTests/
# against the product compile admission already built, so asking for that one
# job is enough to judge a cmuxTests/ diff. No pull request job runs
# cmuxUITests/ at all -- only the dispatch-only test-e2e lane does -- so those
# stay unobserved until someone takes the full suite or records the skip.
UNIT_JUDGED_PREFIXES = ("cmuxTests/",)
UNJUDGED_BY_ANY_PR_JOB_PREFIXES = ("cmuxUITests/",)
UNJUDGED_BY_COMPILE_PREFIXES = UNIT_JUDGED_PREFIXES + UNJUDGED_BY_ANY_PR_JOB_PREFIXES


def diff_needs_the_suite(paths: Iterable[str] | None) -> bool:
    """True when the diff contains changes compile admission cannot judge.

    `paths` is None when the diff could not be read, which reports True so an
    unreadable diff is never the reason a suite-only change goes unchecked.
    """
    if paths is None:
        return True
    return any(
        path.strip().startswith(UNJUDGED_BY_COMPILE_PREFIXES)
        for path in paths
    )


def wants_full_suite(event_name: str, pull_request_policy: str, labels: Iterable[str] | None) -> bool:
    """`labels` is None when they could not be read, which keeps the full suite."""
    if event_name != "pull_request":
        return True
    if pull_request_policy.strip() != COMPILE_ONLY_POLICY:
        return True
    if labels is None:
        return True
    return FULL_SUITE_LABEL in {label.strip() for label in labels}


def wants_unit_suite(
    event_name: str,
    pull_request_policy: str,
    labels: Iterable[str] | None,
    paths: Iterable[str] | None = (),
) -> bool:
    """True when this run should execute `app-host unit tests`.

    The full suite already includes them, so it implies this. Otherwise the
    diff decides: a change under cmuxTests/ is judged by exactly this job and
    by nothing compile admission does, so it selects the job itself rather
    than failing `suite-coverage` and waiting for someone to add a label that
    this module could already have derived. An unreadable diff (`paths` is
    None) runs it too. The `unit-ci` label still asks for it on any diff.

    Only this job is selected: the package tests, the lag lane, release
    admission and the Release build the full suite also unlocks cost a paid
    runner and judge nothing about a change to cmuxTests/.
    """
    if wants_full_suite(event_name, pull_request_policy, labels):
        return True
    if UNIT_SUITE_LABEL in {label.strip() for label in labels or ()}:
        return True
    if paths is None:
        return True
    return any(path.strip().startswith(UNIT_JUDGED_PREFIXES) for path in paths)


def labels_from_event(event_path: str | Path) -> list[str] | None:
    """Read the pull request labels captured in this workflow run's event payload."""
    try:
        with Path(event_path).open(encoding="utf-8") as handle:
            payload = json.load(handle)
    except (OSError, json.JSONDecodeError, TypeError):
        return None

    if not isinstance(payload, dict):
        return None
    pull_request = payload.get("pull_request")
    if not isinstance(pull_request, dict):
        return None
    raw_labels = pull_request.get("labels")
    if not isinstance(raw_labels, list):
        return None

    labels: list[str] = []
    for raw_label in raw_labels:
        if not isinstance(raw_label, dict):
            return None
        name = raw_label.get("name")
        if not isinstance(name, str):
            return None
        labels.append(name)
    return labels


def coverage_gap(
    event_name: str,
    full_suite: bool,
    paths: Iterable[str] | None,
    labels: Iterable[str] | None,
    unit_suite: bool = False,
) -> bool:
    """True when this run skips the only check that could judge its diff.

    An explicit opt-out label records the decision on the pull request, which
    is the point: the skip stops being silent.

    `unit_suite` closes the gap only for the paths `app-host unit tests` can
    actually judge. A cmuxUITests/ diff stays a gap however this run is routed,
    because no pull request job executes it.
    """
    if full_suite or event_name != "pull_request":
        return False
    if labels is not None and SUITE_OPT_OUT_LABEL in {label.strip() for label in labels}:
        return False
    if paths is None:
        return True
    stripped = [path.strip() for path in paths]
    if any(path.startswith(UNJUDGED_BY_ANY_PR_JOB_PREFIXES) for path in stripped):
        return True
    if unit_suite:
        return False
    return any(path.startswith(UNIT_JUDGED_PREFIXES) for path in stripped)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--event-name", required=True)
    parser.add_argument("--pull-request-policy", default="")
    label_source = parser.add_mutually_exclusive_group()
    label_source.add_argument(
        "--event-path",
        help="GitHub event JSON whose pull request labels are the immutable run snapshot",
    )
    label_source.add_argument("--labels-file", help="one label per line; omit when labels could not be read")
    parser.add_argument("--github-output")
    parser.add_argument(
        "--files-from",
        help="changed paths, one per line; omit when the diff could not be read",
    )
    args = parser.parse_args(argv)

    labels = None
    if args.event_path:
        labels = labels_from_event(args.event_path)
    elif args.labels_file:
        with open(args.labels_file, encoding="utf-8") as handle:
            labels = handle.read().splitlines()

    paths = None
    if args.files_from:
        try:
            with open(args.files_from, encoding="utf-8") as handle:
                paths = handle.read().splitlines()
        except (OSError, UnicodeError):
            paths = None

    full = wants_full_suite(args.event_name, args.pull_request_policy, labels)
    unit = wants_unit_suite(args.event_name, args.pull_request_policy, labels, paths)
    gap = coverage_gap(args.event_name, full, paths, labels, unit_suite=unit)
    lines = [
        f"full_suite={'true' if full else 'false'}",
        f"unit_suite={'true' if unit else 'false'}",
        f"coverage_gap={'true' if gap else 'false'}",
    ]
    for line in lines:
        print(line)
    if args.github_output:
        with open(args.github_output, "a", encoding="utf-8") as handle:
            handle.write("\n".join(lines) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
