#!/usr/bin/env python3
"""Tell a CI failure the machine caused from one the pull request's code caused.

ci-failure-attribution.yml runs this on every completed pull request run of
CI (ci.yml), from main, under GITHUB_TOKEN. A PR's code never runs here: the
script reads the run's failed jobs, their logs and annotations, as data.

Each failed job gets a verdict from SIGNATURES, one table of log patterns:

  machine   the runner or its products failed: a runner hook refused the job,
            the compiled products did not restore, the CLI loaded package
            frameworks from another build, the runner went away, the runner
            lacks the Xcode the job pins, GitHub's artifact storage did not
            deliver the compiled products. The job's
            test failures, if any, are not evidence about the code (except
            after a failed artifact download: a test or compile failure the
            job still printed decides it).
  code      a test recorded an issue, a compile or guard failed, and no
            machine signature matched.
  unknown   nothing in the table matched. The comment names the failed step.

Gate jobs (GATE_JOBS: ci-status and the other jobs that only read `needs`)
fail because another job did, so they are left out, as are cancelled jobs and
jobs whose log says they stopped for another job (verdict `derived`).

A machine signature counts only where the job failed: in a step that printed
an `##[error]`, or in a failure annotation. A cache save that warns about the
disk, or a script that spells a signature it never prints, does not count.
A signature may also be bound to one step (a timeout counts only in the
artifact download, where it is GitHub's storage, not a hung test).

`act` writes the verdicts to the job summary and to one bot comment on the
pull request, edited in place, and re-runs the failed jobs when every failed
job is machine. GitHub's attempt counter bounds that: a failed attempt 1 or
2 is re-run, up to LAST_OWNED_ATTEMPT (attempt 2 goes back to the owned
labels like attempt 1, and a mini that is online but broken may fail it
again; attempt 3 goes to Blacksmith, which ends it), or a later attempt a
person started (this re-run then goes to Blacksmith), only while it is still
the run's latest attempt, the pull request is open and its head has not
moved. owned_pool_rescue.py may re-run a refused
job first; the attempt check then skips, and GitHub refuses a second re-run of
a run in progress. A cancelled run is reported, never re-run: the rescue
cancels a stuck run before its own full re-run, and a re-run of failed jobs
here would pre-empt it.

A code or unknown job's failed steps also give its concrete failures
(extract_failures: failed tests with file:line, compile errors, crashes,
warning-budget overages, CLI help contract failures; system and cache `error:`
noise dropped), and each gets an owner:

  yours             its file is one the pull request changes, or tests one
  also red on main  main's latest red full-suite run (the data main_full_suite.py
                    writes into its open issue) fails the same way
  seen on other PRs this bot saw the same test fail, or crash, on another pull
                    request's run in the last SEEN_DAYS days: likely flaky
  new in this PR    none of these: most likely the pull request's ("main, whose
                    full suite is green" only when main's latest full-suite run passed)

The comment's first line is the verdict in those words. A pull request that
merged before its CI finished still gets the comment (fix forward on main).
A green run whose macOS jobs never ran, on a pull request that changes the
app, says so instead of "passes". The comment records the head it speaks for:
when CI starts on a newer head (workflow_run `requested`) or an older head's
run completes, a comment about another head is rewritten to "pending".
"""

from __future__ import annotations

import argparse
import dataclasses
import json
import os
import re
import sys
import urllib.parse
from collections.abc import Callable, Iterable, Mapping
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from guard_attribution import (  # noqa: E402
    ANSI,
    TIMESTAMP,
    GitHub,
    Writer,
    cap,
    code,
    fence,
    pr_number,
    upsert_comment,
)
import ui_tests_dispatch  # noqa: E402
from pr_runner_pool import LAST_OWNED_ATTEMPT  # noqa: E402

MACHINE, CODE, DERIVED, UNKNOWN = "machine", "code", "derived", "unknown"
MARKER = "<!-- cmux-ci-failure-attribution -->"
BOT = "github-actions[bot]"
RED = {"failure", "timed_out"}
# Jobs that only read other jobs' results. Their names as the jobs API reports
# them; tests/test_ci_classify_failures.py derives each from its workflow.
GATE_JOBS = frozenset({
    "ci-status", "tests", "CI timing", "linux-preflight", "macOS admission gate",
    "macos / macOS status", "guards / Guard status", "web / Web status",
})
MAX_EVIDENCE_CHARS = 300
MAX_RENDERED_JOBS = 20


@dataclasses.dataclass(frozen=True)
class Signature:
    name: str
    verdict: str
    pattern: re.Pattern[str]
    why: str
    # Counts only in a step whose `Run ...` header matches.
    step: re.Pattern[str] | None = None
    # A machine fault that a code match elsewhere in the job still outweighs.
    yields_to_code: bool = False


def sig(name: str, verdict: str, pattern: str, why: str, step: str | None = None,
        yields_to_code: bool = False) -> Signature:
    return Signature(name, verdict, re.compile(pattern), why, re.compile(step) if step else None, yields_to_code)


# The step that fetches the compiled test products from GitHub's artifact storage.
DOWNLOAD_ARTIFACT_STEP = r"^actions/download-artifact@"

# First match per verdict is the evidence. A derived match decides the job,
# then a machine match (only in a failed step), then a code match, then a
# machine match that yields to code.
SIGNATURES = (
    sig("admission-declined", DERIVED, r"macOS admission gate declined: ",
        "compile admission stopped because a Linux job failed"),
    sig("runner-hook-refused", MACHINE, r"glaeda-cmux-runner-hook: refused: ",
        "the owned runner refused the job (host busy or out of capacity)"),
    sig("product-restore-failed", MACHINE, r'^CMUX_TEST_PRODUCT_RESTORE \{.*"outcome": "failure"',
        "the compiled app-host products did not restore on this runner"),
    sig("app-host-preparation", MACHINE, r"Unexpected app-host preparation outcome",
        "the isolated app-host home was not prepared"),
    sig("gui-token-unavailable", MACHINE,
        r"^Could not take this Mac's gui token for the app-host tests \(take-gui exited ",
        "the runner could not acquire the GUI token for app-host tests"),
    # The CLI and the package framework it links came from different builds:
    # the runner staged products from another job. Compiled together, they match.
    sig("mixed-products", MACHINE, r"dyld\[\d+\]: Symbol not found: ",
        "a binary loaded a framework from another build (stale products on the runner)"),
    sig("runner-lost", MACHINE,
        r"lost communication with the server|The runner has received a shutdown signal"
        r"|The hosted runner encountered an error",
        "the runner went away mid-job"),
    sig("disk-full", MACHINE, r"No space left on device", "the runner's disk is full"),
    # scripts/select-ci-xcode.sh on a Mac without the Xcode the job pins. The
    # marker is today's text; the anchored messages are what a pull request
    # branched before it prints (the classifier runs main's copy on any head).
    sig("xcode-pin-missing", MACHINE,
        r"\[cmux-ci machine: xcode-pin-missing\]|^Pinned Xcode developer dir (?:does not exist|has no usable macOS SDK): "
        r"|^This macOS \d+ runner has no Xcode \S+, the version scripts/ci/xcode-pins\.txt pins",
        "the runner does not have the Xcode this job pins (install it: scripts/ci/xcode_pin_audit.py)"),
    # `Download compiled (app-host) test product`: GitHub's artifact storage did not deliver the
    # products (runs 37388244997 attempts 2 and 3, 37388340030 attempt 2). The steps after it fail
    # for want of them; a test or compile failure the job still printed outweighs it.
    sig("artifact-download-failed", MACHINE,
        r"^Unable to download artifact\(s\): .*Artifact download failed after \d+ retries",
        "GitHub's artifact storage did not deliver the compiled test product",
        step=DOWNLOAD_ARTIFACT_STEP, yields_to_code=True),
    sig("artifact-download-timeout", MACHINE, r"^The action has timed out\.$",
        "downloading the compiled test product from GitHub's artifact storage timed out",
        step=DOWNLOAD_ARTIFACT_STEP, yields_to_code=True),
    sig("swift-testing-issue", CODE, r"^✘ (?:Test|Suite) .+ (?:recorded an issue|failed after)", "a test failed"),
    sig("xctest-failure", CODE, r"\.swift:\d+: error: -\[", "a test failed"),
    sig("ratchet-new-failure", CODE, r"^RATCHET_NEW_FAILURE ", "a test failed that passes on main"),
    sig("compile-error", CODE, r"\S+\.(?:swift|m|mm|c|h|ts|tsx|js|py|rs|zig):\d+:\d+: error: ",
        "a compile error"),
    sig("guard-failed", CODE, r"^\s*FAIL\s+[\d.]+s\s", "a guard step failed"),
    sig("static-check-failed", CODE, r"^FAILED \S+ \(\d", "a static check failed"),
    sig("unittest-failure", CODE, r"^(?:FAIL|ERROR): test\w* \(", "a Python test failed"),
)


