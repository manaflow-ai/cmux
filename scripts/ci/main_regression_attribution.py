#!/usr/bin/env python3
"""Name the merged pull requests behind tests that newly fail on main.

main_full_suite.py keeps one issue open while main's full suite is red, but a
red run lists failing jobs, not what broke them, and nobody is told. This
reads a red full-suite run and finds its new failures: app-host tests the
shard ratchet reported as RATCHET_NEW_FAILURE, or xcodebuild listed under
"Failing tests:" in a batch the ratchet does not grade, that are not in the
known-failures catalog and did not fail in the previous full-suite run whose app-host
shards all finished. A failure in a shard that run did not fully grade (a
dedicated lane failed first, or the batch stopped early) is listed as having
no baseline instead. Such a run is only used while the test list and shard
packing are unchanged; otherwise an older, fully graded run is the baseline,
and tests the skipped runs saw failing are not new either.

A batch whose app host xcodebuild restarted (the app crashed, exited or hit a
test timeout) records the test that was running as failed. That test did not
regress: the app died under it. The test in flight at the restart (started in
the live log, never finished) is reported as "the app host crashed while
running it", with the crash signature the log shows (the objc, Swift or
uncaught-exception message before the backtrace), or the diagnostics
artifact to read when the log has none. Every other failure of that batch is
an ordinary failure. When the baseline or a run skipped on the way to it
already showed every signature of the crash, the crash is pre-existing: it
is listed once as recurring and pings nobody, whichever test it hit this
time. A crash with no signature, or with a signature no earlier run showed,
is new.

Each new failure is attributed to the commits between the two runs' head
SHAs, mapped to the pull requests merged into main by those commits. Each
pull request, including the only one in the range, is ranked by whether its
diff reaches the failing test's suite: 2 when it edits the suite
(test_impact.py), 1 when a changed app declaration or string, or a changed
localized string (reverse_test_impact.literal_suites), is named by the suite
(reverse_test_impact.py), 0 otherwise. The top score names the suspects; when
every score is 0 the failure is left unattributed, with the reason, rather
than blaming the range. A tie lists pull requests labeled merged-unverified
(merge_receipt.py: a judging check was not green when they merged) first.

`report` writes a "New since" markdown section for the tracking issue (read
by main_full_suite.py report --extra-section) and comments once on each
suspect pull request, idempotent through a hidden marker keyed on the pull
request and its failing test set, and once per commit range. A test tied between more than
MAX_PINGED_SUSPECTS pull requests is listed in the issue only. The section
ends with a hidden data marker (DATA_PREFIX): the failures, their suspects,
and the commits in the range that can change an app-host test's outcome.
main_regression_bisect.py reads it to rerun and bisect each failure. A new
crash's victims are included with `"crash": true`, so a crash from a pull
request the ranking missed is still bisected; a recurring crash's are not.
Nothing is reverted or re-run here.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
from collections.abc import Callable, Iterable, Mapping
from dataclasses import dataclass, field
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import main_full_suite as suite_run  # noqa: E402
from merge_receipt import LABEL as UNVERIFIED_LABEL  # noqa: E402
from app_host_test_rerun import OUTSIDE_THE_APP, TEST_ROOT  # noqa: E402
from app_host_result_accounting import RESTART_MARKER  # noqa: E402

APP_HOST_JOB_RE = re.compile(r"app-host unit tests \((\d+)/\d+\)")
ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")
TIMESTAMP_RE = re.compile(r"^\d{4}-\d\d-\d\dT[\d:.]+Z ?")
# One ratchet verdict per line.
RATCHET_RE = re.compile(r"^RATCHET_NEW_FAILURE (\S+)\s*$")
# xcodebuild's closing "Failing tests:" block, one tab-indented `Suite.test()`
# per line. Batches the ratchet does not grade (dedicated lanes such as the
# global-search shortcuts batch) name their failures only here.
FAILING_TESTS_HEADER = "Failing tests:"
FAILING_TEST_RE = re.compile(r"^\t(?:cmuxTests\.)?([A-Za-z_][\w.]*)\.([A-Za-z_]\w*\(.*\))\s*$")
EXECUTION_FAILED_MARKERS = ("** TEST EXECUTE FAILED **", "** TEST FAILED **")
RAN_CONCLUSIONS = frozenset({"success", "failure"})
# app_host_result_accounting.py closes every graded batch with one of these.
# Only the accounting's own lines count: a dedicated lane's xcodebuild failure
# stops the shard before its graded batches run.
VERDICT_MARKERS = (
    "RATCHET_NEW_FAILURE ", "typed app-host run passed", "known-main failures tolerated",
    "recorded verdicts:",
)
# ...and prints one of these when a batch's tests did not all report, so a
# test that already failed may be missing from its RATCHET_NEW_FAILURE lines.
INCOMPLETE_MARKERS = (
    "incomplete app-host run:",
    "typed xcresult is incomplete",
    "typed xcresult contains zero Test Case nodes",
    "No typed xcresult test JSON found",
    "is not ratchetable",
    "selector matched zero built tests",
    "nonterminal or unknown result",
)
# app_host_result_accounting.py opens a restarted batch's verdicts with this.
# Every failure it then records was cut short by the app exiting, and one of
# them is the test the app died under.
RESTARTED_VERDICT = "incomplete app-host run: app host restarted"
# xcodebuild_noninteractive.py stops a crash-looping batch with this.
RESTART_BUDGET_ABORT = "Aborted by the app-host restart budget"
# Each batch echoes its xcodebuild command line before it runs.
XCODEBUILD_INVOCATION = "xcodebuild -xctestrun"
# The reason a crashing app host prints before its backtrace.
CRASH_MESSAGE_RES = (
    re.compile(r"^objc\[\d+\]: (.+)$"),
    re.compile(r"\b((?:Fatal error|Precondition failed|Assertion failed): .+)$"),
    re.compile(r"(Terminating app due to uncaught exception .+)$"),
)
# The Swift runtime backtracer's header for a crashed process.
PROGRAM_CRASHED_RE = re.compile(r"^\*\*\* Program crashed: (.+?)(?: at 0x[0-9a-fA-F]+)? \*\*\*$")
# Live lines that start or end a test: XCTest's, then Swift Testing's.
XCTEST_LIVE_RE = re.compile(r"^Test Case '-\[(?:\w+\.)?(\w+) (\w+)\]' (started|passed|failed|skipped)\b")
SWIFT_TESTING_LIVE_RE = re.compile(
    r'^(\u25c7|\u2714|\u2718|\u2799|\u279c) Test ("(?:[^"\\]|\\.)*"|\S+) (started|passed|failed|skipped)\b'
)
SWIFT_TEST_ATTRIBUTE_RE = re.compile(r'@Test\s*\(\s*"((?:[^"\\\n]|\\.)*)"')
SWIFT_FUNC_RE = re.compile(r"\bfunc\s+(\w+)")
# How many lines above that header the message may be.
CRASH_MESSAGE_WINDOW = 12
HEX_RE = re.compile(r"0x[0-9a-fA-F]+")
MAX_SIGNATURE_CHARS = 160
# The shard's upload step names its diagnostics artifact (crash reports, xcresults).
DIAGNOSTICS_ARTIFACT_RE = re.compile(r"^\s*name: (cmux-app-host-diagnostics-\S+)\s*$")
CATALOG = Path(__file__).resolve().parent / "app-host-known-failures.json"
MARKER_PREFIX = "<!-- main-regression-attribution"
MARKER_RE = re.compile(r"<!-- main-regression-attribution pr=(\d+) tests=(\w+) range=(\S+) -->")
# One line of JSON main_regression_bisect.py reads back from the issue.
DATA_PREFIX = "<!-- main-regression-data "
# A longer range is not bisected, and keeps the section well under GitHub's
# comment size limit.
MAX_BISECT_COMMITS = 256
# Bounds on one report, so a long red streak cannot fan out into a comment storm.
MAX_RANKED_PRS = 40
MAX_COMMENTED_PRS = 5
# A test that ties more pull requests than this is listed in the issue but
# pings none of them: that is a guess, and slice 2's bisect should settle it.
MAX_PINGED_SUSPECTS = 3
# Earlier runs tried as the baseline before giving up on a comparison.
MAX_BASELINE_CANDIDATES = 8
MAX_LISTED_TESTS = 30


@dataclass
class PullRequest:
    number: int
    title: str
    url: str
    merge_sha: str
    author: str = ""
    # Suites the diff edits, and suites that name what the diff changes.
    edited_suites: set[str] = field(default_factory=set)
    reached_suites: set[str] = field(default_factory=set)
    # Labeled by merge_receipt.py: a judging check was not green at merge.
    unverified: bool = False
    # The paths its merge commit changes, once rank_inputs read its diff.
    paths: list[str] = field(default_factory=list)
    ranked: bool = False


@dataclass
class HostCrash:
    """App-host restarts in one shard job, and the failures they left behind."""

    shard: str
    job_url: str = ""
    # Normalized crash messages in log order; empty when the log shows none.
    signatures: list[str] = field(default_factory=list)
    # Failures recorded in a batch the app host restarted in, minus the catalog.
    tests: list[str] = field(default_factory=list)
    artifact: str = ""


@dataclass
class CrashFinding:
    """One shard's crash, and the earlier run's crash that makes it not new."""

    crash: HostCrash
    prior: tuple[Mapping[str, object], HostCrash] | None = None


def clean(raw: str) -> str:
    return TIMESTAMP_RE.sub("", ANSI_RE.sub("", raw)).rstrip()


def failing_test_id(line: str) -> str | None:
    """`Suite/test()` for one line of xcodebuild's "Failing tests:" block."""
    listed = FAILING_TEST_RE.match(line)
    return f"{listed.group(1).replace('.', '/')}/{listed.group(2)}" if listed else None


