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
import re
import sys
from collections.abc import Iterable
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from cmux_unit_test_shard import (  # noqa: E402
    DEFAULT_TIMINGS_PATH,
    FOCUSED_GATE_SELECTORS,
    discover_selectors,
    load_timings,
    reweight_selectors,
)

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

# Measured serial test time a changed-suites run may hold. One runner executes
# it as a single batch, so it has to fit comfortably inside the batch timeout
# a normal shard's batch fits in; a larger diff takes all seven shards.
CHANGED_SUITES_BUDGET_MS = 10 * 60 * 1000

# A column-zero declaration. Suites and extensions of suites are what a
# changed-suites run executes; any other one another file can see is a helper.
TOP_LEVEL_DECLARATION_RE = re.compile(
    r"^(?:@[A-Za-z_][A-Za-z0-9_]*(?:\([^)]*\))?\s+)*"
    r"((?:[a-z]+\s+)*)"
    r"(func|enum|struct|class|actor|protocol|extension|let|var|typealias)\s+"
    r"([A-Za-z_][A-Za-z0-9_]*)"
)
FILE_LOCAL_MODIFIERS = {"private", "fileprivate"}


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


def suites_declared_in(
    root: Path, paths: Iterable[str] | None, added: Iterable[str] = ()
) -> list[str]:
    """The cmuxTests/ suites declared or extended in the changed files.

    Returns an empty list, meaning "run every suite", whenever the answer could
    be incomplete: an unreadable diff, a changed file under cmuxTests/ that is
    not Swift, or an existing one that declares no suite or declares anything
    else other files can see. A helper like that can change the behavior of
    any suite, and nothing here can say which. A file `added` by this diff is
    the exception: nothing called it before, so only files this diff also
    changed can use it.
    """
    if paths is None:
        return []
    new_files = {path.strip() for path in added}
    suites: set[str] = set()
    for path in (path.strip() for path in paths):
        if not path.startswith(UNIT_JUDGED_PREFIXES):
            continue
        source = root / path
        if not source.exists():
            # Deleted: nothing of it is left to run.
            continue
        if not path.endswith(".swift"):
            return []
        try:
            lines = source.read_text(encoding="utf-8").splitlines()
        except (OSError, UnicodeError):
            return []
        declared: set[str] = set()
        shares_helpers = False
        for line in lines:
            match = TOP_LEVEL_DECLARATION_RE.match(line)
            if match is None:
                continue
            modifiers, kind, name = match.groups()
            if name.endswith("Tests") and kind in {"class", "struct", "actor", "extension"}:
                declared.add(name)
            elif not FILE_LOCAL_MODIFIERS & set(modifiers.split()):
                shares_helpers = True
        if (shares_helpers or not declared) and path not in new_files:
            return []
        suites |= declared
    return sorted(f"cmuxTests/{name}" for name in suites)


def changed_unit_selectors(
    root: Path, paths: Iterable[str] | None, added: Iterable[str] = ()
) -> list[str]:
    """Suite selectors for a unit run the diff selected, or [] for all of them.

    A pull request that edits a few tests needs those tests run, not the
    other few thousand across seven shards. An empty answer keeps the full
    unit suite: see suites_declared_in(), plus a suite a strict step owns
    (those need an app host of their own, which one shared batch is not) and
    a changed set whose measured time would not fit one batch.
    """
    suites = suites_declared_in(root, paths, added)
    if not suites or FOCUSED_GATE_SELECTORS & set(suites):
        return []
    wanted = {suite.split("/", 1)[1] for suite in suites}
    selectors, _ = reweight_selectors(discover_selectors(root), load_timings(DEFAULT_TIMINGS_PATH))
    cost = sum(
        selector.weight for selector in selectors if selector.identifier.split("/")[1] in wanted
    )
    if cost > CHANGED_SUITES_BUDGET_MS:
        return []
    return suites


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
    parser.add_argument(
        "--added-from",
        help="paths the diff adds, one per line; omit when unknown, which treats none as new",
    )
    parser.add_argument("--root", type=Path, default=Path.cwd())
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

    added: list[str] = []
    if args.added_from:
        try:
            with open(args.added_from, encoding="utf-8") as handle:
                added = handle.read().splitlines()
        except (OSError, UnicodeError):
            added = []

    full = wants_full_suite(args.event_name, args.pull_request_policy, labels)
    unit = wants_unit_suite(args.event_name, args.pull_request_policy, labels, paths)
    gap = coverage_gap(args.event_name, full, paths, labels, unit_suite=unit)
    # Only a unit run the diff asked for narrows. `full-ci` and `unit-ci` are
    # explicit requests for every suite.
    asked_for_every_suite = full or UNIT_SUITE_LABEL in {label.strip() for label in labels or ()}
    selectors = [] if not unit or asked_for_every_suite else changed_unit_selectors(args.root, paths, added)
    lines = [
        f"full_suite={'true' if full else 'false'}",
        f"unit_suite={'true' if unit else 'false'}",
        f"unit_selectors={' '.join(selectors)}",
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