def log_sections(text: str) -> list[tuple[str, bool, list[str]]]:
    """The log's steps as (command, failed, output lines), without timestamps, colors or echoed scripts.

    A step starts with `##[group]Run <command>`, and GitHub prints its script
    (colored), or an action's `with:` inputs, inside that group, so a signature
    spelled in a script (an `echo "::error::..."` branch never taken) must not
    count. A group a step prints itself may also be titled "Run ..."; its first
    line is output, not script, and it stays. A step failed when it printed an
    `##[error]` line. The command is what follows `Run ` (`actions/download-artifact@<sha>`
    for an action), "" before the first step.
    """
    steps: list[tuple[str, bool, list[str]]] = [("", False, [])]
    raw_lines = text.splitlines()
    in_header = False
    for index, raw in enumerate(raw_lines):
        line = ANSI.sub("", TIMESTAMP.sub("", raw.lstrip("\ufeff")))
        if line.startswith("##[group]Run "):
            following = raw_lines[index + 1] if index + 1 < len(raw_lines) else ""
            following_text = TIMESTAMP.sub("", following)
            if "\x1b[36;1m" in following or following_text.startswith("with:"):
                steps.append((line.removeprefix("##[group]Run ").strip(), False, []))
                in_header = True
                continue
        if in_header:
            if line.startswith("##[endgroup]"):
                in_header = False
            continue
        command, failed, lines = steps[-1]
        if line.startswith("##[error]"):
            steps[-1] = (command, True, lines)
        lines.append(line.removeprefix("##[error]"))
    return steps


def log_steps(text: str) -> list[tuple[bool, list[str]]]:
    """log_sections without the commands: (failed, output lines) per step."""
    return [(failed, lines) for _, failed, lines in log_sections(text)]


# A machine signature that yields to code (Signature.yields_to_code), as found[] keys it.
WEAK_MACHINE = "machine-yields-to-code"


def classify_text(text: str, annotations: Iterable[str] = ()) -> dict:
    """Verdict, signature and evidence for one job's log and its failure annotations."""
    sections = [*log_sections(text), ("", True, [a for note in annotations for a in str(note).splitlines()])]
    found: dict[str, tuple[Signature, str]] = {}
    for command, failed, lines in sections:
        for line in lines:
            for signature in SIGNATURES:
                if signature.verdict == MACHINE and not failed:
                    continue
                if signature.step is not None and not signature.step.search(command):
                    continue
                key = WEAK_MACHINE if signature.yields_to_code else signature.verdict
                if key not in found and signature.pattern.search(line):
                    found[key] = (signature, line.strip())
    for verdict in (DERIVED, MACHINE, CODE, WEAK_MACHINE):
        if verdict in found:
            signature, line = found[verdict]
            return {"verdict": signature.verdict, "signature": signature.name, "why": signature.why,
                    "evidence": line[:MAX_EVIDENCE_CHARS]}
    return {"verdict": UNKNOWN, "signature": None, "why": "no known signature in the log", "evidence": ""}


def classify_jobs(jobs: Iterable[Mapping], texts: Mapping[int, tuple[str, list[str]]]) -> list[dict]:
    """Verdicts for the run's failed jobs, gates left out. `texts` holds each job's log and failure annotations."""
    out = []
    for job in jobs:
        if job.get("conclusion") not in RED or job.get("name") in GATE_JOBS:
            continue
        text = texts.get(int(job["id"]), ("", []))
        result = classify_text(*text)
        if result["verdict"] == DERIVED:
            continue
        # A machine job's test failures are not evidence about the code (SIGNATURES).
        result["failures"] = extract_failures(*text) if result["verdict"] != MACHINE else []
        step = next((s.get("name") for s in job.get("steps") or [] if s.get("conclusion") in RED), None)
        if result["verdict"] == UNKNOWN:
            result["why"] = ("timed out" if job.get("conclusion") == "timed_out" else "no known signature") + (
                f"; failed step: {code(step, 80)}" if step else "")
        out.append({"id": int(job["id"]), "name": job.get("name"), "runner": job.get("runner_name"),
                    "url": job.get("html_url"), "conclusion": job.get("conclusion"), "step": step, **result})
    return out


def all_machine(jobs: list[dict]) -> bool:
    return bool(jobs) and all(job["verdict"] == MACHINE for job in jobs)


# ---------------------------------------------------------------- concrete failures

# A job's verdict says "code"; a pull request author needs the test or the
# line. These read the failed steps' output (log_steps) for the failures a
# person acts on, in this order: compile errors, failed tests, crashes, Swift
# warning-budget overages, CLI help contract failures. App-host logs carry
# hundreds of `error:` lines from the system and the compilation cache
# (RBSServiceErrorDomain, NSCocoaErrorDomain 4097, `error: <dictionary`,
# `error: UpdateFailed`, `error: read-only cache client`, `error: failed to
# update cache`); none has a source location, and NOISE drops them first.
COMPILE_LINE = re.compile(
    r"^(?P<path>\S+\.(?:swift|m|mm|c|h|metal)):(?P<line>\d+):\d+: error: (?P<message>.+)$")
# Swift Testing: `✘ Test <name> recorded an issue [with N argument ...] at <File>.swift:<line>:<col>: <message>`.
SWIFT_ISSUE = re.compile(
    r'^✘ Test (?P<test>"(?:[^"\\]|\\.)*"|\S+) recorded an issue (?:.*? )?at '
    r"(?P<path>[\w+.\-/]+\.swift):(?P<line>\d+):\d+: (?P<message>.*)$")
SWIFT_FAILED = re.compile(r'^✘ Test (?P<test>"(?:[^"\\]|\\.)*"|\S+) (?:with \d+ test cases? )?failed after ')
# XCTest: `<path>/<File>.swift:<line>: error: -[cmuxTests.Suite testName] : XCTAssert... failed: ...`.
XCTEST_ISSUE = re.compile(
    r"^(?P<path>\S+\.swift):(?P<line>\d+): error: -\[(?:\w+\.)?(?P<suite>\w+) (?P<test>\w+)\] : (?P<message>.*)$")
XCTEST_FAILED = re.compile(r"^Test Case '-\[(?:\w+\.)?(?P<suite>\w+) (?P<test>\w+)\]' failed \(")
# The shard ratchet's verdict, `Suite/test()`: a failure the lines above missed (a crash cut it short).
RATCHET = re.compile(r"^RATCHET_NEW_FAILURE (?P<suite>\w+)/(?P<test>\S+)\s*$")
CRASH = (
    re.compile(r"^\*\*\* Program crashed: (?P<message>.+?)(?: at 0x[0-9a-fA-F]+)? \*\*\*$"),
    re.compile(r"(?:(?P<path>[\w+.\-/]+\.swift):(?P<line>\d+): )?(?P<message>Fatal error: .+)$"),
    re.compile(r"(?P<message>Cannot form weak reference to instance .+? of class \S+)"),
    re.compile(r"(?P<message>Terminating app due to uncaught exception .+)$"),
)
WARNING_BUDGET = "Swift warning budget exceeded."
WARNING_OVER = re.compile(r"^\+\d+ (?P<path>\S+): (?P<message>.+)$")
CLI_CONTRACT = "FAIL: CLI help contract probes failed"
NOISE = re.compile(
    r"^error: (?:Error Domain=|<dictionary|UpdateFailed|read-only cache client|failed to update cache)"
    r"|Error Domain=(?:RBSServiceErrorDomain|NSCocoaErrorDomain) Code=")