def log_failures(log_text: str, known: Iterable[str] = ()) -> set[str]:
    """Failing test ids in one app-host job log that the known-failures catalog does not list.

    Ratchet verdicts are already graded against the catalog; the xcodebuild
    block is not, so both pass through the catalog here.
    """
    found = set()
    in_block = False
    for raw in log_text.splitlines():
        line = clean(raw)
        match = RATCHET_RE.match(line.strip())
        if match:
            found.add(match.group(1))
        if line.strip() == FAILING_TESTS_HEADER:
            in_block = True
            continue
        if in_block:
            test = failing_test_id(line)
            if test:
                found.add(test)
            else:
                in_block = False
    return found - set(known)


def crash_message(line: str) -> str | None:
    for pattern in CRASH_MESSAGE_RES:
        match = pattern.search(line)
        if match:
            return match.group(1)
    return None


def signature(text: str) -> str:
    """A crash message with addresses and spacing that change every run taken out."""
    first_sentence = HEX_RE.sub("0x*", text).split(". ", 1)[0]
    return " ".join(first_sentence.split())[:MAX_SIGNATURE_CHARS]


def swift_test_names(sources: Iterable[str]) -> dict[str, str]:
    """Swift Testing display name -> function name, over cmuxTests/ sources.

    The live log names a Swift Testing test by its display name when it has
    one; the accounting names it `Suite/function()`. A display name two
    functions share maps to neither.
    """
    names: dict[str, str] = {}
    shared: set[str] = set()
    for text in sources:
        for match in SWIFT_TEST_ATTRIBUTE_RE.finditer(text):
            function = SWIFT_FUNC_RE.search(text, match.end(), match.end() + 600)
            if not function:
                continue
            display = match.group(1)
            if display in names and names[display] != function.group(1):
                shared.add(display)
            names[display] = function.group(1)
    return {display: function for display, function in names.items() if display not in shared}


def function_of(test: str) -> str:
    """`name` for a `Suite/name(...)` or `Suite/name` test id."""
    return test.rsplit("/", 1)[-1].split("(", 1)[0]


def live_test(line: str, display_names: Mapping[str, str]) -> tuple[str, str] | None:
    """(key, state) for a live xcodebuild line that starts or ends a test.

    The key is a `Suite/testName` id for XCTest and a bare function name for
    Swift Testing, whose live lines do not name the suite.
    """
    xctest = XCTEST_LIVE_RE.match(line)
    if xctest:
        return f"{xctest.group(1)}/{xctest.group(2)}", xctest.group(3)
    swift = SWIFT_TESTING_LIVE_RE.match(line)
    if swift and swift.group(2) != "run":
        name = swift.group(2)
        if name.startswith('"'):
            name = display_names.get(name[1:-1], name)
        return name.split("(", 1)[0], swift.group(3)
    return None


def matches(key: str, test: str) -> bool:
    """True when a live-log key names the accounting's test id."""
    if "/" in key:
        return test == key or test.split("(", 1)[0] == key
    return function_of(test) == key


