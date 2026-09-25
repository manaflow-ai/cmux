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
from test_impact import affected_suites, changed_lines  # noqa: E402
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

# Compile admission builds the app-host product and stops, unless it runs a
# changed-suites run itself (runs_in_admission). Restoring the product on a
# shard's runner and running tests against it happens only in `app-host unit
# tests`, so a compile-only pull request that edits that path runs none of its
# change. These are the paths that job's steps run and nothing else in a pull
# request exercises the same way; the artifact transport scripts are left out
# because ci-artifact-transport.yml runs them on their own edits.
#
# The canary only rides on a compile the pull request pays for anyway: ci.yml
# drops it when the build inputs were already compiled, which covers most of
# these paths on their own, since the fingerprint leaves them out. It never
# adds a compile just to run the canary.
MACOS_WORKFLOW_PATH = ".github/workflows/ci-macos.yml"
APP_HOST_CONSUMER_JOB = "app-host-unit-tests"
APP_HOST_CONSUMER_PATHS = (
    MACOS_WORKFLOW_PATH,  # only hunks inside APP_HOST_CONSUMER_JOB count
    "scripts/ci/app-host-isolation.sh",
    "scripts/ci/app-host-known-failures.json",
    "scripts/ci/app-host-processes.sh",
    "scripts/ci/app_host_result_accounting.py",
    "scripts/ci/app_host_test_lock.py",
    "scripts/ci/app_host_test_products.py",
    "scripts/ci/classify-app-host-test-output.py",
    "scripts/ci/cleanup-app-host-home.sh",
    "scripts/ci/cmux_unit_test_shard.py",
    "scripts/ci/collect-app-host-diagnostics.sh",
    "scripts/ci/enable-xctest-automation-mode.sh",
    "scripts/ci/enumerate-app-host-tests.sh",
    "scripts/ci/prepare-app-host-home.sh",
    "scripts/ci/require_selected_test_execution.sh",
    "scripts/ci/restore-app-host-test-product.sh",
    "scripts/ci/run-and-capture.sh",
    "scripts/ci/run-app-host-unit-batches.sh",
    "scripts/ci/run-app-host-xcodebuild.sh",
    "scripts/ci/run-in-console-session.sh",
    "scripts/ci/xcodebuild_noninteractive.py",
)
# What a consumer edit runs instead of seven shards: one small, pure-logic
# XCTest suite (57 tests, 62 ms measured) on the changed-suites worker. It
# proves the product restored, the app host launched, and selected tests
# executed and were accounted for, which is what a consumer edit can break.
CONSUMER_CANARY_SELECTOR = "cmuxTests/CmuxSSHURLRequestTests"


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


def strict_steps(workflow: str, suites: Iterable[str]) -> list[str] | None:
    """Names of the app-host steps that run `suites` a strict step owns.

    Such a suite gets an app host and settings of its own from its step, so a
    changed-suites run runs that step rather than putting the suite in its
    shared batch. None when a selected strict suite has no step that names it.
    """
    job = workflow[workflow.index("\n  app-host-unit-tests:\n") :]
    job = job[: re.search(r"\n  [A-Za-z0-9_-]+:\n", job[1:]).start() + 1]
    owners: dict[str, set[str]] = {}
    for block in job.split("\n      - name: ")[1:]:
        name = block.split("\n", 1)[0].strip()
        condition = re.search(r"^        if: (.*)$", block, re.M)
        if condition is None or "_SHARD)" not in condition.group(1) or "!=" in condition.group(1):
            continue
        for selector in FOCUSED_GATE_SELECTORS:
            if re.search(rf"\b{selector.split('/', 1)[1]}\b", block):
                owners.setdefault(selector, set()).add(name)
    names: set[str] = set()
    for suite in suites:
        if suite in FOCUSED_GATE_SELECTORS:
            if suite not in owners:
                return None
            names |= owners[suite]
    return sorted(names)


def changed_unit_selectors(
    root: Path, paths: Iterable[str] | None, diff: str | None = None
) -> list[str]:
    """Suite selectors for a unit run the diff selected, or [] for all of them.

    A pull request that edits a few tests needs those tests run, not the
    other few thousand across seven shards. An empty answer keeps the full
    unit suite: see test_impact.affected_suites(), strict_steps(), and a
    shared batch whose measured time would not fit one worker's.
    """
    if paths is None:
        return []
    suites = affected_suites(root, [path.strip() for path in paths], diff)
    if not suites:
        return []
    workflow = (root / ".github/workflows/ci-macos.yml").read_text(encoding="utf-8")
    if strict_steps(workflow, suites) is None:
        return []
    wanted = {suite.split("/", 1)[1] for suite in suites}
    selectors, _ = reweight_selectors(discover_selectors(root), load_timings(DEFAULT_TIMINGS_PATH))
    cost = sum(
        selector.weight for selector in selectors if selector.identifier.split("/")[1] in wanted
    )
    if cost > CHANGED_SUITES_BUDGET_MS:
        return []
    return suites


def job_lines(workflow: str, job: str) -> range | None:
    """1-based line numbers of `job` in a workflow's text, header included."""
    lines = workflow.splitlines()
    try:
        start = lines.index(f"  {job}:") + 1
    except ValueError:
        return None
    end = next(
        (
            number
            for number, line in enumerate(lines[start:], start=start + 1)
            if re.match(r"^  [A-Za-z0-9_-]+:$", line)
        ),
        len(lines) + 1,
    )
    return range(start, end)