HEX = re.compile(r"0x[0-9a-fA-F]+")
# Where a CI checkout's paths start (/tmp/cmux-ci/src/Sources/X.swift is Sources/X.swift).
REPO_ROOTS = re.compile(r"(?:^|/)((?:Sources|cmuxTests|cmuxUITests|Packages|CLI|TunnelExtension|ios|web|scripts|tests)/.+)$")
MAX_FAILURES_PER_JOB = 8
MAX_RENDERED_FAILURES = 10
MAX_FAILURE_MESSAGE_CHARS = 160
MAX_CLI_DETAILS = 3


def repo_path(path: str) -> str:
    """A log's absolute source path relative to the repository, or as printed."""
    found = REPO_ROOTS.search(path)
    return found.group(1) if found else path


def failure(kind: str, path: str = "", line: int | None = None, test: str = "", message: str = "",
            suite: str = "") -> dict:
    message = " ".join(message.split())[:MAX_FAILURE_MESSAGE_CHARS]
    path = repo_path(path) if path else (f"{suite}.swift" if suite else "")
    return {"kind": kind, "file": path, "line": line, "test": test, "message": message}


def failure_key(item: Mapping) -> str:
    """What makes two failures the same one, across a PR's run and main's: a test by its file and
    name, a compile error by its file and message (lines move under unrelated edits), a crash by
    its message without addresses."""
    name = Path(str(item.get("file") or "")).name
    if item.get("kind") == "test":
        return f"test:{name}:{item.get('test') or item.get('line')}"
    if item.get("kind") == "crash":
        return f"crash:{HEX.sub('0x*', str(item.get('message') or ''))}"
    return f"{item.get('kind')}:{name}:{item.get('message')}"


def where(item: Mapping) -> str:
    name = Path(str(item.get("file") or "")).name
    return f"{name}:{item['line']}" if name and item.get("line") else name


def extract_failures(text: str, annotations: Iterable[str] = ()) -> list[dict]:
    """The concrete failures in one job's failed steps, deduplicated, at most MAX_FAILURES_PER_JOB."""
    lines = [line.replace("\u200b", "").strip()
             for failed, step in log_steps(text) if failed for line in step]
    lines += [a.strip() for note in annotations for a in str(note).splitlines()]
    found: list[dict] = []
    for index, line in enumerate(lines):
        if not line or NOISE.search(line):
            continue
        if match := COMPILE_LINE.match(line):
            found.append(failure("compile", match["path"], int(match["line"]), message=match["message"]))
        elif match := SWIFT_ISSUE.match(line):
            found.append(failure("test", match["path"], int(match["line"]), match["test"].strip('"'),
                                 match["message"]))
        elif match := XCTEST_ISSUE.match(line):
            found.append(failure("test", match["path"], int(match["line"]), f"{match['suite']}.{match['test']}",
                                 match["message"]))
        elif match := SWIFT_FAILED.match(line):
            found.append(failure("test", test=match["test"].strip('"'), message="failed"))
        elif match := (XCTEST_FAILED.match(line) or RATCHET.match(line)):
            found.append(failure("test", test=f"{match['suite']}.{match['test']}", suite=match["suite"],
                                 message="failed"))
        elif line == WARNING_BUDGET:
            for over in lines[index + 1:index + 30]:
                if match := WARNING_OVER.match(over):
                    found.append(failure("warning", match["path"], message=match["message"]))
        elif line == CLI_CONTRACT:
            details = [d for d in lines[index + 1:index + 40]
                       if d and not d.startswith(("stdout=", "stderr=", "Process completed"))]
            for detail in details[:MAX_CLI_DETAILS] or ["(no detail)"]:
                found.append(failure("cli-contract", message=detail))
        else:
            for pattern in CRASH:
                if match := pattern.search(line):
                    groups = match.groupdict()
                    found.append(failure("crash", groups.get("path") or "",
                                         int(groups["line"]) if groups.get("line") else None,
                                         message=match["message"]))
                    break
    return dedupe(found)[:MAX_FAILURES_PER_JOB]


def dedupe(found: Iterable[dict]) -> list[dict]:
    """One entry per failure, compile errors first. A test named only by its suite (the summary
    `failed` line, the ratchet) is dropped when an issue line already points into its file."""
    order = {"compile": 0, "test": 1, "crash": 2, "warning": 3, "cli-contract": 4}
    found = sorted(found, key=lambda item: order.get(item["kind"], 9))
    located = {Path(item["file"]).name for item in found if item["kind"] == "test" and item.get("line")}
    named = {item["test"] for item in found if item["kind"] == "test" and item.get("line")}
    out, seen = [], set()
    for item in found:
        if item["kind"] == "test" and not item.get("line"):
            if Path(item["file"]).name in located or item["test"] in named:
                continue
        key = (failure_key(item), item.get("line") if item["kind"] == "compile" else None)
        if key not in seen:
            seen.add(key)
            out.append(item)
    return out


# ---------------------------------------------------------------- whose failure

YOURS, ON_MAIN, NEW = "yours", "also red on main", "new in this PR"
FLAKY = "seen on other PRs"


def owner(item: Mapping, changed: Iterable[str], main_keys: Iterable[str]) -> tuple[str, str]:
    """(ownership, why) for one concrete failure.

    yours            its file is one the pull request changes, or it tests one
                     (FooTests.swift and Foo.swift), or its suite is that file's
    also red on main main's latest completed full-suite run fails the same way
    new in this PR   otherwise: main does not show it, so it is most likely the PR's
    """
    changed = list(changed)
    stems = {Path(path).stem for path in changed}
    path = str(item.get("file") or "")
    name = Path(path).name
    stem = Path(name).stem
    if "/" in path:
        # A compiler path: the PR's file at that path, never another package's file of the same name.
        relative = path.lstrip("/")
        if any(relative == c or relative.endswith("/" + c) or c.endswith("/" + relative) for c in changed):
            return YOURS, "a file this PR changes"
    elif path:
        # Swift Testing names only the file. One changed file of that name is it; several are a guess.
        same = [c for c in changed if Path(c).name == name]
        if len(same) == 1:
            return YOURS, "a file this PR changes"
        if same:
            return YOURS, f"this PR changes {len(same)} files named {name}"
    if stem.endswith("Tests") and stem.removesuffix("Tests") in stems:
        return YOURS, f"tests {stem.removesuffix('Tests')}.swift, which this PR changes"
    if failure_key(item) in set(main_keys):
        return ON_MAIN, "fails on main too"
    return NEW, "not failing on main"


def attribute(jobs: list[dict], changed: Iterable[str], main_keys: Iterable[str]) -> None:
    changed, main_keys = list(changed), set(main_keys)
    for job in jobs:
        for item in job.get("failures") or []:
            item["owner"], item["owner_why"] = owner(item, changed, main_keys)


# ---------------------------------------------------------------- GitHub


def run_jobs(gh: GitHub, run_id: int, attempt: int) -> list[dict]:
    """The jobs of this attempt, not of a re-run that started since."""
    jobs: list[dict] = []
    for page in range(1, 5):
        body = gh.get(f"repos/{gh.repo}/actions/runs/{run_id}/attempts/{attempt}/jobs?per_page=100&page={page}")
        batch = list((body or {}).get("jobs", []))  # type: ignore[union-attr]
        jobs += batch
        if len(batch) < 100:
            break
    return jobs