def in_flight_victims(candidates: list[str], in_flight: list[str], failed: set[str], restarts: int) -> list[str]:
    """The failures one restarted batch recorded only because the app host died.

    xcodebuild records the test running at each restart as failed, and every
    genuine failure of the batch as failed too. A candidate the live log saw
    start and never finish is the crash's. When the live log cannot name it
    (a display name no source maps), the failures with no failed line of
    their own are the crash's only if there are exactly as many as restarts
    left unexplained; otherwise none are, and they stay ordinary failures.
    """
    victims = [test for test in candidates if any(matches(key, test) for key in in_flight)]
    unexplained = restarts - len(victims)
    leftover = [
        test for test in candidates
        if test not in victims and not any(matches(key, test) for key in failed)
    ]
    if unexplained > 0 and len(leftover) == unexplained:
        victims += leftover
    return victims


def host_crash(
    log_text: str,
    known: Iterable[str] = (),
    shard: str = "",
    job_url: str = "",
    display_names: Mapping[str, str] | None = None,
) -> HostCrash | None:
    """The app-host restarts one shard log shows, or None when its app host never restarted.

    A batch's failures are what xcodebuild lists under "Failing tests:" and
    what the accounting records under RESTARTED_VERDICT. Of those, only the
    test in flight at a restart is the crash's (in_flight_victims); the rest
    are ordinary failures. The signature is the message printed within
    CRASH_MESSAGE_WINDOW lines above the backtracer's "Program crashed"
    header, else that header's reason; with no header, the last message
    before the restart.
    """
    known = set(known)
    display_names = display_names or {}
    crash = HostCrash(shard=shard, job_url=job_url)
    restarted = in_block = in_verdicts = backtraced = False
    message: str | None = None
    since_message = 0
    # One xcodebuild batch: tests running now, tests running at each restart,
    # tests that printed a failure, the failures it recorded, its restarts.
    running: list[str] = []
    in_flight: list[str] = []
    failed: set[str] = set()
    candidates: list[str] = []
    restarts = 0

    def close_batch() -> None:
        nonlocal running, in_flight, failed, candidates, restarts
        if restarts:
            crash.tests.extend(in_flight_victims(list(dict.fromkeys(candidates)), in_flight, failed, restarts))
        running, in_flight, failed, candidates, restarts = [], [], set(), [], 0

    for raw in log_text.splitlines():
        line = clean(raw)
        stripped = line.strip()
        since_message += 1
        found = crash_message(stripped)
        if found:
            message, since_message = found, 0
        artifact = DIAGNOSTICS_ARTIFACT_RE.match(line)
        if artifact:
            crash.artifact = artifact.group(1)
        header = PROGRAM_CRASHED_RE.match(stripped)
        if header:
            backtraced = True
            text = message if message and since_message <= CRASH_MESSAGE_WINDOW else f"crashed: {header.group(1)}"
            if signature(text) not in crash.signatures:
                crash.signatures.append(signature(text))
        if XCODEBUILD_INVOCATION in line:
            close_batch()
        live = live_test(stripped, display_names)
        if live:
            key, state = live
            if state == "started":
                running.append(key)
            else:
                if key in running:
                    running.remove(key)
                if state == "failed":
                    failed.add(key)
        if RESTART_BUDGET_ABORT in line:
            restarted = True
        if RESTART_MARKER in line:
            if not backtraced and message and signature(message) not in crash.signatures:
                crash.signatures.append(signature(message))
            restarted = True
            restarts += 1
            in_flight += running
            running = []
            backtraced, message = False, None
        if stripped == FAILING_TESTS_HEADER:
            in_block = True
            continue
        if in_block:
            test = failing_test_id(line)
            if test:
                candidates.append(test)
            else:
                in_block = False
        if stripped.startswith(RESTARTED_VERDICT):
            restarted = in_verdicts = True
            continue
        if in_verdicts:
            verdict = RATCHET_RE.match(stripped)
            if verdict:
                candidates.append(verdict.group(1))
            elif not stripped.startswith("RATCHET_KNOWN_FAILURE "):
                in_verdicts = False
                close_batch()
    close_batch()
    if not restarted:
        return None
    crash.tests = [test for test in dict.fromkeys(crash.tests) if test not in known]
    return crash


def prior_crash(
    crash: HostCrash, earlier: Iterable[tuple[Mapping[str, object], HostCrash]],
) -> tuple[Mapping[str, object], HostCrash] | None:
    """An earlier restart that makes this one not new, or None.

    Only a crash whose every signature an earlier run already showed is
    recurring. A crash with no signature cannot be compared, so it is new,
    and so is a shard that crashed a second, new way besides a known one:
    scoring keeps a new crash from pinging a pull request its diff does not
    reach.
    """
    earlier = [(run, other) for run, other in earlier if other.signatures]
    if not crash.signatures:
        return None
    seen = {sig for _, other in earlier for sig in other.signatures}
    if not set(crash.signatures) <= seen:
        return None
    return next((run, other) for run, other in earlier if crash.signatures[0] in other.signatures)


def crash_victims(findings: Iterable[CrashFinding]) -> dict[str, CrashFinding]:
    """Each test an app-host crash cut short, and that crash."""
    victims: dict[str, CrashFinding] = {}
    for finding in findings:
        for test in finding.crash.tests:
            victims.setdefault(test, finding)
    return victims


def shard_log_complete(log_text: str) -> bool:
    """True when a failed shard graded every batch, so its failures are the full set."""
    return any(text in log_text for text in VERDICT_MARKERS) and not any(
        text in log_text for text in INCOMPLETE_MARKERS
    )


def app_host_jobs(jobs: Iterable[Mapping[str, object]]) -> list[Mapping[str, object]]:
    return [job for job in jobs if APP_HOST_JOB_RE.search(str(job.get("name") or ""))]


def app_host_ran(jobs: Iterable[Mapping[str, object]]) -> bool:
    """True when every app-host shard finished, so its failures are a full picture."""
    shards = app_host_jobs(jobs)
    return bool(shards) and all(job.get("conclusion") in RAN_CONCLUSIONS for job in shards)