def admission_route_lines(workflow: str) -> set[int]:
    """1-based lines of compile admission that route the product's consumers.

    Its `outputs:` block, and the CMUX_PRODUCT_RUNNER and CMUX_CI_XCODE_APP
    env the `runner` and `xcode_app` outputs read: the shards run on that pool
    and pin that Xcode (#14163).
    """
    job = job_lines(workflow, "macos-compile-admission")
    if job is None:
        return set()
    lines = workflow.splitlines()
    route: set[int] = set()
    in_outputs = False
    for number in job:
        text = lines[number - 1]
        if re.match(r"^    [A-Za-z_-]+:", text):
            in_outputs = text.startswith("    outputs:")
        if in_outputs or re.match(r"^      (CMUX_PRODUCT_RUNNER|CMUX_CI_XCODE_APP):", text):
            route.add(number)
    return route


def consumer_canary_selectors(
    root: Path, paths: Iterable[str] | None, diff: str | None
) -> list[str]:
    """[CONSUMER_CANARY_SELECTOR] when the diff edits the app-host consumer path.

    A ci-macos.yml edit counts only when one of its hunks sits inside
    `app-host unit tests` or compile admission's consumer route
    (admission_route_lines); most of that file is other jobs, which the lanes
    they define already judge. When the diff has no hunks for it, the edit
    cannot be placed and counts. An unreadable file list returns [] because
    the caller already runs every unit suite for it.
    """
    if paths is None:
        return []
    stripped = {path.strip() for path in paths}
    if stripped & set(APP_HOST_CONSUMER_PATHS[1:]):
        return [CONSUMER_CANARY_SELECTOR]
    if MACOS_WORKFLOW_PATH not in stripped:
        return []
    hunks = changed_lines(diff).get(MACOS_WORKFLOW_PATH) if diff else None
    if not hunks:
        return [CONSUMER_CANARY_SELECTOR]
    try:
        workflow = (root / MACOS_WORKFLOW_PATH).read_text(encoding="utf-8")
    except (OSError, UnicodeError):
        return [CONSUMER_CANARY_SELECTOR]
    job = job_lines(workflow, APP_HOST_CONSUMER_JOB)
    route = admission_route_lines(workflow)
    if job is None or any(line in job or line in route for line in hunks):
        return [CONSUMER_CANARY_SELECTOR]
    return []


def runs_in_admission(
    root: Path,
    paths: Iterable[str] | None,
    diff: str | None,
    selectors: Iterable[str],
    steps: Iterable[str],
    canary: bool,
) -> bool:
    """True when compile admission should run `selectors` itself.

    The runner that just compiled the product can run a few suites in less
    time than a separate worker spends queueing, checking out and downloading
    it. It runs only the shared batch, so a suite a strict step owns keeps the
    worker, and so does any diff the consumer canary would flag: that worker is
    what a consumer edit has to prove.
    """
    selectors = list(selectors)
    if not selectors or canary or list(steps):
        return False
    return not consumer_canary_selectors(root, paths, diff)


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
        "--diff-from",
        help="`git diff -U0` of cmuxTests/ and ci-macos.yml; omit to count every line of a changed file",
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

    diff = None
    if args.diff_from:
        try:
            diff = Path(args.diff_from).read_text(encoding="utf-8")
        except (OSError, UnicodeError):
            diff = None

    full = wants_full_suite(args.event_name, args.pull_request_policy, labels)
    unit = wants_unit_suite(args.event_name, args.pull_request_policy, labels, paths)
    gap = coverage_gap(args.event_name, full, paths, labels, unit_suite=unit)
    # Only a unit run the diff asked for narrows. `full-ci` and `unit-ci` are
    # explicit requests for every suite.
    asked_for_every_suite = full or UNIT_SUITE_LABEL in {label.strip() for label in labels or ()}
    selectors = [] if not unit or asked_for_every_suite else changed_unit_selectors(args.root, paths, diff)
    canary = False
    if not unit:
        # Nothing else asked for the unit tests, so a consumer edit takes the
        # one-suite canary rather than seven shards. ci.yml drops it again when
        # the compile is reused: it only rides on a compile this run pays for.
        selectors = consumer_canary_selectors(args.root, paths, diff)
        unit = canary = bool(selectors)
    steps: list[str] = []
    if selectors:
        workflow = (args.root / ".github/workflows/ci-macos.yml").read_text(encoding="utf-8")
        steps = strict_steps(workflow, selectors) or []
    in_admission = runs_in_admission(args.root, paths, diff, selectors, steps, canary)
    lines = [
        f"full_suite={'true' if full else 'false'}",
        f"unit_suite={'true' if unit else 'false'}",
        f"unit_selectors={' '.join(selectors)}",
        f"unit_strict_steps={''.join(f'|{step}' for step in steps) + '|' if steps else ''}",
        f"coverage_gap={'true' if gap else 'false'}",
        f"unit_canary={'true' if canary else 'false'}",
        f"unit_in_admission={'true' if in_admission else 'false'}",
    ]
    for line in lines:
        print(line)
    if args.github_output:
        with open(args.github_output, "a", encoding="utf-8") as handle:
            handle.write("\n".join(lines) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