def job_text(gh: GitHub, job_id: int) -> tuple[str, list[str]]:
    """The job's log and its failure annotations (a lost runner leaves only an annotation)."""
    log, notes = "", []
    try:
        log = str(gh.request("GET", f"repos/{gh.repo}/actions/jobs/{job_id}/logs", text=True))
    except RuntimeError as error:
        print(f"job {job_id}: no log: {error}", file=sys.stderr)
    try:
        for note in gh.get(f"repos/{gh.repo}/check-runs/{job_id}/annotations?per_page=50") or []:  # type: ignore[union-attr]
            if note.get("annotation_level") == "failure":
                notes.append(str(note.get("message") or ""))
    except RuntimeError as error:
        print(f"job {job_id}: no annotations: {error}", file=sys.stderr)
    return log, notes


def macos_ran(jobs: Iterable[Mapping]) -> bool:
    """Whether any macOS job compiled or tested. When the fast guards or the static checks fail, or
    the change areas route nothing to macOS, `macos` and the admission gate are skipped and a green
    ci-status says nothing about the app."""
    return any(str(j.get("name") or "").startswith("macos / ") and j.get("name") not in GATE_JOBS
               and j.get("conclusion") in ("success", "failure", "timed_out") for j in jobs)


# ci.yml's `macos` job needs these two (by their display names) to succeed. Otherwise it skips
# because of change routing (nothing for macOS, or an admitted compile reused), which is not a
# gap: tests/test_ci_classify_failures.py pins the names to ci.yml.
MACOS_PREREQUISITES = ("changes", "Fast static checks")


def macos_blocked(jobs: Iterable[Mapping]) -> str:
    """Why the macOS jobs could not run, or "" when they ran or routing skipped them."""
    jobs = list(jobs)
    if macos_ran(jobs):
        return ""
    found = {str(j.get("name")): str(j.get("conclusion") or j.get("status") or "missing") for j in jobs}
    return ", ".join(f"`{name}` {found.get(name, 'missing')}" for name in MACOS_PREREQUISITES
                     if found.get(name) != "success")


def classify_run(gh: GitHub, run: Mapping) -> dict:
    attempt = int(run.get("run_attempt") or 1)
    jobs = run_jobs(gh, int(run["id"]), attempt)
    red = [j for j in jobs if j.get("conclusion") in RED and j.get("name") not in GATE_JOBS]
    texts = {int(j["id"]): job_text(gh, int(j["id"])) for j in red}
    return {"run_id": int(run["id"]), "attempt": attempt,
            "run_url": run.get("html_url"), "head_sha": run.get("head_sha"),
            "conclusion": run.get("conclusion"), "jobs": classify_jobs(jobs, texts),
            "macos_ran": macos_ran(jobs), "macos_blocked": macos_blocked(jobs)}


def run_pull(gh: GitHub, run: Mapping, pr: int | None = ...) -> tuple[int | None, dict]:  # type: ignore[assignment]
    """The run's pull request and its state. pr_number() finds an open one (pass `pr` when it was
    already looked up); a pull request merged before its CI finished (#17074, #17232, #17233 on
    2026-10-05) is closed by the time the run completes, and its run lists no pull request, so a
    merged one at this head is looked up too."""
    if pr is ...:
        pr = pr_number(gh, run)
    if pr:
        return pr, gh.pull(pr)
    owner = str((run.get("head_repository") or {}).get("full_name") or "").split("/")[0]
    if not owner or not run.get("head_branch"):
        return None, {}
    head = urllib.parse.quote(f"{owner}:{run.get('head_branch')}", safe="")
    body = gh.get(f"repos/{gh.repo}/pulls?state=closed&head={head}&sort=updated&direction=desc&per_page=5")
    for pull in body or []:  # type: ignore[union-attr]
        if (pull.get("head") or {}).get("sha") == run.get("head_sha") and pull.get("merged_at"):
            return int(pull["number"]), pull
    return None, {}


# Paths whose change means the macOS jobs should have run (detect_ci_change_areas.py routes more).
APP_PATHS = ("Sources/", "cmuxTests/", "cmuxUITests/", "CLI/", "Packages/", "TunnelExtension/", "cmux.xcodeproj/")
MAX_FILE_PAGES = 10


def pr_files(gh: GitHub, pr: int) -> list[str]:
    files: list[str] = []
    for page in range(1, MAX_FILE_PAGES + 1):
        batch = list(gh.get(f"repos/{gh.repo}/pulls/{pr}/files?per_page=100&page={page}") or [])  # type: ignore[arg-type]
        files += [str(f.get("filename") or "") for f in batch]
        files += [str(f["previous_filename"]) for f in batch if f.get("previous_filename")]
        if len(batch) < 100:
            break
    return files


def safe_pr_files(gh: GitHub, pr: int) -> list[str]:
    """pr_files, or none when the API fails: the comment is still written, with no "yours"."""
    try:
        return pr_files(gh, pr)
    except (RuntimeError, ValueError, KeyError, TypeError, AttributeError) as error:
        print(f"::warning::pull request {pr} files unreadable: {error}", file=sys.stderr)
        return []


def touches_app(files: Iterable[str]) -> bool:
    return any(path.startswith(APP_PATHS) or path.endswith(".swift") for path in files)


# main_full_suite.py keeps one open issue while main's full suite is red, and
# writes the concrete failures of each red run it reports into it as data.
MAIN_FAILURES_PREFIX = "<!-- cmux-main-failures "
MAIN_FAILURES_RE = re.compile(re.escape(MAIN_FAILURES_PREFIX) + r"(\{.*?\}) -->")


def main_failures_marker(run: Mapping, failures: Iterable[Mapping]) -> str:
    data = {"run": run.get("id"), "sha": run.get("head_sha"),
            "keys": sorted({failure_key(f) for f in failures})[:300]}
    # `>` escaped inside the JSON strings, so log text cannot close the comment.
    return MAIN_FAILURES_PREFIX + json.dumps(data, separators=(",", ":")).replace(">", "\\u003e") + " -->"


def parse_main_failures(bodies: Iterable[str]) -> dict:
    """The newest data marker among the issue's body and comments, oldest first."""
    found: dict = {}
    for body in bodies:
        for raw in MAIN_FAILURES_RE.findall(str(body or "")):
            try:
                found = json.loads(raw)
            except json.JSONDecodeError:
                continue
    return found


def login(item: Mapping) -> str:
    return str((item.get("user") or {}).get("login") or "")


MAIN_RED, MAIN_GREEN, MAIN_UNKNOWN = "red", "green", "unknown"


def main_state(main: Mapping) -> str:
    """What main_red() found; {} (it failed) is unknown."""
    return str(main.get("state") or (MAIN_RED if main.get("issue") else MAIN_UNKNOWN))