def earlier_tested_runs(
    runs: Iterable[Mapping[str, object]], current: Mapping[str, object], branch: str = "main",
) -> list[Mapping[str, object]]:
    """Completed green or red full-suite runs created before `current`, newest first."""
    created = str(current.get("created_at") or "")
    earlier = [
        run for run in runs
        if suite_run.is_main_full_suite_run(run, branch)
        and run.get("status") == "completed"
        and run.get("conclusion") in suite_run.TESTED_CONCLUSIONS
        and run.get("id") != current.get("id")
        and str(run.get("created_at") or "") < created
    ]
    earlier.sort(key=lambda run: str(run.get("created_at") or ""), reverse=True)
    return earlier


def shard_of(job: Mapping[str, object]) -> str:
    match = APP_HOST_JOB_RE.search(str(job.get("name") or ""))
    return match.group(1) if match else ""


def new_failures(
    current: Mapping[str, list[str]],
    current_shards: Mapping[str, set[str]],
    previous: set[str],
    ungraded: set[str],
) -> tuple[dict[str, list[str]], list[str]]:
    """(new failure -> job URLs, failures with no baseline) against the previous run.

    A test that failed only in shards the previous run did not grade has no
    baseline: it may have been failing there unseen, so it is not called new.
    """
    new: dict[str, list[str]] = {}
    unknown: list[str] = []
    for test, jobs in sorted(current.items()):
        if test in previous:
            continue
        if current_shards.get(test, set()) <= ungraded:
            unknown.append(test)
        else:
            new[test] = jobs
    return new, unknown


def merged_prs(
    range_shas: Iterable[str], associated: Mapping[str, list[Mapping[str, object]]], branch: str = "main",
) -> tuple[list[PullRequest], list[str]]:
    """Pull requests merged into `branch` by a commit in the range, oldest first, and direct commits.

    A commit also lists open or unrelated pull requests that contain it, so a
    pull request counts only when its merge commit is itself in the range.
    """
    ordered = list(range_shas)
    in_range = set(ordered)
    found: dict[int, PullRequest] = {}
    covered: set[str] = set()
    for sha in ordered:
        for pr in associated.get(sha, []):
            merge_sha = str(((pr.get("mergeCommit") or {}) or {}).get("oid") or "")
            if pr.get("state") != "MERGED" or pr.get("baseRefName") != branch or merge_sha not in in_range:
                continue
            covered.add(sha)
            number = int(pr["number"])
            if number not in found:
                found[number] = PullRequest(
                    number=number,
                    title=str(pr.get("title") or ""),
                    url=str(pr.get("url") or ""),
                    merge_sha=merge_sha,
                    author=str(((pr.get("author") or {}) or {}).get("login") or ""),
                    unverified=any(
                        label.get("name") == UNVERIFIED_LABEL
                        for label in ((pr.get("labels") or {}).get("nodes") or [])
                    ),
                )
    merge_order = {sha: index for index, sha in enumerate(reversed(ordered))}
    prs = sorted(found.values(), key=lambda pr: merge_order.get(pr.merge_sha, 0))
    direct = [sha for sha in ordered if sha not in covered]
    return prs, direct


def suite_of(test: str) -> str:
    return test.split("/", 1)[0]


def score(test: str, pr: PullRequest) -> int:
    name = suite_of(test)
    if name in pr.edited_suites:
        return 2
    if name in pr.reached_suites:
        return 1
    return 0


def suspects_for(
    test: str, prs: list[PullRequest], direct: Iterable[str] = (),
) -> tuple[list[PullRequest], str]:
    """(suspects, how) for one failing test; no suspects when the range gives no signal.

    The only pull request in the range is scored like any other: being alone
    says it merged nearby, not that its diff reaches the failing suite.
    """
    direct = list(direct)
    if not prs:
        return [], "no merged pull request in the range"
    scored = [(score(test, pr), pr) for pr in prs]
    best = max((value for value, _ in scored), default=0)
    if best == 0:
        if len(prs) == 1 and not direct:
            return [], lone_reason(prs[0])
        return [], "no pull request in the range reaches this suite"
    how = "edits the suite" if best == 2 else "changes code the suite names"
    if len(prs) == 1 and not direct:
        how = f"only pull request in the range; {how}"
    tied = [pr for value, pr in scored if value == best]
    # A pull request that merged before its checks passed is listed first in a
    # tie; the others stay, since a verified head can still break main
    # through an interaction with another merge.
    tied.sort(key=lambda pr: not pr.unverified)
    return tied, how


def split_crashes(
    failures: Mapping[str, list[str]], findings: Iterable[CrashFinding],
) -> tuple[dict[str, list[str]], dict[str, list[str]], dict[str, HostCrash]]:
    """(regressions, failures to attribute, attributed tests a crash cut short) among new failures.

    A test a crash cut short is reported with the crash, not as a
    regression; only a new crash's victims are bisected. A new crash's tests are still
    attributed, so a pull request whose diff reaches the suite hears about
    it; a recurring crash's tests are attributed to nobody.
    """
    victims = crash_victims(findings)
    regressions = {test: jobs for test, jobs in failures.items() if test not in victims}
    attributed = {
        test: jobs for test, jobs in failures.items() if test not in victims or victims[test].prior is None
    }
    crashed = {test: victims[test].crash for test in attributed if test in victims}
    return regressions, attributed, crashed


def lone_reason(pr: PullRequest) -> str:
    """Why the only pull request in the range is not named."""
    if not pr.ranked:
        return "the only pull request in the range could not be diffed"
    if pr.paths and all(path.startswith(OUTSIDE_THE_APP) and not path.startswith(TEST_ROOT) for path in pr.paths):
        return "the only pull request in the range changes nothing the app host loads"
    return "the only pull request in the range does not reach this suite"


def tests_digest(tests: Iterable[str]) -> str:
    return hashlib.sha256("\n".join(sorted(tests)).encode()).hexdigest()[:16]


def commit_range(previous: Mapping[str, object], run: Mapping[str, object]) -> str:
    return f"{short(str(previous.get('head_sha') or ''))}..{short(str(run.get('head_sha') or ''))}"


def marker(pr_number: int, tests: Iterable[str], range_: str) -> str:
    return f"{MARKER_PREFIX} pr={pr_number} tests={tests_digest(tests)} range={range_} -->"


def already_told(bodies: Iterable[str], pr_number: int, tests: Iterable[str], range_: str) -> bool:
    """A pull request hears once per failing test set, and once per commit range.

    The range covers a re-run of the same red run whose failing set shifted.
    """
    digest = tests_digest(tests)
    for body in bodies:
        for number, seen_digest, seen_range in MARKER_RE.findall(body or ""):
            if int(number) == pr_number and (seen_digest == digest or seen_range == range_):
                return True
    return False