def main_red(gh: GitHub) -> dict:
    """{state, issue, url, keys} for main's full suite: red with the open issue's failure keys, red
    without an issue, green, or unknown.

    Green needs main's latest completed full-suite run to have passed. No open issue is not enough:
    a token without the `issues` permission finds none, and the issue lags the run (#17258 was told
    main was green while #17286 was open and main's latest run was red)."""
    import main_full_suite

    issues = list(gh.get(f"repos/{gh.repo}/issues?labels={main_full_suite.ISSUE_LABEL}&state=open&per_page=1") or [])  # type: ignore[arg-type]
    if not issues:
        body = gh.get(f"repos/{gh.repo}/actions/workflows/{main_full_suite.CI_WORKFLOW_FILE}/runs?branch=main"
                      f"&event={main_full_suite.DISPATCH_EVENT}&status=completed&per_page=20") or {}
        latest = main_full_suite.latest_tested_run(body.get("workflow_runs") or [])  # type: ignore[union-attr]
        if latest is None:
            return {"state": MAIN_UNKNOWN, "keys": []}
        if latest.get("conclusion") == "success":
            return {"state": MAIN_GREEN, "keys": []}
        return {"state": MAIN_RED, "url": latest.get("html_url"), "keys": []}
    issue = issues[0]
    # Anyone can comment a marker on the issue ("this also fails on main" would excuse their own
    # failure); only what main_full_suite.py posted, as the workflow's bot, counts.
    bodies = [str(issue.get("body") or "")] if login(issue) == BOT else []
    count = int(issue.get("comments") or 0)
    if count:
        last = (count - 1) // 100 + 1
        bodies += [str(c.get("body") or "") for c in gh.get(
            f"repos/{gh.repo}/issues/{issue['number']}/comments?per_page=100&page={last}") or []  # type: ignore[union-attr]
            if login(c) == BOT]
    data = parse_main_failures(bodies)
    return {"state": MAIN_RED, "issue": int(issue["number"]), "url": issue.get("html_url"),
            "keys": list(data.get("keys") or [])}


# ---------------------------------------------------------------- seen on other pull requests

# A failure main does not show may still be no PR's: a flaky test or crash fails on unrelated PRs
# (TerminalNotificationDirectInteractionTests crashed on #15409, #16048 and #17258, issue #17483, and
# passed on main's full suite). This bot keeps a rolling record of the test failures and crashes it
# attributed to no PR's files and to no red main, by pull request and day, in a hidden marker in the
# body of a closed issue its main-full-suite reports opened, so editing it notifies no one. One GET
# reads it (only when a failure is "new in this PR") and at most one PATCH a run updates it. Only the
# bot's own body counts, and only a same-repository PR's run writes to it: a fork's log could
# otherwise plant failures to excuse another PR's. Concurrent runs may drop each other's update; the
# record is evidence, not a ledger.
SEEN_ISSUE = 17286
SEEN_PREFIX = "<!-- cmux-pr-failures-seen "
SEEN_RE = re.compile(re.escape(SEEN_PREFIX) + r"(\{.*?\}) -->", re.DOTALL)
SEEN_DAYS = 14
MAX_SEEN_PRS = 5
MAX_SEEN_CHARS = 40000


def seen_keys(item: Mapping, job_failures: Iterable[Mapping]) -> list[str]:
    """What identifies a failure across pull requests: a test by its key; a crash with the test that
    crashed (its message alone, "Bad pointer dereference", names no test). Other kinds: none."""
    if item.get("kind") == "test":
        return [failure_key(item)]
    if item.get("kind") == "crash":
        return [f"{failure_key(item)} in {failure_key(t)}" for t in job_failures if t.get("kind") == "test"]
    return []


def parse_seen(body: str) -> dict[str, dict[str, str]]:
    """{key: {pr: last day seen}} from the marker, or {}."""
    found = SEEN_RE.search(str(body or ""))
    if not found:
        return {}
    try:
        data = json.loads(found.group(1))
    except json.JSONDecodeError:
        return {}
    seen = data.get("seen") if isinstance(data, dict) else None
    if not isinstance(seen, dict):
        return {}
    return {str(k): {str(p): str(d) for p, d in v.items()} for k, v in seen.items() if isinstance(v, dict)}


def seen_marker(record: Mapping[str, Mapping[str, str]]) -> str:
    # `>` escaped inside the JSON strings, so log text cannot close the comment.
    data = json.dumps({"v": 1, "seen": record}, separators=(",", ":"), sort_keys=True)
    return SEEN_PREFIX + data.replace(">", "\\u003e") + " -->"


def prune_seen(record: Mapping[str, Mapping[str, str]], now: str) -> dict[str, dict[str, str]]:
    """Sightings of the last SEEN_DAYS days, the first MAX_SEEN_PRS per failure (the PR that started
    it must outlive the ones that hit it later), the most recently seen failures first while the
    marker fits MAX_SEEN_CHARS."""
    from datetime import date, timedelta

    cutoff = (date.fromisoformat(now[:10]) - timedelta(days=SEEN_DAYS)).isoformat()
    kept: dict[str, dict[str, str]] = {}
    for key, prs in record.items():
        recent = sorted((d, p) for p, d in prs.items() if d >= cutoff)[:MAX_SEEN_PRS]
        if recent:
            kept[key] = {p: d for d, p in recent}
    out: dict[str, dict[str, str]] = {}
    size = len(seen_marker({}))
    for key in sorted(kept, key=lambda k: max(kept[k].values()), reverse=True):
        entry = len(json.dumps({key: kept[key]}, separators=(",", ":")).replace(">", "\\u003e")) + 1
        if size + entry > MAX_SEEN_CHARS:
            break
        out[key], size = kept[key], size + entry
    return out


def seen_elsewhere(record: Mapping[str, Mapping[str, str]], keys: Iterable[str], pr: int, now: str) -> set[str]:
    """The other pull requests that hit any of these keys in the last SEEN_DAYS days, before this one
    first did. One that hit it later is usually stacked on this PR or a copy of its change, so it
    would hide this PR's own regression."""
    pruned = prune_seen({k: record[k] for k in keys if k in record}, now)
    return {p for prs in pruned.values() for p, d in prs.items()
            if p != str(pr) and d < prs.get(str(pr), now)}


def now_utc() -> str:
    """A sighting's time: to the second, so two PRs that fail on the same day keep their order."""
    from datetime import datetime, timezone

    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def mark_seen_elsewhere(gh: GitHub, pr: int, report: dict, now: str) -> tuple[dict, str] | None:
    """Turn each "new in this PR" failure another PR also hit into FLAKY. Returns the record and the
    issue body it came from, or None when nothing was read."""
    pending = [(job, item) for job in report["jobs"] if job["verdict"] != MACHINE
               for item in job.get("failures") or [] if item.get("owner") == NEW]
    if not any(seen_keys(item, job.get("failures") or []) for job, item in pending):
        return None
    try:
        issue = gh.get(f"repos/{gh.repo}/issues/{SEEN_ISSUE}") or {}
    except RuntimeError as error:
        print(f"::warning::issue {SEEN_ISSUE} (failures seen on other PRs) unreadable: {error}", file=sys.stderr)
        return None
    if login(issue) != BOT:  # type: ignore[arg-type]
        return None
    body = str(issue.get("body") or "")  # type: ignore[union-attr]
    record = parse_seen(body)
    for job, item in pending:
        others = seen_elsewhere(record, seen_keys(item, job.get("failures") or []), pr, now)
        if others:
            item["owner"] = FLAKY
            item["owner_why"] = f"failed on {len(others)} other PR{'s' if len(others) > 1 else ''} " \
                                f"in the last {SEEN_DAYS} days"
    return record, body


def record_seen(record: Mapping[str, Mapping[str, str]], report: Mapping, pr: int, now: str) -> dict | None:
    """The record with this run's not-yours, not-on-main failures added, or None when unchanged."""
    updated = {k: dict(v) for k, v in record.items()}
    for job in report["jobs"]:
        if job["verdict"] == MACHINE:
            continue
        for item in job.get("failures") or []:
            if item.get("owner") in (NEW, FLAKY):
                for key in seen_keys(item, job.get("failures") or []):
                    updated.setdefault(key, {}).setdefault(str(pr), now)  # the first sighting
    updated = prune_seen(updated, now)
    return None if updated == record else updated


def seen_body(body: str, record: Mapping[str, Mapping[str, str]]) -> str:
    marker = seen_marker(record)
    if SEEN_RE.search(body):
        return SEEN_RE.sub(lambda _: marker, body, count=1)
    return body.rstrip("\n") + "\n\n" + marker


# ---------------------------------------------------------------- the comment