def short(sha: str) -> str:
    return sha[:10]


def outcome_commits(log_text: str) -> list[str]:
    """Commits, oldest first, whose diff can change an app-host test's outcome.

    Reads `git log --first-parent --reverse --diff-merges=first-parent
    --name-only --format=%x00%H`. A commit that only touches paths no
    app-host product or test reads (docs, web, CI scripts) cannot make a test
    start failing, so a bisect skips it.
    """
    relevant: list[str] = []
    for record in log_text.split("\0"):
        lines = [line.strip() for line in record.strip().splitlines() if line.strip()]
        if not lines:
            continue
        sha, paths = lines[0], lines[1:]
        if any(path.startswith(TEST_ROOT) or not path.startswith(OUTSIDE_THE_APP) for path in paths):
            relevant.append(sha)
    return relevant


def data_marker(
    *,
    run: Mapping[str, object],
    previous: Mapping[str, object],
    failures: Mapping[str, list[str]],
    attributions: Mapping[str, tuple[list[PullRequest], str]],
    prs: list[PullRequest],
    commits: list[str],
    crashed: Iterable[str] = (),
) -> str:
    """The hidden JSON main_regression_bisect.py reads: regressions, then new crashes' victims.

    A victim of a crash no earlier run had carries `"crash": true`, so a crash
    a pull request the scorer missed caused is still bisected. A recurring
    crash's victims are left out: every commit in the range would reproduce it.
    """
    crashed = [test for test in crashed if test not in failures]
    bisected = commits if len(commits) <= MAX_BISECT_COMMITS else None
    listed = set(bisected or ())
    data = {
        "v": 1,
        "run_id": run.get("id"),
        "run_url": run.get("html_url"),
        "head": run.get("head_sha"),
        "prev": previous.get("head_sha"),
        "prev_run_url": previous.get("html_url"),
        "tests": [
            {
                "test": test,
                "suspects": [pr.number for pr in attributions[test][0]],
                "how": attributions[test][1],
                **({"crash": True} if test in crashed else {}),
            }
            for test in [*failures, *crashed][:MAX_LISTED_TESTS]
        ],
        "prs": {pr.merge_sha: pr.number for pr in prs if pr.merge_sha in listed},
        "commits": bisected,
    }
    return f"{DATA_PREFIX}{json.dumps(data, separators=(',', ':'))} -->"


def named(attribution: tuple[list[PullRequest], str]) -> str:
    suspects, how = attribution
    return f"{', '.join(f'#{pr.number}' for pr in suspects) or 'unattributed'} ({how})"


def crash_lines(
    run: Mapping[str, object],
    findings: list[CrashFinding],
    attributions: Mapping[str, tuple[list[PullRequest], str]],
) -> list[str]:
    """One line per distinct crash: where it hit, what it cut short, and whether it is new.

    Shards that crashed the same way share a line, so a crash that moves
    between tests from run to run is reported once, not as a new failure of
    each test it lands on.
    """
    groups: dict[tuple[str, bool], list[CrashFinding]] = {}
    for finding in findings:
        key = (finding.crash.signatures[0] if finding.crash.signatures else "", finding.prior is not None)
        groups.setdefault(key, []).append(finding)
    lines = ["App host crashes. The test running when the app host died is recorded as failed; it is listed here, not as a new failure:"]
    for (sig, recurring), group in groups.items():
        where = ", ".join(f"[shard {finding.crash.shard}]({finding.crash.job_url})" for finding in group)
        tests = list(dict.fromkeys(test for finding in group for test in finding.crash.tests))
        running = ", ".join(f"`{test}`" for test in tests[:MAX_LISTED_TESTS]) or "no recorded test"
        if sig:
            what = f"`{sig}`"
        else:
            artifacts = ", ".join(f"`{finding.crash.artifact}`" for finding in group if finding.crash.artifact)
            what = (
                "no crash message in the log; the backtrace is in the "
                + (f"{artifacts} artifact" if artifacts else "shard's app-host diagnostics artifact")
                + f" of [this run]({run.get('html_url')}#artifacts)"
            )
        line = f"- {what} in {where}, while running {running}"
        if recurring:
            prior_run, prior = next(finding.prior for finding in group if finding.prior)
            line += (
                f". Not new: [an earlier run]({prior_run.get('html_url')}) at "
                f"`{short(str(prior_run.get('head_sha') or ''))}` had the same crash (shard {prior.shard})."
            )
        else:
            verdicts = [f"`{test}` {named(attributions[test])}" for test in tests if test in attributions]
            line += ". New since the baseline" + (": " + "; ".join(verdicts) if verdicts else ".")
        lines.append(line)
    return lines


def issue_section(
    *,
    repo: str,
    run: Mapping[str, object],
    previous: Mapping[str, object] | None,
    failures: Mapping[str, list[str]],
    attributions: Mapping[str, tuple[list[PullRequest], str]],
    prs: list[PullRequest],
    direct: list[str],
    no_baseline: Iterable[str] = (),
    commits: list[str] | None = None,
    crashes: Iterable[CrashFinding] = (),
    crashed: Iterable[str] = (),
) -> str:
    """The tracking issue's section for one red run.

    `failures` are the regressions; tests an app-host crash cut short are
    listed under `crashes` instead, with their suspects in `attributions`
    when the crash is new; `crashed` names those, for the bisect data.
    """
    if previous is None:
        return "### New failures\n\nNo earlier full-suite run with every app-host shard finished to compare against."
    prev_sha = str(previous.get("head_sha") or "")
    head_sha = str(run.get("head_sha") or "")
    lines = [
        f"### New since `{short(prev_sha)}`",
        "",
        f"Compared with [the previous full-suite run]({previous.get('html_url')}) "
        f"({previous.get('conclusion')}); commits: "
        f"https://github.com/{repo}/compare/{prev_sha}...{head_sha}",
        "",
    ]
    no_baseline = list(no_baseline)
    if no_baseline:
        lines += [
            "Not compared, because that run's shard stopped before grading them: "
            + ", ".join(f"`{test}`" for test in no_baseline[:MAX_LISTED_TESTS]),
            "",
        ]
    crashes = list(crashes)
    if crashes:
        lines += crash_lines(run, crashes, attributions) + [""]
    if not failures and not crashes:
        lines.append("No app-host test fails here that did not already fail in that run.")
        return "\n".join(lines)
    if not failures:
        lines.append("No other app-host test fails here that did not already fail in that run.")
    else:
        lines += ["Test | Suspect | Jobs", "--- | --- | ---"]
        for test in list(failures)[:MAX_LISTED_TESTS]:
            jobs = " ".join(f"[job]({url})" for url in failures[test][:3])
            lines.append(f"`{test}` | {named(attributions[test])} | {jobs}")
        if len(failures) > MAX_LISTED_TESTS:
            lines.append(f"...and {len(failures) - MAX_LISTED_TESTS} more | |")
    if not failures and not attributions:
        return "\n".join(lines)
    lines += ["", f"Pull requests merged in the range: " + (", ".join(f"#{pr.number}" for pr in prs) or "none")]
    if direct and not prs:
        lines.append("Commits without a merged pull request: " + ", ".join(short(sha) for sha in direct[:10]))
    if commits is not None:
        lines += ["", data_marker(
            run=run, previous=previous, failures=failures, attributions=attributions, prs=prs, commits=commits,
            crashed=crashed,
        )]
    return "\n".join(lines)


def pr_comment(
    *,
    repo: str,
    pr: PullRequest,
    tests: list[str],
    how: Mapping[str, str],
    run: Mapping[str, object],
    previous: Mapping[str, object],
    failures: Mapping[str, list[str]],
    others: Mapping[str, list[int]],
    crashed: Mapping[str, HostCrash] | None = None,
) -> str:
    """The comment one suspect pull request gets; `crashed` maps tests an app-host crash cut short to it."""
    crashed = crashed or {}
    prev_sha = str(previous.get("head_sha") or "")
    head_sha = str(run.get("head_sha") or "")
    verb = "newly fail or crash the app host" if any(test in crashed for test in tests) else "newly fail"
    lines = [
        marker(pr.number, tests, commit_range(previous, run)),
        f"These app-host tests {verb} in [main's full suite]({run.get('html_url')}) "
        f"at `{short(head_sha)}`, after this pull request merged. They did not fail in "
        f"[the previous full-suite run]({previous.get('html_url')}) at `{short(prev_sha)}`, "
        "and are not in `scripts/ci/app-host-known-failures.json`.",
        "",
    ]
    for test in tests[:MAX_LISTED_TESTS]:
        jobs = " ".join(f"[job]({url})" for url in failures[test][:3])
        shared = others.get(test) or []
        also = f"; also suspected: {', '.join(f'#{n}' for n in shared)}" if shared else ""
        crash = crashed.get(test)
        died = ""
        if crash is not None:
            died = "the app host crashed while running it" + (
                f": `{crash.signatures[0]}`; " if crash.signatures else "; "
            )
        lines.append(f"- `{test}` ({died}{how[test]}{also}) {jobs}")
    if len(tests) > MAX_LISTED_TESTS:
        lines.append(f"- ...and {len(tests) - MAX_LISTED_TESTS} more")
    lines += [
        "",
        f"Commits in the range: https://github.com/{repo}/compare/{prev_sha}...{head_sha}",
        "",
        "Pull requests run only the suites their diff reaches, so main's full suite is where "
        "this shows first. If this pull request is the cause, please fix forward or revert; if "
        "it is not, say so here. This is an automated attribution and can be wrong, most often "
        "for a flaky test.",
    ]
    return "\n".join(lines)


def comment_plan(
    failures: Mapping[str, list[str]], attributions: Mapping[str, tuple[list[PullRequest], str]],
) -> list[tuple[PullRequest, list[str], dict[str, str], dict[str, list[int]]]]:
    """(pr, its tests, how each was attributed, co-suspects per test) per suspect pull request."""
    by_pr: dict[int, tuple[PullRequest, list[str], dict[str, str], dict[str, list[int]]]] = {}
    for test in failures:
        suspects, how = attributions[test]
        if len(suspects) > MAX_PINGED_SUSPECTS:
            continue
        for pr in suspects:
            entry = by_pr.setdefault(pr.number, (pr, [], {}, {}))
            entry[1].append(test)
            entry[2][test] = how
            others = [other.number for other in suspects if other.number != pr.number]
            if others:
                entry[3][test] = others
    return list(by_pr.values())


def untold(
    plan: Iterable[tuple[PullRequest, list[str], dict[str, str], dict[str, list[int]]]],
    told: Callable[[PullRequest, list[str]], bool],
) -> list[tuple[PullRequest, list[str], dict[str, str], dict[str, list[int]]]]:
    """The first MAX_COMMENTED_PRS planned comments whose pull request was not told yet.

    The cap counts comments this report posts, so suspects told by an earlier report do
    not use it up and crowd out one that has not heard.
    """
    chosen = []
    for entry in plan:
        if len(chosen) >= MAX_COMMENTED_PRS:
            break
        pr, tests = entry[0], entry[1]
        if told(pr, tests):
            print(f"#{pr.number} already told about these tests.")
            continue
        chosen.append(entry)
    return chosen


# ---- I/O ---------------------------------------------------------------------------------


def gh(args: list[str]) -> str:
    return subprocess.run(["gh", *args], check=True, capture_output=True, text=True).stdout


def git(root: Path, *args: str) -> str:
    return subprocess.run(
        ["git", "-C", str(root), *args], check=True, capture_output=True, text=True, errors="replace",
    ).stdout


def run_jobs(repo: str, run_id: object) -> list[dict]:
    return suite_run.gh_json_lines([
        f"repos/{repo}/actions/runs/{run_id}/jobs", "--paginate",
        "-X", "GET", "-f", "filter=latest", "-f", "per_page=100",
        "--jq", ".jobs[] | {id, name, conclusion, html_url} | tojson",
    ])