# The head and state the comment speaks for, so a push can mark it stale.
# Older comments name their head only in the text (LEGACY_HEAD).
HEAD_RE = re.compile(r"<!-- cmux-ci-failure-attribution head=([0-9a-f]+) state=([\w-]+) -->")
LEGACY_HEAD = re.compile(r"CI (?:passes|failed|stopped) on `([0-9a-f]{7,40})`")
VERDICT_PREFIX = "**"
MACOS_SKIPPED = "macOS jobs did not run: compile and app tests were skipped"
MAX_VERDICT_ITEMS = 3


def head_marker(sha: str, state: str) -> str:
    return f"<!-- cmux-ci-failure-attribution head={sha} state={state} -->"


def comment_head(body: str) -> tuple[str, str]:
    """(head, state) an existing comment speaks for; state is passes, unverified, failed, stopped or pending."""
    if found := HEAD_RE.search(body):
        return found.group(1), found.group(2)
    if found := LEGACY_HEAD.search(body):
        return found.group(1), "passes" if "CI passes on" in body else "failed"
    return "", ""


def same_head(short_or_full: str, sha: str) -> bool:
    return bool(short_or_full) and bool(sha) and (sha.startswith(short_or_full) or short_or_full.startswith(sha))


def verdict_of(body: str) -> str:
    """The comment's first visible line: its verdict."""
    return next((line for line in body.splitlines() if line.startswith(VERDICT_PREFIX)), "")


def describe(item: Mapping, why: bool = True) -> str:
    place = code(where(item) or item.get("file") or "?", 100)
    reason = f" ({item['owner_why']})" if why and item.get("owner_why") and item.get("owner") == YOURS else ""
    kind = item.get("kind")
    if kind == "compile":
        return f"compile error in {code(item['file'] + (':' + str(item['line']) if item.get('line') else ''), 100)} " \
               f"{code(item['message'], 80)}{reason}"
    if kind == "crash":
        return f"crash {code(item['message'], 80)}" + (f" at {place}" if item.get("file") else "")
    if kind == "warning":
        return f"new warning in {place} {code(item['message'], 80)}{reason}"
    if kind == "cli-contract":
        return f"CLI help contract: {code(item['message'], 80)}"
    return f"{place}{reason}"


def listed(items: list[Mapping], why: bool = True) -> str:
    """The first few failures; one compile error per file, the rest of that file counted."""
    shown: list[str] = []
    per_file: dict[str, int] = {}
    for item in items:
        if item.get("kind") == "compile":
            per_file[item["file"]] = per_file.get(item["file"], 0) + 1
            if per_file[item["file"]] > 1:
                continue
        shown.append(item)  # type: ignore[arg-type]
    texts = []
    for item in shown[:MAX_VERDICT_ITEMS]:
        extra = per_file.get(item["file"], 1) - 1 if item.get("kind") == "compile" else 0
        texts.append(describe(item, why) + (f" (+{extra} more in that file)" if extra else ""))
    rest = len(shown) - MAX_VERDICT_ITEMS
    return ", ".join(texts) + (f" and {rest} more" if rest > 0 else "")


def verdict_line(report: Mapping, rerun: bool, rerun_line: str) -> str:
    """The comment's first line: whose failure it is, in plain words."""
    sha = (report.get("head_sha") or "")[:10]
    if report.get("conclusion") == "success":
        if report.get("macos_skipped"):
            return f"**Not verified:** {MACOS_SKIPPED} on `{sha}`; ci-status is green without them."
        return f"**Passes:** CI passes on `{sha}`."
    jobs = report["jobs"]
    failures = [f for job in jobs if job["verdict"] != MACHINE for f in job.get("failures") or []]
    yours = [f for f in failures if f.get("owner") == YOURS]
    new = [f for f in failures if f.get("owner") == NEW]
    on_main = [f for f in failures if f.get("owner") == ON_MAIN]
    flaky = [f for f in failures if f.get("owner") == FLAKY]
    main = report.get("main_red") or {}
    issue = f" (#{main['issue']})" if main.get("issue") else ""
    unexplained = [j for j in jobs if j["verdict"] != MACHINE and not j.get("failures")]
    # Counted by PR, never linked: a #number here would cross-reference those PRs.
    seen_too = f" Seen on other PRs too (likely flaky): {listed(flaky, False)}." if flaky else ""
    if yours:
        line = f"**Yours to fix:** {listed(yours)}."
        if new:
            line += f" Also failing here, not on main: {listed(new, False)}."
        if on_main:
            line += f" Not yours: {len(on_main)} more also fail on main{issue}."
        line += seen_too
    elif new:
        # Green only when main's latest full-suite run passed (main_red).
        where_main = {MAIN_RED: " but not on main's latest full suite" if main.get("issue") or main.get("keys")
                      else "; main's latest full suite is red too, and its failures could not be read",
                      MAIN_GREEN: " but not on main, whose full suite is green"}.get(
                          main_state(main), "; main's full-suite result could not be read")
        # A compile error in a file the PR does not change may still be its own (a removed
        # declaration) or main's (#17232 merged #17368's break); the line says which files.
        untouched = " (not a file this PR changes)" if all(f.get("kind") == "compile" for f in new) else ""
        line = f"**Probably yours:** {listed(new)}{untouched} fails here{where_main}."
        if on_main:
            line += f" {len(on_main)} more also fail on main{issue}."
        line += seen_too
    elif on_main and not unexplained:
        line = f"**Not yours:** {listed(on_main)} also fails on main{issue}; merge main once it is fixed there."
        line += seen_too
    elif flaky and not unexplained:
        line = f"**Seen on other PRs too (likely flaky):** {listed(flaky, False)} also failed on other PRs " \
               "before this one; check whether it is this PR's before re-running."
    elif unexplained:
        job = unexplained[0]
        who = "Probably yours" if job["verdict"] == CODE else "Unclear"
        line = f"**{who}:** {code(job['name'], 100)} failed: {job['why']}" + (
            f", {code(job['evidence'], 100)}" if job.get("evidence") else "") + "."
    elif jobs:
        line = "**Machine:** " + ("the runner failed, not this PR; re-running the failed jobs." if rerun
                                  else f"the runner failed, not this PR. {rerun_line}")
    else:
        line = "**Gates only:** only gate jobs failed; see the run."
    if report.get("conclusion") == "cancelled":
        line += " CI was cancelled before it finished."
    if report.get("merged") and any(j["verdict"] != MACHINE for j in jobs):
        line += " This PR merged before its CI finished: fix forward on main."
    return line


def render_failures(jobs: list[Mapping]) -> list[str]:
    rows = []
    for job in jobs:
        if job["verdict"] == MACHINE:
            continue
        for item in job.get("failures") or []:
            test = f" {code(item['test'], 100)}" if item.get("kind") == "test" and item.get("test") else ""
            message = f": {code(item['message'], 120)}" if item.get("kind") == "test" and item.get("message") else ""
            link = f" ([job]({job['url']}))" if job.get("url") else ""
            rows.append(f"- **{item.get('owner') or NEW}** {describe(item, False)}{test}{message}{link}")
    if not rows:
        return []
    out = ["", "Failures:", *rows[:MAX_RENDERED_FAILURES]]
    if len(rows) > MAX_RENDERED_FAILURES:
        out.append(f"- ... {len(rows) - MAX_RENDERED_FAILURES} more in the job logs")
    return out


def render_comment(report: Mapping, rerun: str, reran: bool = False) -> str:
    sha = (report.get("head_sha") or "")[:10]
    run = f"[run {report['run_id']} attempt {report['attempt']}]({report.get('run_url')})"
    jobs = report["jobs"]
    state = ("unverified" if report.get("macos_skipped") else "passes") if report.get("conclusion") == "success" \
        else "stopped" if report.get("conclusion") == "cancelled" else "failed"
    out = [MARKER, head_marker(str(report.get("head_sha") or ""), state), verdict_line(report, reran, rerun), ""]
    if report.get("conclusion") == "success":
        out.append(f"CI passes on `{sha}` ({run}).")
        if report.get("macos_skipped"):
            out.append(f"{MACOS_SKIPPED}: {report.get('macos_blocked')} (the `macos` job needs both to succeed). "
                       "Re-run CI once they pass, before merging.")
    else:
        counts = {v: sum(1 for j in jobs if j["verdict"] == v) for v in (MACHINE, CODE, UNKNOWN)}
        summary = ", ".join(f"{n} {v}" for v, n in counts.items() if n)
        verb = "stopped" if report.get("conclusion") == "cancelled" else "failed"
        out += [f"CI {verb} on `{sha}` ({run}): {summary or 'no failed job besides the gates'}."]
        if report.get("macos_skipped"):
            out.append(f"{MACOS_SKIPPED}: {report.get('macos_blocked')}.")
        out.append("")
        if jobs:
            out += ["| Job | Verdict | Why |", "| --- | --- | --- |"]
            for job in jobs[:MAX_RENDERED_JOBS]:
                name = f"[{job['name']}]({job['url']})" if job.get("url") else str(job["name"])
                where_ = f" (runner `{job['runner']}`)" if job.get("runner") and job["verdict"] == MACHINE else ""
                out.append(f"| {name.replace('|', '/')} | **{job['verdict']}** | {job['why']}{where_} |")
            if len(jobs) > MAX_RENDERED_JOBS:
                out.append(f"| ... {len(jobs) - MAX_RENDERED_JOBS} more | | |")
            out += render_failures(jobs)
            evidence = [f"{job['name']}: {job['evidence']}" for job in jobs[:MAX_RENDERED_JOBS] if job["evidence"]]
            if evidence:
                out += ["", "<details><summary>Matched log lines</summary>", "", fence("\n".join(evidence)),
                        "", "</details>"]
        out += ["", rerun]
    out += ["", "Written by `scripts/ci/classify_failures.py` (ci-failure-attribution.yml); signatures are its "
                "`SIGNATURES` table. A machine verdict is the runner's fault, not this PR's; **yours** means the "
                "failing file is one this PR changes, **also red on main** that main's latest full suite fails "
                "the same way, **seen on other PRs** that it failed on another pull request's run lately."]
    return cap("\n".join(out) + "\n")


def render_pending(head: str, run_url: str | None, old_head: str, old_body: str) -> str:
    """The comment once the pull request's head moved past the result it states."""
    last = verdict_of(old_body)
    if last.startswith("**Pending:**"):
        # Already pending for an older push: keep the last real result it quotes.
        last = next((line.removeprefix("Last result: ") for line in old_body.splitlines()
                     if line.startswith("Last result: ")), "")
        old_head = next((m.group(1) for m in re.finditer(r"for `([0-9a-f]+)`", old_body)), old_head)
    run = f" ([run]({run_url}))" if run_url else ""
    out = [MARKER, head_marker(head, "pending"),
           f"**Pending:** CI is running on `{head[:10]}`{run}; the result below was for `{old_head[:10]}` and no "
           "longer applies.", ""]
    if last:
        # Unbolded, so the quoted result never reads as this comment's verdict.
        out += [f"Last result: {last.replace('**', '')}", ""]
    out.append("Written by `scripts/ci/classify_failures.py` (ci-failure-attribution.yml); it is rewritten when "
               "this head's CI completes.")
    return "\n".join(out) + "\n"


def mark_pending(writer: Writer, repo: str, pr: int, existing: list[dict], head: str,
                 run_url: str | None) -> bool:
    """Rewrite the comment when it speaks for a head other than `head`. Only an existing comment."""
    current = next((c for c in existing if MARKER in str(c.get("body") or "")), None)
    if current is None:
        return False
    body = str(current.get("body") or "")
    old_head, _ = comment_head(body)
    if same_head(old_head, head):
        return False
    upsert_comment(writer, repo, pr, MARKER, render_pending(head, run_url, old_head, body), existing)
    return True


# ---------------------------------------------------------------- acting


def rerun_decision(report: Mapping, latest: Mapping | Callable[[], Mapping]) -> tuple[bool, str]:
    """Whether to re-run the failed jobs, and the line that says so. `latest` is the run as it is
    now, or a function that reads it: only a run whose every failure is the machine's needs it."""
    jobs = report["jobs"]
    if not jobs:
        return False, "Not re-run automatically: only gate jobs failed."
    if not all_machine(jobs):
        blockers = [j["name"] for j in jobs if j["verdict"] != MACHINE]
        return False, ("Not re-run automatically: " + ", ".join(f"`{n}`" for n in blockers[:5])
                       + (" is not a machine failure." if len(blockers) == 1 else " are not machine failures."))
    if report.get("conclusion") != "failure":
        return False, "Every failure is a machine failure; a cancelled run is not re-run automatically."
    if callable(latest):
        latest = latest()
    if int(latest.get("run_attempt") or 0) != report["attempt"] or latest.get("status") != "completed":
        return False, "Every failure is a machine failure; the run has been re-run already."
    # Attempt 1, whose re-run (attempt 2) goes back to the minis; attempt 2, which an online but broken mini
    # (a full disk, a failed product restore) may have failed again, whose re-run (attempt 3) takes Blacksmith;
    # or a later attempt a person started, whose re-run by this bot takes Blacksmith
    # (pr_runner_pool.host_fault_retry()). Blacksmith ends the chain.
    if report["attempt"] > LAST_OWNED_ATTEMPT and str((latest.get("triggering_actor") or {}).get("login") or "") == BOT:
        return False, (f"Every failure is a machine failure, but attempt {report['attempt']} was already an "
                       "automatic re-run. Re-run it by hand if it should go again.")
    return True, (f"Every failure is a machine failure: re-ran the failed jobs as attempt {report['attempt'] + 1} "
                  "(the checks show its result).")


def own_failures(gh: GitHub, pr: int, report: dict, files: list[str] | None) -> list[str]:
    """Each concrete failure's ownership: the PR's files first, main's red run only for the rest."""
    failures = [f for job in report["jobs"] if job["verdict"] != MACHINE for f in job.get("failures") or []]
    if not failures:
        return files or []
    files = safe_pr_files(gh, pr) if files is None else files
    attribute(report["jobs"], files, [])
    if any(f["owner"] != YOURS for f in failures):
        try:
            report["main_red"] = main_red(gh)
        except (RuntimeError, ValueError, KeyError, TypeError, AttributeError) as error:
            print(f"::warning::main's red full-suite issue unreadable: {error}", file=sys.stderr)
            report["main_red"] = {}
        attribute(report["jobs"], files, report["main_red"].get("keys") or [])
    return files


def reports_only_where_commented(report: Mapping) -> bool:
    """A run that writes nothing on a pull request without this bot's comment: green with the macOS
    jobs run, or cancelled before a job failed. act() reads the pull request only when it has one."""
    if report.get("conclusion") == "success":
        return not report.get("macos_blocked")
    return report.get("conclusion") == "cancelled" and not report["jobs"]


def write_summary(body: str) -> None:
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write(body.replace(MARKER + "\n", ""))