def job_failures(
    repo: str, jobs: list[Mapping[str, object]], known: Iterable[str],
    display_names: Mapping[str, str] | None = None,
) -> tuple[dict[str, list[str]], dict[str, set[str]], set[str], list[HostCrash]]:
    """(failing test -> job URLs, failing test -> shards, shards that did not grade every test,
    shards whose app host restarted) for one run."""
    from app_host_failure_census import _gh_api_escape_flag

    failures: dict[str, list[str]] = {}
    shards: dict[str, set[str]] = {}
    ungraded: set[str] = set()
    crashes: list[HostCrash] = []
    for job in app_host_jobs(jobs):
        if job.get("conclusion") != "failure":
            continue
        log = gh(["api", *_gh_api_escape_flag(), f"repos/{repo}/actions/jobs/{job['id']}/logs"])
        if not shard_log_complete(ANSI_RE.sub("", log)):
            ungraded.add(shard_of(job))
        for test in log_failures(log, known):
            failures.setdefault(test, []).append(str(job.get("html_url") or ""))
            shards.setdefault(test, set()).add(shard_of(job))
        crash = host_crash(log, known, shard_of(job), str(job.get("html_url") or ""), display_names)
        if crash is not None:
            crashes.append(crash)
    return failures, shards, ungraded, crashes


# What decides which physical shard runs a test. The lane env vars in
# ci-macos.yml also do, but that file changes too often to gate on.
SHARD_INPUTS = (
    "cmuxTests",
    "scripts/ci/cmux-unit-test-timings.json",
    "scripts/ci/cmux_unit_test_shard.py",
    "scripts/ci/run-app-host-unit-batches.sh",
)


def shard_map_changed(root: Path, base: str, head: str) -> bool:
    """True unless the test list and shard packing are the same at both commits."""
    result = subprocess.run(
        ["git", "-C", str(root), "diff", "--quiet", base, head, "--", *SHARD_INPUTS],
        capture_output=True, text=True,
    )
    return result.returncode != 0


def associated_prs(repo: str, shas: list[str]) -> dict[str, list[dict]]:
    owner, name = repo.split("/", 1)
    result: dict[str, list[dict]] = {}
    for start in range(0, len(shas), 40):
        chunk = shas[start:start + 40]
        fields = " ".join(
            f'c{index}: object(oid: "{sha}") {{ ... on Commit {{ associatedPullRequests(first: 5) '
            "{ nodes { number title url state baseRefName author { login } mergeCommit { oid } "
            "labels(first: 20) { nodes { name } } } } } }"
            for index, sha in enumerate(chunk)
        )
        query = f'query {{ repository(owner: "{owner}", name: "{name}") {{ {fields} }} }}'
        data = json.loads(gh(["api", "graphql", "-f", f"query={query}"]))["data"]["repository"]
        for index, sha in enumerate(chunk):
            node = data.get(f"c{index}") or {}
            result[sha] = ((node.get("associatedPullRequests") or {}).get("nodes")) or []
    return result


def overlay(files: Mapping[str, str], changes: Mapping[str, str | None]) -> dict[str, str]:
    """`files` with changed paths replaced by their text, or removed when None."""
    result = dict(files)
    for path, text in changes.items():
        if text is None:
            result.pop(path, None)
        else:
            result[path] = text
    return result


def xcstrings_literals(old_text: str, new_text: str) -> set[str]:
    """Keys, and old and new values, of the entries a string catalog diff changes."""

    def entries(text: str) -> dict:
        try:
            data = json.loads(text) if text.strip() else {}
        except json.JSONDecodeError:
            return {}
        strings = data.get("strings") if isinstance(data, dict) else None
        return strings if isinstance(strings, dict) else {}

    def values(node: object) -> Iterable[str]:
        if isinstance(node, dict):
            for key, value in node.items():
                if key == "value" and isinstance(value, str):
                    yield value
                else:
                    yield from values(value)
        elif isinstance(node, list):
            for item in node:
                yield from values(item)

    old, new = entries(old_text), entries(new_text)
    found: set[str] = set()
    for key in set(old) | set(new):
        if old.get(key) == new.get(key):
            continue
        found.add(key)
        found |= set(values(old.get(key))) ^ set(values(new.get(key)))
    return found


def rank_inputs(root: Path, prs: list[PullRequest]) -> None:
    """Fill each pull request's suite sets from its merge commit's diff.

    The trees are read once from the checkout. Each pull request's own changed
    files are read at its merge commit, so its hunks' line numbers match the
    text they are resolved against.
    """
    import tempfile

    import reverse_test_impact
    import test_impact

    head_files = reverse_test_impact.read_root(root)
    for pr in prs[:MAX_RANKED_PRS]:
        base = f"{pr.merge_sha}^1"
        try:
            status = git(root, "diff", "--no-renames", "--name-status", base, pr.merge_sha).splitlines()
            test_diff = git(root, "diff", "--no-renames", "-U0", base, pr.merge_sha, "--", "cmuxTests")
            app_diff = git(
                root, "diff", "--no-renames", "-U0", base, pr.merge_sha,
                "--", "Sources", "Packages/macOS", "Packages/Shared", "CLI",
            )
            changes: dict[str, str | None] = {}
            for line in status:
                code, _, path = line.partition("\t")
                if path.endswith(".swift") and path.startswith(reverse_test_impact.TREE_PREFIXES):
                    changes[path] = None if code == "D" else git(root, "show", f"{pr.merge_sha}:{path}")
            # A test that asserts on localized text spells the entry's key or
            # a value, which no Swift diff shows when only the catalog changed.
            literals: set[str] = set()
            for line in status:
                code, _, path = line.partition("\t")
                if path.endswith(".xcstrings") and not path.startswith(OUTSIDE_THE_APP):
                    literals |= xcstrings_literals(
                        "" if code == "A" else git(root, "show", f"{base}:{path}"),
                        "" if code == "D" else git(root, "show", f"{pr.merge_sha}:{path}"),
                    )
        except subprocess.CalledProcessError as error:
            print(f"::warning::Could not diff #{pr.number}: {(error.stderr or '').strip()}", file=sys.stderr)
            continue
        files = overlay(head_files, changes)
        paths = [line.partition("\t")[2] for line in status]
        pr.paths, pr.ranked = paths, True
        if any(path.startswith("cmuxTests/") for path in paths):
            with tempfile.TemporaryDirectory(prefix="attribution-") as scratch:
                for path, text in files.items():
                    if path.startswith("cmuxTests/"):
                        target = Path(scratch) / path
                        target.parent.mkdir(parents=True, exist_ok=True)
                        target.write_text(text, encoding="utf-8")
                edited = test_impact.affected_suites(Path(scratch), paths, test_diff) or []
            pr.edited_suites = {suite.removeprefix("cmuxTests/") for suite in edited}
        pr.reached_suites = set(reverse_test_impact.select(files, app_diff).suites)
        pr.reached_suites |= reverse_test_impact.literal_suites(files, literals)


def pr_comment_bodies(repo: str, number: int) -> list[str]:
    owner, name = repo.split("/", 1)
    query = (
        'query($owner: String!, $name: String!, $number: Int!) { repository(owner: $owner, name: $name) '
        "{ pullRequest(number: $number) { comments(last: 100) { nodes { body } } } } }"
    )
    data = json.loads(gh([
        "api", "graphql", "-f", f"query={query}", "-f", f"owner={owner}", "-f", f"name={name}",
        "-F", f"number={number}",
    ]))
    nodes = data["data"]["repository"]["pullRequest"]["comments"]["nodes"]
    return [str(node.get("body") or "") for node in nodes]


def resolve_run(args: argparse.Namespace) -> dict | None:
    if args.run_id:
        run = suite_run.gh_json_lines([f"repos/{args.repo}/actions/runs/{args.run_id}", "--jq", "tojson"])[0]
        if not suite_run.is_main_full_suite_run(run, args.branch) or run.get("status") != "completed":
            return None
        return run
    return suite_run.latest_tested_run(
        suite_run.list_runs(args.repo, args.branch, ["-f", "status=completed"]), args.branch,
    )


def command_report(args: argparse.Namespace) -> int:
    run = resolve_run(args)
    if run is None or run.get("conclusion") != "failure":
        print("No red full-suite run to attribute.")
        return 0
    jobs = run_jobs(args.repo, run["id"])
    if not app_host_ran(jobs):
        print(f"Run {run['id']} did not finish every app-host shard; nothing to compare.")
        return 0
    known = set(json.loads(CATALOG.read_text(encoding="utf-8")).get("tests") or {})
    display_names = swift_test_names(
        path.read_text(encoding="utf-8", errors="replace") for path in (args.root / "cmuxTests").rglob("*.swift")
    )
    current, current_shards, _, crashes = job_failures(args.repo, jobs, known, display_names)

    # The baseline is the newest earlier run whose app-host shards all
    # finished. A shard of it that stopped before grading every test cannot
    # show a test was already failing, so failures in that shard get no verdict.
    previous = None
    previous_ungraded: set[str] = set()
    earlier = earlier_tested_runs(
        suite_run.list_runs(args.repo, args.branch, ["-f", "status=completed"]), run, args.branch,
    )
    # A run with an ungraded shard is a usable baseline only while shard
    # numbers still name the same tests: shards are packed from the test list
    # and timings, so a change to either can move a test into a shard it never
    # ran in. Otherwise look further back for a fully graded run, keeping what
    # the skipped runs saw fail, since a test failing there is not new either.
    # Their app-host crashes are kept too: a crash they already had is not new.
    seen_failing: set[str] = set()
    earlier_crashes: list[tuple[Mapping[str, object], HostCrash]] = []
    for candidate in earlier[:MAX_BASELINE_CANDIDATES]:
        candidate_jobs = run_jobs(args.repo, candidate["id"])
        if not app_host_ran(candidate_jobs):
            continue
        failed: dict[str, list[str]] = {}
        ungraded: set[str] = set()
        if candidate.get("conclusion") == "failure":
            failed, _, ungraded, candidate_crashes = job_failures(args.repo, candidate_jobs, known, display_names)
            earlier_crashes += [(candidate, crash) for crash in candidate_crashes]
        seen_failing |= set(failed)
        if ungraded and shard_map_changed(args.root, str(candidate["head_sha"]), str(run["head_sha"])):
            continue
        previous, previous_ungraded = candidate, ungraded
        break
    previous_failures = seen_failing

    findings = [CrashFinding(crash, prior_crash(crash, earlier_crashes)) for crash in crashes]
    failures: dict[str, list[str]] = {}
    no_baseline: list[str] = []
    if previous:
        failures, no_baseline = new_failures(current, current_shards, previous_failures, previous_ungraded)
    regressions, attributed, crashed = split_crashes(failures, findings)
    no_baseline = [test for test in no_baseline if test not in crash_victims(findings)]
    prs: list[PullRequest] = []
    direct: list[str] = []
    attributions: dict[str, tuple[list[PullRequest], str]] = {}
    commits: list[str] | None = None
    if previous and attributed:
        range_ = f"{previous['head_sha']}..{run['head_sha']}"
        shas = git(args.root, "rev-list", range_).split()
        prs, direct = merged_prs(shas, associated_prs(args.repo, shas), args.branch)
        rank_inputs(args.root, prs)
        attributions = {test: suspects_for(test, prs, direct) for test in attributed}
        commits = outcome_commits(git(
            args.root, "log", "--first-parent", "--reverse", "--diff-merges=first-parent",
            "--name-only", "--format=%x00%H", range_,
        ))

    section = issue_section(
        repo=args.repo, run=run, previous=previous, failures=regressions,
        attributions=attributions, prs=prs, direct=direct, no_baseline=no_baseline, commits=commits,
        crashes=findings, crashed=list(crashed),
    )
    print(section)
    if args.section_output:
        Path(args.section_output).write_text(section + "\n", encoding="utf-8")

    def told(pr: PullRequest, tests: list[str]) -> bool:
        return already_told(pr_comment_bodies(args.repo, pr.number), pr.number, tests, commit_range(previous, run))

    for pr, tests, how, others in untold(comment_plan(attributed, attributions), told):
        body = pr_comment(
            repo=args.repo, pr=pr, tests=tests, how=how, run=run, previous=previous,
            failures=attributed, others=others, crashed=crashed,
        )
        if args.dry_run:
            print(f"--- would comment on #{pr.number} ---\n{body}")
            continue
        gh(["api", f"repos/{args.repo}/issues/{pr.number}/comments", "-f", f"body={body}"])
        print(f"Commented on #{pr.number}.")
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", ""))
    parser.add_argument("--branch", default="main")
    commands = parser.add_subparsers(dest="command", required=True)
    report = commands.add_parser("report", help="attribute a red run's new failures and tell the suspects")
    report.add_argument("--run-id", help="defaults to the newest green or red full-suite run")
    report.add_argument("--root", type=Path, default=Path.cwd(), help="a main checkout with history")
    report.add_argument("--section-output", help="write the issue's markdown section here")
    report.add_argument("--dry-run", action="store_true", help="print pull request comments instead of posting")
    report.set_defaults(handler=command_report)
    args = parser.parse_args(argv)
    if not args.repo:
        parser.error("--repo or GITHUB_REPOSITORY is required")
    return args.handler(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