def act(gh: GitHub, writer: Writer, run: Mapping, report: dict) -> dict:
    """Summary, comment and re-run for the run's pull request, when the run is still its latest word."""
    existing: list[dict] | None = None
    if reports_only_where_commented(report):
        # Most runs are green. Without this bot's comment on the pull request there is nothing to
        # update or mark pending, so the comments are read first and the pull request only when one
        # is there (every workflow shares GITHUB_TOKEN's API budget; it ran out on 2026-10-06).
        pr = pr_number(gh, run)
        if pr:
            existing = [c for c in gh.comments(pr) if (c.get("user") or {}).get("login") == BOT]
            if not any(MARKER in str(c.get("body") or "") for c in existing):
                if report.get("conclusion") == "success":
                    write_summary(render_comment(report, ""))
                return {"pr": pr, "rerun": False, "line": "skipped: nothing reported on this pull request"}
        pr, pull = run_pull(gh, run, pr)
    else:
        pr, pull = run_pull(gh, run)
    merged = bool(pull.get("merged_at"))
    if not pr or (pull.get("state") != "open" and not merged):
        return {"pr": pr, "rerun": False, "line": "skipped: no open pull request at this head"}
    # Only this workflow's own comment: anyone can post one carrying the marker.
    if existing is None:
        existing = [c for c in gh.comments(pr) if (c.get("user") or {}).get("login") == BOT]
    current = next((c for c in existing if MARKER in str(c.get("body") or "")), None)
    head = str((pull.get("head") or {}).get("sha") or "")
    if head != report.get("head_sha"):
        # A run for a head the PR has moved past says nothing itself, but the comment must not keep
        # stating an older head's result (a "passes" for 2957faacff stood on #17232's red b5691441b0).
        if not merged and mark_pending(writer, gh.repo, pr, existing, head, None):
            return {"pr": pr, "rerun": False, "line": f"marked pending on {head[:10]}"}
        return {"pr": pr, "rerun": False, "line": "skipped: no open pull request at this head"}
    if report.get("conclusion") == "cancelled" and not report["jobs"]:
        return {"pr": pr, "rerun": False, "line": "skipped: cancelled with no failed job"}
    report["merged"] = merged
    files = own_failures(gh, pr, report, None)
    now = now_utc()
    try:
        seen = mark_seen_elsewhere(gh, pr, report, now)
    except (RuntimeError, ValueError, KeyError, TypeError, AttributeError) as error:
        print(f"::warning::issue {SEEN_ISSUE} (failures seen on other PRs) unreadable: {error}", file=sys.stderr)
        seen = None
    same_repo = str((run.get("head_repository") or {}).get("full_name") or "").lower() == gh.repo.lower()
    if seen is not None and same_repo:
        try:
            record, issue_body = seen
            updated = record_seen(record, report, pr, now)
            if updated is not None:
                writer.call("PATCH", f"repos/{gh.repo}/issues/{SEEN_ISSUE}", {"body": seen_body(issue_body, updated)})
        except (RuntimeError, ValueError, KeyError, TypeError, AttributeError) as error:
            print(f"::warning::could not record failures in issue {SEEN_ISSUE}: {code(error)}", flush=True)
    if report.get("macos_blocked"):
        report["macos_skipped"] = touches_app(files or safe_pr_files(gh, pr))
    rerun, line = False, ""
    if report.get("conclusion") != "success":
        rerun, line = rerun_decision(report, lambda: gh.run(int(report["run_id"])))
        if merged and rerun:
            rerun, line = False, "Not re-run: this PR has merged."
    if rerun:
        try:
            writer.call("POST", f"repos/{gh.repo}/actions/runs/{report['run_id']}/rerun-failed-jobs", {})
        except RuntimeError as error:
            # GitHub refuses to re-run a run another re-run already started.
            rerun, line = False, f"Every failure is a machine failure; the re-run request failed: {code(error)}"
        else:
            # This token's re-run may emit no workflow_run event; start the UI
            # test dispatch the new attempt's ui-tests job waits for.
            path, body = ui_tests_dispatch.rerun_dispatch(report["run_id"], int(report.get("attempt") or 1) + 1)
            try:
                writer.call("POST", f"repos/{gh.repo}/{path}", body)
            except RuntimeError as error:
                print(f"::warning::could not start {ui_tests_dispatch.DISPATCH_WORKFLOW_FILE}: {code(error)}", flush=True)
    body = render_comment(report, line, rerun)
    write_summary(body)
    # A green run says so only where a failure was reported before; a green run whose macOS jobs
    # never ran says that even where nothing was reported, since it looks green. A machine-only
    # failure that is being re-run asks nothing of the author, so it posts no new comment either.
    quiet = report.get("conclusion") == "success" and not report.get("macos_skipped") or rerun
    if current is not None or not quiet:
        upsert_comment(writer, gh.repo, pr, MARKER, body, existing)
    return {"pr": pr, "rerun": rerun, "line": line}


def act_requested(gh: GitHub, writer: Writer, run: Mapping) -> dict:
    """A CI run started for a new head: an existing comment about an older head says pending.
    Metadata only: the PR, its head and the bot's comments; no log, nothing of the PR runs."""
    pr = pr_number(gh, run)
    if not pr:
        return {"pr": pr, "rerun": False, "line": "skipped: not the open pull request's head"}
    # The comments first: without this bot's comment there is nothing to mark, and the pull
    # request is not read.
    existing = [c for c in gh.comments(pr) if (c.get("user") or {}).get("login") == BOT]
    if not any(MARKER in str(c.get("body") or "") for c in existing):
        return {"pr": pr, "rerun": False, "line": "nothing to mark"}
    pull = gh.pull(pr)
    head = str((pull.get("head") or {}).get("sha") or "")
    if pull.get("state") != "open" or head != run.get("head_sha"):
        return {"pr": pr, "rerun": False, "line": "skipped: not the open pull request's head"}
    changed = mark_pending(writer, gh.repo, pr, existing, head, str(run.get("html_url") or "") or None)
    return {"pr": pr, "rerun": False, "line": f"marked pending on {head[:10]}" if changed else "nothing to mark"}


# ---------------------------------------------------------------- commands


def load_run(gh: GitHub | None, run_id: int | None) -> dict:
    event_path = os.environ.get("GITHUB_EVENT_PATH")
    if run_id is None and event_path and Path(event_path).is_file():
        event = json.loads(Path(event_path).read_text())
        if event.get("workflow_run"):
            return event["workflow_run"]
    if run_id is None or gh is None:
        raise SystemExit("no workflow_run event: pass --run-id with GH_TOKEN set")
    return gh.run(run_id)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", "manaflow-ai/cmux"))
    sub = parser.add_subparsers(dest="command", required=True)
    classify = sub.add_parser("classify", help="read-only: print each failed job's verdict as JSON")
    classify.add_argument("--run-id", type=int)
    classify.add_argument("--log", action="append", default=[],
                          help="classify these saved job logs instead of a run (repeatable)")
    run_act = sub.add_parser("act", help="classify, then write the summary and PR comment and re-run machine failures")
    run_act.add_argument("--run-id", type=int, help="default: the workflow_run event")
    run_act.add_argument("--dry-run", action="store_true", help="print the writes instead of making them")
    args = parser.parse_args(argv)

    if args.command == "classify" and args.log:
        for path in args.log:
            print(json.dumps({"log": path, **classify_text(Path(path).read_text(errors="replace"))}))
        return 0
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    gh = GitHub(args.repo, token) if token else None
    run = load_run(gh, args.run_id)
    if gh is None:
        raise SystemExit("set GH_TOKEN")
    if args.command == "act" and run.get("status") != "completed":
        # workflow_run `requested`: a new head's CI started. Only an older head's comment changes.
        writer = Writer(gh, args.dry_run)
        result = act_requested(gh, writer, run)
        for entry in writer.log:
            print(entry)
        print(json.dumps(result))
        print(f"api calls: {gh.calls}")
        return 0
    if run.get("conclusion") not in ("success", "failure", "cancelled"):
        print(f"run {run.get('id')} concluded {run.get('conclusion')}; nothing to attribute")
        return 0
    # A green run's jobs are read too (no logs): its macOS jobs may never have run.
    report = classify_run(gh, run)
    if args.command == "classify":
        print(json.dumps(report, indent=2))
        return 0
    writer = Writer(gh, args.dry_run)
    result = act(gh, writer, run, report)
    for entry in writer.log:
        print(entry)
    print(json.dumps({**result, "jobs": [(j["name"], j["verdict"], j["signature"]) for j in report["jobs"]]}))
    print(f"api calls: {gh.calls}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
