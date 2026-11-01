#!/usr/bin/env python3
"""Excuse a red check that fails the same way on the base branch.

Run via scripts/gh-merge-green before it refuses a red cmux-next run or a red
required check. A failed job on the PR head is excused only when the same job
also failed on the base, and the head's failed steps and failing test names
are all among the base's. Error lines are compared only when no test failed (a
compile error, say), and warnings never are: they vary run to run (SwiftPM's
cache warnings refused #18147 on 2026-10-07). Names are compared, not counts:
the base may fail more. A runner refusal (no steps, a failed setup step, or the glaeda
hook's refusal), a cancelled or timed-out job, and a failure with no test or
error line to compare are never excused. One base red then no longer freezes
every pull request into that base (2026-10-07: four base reds, and the PRs
fixing them deadlocked on each other's reds).

Where the base verdict comes from, in order (2026-10-19: #21729 and #21807
were refused over "no base verdict" for reds the base had too):
1. The check runs on the base tip and on the merge-base of the base and the
   head. When one has no verdict for the job (a path filter skipped it, or the
   push run was cancelled), up to LOOKBACK commits before it are tried. Any
   workflow and event counts, so a job that runs in a different workflow on
   push (`web / ...` in cmux-next web) is still found. The job is red on the
   base when either line's nearest verdict fails the same way.
2. Only when no commit in 1 has a verdict (a commit's verdict is newer than a
   run found by searching): the newest completed push, schedule or dispatch
   runs on the base branch of the head job's workflow, and of every workflow that runs a job of that name on the
   base commits read in 1 (a skipped one included). A pull request runs the web
   jobs in ci.yml, a feat-cmux-next push in cmux-next web, and react-apps-check
   runs there only when the push touches webviews, so the base tip's is usually
   skipped (2026-10-20: one push in five to ten ran it). The newest of the 20
   runs that has a verdict for the job decides.
A job the base never runs (the cmux-next checks job before it ran on
feat-cmux-next pushes) has no base verdict; the refusal says so and lists each
commit and run it read.
Names match exactly first; failing that, ignoring a matrix suffix (`(1)`,
`(Xcode 26)`) and a reusable-workflow caller prefix (`web / `).

A sharded job (`react-apps-check (1)`, `Web tests (2/4)`) is compared with
every shard of it on the base commit at once: shard placement differs between
runs, so the same red test lands in shard 1 on one run and shard 4 on another
(2026-10-20, twelve-wide web shards since #22237). The head shard is excused
when its failing tests are among those of all the base's failed shards.

A status job that only reports other jobs' results (`web / Web status`,
`web / react-apps-check`: no failing test or error line, only `<job>: failure`
lines, each naming a failed job of its run) has nothing of its own to compare.
Every failed job of its run with
the same caller prefix (every failed job of the run when it has none) is judged
instead, so it is excused only when each of them is, and refused when there is
none (2026-10-20: #22097 was refused with "no failing test or error line to
match" for `web / Web status`).

Every refusal names the job, the head SHA, and each base commit, run or pull
request it was compared with, so a missing base verdict never blocks silently.

God-file, localization and concurrency lint is held to more: every line its
failed steps printed, numbers masked, must be on the base's too. Their findings
are lines such as `Localizable.xcstrings:key: missing uk`, not error lines, so a
pull request adding one more missing translation to a base already red there
would otherwise pass as the base's (2026-10-19: base reds in the cmux-next
checks job refused every feat-cmux-next PR, and --override cannot waive lint).

A job that runs tests is judged per test by scripts/ci/test_reds.py, the one
classifier for "red on the base, so not ours" (the same file as on
feat-cmux-next; 2026-10-28: cmux#26346 landed with its own test helper crash
because the job was red on the base too). A failing test the base does not
fail is the head's; a crash (signal, abort, EXC_*, Fatal error) is the head's
whatever the base shows; and a run whose per-test results are cut short is
the head's, since nothing in it can be compared.

A red step that prints no test name, error line or crash (defaults-snapshot's
`... changed` / `not stamped`) is compared by what its failed steps printed,
numbers and hashes masked, like lint; but the head must print exactly what the
base printed, not a part of it: a head that fails earlier, silently, prints a
prefix of the base's output (2026-10-20: defaults-snapshot red on
feat-cmux-next too was refused with "no failing test or error line to match").

A base verdict older than the merge-base cannot say a red is the head's: the
red may have landed on the base after it (2026-10-20: feat-cmux-next's CI
workflow runs only when dispatched, and its newest run, from 02:29Z, refused
every red that landed after it). A base run, or a merge-base~N / base tip~N
commit, that predates the merge-base still excuses a red it shares, since the
head inherits it; when it does not, the refusal names it as stale, with the
merge-base, the base tip, and the run already going at the tip or the command
that dispatches one. It never dispatches: that is a write starting a whole CI
run, and every lane asking at once would start one each.

A base commit's verdict for a job is its newest run of it that has one: a commit
often runs a job twice, and a workflow_dispatch DEV run skips the checks job its
push run failed (2026-10-24: e8697614's skipped check hid the push run's red).

With `--pull N`, a red the base comparison did not excuse (the base fixed it after
the head's run, or prints it differently) is still not the PR's when every failed
step of the job names files, none of them (nor the step's own script) is a file the
PR changes, and a base commit or run read had the job red. It fails closed: a failing
test (it names the test, not the bug), an error line or a red step naming no file, a
PR changing check code, workflows, baselines or allowlists, and a file list GitHub
cut short are never excused this way.

Exit 0: excused (audit lines on stdout); 1: not excused; 3: GitHub rate-limited
a read (the reset time on stderr).
"""
from __future__ import annotations

import argparse
import importlib.util
import re
import sys
from collections import Counter
from pathlib import Path

_spec = importlib.util.spec_from_file_location("main_fix_evidence", Path(__file__).with_name("main_fix_evidence.py"))
_evidence = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_evidence)
_spec = importlib.util.spec_from_file_location("test_reds", Path(__file__).with_name("test_reds.py"))
test_reds = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(test_reds)
GitHub, Refused, job_for, latest_checks = _evidence.GitHub, _evidence.Refused, _evidence.job_for, _evidence.latest_checks
RateLimited = _evidence.RateLimited

SETUP_STEPS = frozenset({"Set up job", "Set up runner"})
# Jobs that only report the run's other jobs: judged by those jobs, never by themselves.
AGGREGATES = frozenset({"ci-status"})
HOOK_REFUSAL = "glaeda-cmux-runner-hook: refused"
VERDICTS = frozenset({"success", "failure"})
# Base commits tried before the tip and before the merge-base when they have no verdict.
# Each is read only while the ones after it have none, so a wider window costs nothing
# when the tip has a verdict (2026-10-24: two pushes still running and a dispatch run per
# commit used up five).
LOOKBACK = 10
TESTS = (
    re.compile(r"✘ Test (.+?\)) (?:recorded an issue|failed)"),  # Swift Testing
    re.compile(r"Test Case '-\[(\S+ \S+)\]' failed"),  # XCTest
    re.compile(r"^test (\S+) \.\.\. FAILED$"),  # cargo test
    re.compile(r"^(?:FAIL|ERROR): (\S+ \([^)]+\))"),  # unittest
    re.compile(r"^FAILED (\S+::\S+)"),  # pytest
    re.compile(r"^\(fail\) (.+?)(?: \[[\d.]+m?s\])?$"),  # bun test
    # A bun test file that failed, also one that died loading with no `(fail)` line,
    # and bun's error outside any test (a file that failed to load beside a red test).
    re.compile(r"^# (Unhandled error between tests)$"),
    re.compile(r"^(?:##\[group\])?FAIL (\S+\.test\.[cm]?[jt]sx?)(?: \(limit \d+s\))?$"),
)
ERROR = re.compile(r"##\[error\]|\berror:")
WARNING = re.compile(r"##\[warning\]|\bwarning:")
# Summaries carry counts, and a test's own lines already name it.
GENERIC = re.compile(r"Process completed with exit code|red tests?:|✘ Test |Test Case '|\.\.\. FAILED$")
STAMP = re.compile(r"^﻿?\d{4}-\d\d-\d\dT[\d:.]+Z ?")
# SwiftPM's line for a killed test helper, and the hang sampler's ::error lines for it.
CRASH = re.compile(r"exited with unexpected signal code (\d+)|the test helper died on signal (\d+)")
# Checks whose every finding must be the base's (gh-merge-green never waives them).
LINT = re.compile(r"god[ -]?files?|l10n|locali[sz]ation|concurrency", re.IGNORECASE)
# Per-run noise in what a step prints: mktemp names, a temporary folder's own name
# (Python's mkdtemp: /tmp/cmux-prepush-foe40iki), and commit or object hashes.
RUN_NOISE = re.compile(r"\btmp\.[A-Za-z0-9]{6,}|(?<=/tmp/)[^/\s'\"]+|(?<=/T/)[^/\s'\"]+|\b[0-9a-f]{7,40}\b")
# A Python set of strings an assertion says something is missing from (`'X' not found in
# {...}`): its order changes every run (PYTHONHASHSEED) and its items with the tree (every
# package folder), so it is masked there and only there; what is missing is still compared.
STRING_SET = re.compile(r"(?<=not found in )\{'[^'\n]*'(?:, '[^'\n]*')*\}")
# Why a red is still not the pull request's when its failed steps name only files it does
# not change (outside_the_diff). A path token is taken whole; it names a file when it has a
# folder and an extension, or is a bare file name with a source or config extension (so
# docs.example.com is not one).
TOKEN = re.compile(r"[^\s'\"`()<>\[\]{},;|=]+")
# A quoted file name, which may hold spaces ('webviews/src/My File.ts').
QUOTED = re.compile(r"['\"`]([^'\"`\n]*\.[A-Za-z][A-Za-z0-9]{0,9})['\"`]")
FILE_EXTENSIONS = frozenset(
    "swift m mm h c cc cpp hpp rs zig go py rb js mjs cjs jsx ts tsx mts cts css scss html vue svelte json "
    "jsonc toml yaml yml plist xcstrings strings xib storyboard sh bash zsh md txt tsv csv lock lockb "
    "xcconfig entitlements pbxproj resolved png jpg jpeg gif svg pdf ttf otf wasm".split())
# Any line that says a test failed: it names the test, not the file with the bug.
TEST_MARK = re.compile(r"\bfail\w*|\(fail\)|\bnot ok\b|assert|traceback|panic|✘|✗|✕|×|did not pass|not passed|unsuccessful|\bbroken\b|\bregress", re.IGNORECASE)
# Any warning, in any case: a warning never pins a red to files.
ANY_WARNING = re.compile(r"##\[warning\]|\bwarn(?:ing)?s?\b", re.IGNORECASE)
# A URL, with or without its scheme: a scheme, `//host`, or a first segment shaped like a host
# name (`docs.example.com/a.ts`). A repository folder with a dot in it reads as one too, which
# only refuses (fails closed).
URL_LIKE = re.compile(r"^[A-Za-z][\w+-]*:(?!\d)|[A-Za-z][\w+.-]*:/|^//|^[\w.-]+:\d+/|"
                      r"^[\w-]+(?:\.[\w-]+)*\.[A-Za-z]{2,}(?::\d+)?/", re.IGNORECASE)
# Any line that reports an error; each must name a file.
ERRORISH = re.compile(r"##\[error\]|\berrors?\b|\bfatal\b|\bexceptions?\b", re.IGNORECASE)
# A pull request may be excused by files only when every file it changes is source a check
# reads, never what decides how checks run or what files build to. Check code, workflows,
# baselines and allowlists decide what a check reports without the report naming them, and
# build inputs (manifests, lockfiles, project, container and tool config, any dotfile) change
# what every file builds to; a test, spec, fixture, snapshot or mock (cmuxTests/, tests_v2/,
# webviews/test/, *.test.ts) changes what a test job reports. Rather than list every such
# input, only source-type files outside dot folders are allowed, minus those.
SOURCE_EXTENSIONS = frozenset(
    "swift m mm h c cc cpp hpp rs zig go py rb js mjs cjs jsx ts tsx mts cts css scss html vue svelte md "
    "png jpg jpeg gif svg pdf webp ico ttf otf xcstrings strings xib storyboard".split())
GUARDED = re.compile(
    r"^(?:\.github|config)/|(?:^|/)build[-_]support/|test|spec|fixture|snapshot|mock|(?:^|/)scripts/|(?:^|/)\.|baseline|allowlist|(?:^|/)(?:Package\.swift|"
    r"[^/]*\.config\.[cm]?[jt]s|build\.zig|build\.rs|setup\.py|conftest\.py|noxfile\.py|Rakefile|Fastfile)$",
    re.IGNORECASE)


def guarded(path: str) -> bool:
    """Whether a changed file can change what a check reports without the report naming it."""
    name = path.rsplit("/", 1)[-1]
    extension = name.rsplit(".", 1)[-1].lower() if "." in name.strip(".") else ""
    return bool(GUARDED.search(path)) or extension not in SOURCE_EXTENSIONS


EXIT_LINE = re.compile(r"##\[error\]Process completed with exit code")
RED_CHECK = re.compile(r"##\[error\]red check: ")
# GitHub lists at most 3000 files of a pull request.
MAX_PR_FILES = 3000
# check-l10n.sh prints its first 200 errors, then this.
CUT_SHORT = re.compile(r"^\.\.\. \d+ more$")
ANSI = re.compile(r"\x1b\[[0-9;]*m|\^\[\[[0-9;]*m")
# A log GitHub served without step names, and the lines that end a job's last step there.
UNKNOWN_STEP = "UNKNOWN STEP"
POST_STEPS = re.compile(r"^(Post job cleanup\.|A job completed hook has been configured|Cleaning up orphan processes)")
STARTED_HOOK = re.compile(r"^A job started hook has been configured")
RUNNER_STEPS = re.compile(r"^(Set up job|Set up runner|Complete job|Complete runner|Post )")
CRASH_LINE = re.compile(r"exited with unexpected signal code|the test helper died on signal|"
                        r"no \"Test run with\" summary line")
# A trailing matrix value: `(1)`, `(Xcode 26)`, `(${{ matrix.shard }})`.
MATRIX = re.compile(r"\s*\((?:[^()]|\([^()]*\))*\)\s*$")
# A shard index: `(1)`, `(2/4)`.
SHARD = re.compile(r"\s*\(\d+(?:/\d+)?\)\s*$")
# What a status job prints for each job it reports red.
AGGREGATE_LINE = re.compile(r"^[A-Za-z0-9_.#-]+: failure$")
UNKNOWN_STEP = "UNKNOWN STEP"


def short(sha: str | None) -> str:
    return (sha or "?")[:10]


def lines_of(log: str) -> list[str]:
    """The text of each `job<TAB>step<TAB>stamp text` line of `gh run view --log`."""
    found = []
    for line in log.splitlines():
        parts = line.split("\t", 2)
        found.append(STAMP.sub("", parts[-1]).strip())
    return found


def soft_failed_steps(job: dict, log: str) -> set[str]:
    """Steps that logged an ##[error] although the API does not call them failed (continue-on-error).

    The cmux-next checks job runs each lint as such a step and fails only in its last
    step, so these name which lints are red.
    """
    failed = {step["name"] for step in job.get("steps") or []
              if step.get("conclusion") not in (None, "success", "skipped")}
    found = set()
    for line in log.splitlines():
        parts = line.split("\t", 2)
        if len(parts) == 3 and parts[1] not in failed and parts[1] != UNKNOWN_STEP and "##[error]" in parts[2]:
            found.add(parts[1])
    return found


def signature(job: dict, log: str) -> tuple[set[str], set[str], set[str]]:
    """(failed step names, failing test names, error lines with numbers masked)."""
    steps = {step["name"] for step in job.get("steps") or []
             if step.get("conclusion") not in (None, "success", "skipped")}
    steps |= soft_failed_steps(job, log)
    tests: set[str] = set()
    errors: set[str] = set()
    for text in lines_of(log):
        for pattern in TESTS:
            if match := pattern.search(text):
                tests.add(match.group(1))
        if ERROR.search(text) and not GENERIC.search(text) and not WARNING.search(text) and not CRASH_LINE.search(text):
            errors.add(re.sub(r"\d+", "#", text.replace("##[error]", "").strip()))
    return steps, tests, errors


def step_lines(log: str) -> list[tuple[str, str]]:
    """(step, text) for each `job<TAB>step<TAB>stamp text` line of `gh run view --log`.
    GitHub sometimes serves a job's log with no step names, every line under `UNKNOWN STEP`
    (2026-10-20: the checks job of #22200 on a Blacksmith runner, while the base's had them).
    Then each step is told by the `##[group]Run ...` echo that opens it and ends at the next one
    or at the job's post steps; the runner's own setup, hooks and cleanup belong to no step, and
    printed() refuses when the blocks do not match the steps that ran one for one:
    otherwise the whole job, its runner banner and fetched tags, counted as one failed step's
    findings that no base run could have."""
    parsed = [(parts[1], parts[2]) for parts in (line.split("\t", 2) for line in log.splitlines())
              if len(parts) == 3]
    if not parsed or any(step != UNKNOWN_STEP for step, _ in parsed):
        return parsed
    found, step, blocks, hook, post = [], None, 0, False, False
    for _, raw in parsed:
        text = ANSI.sub("", STAMP.sub("", raw.lstrip("\ufeff"))).strip()
        if post:
            continue
        if STARTED_HOOK.match(text):
            # The runner's own job-started hook echoes a `Run` group of its own before the first step.
            hook, step = True, None
        elif POST_STEPS.match(text):
            post, step = True, None
            continue
        elif text.startswith("##[group]Run "):
            if hook:
                hook = False
                continue
            blocks += 1
            step = f"{UNKNOWN_STEP} {blocks}"
        if step is not None:
            found.append((step, raw))
    return found


def ran_steps(job: dict) -> int:
    """How many of the job's own steps ran: not the runner's set-up, completion or post steps."""
    return sum(1 for step in job.get("steps") or []
               if step.get("conclusion") not in (None, "skipped")
               and not RUNNER_STEPS.match(step.get("name") or ""))


def printed(job: dict, log: str) -> Counter[str]:
    """What the job's failed steps printed, each line counted, with numbers masked
    unless a letter leads them (a line number, total or duration; never `step2`): each
    step's output after the `##[group]` echo of its script and environment, without
    warnings or the exit-code line. A step that continues on error reports success but
    logs its `##[error]`; it counts. Output a checker cut short refuses: what it hid
    cannot be compared."""
    failed = {step["name"] for step in job.get("steps") or []
              if step.get("conclusion") not in (None, "success", "skipped")}
    lines = step_lines(log)
    blocks = {step for step, _ in lines if step.startswith(f"{UNKNOWN_STEP} ")}
    if blocks and len(blocks) != ran_steps(job):
        # A composite action or a script's own `Run` group adds a block: a step's findings could
        # then fall outside the block that logged its error, unseen. Refuse rather than guess.
        raise Refused(f"'{job.get('name')}': its log names no steps and has {len(blocks)} `Run` groups for "
                      f"{ran_steps(job)} steps; its findings cannot be told apart to compare with the base")
    for step, raw in lines:
        if "##[error]" in raw:
            failed.add(step)
    found: Counter[str] = Counter()
    echo: set[str] = set()
    opened: set[str] = set()
    for step, raw in lines:
        if step not in failed:
            continue
        text = ANSI.sub("", STAMP.sub("", raw.lstrip("\ufeff"))).strip()
        if text.startswith("##[group]Run ") and step not in opened:
            # A step's first `Run` group is its own script; a later one (a composite action's
            # inner step) is output like any nested group.
            echo.add(step)
            opened.add(step)
            continue
        if text.startswith("##[endgroup]"):
            echo.discard(step)
            continue
        # Only a step's own `Run` echo is its script: a nested group (a script's own
        # `##[group]test x: failed`) is output, so a finding inside one is compared too.
        text = text.removeprefix("##[group]")
        if step in echo or not text or WARNING.search(text) or GENERIC.search(text):
            continue
        if CUT_SHORT.match(text):
            raise Refused(f"'{job.get('name')}': step '{step}' printed output cut short ({text}); "
                          "the findings it hid cannot be compared with the base")
        text = STRING_SET.sub("{…}", text)
        found[re.sub(r"(?<![A-Za-z0-9_])\d+", "#", RUN_NOISE.sub("…", text.replace("##[error]", "").strip()))] += 1
    return found


def crash_signals(log: str) -> set[str]:
    """The signals a test helper died on, from SwiftPM's or the hang sampler's lines."""
    return {first or second for first, second in CRASH.findall(log)}


def refused_at_setup(job: dict, log: str | None = None) -> bool:
    steps = job.get("steps") or []
    if not steps or any(step.get("name") in SETUP_STEPS and step.get("conclusion") == "failure" for step in steps):
        return True
    return log is not None and HOOK_REFUSAL in log


def name_tiers(name: str) -> list[str]:
    """Keys from strictest to loosest: exact, no matrix suffix, no caller prefix, neither."""
    bare = MATRIX.sub("", name).strip()
    tail = name.rsplit(" / ", 1)[-1].strip()
    tail_bare = MATRIX.sub("", tail).strip()
    return [key.casefold() for key in (name, bare, tail, tail_bare)]


def matching(name: str, candidates: list[dict]) -> tuple[list[dict], str]:
    """The candidates (jobs or check runs) that are `name`, at the strictest tier any reaches."""
    wanted = name_tiers(name)
    labels = ("", " (matched without its matrix suffix)", " (matched without its caller prefix)",
              " (matched without its matrix suffix and caller prefix)")
    for tier, key in enumerate(wanted):
        if not key:
            continue
        found = [candidate for candidate in candidates
                 if (candidate_key := name_tiers(candidate.get("name") or "")[tier]) and candidate_key == key]
        if found:
            return found, labels[tier]
    return [], ""


def matching_shards(name: str, candidates: list[dict]) -> tuple[list[dict], str]:
    """Every shard of a sharded `name` among the candidates; else `matching`."""
    if SHARD.search(name):
        stripped = SHARD.sub("", name)
        shards = [candidate for candidate in candidates if SHARD.search(candidate.get("name") or "")]
        wanted = name_tiers(stripped)
        for tier in (0, 2):
            found = [candidate for candidate in shards
                     if name_tiers(SHARD.sub("", candidate["name"]))[tier] == wanted[tier]]
            if found:
                return found, " (every shard)" if tier == 0 else " (every shard, matched without its caller prefix)"
    return matching(name, candidates)


def pooled(jobs: list[dict]) -> dict:
    """One job standing for several failed shards: their steps together; Base.log joins their logs."""
    return dict(jobs[0], steps=[step for found in jobs for step in found.get("steps") or []],
                name=f"{SHARD.sub('', jobs[0].get('name', ''))} ({len(jobs)} failed shards)",
                _pooled=jobs)


def reported_red(log: str) -> list[str]:
    """The job ids a status job prints as `<job>: failure`, outside the echo of its script.

    `gh run view --log` often files every line under UNKNOWN STEP, so the runner's own
    banner is in the log too; a status job is told apart by the jobs it names
    (`report_matches`), not by printing nothing else."""
    found, echo = [], False
    for text in lines_of(log):
        text = ANSI.sub("", text)
        if text.startswith("##[group]Run "):
            echo = True
        elif text.startswith("##[endgroup]"):
            echo = False
        elif not echo and AGGREGATE_LINE.match(text.removeprefix("##[group]")):
            # A nested group is output, not the step's script: a red it reports is judged too.
            found.append(text.removeprefix("##[group]").rsplit(":", 1)[0])
    return sorted(set(found))


def job_key(name: str) -> str:
    return re.sub(r"[\s_]+", "-", MATRIX.sub("", name.rsplit(" / ", 1)[-1]).strip().casefold())


# A job id's suffix naming the legs of a matrix job (`react-apps-check-shard`).
LEG_SUFFIX = re.compile(r"-shards?$")


def report_matches(reported: list[str], under: list[dict], prefixed: bool) -> dict[str, list[dict]]:
    """For each job id a status job reports red, the failed jobs of `under` it names.

    A job id names a job whose name, without caller prefix or matrix suffix and with
    spaces as dashes, is the id (`web-tests` is `Web tests (2/4)`) or the id without a
    leg suffix (`react-apps-check-shard` is `react-apps-check (3)`). A status job with
    no caller prefix also names the jobs of a caller (`web` is `web / Web tests (1/4)`);
    under a prefixed one, every job shares the caller, so that would name them all."""
    matches = {}
    for job_id in reported:
        wanted = job_id.casefold()
        matches[job_id] = [
            found for found in under
            if (key := job_key(found.get("name", ""))) and (
                wanted == key or LEG_SUFFIX.sub("", wanted) == key
                or (not prefixed and " / " in found.get("name", "")
                    and wanted == job_key(found["name"].split(" / ", 1)[0])))]
    return matches


def caller_prefix(name: str) -> str:
    return name.rsplit(" / ", 1)[0] + " / " if " / " in name else ""


def job_url(repo: str, job: dict) -> str:
    return job.get("html_url") or f"https://github.com/{repo}/actions/runs/{job.get('run_id')}/job/{job.get('id')}"


def head_jobs(repo: str, sha: str, runs: list[int], checks: list[str], github) -> list[dict]:
    jobs: dict[int, dict] = {}
    for run in runs:
        for page in github.json(f"repos/{repo}/actions/runs/{run}/jobs?filter=latest&per_page=100", paginate=True):
            for job in page.get("jobs") or []:
                if job.get("name") in AGGREGATES:
                    continue
                if job.get("status") == "completed" and job.get("conclusion") not in ("success", "skipped", "neutral"):
                    if job.get("head_sha") not in (None, sha):
                        raise Refused(f"{job.get('name')}: job is not for the exact SHA {sha}")
                    jobs[job["id"]] = job
    if checks:
        latest = latest_checks(repo, sha, github)
        aggregate_runs = []
        for name in checks:
            if name not in latest:
                raise Refused(f"{name}: has not run on exact head {sha}")
            job = job_for(repo, latest[name], sha, github)
            if name in AGGREGATES:
                aggregate_runs.append(job["run_id"])
            else:
                jobs[job["id"]] = job
        for run in aggregate_runs:
            found = head_jobs(repo, sha, [run], [], github)
            if not found:
                raise Refused(f"run {run}: its aggregate check failed with no failed job to compare with the base")
            jobs.update((job["id"], job) for job in found)
    return list(jobs.values())


def verdict_checks(repo: str, sha: str, github) -> dict:
    """Per check name on a base commit, the newest GitHub Actions run of it with a verdict, else
    the newest. A commit often runs a job twice, and the newer can have none: a workflow_dispatch
    DEV run skips the cmux-next checks job its push run failed (2026-10-24: e8697614's skipped
    check 121029429698 hid push run 40146316318's red, so the base had "no verdict")."""
    ranked: dict[str, tuple[tuple[bool, int], dict]] = {}
    for page in github.json(f"repos/{repo}/commits/{sha}/check-runs?per_page=100", paginate=True):
        for check in page.get("check_runs") or []:
            # A third-party app cannot provide compile or test evidence.
            if check.get("app", {}).get("slug") != "github-actions":
                continue
            rank = (check.get("status") == "completed" and check.get("conclusion") in VERDICTS, check["id"])
            if check["name"] not in ranked or rank > ranked[check["name"]][0]:
                ranked[check["name"]] = (rank, check)
    return {name: check for name, (_, check) in ranked.items()}


def changed_files(repo: str, pr: int, github) -> set[str]:
    """Every path the pull request changes, both ends of a rename included."""
    files = []
    for page in github.json(f"repos/{repo}/pulls/{pr}/files?per_page=100", paginate=True):
        files.extend(page if isinstance(page, list) else [page])
    if len(files) >= MAX_PR_FILES:
        raise Refused(f"#{pr} changes {len(files)} files, as many as GitHub lists; which it changes is unknown")
    return {path for entry in files for path in (entry.get("filename"), entry.get("previous_filename")) if path}


def touched(path: str, changed: set[str]) -> str | None:
    """The changed file a named path may be: the same, or one a suffix of the other (a bare
    file name, an absolute runner path), so a doubt counts as changed."""
    for name in changed:
        # A bare name matches any changed file ending in it: a token cut at a space
        # (`My File.ts` read as `File.ts`) still counts as the changed file.
        if path == name or name.endswith(path if "/" not in path else "/" + path) or path.endswith("/" + name):
            return name
    return None


def without_files(text: str) -> str:
    """The line with every file it names blanked out."""
    for path in sorted(file_paths(text), key=len, reverse=True):
        text = text.replace(path, " ")
    return text


def file_paths(text: str) -> set[str]:
    """The files a line names, each token taken whole (`assets/Foo@2x.png`, never `2x.png`)."""
    found = set()
    for token in TOKEN.findall(text) + QUOTED.findall(text):
        # Windows paths (the cmux-tui Windows lane prints `src\foo.rs`, or `C:\a\cmux\src\foo.rs`)
        # compare with forward slashes, the drive letter dropped (the suffix match finds the file).
        token = re.sub(r"^[A-Za-z]:(?=[\\/])", "", token).replace("\\", "/")
        if URL_LIKE.search(token):
            continue  # a URL is somewhere else, not a file of this repository
        token = re.sub(r":\d+(?::\d+)?:?$", "", token.rstrip(".:")).removeprefix("./")
        name = token.rsplit("/", 1)[-1]
        if "." not in name.strip("."):
            continue
        extension = name.rsplit(".", 1)[-1].lower()
        if ("/" in token and re.fullmatch(r"[a-z][a-z0-9]{0,9}", extension)) or extension in FILE_EXTENSIONS:
            found.add(token)
    return found


def outside_the_diff(job: dict, log: str, changed: set[str]) -> list[str]:
    """The files a red job's failed steps name, when none is one the pull request changes.

    Raises Refused when a failed step cannot be pinned to files: any line saying a test
    failed (it names the test, not where the bug is), an error line naming no file, or a
    step whose output (warnings aside) names none. A step's own script and env (its
    `##[group]Run` echo) and its warnings must be outside the diff too, but never pin a red
    to files by themselves: a step naming files only there refuses. A pull request changing check code, workflows, baselines, allowlists or build inputs
    is never excused this way. The summary step that only lists the other steps' reds
    (`red check: X`) is skipped."""
    name = job.get("name", "")
    if guarded_paths := sorted(path for path in changed if guarded(path)):
        raise Refused(f"it changes check code, a baseline or a build input ({guarded_paths[0]}), which can move "
                      "a finding without the finding naming it")
    lines = step_lines(log)
    blocks = {step for step, _ in lines if step.startswith(f"{UNKNOWN_STEP} ")}
    if blocks and len(blocks) != ran_steps(job):
        raise Refused(f"its log names no steps and has {len(blocks)} `Run` groups for {ran_steps(job)} steps")
    # A log with no step names has blocks, not the API's step names: its red blocks are those that
    # logged an error (each continue-on-error lint, and the step that fails the job, does).
    failed = set() if blocks else {step["name"] for step in job.get("steps") or []
                                   if step.get("conclusion") not in (None, "success", "skipped")}
    failed |= {step for step, raw in lines if "##[error]" in raw}
    echo: dict[str, list[str]] = {}
    output: dict[str, list[str]] = {}
    in_echo: set[str] = set()
    for step, raw in lines:
        if step not in failed:
            continue
        text = ANSI.sub("", STAMP.sub("", raw.lstrip("﻿"))).strip()
        if text.startswith("##[group]Run ") and step not in echo:
            # Only the step's first `Run` group is its script; a later one is output.
            in_echo.add(step)
            echo.setdefault(step, []).append(text[len("##[group]Run "):])
        elif text.startswith("##[endgroup]") and step in in_echo:
            in_echo.discard(step)
        elif text:
            # Only a step's own `Run` echo is its script; a nested group (a script's own
            # `##[group]test x: failed`) is output and is read like the rest.
            (echo if step in in_echo else output).setdefault(step, []).append(text)
    named: list[str] = []
    pinned = 0
    for step in sorted(failed):
        said = [text for text in output.get(step, []) if not text.startswith("##[endgroup]")]
        errors = [text for text in said if ERRORISH.search(text) and not EXIT_LINE.search(text)
                  and not WARNING.search(text)]
        if errors and all(RED_CHECK.search(text) for text in errors):
            continue  # the summary step: each step it lists is judged on its own
        # Test language is looked for outside file names: `webviews/src/panic.ts` is not a panic.
        if failing := [text for text in said
                       if any(pattern.search(text) for pattern in TESTS) or CRASH.search(text)
                       or TEST_MARK.search(without_files(text))]:
            raise Refused(f"step '{step}' says a test failed ({failing[0][:160]}), which names the test, "
                          "not the file with the bug")
        if unpinned := [text for text in errors if not file_paths(text)]:
            raise Refused(f"step '{step}' has an error naming no file: {unpinned[0][:200]}")
        # The findings are what the step printed, warnings aside; its script, env and warnings
        # only widen what must be outside the diff, never pin the red to files themselves.
        paths = {found for text in said if not ANY_WARNING.search(text) for found in file_paths(text)}
        if not paths:
            raise Refused(f"step '{step}' failed naming no file outside its warnings and script")
        for path in sorted({found for text in said + echo.get(step, []) for found in file_paths(text)}):
            if hit := touched(path, changed):
                raise Refused(f"step '{step}' names {path}, which this pull request changes ({hit})")
        pinned += 1
        # Name what the errors name; a step whose findings print no error line (NO-SWIFTUI) names them all.
        named.extend(sorted({found for text in errors for found in file_paths(text)} or paths))
    if not pinned:
        raise Refused(f"'{name}' has no failed step to pin to files")
    return named


class Head:
    """One failed head job and the signature every base candidate is compared with."""

    def __init__(self, repo: str, job: dict, log: str):
        self.job, self.name, self.url = job, job.get("name", ""), job_url(repo, job)
        self.steps, self.tests, self.errors = signature(job, log)
        self.log, self.own = log, test_reds.read(log)
        self.crash = crash_signals(log)
        self.soft = soft_failed_steps(job, log)
        self.lint = bool(LINT.search(self.name))
        # A red step with no test, error line or crash to name is compared by what it printed.
        self.by_output = self.lint or not (self.tests or self.errors or self.crash)
        self.output_error = ""
        try:
            self.printed = printed(job, log) if self.by_output else Counter()
        except Refused as unreadable:
            if self.lint:
                raise
            # A status job reports through its lines instead; judge() refuses only when it compares output.
            self.printed, self.output_error = Counter(), str(unreadable)

    def mismatch(self, base_job: dict, base_log: str, where: str) -> str | None:
        """Why `base_job` does not fail the way this head job does, or None when it does."""
        base_steps, base_tests, base_errors = signature(base_job, base_log)
        verdict = test_reds.classify(self.log, base_log, self.name, where)
        if verdict is not None and verdict.own:
            return "; ".join(verdict.reasons)[:800]
        # Not a test job (a compile or tool that died on a signal): the base must have died the same way.
        if missing := sorted(self.crash - crash_signals(base_log)):
            return f"the process died on signal {', '.join(missing)}, and {where} did not"
        compared = [("failed steps", self.steps, base_steps), ("failing tests", self.tests, base_tests)]
        if self.by_output:
            try:
                base_printed = printed(base_job, base_log)
            except RateLimited:
                raise
            except Refused as cut_short:
                return f"{where}: {cut_short}"
            # By count: one more copy of a base finding (a second blocking call) is the head's.
            compared.append(("findings" if self.lint else "output", set(self.printed - base_printed), set()))
            if not self.lint:
                # Exactly the base's output: a head that failed earlier, silently, prints only part of it.
                compared.append(("output the head did not print, which is", set(base_printed - self.printed), set()))
        elif not self.tests:
            compared.append(("errors", self.errors, base_errors))
        for kind, head, seen in compared:
            if missing := sorted(head - seen):
                return f"{kind} not on {where}: {'; '.join(missing)[:600]}"
        return None

    def what(self) -> str:
        crash = [f"the test helper died on signal {signal}" for signal in sorted(self.crash)]
        found = "; ".join(crash + sorted(self.tests)) or "; ".join(sorted(self.printed or self.errors)) or \
            "red steps " + "; ".join(sorted(self.soft))
        return found[:400]


class Base:
    """Base-branch evidence, fetched lazily and shared by every failed head job."""

    def __init__(self, repo: str, base: str, sha: str, github, lookback: int = LOOKBACK):
        self.repo, self.base, self.sha, self.github, self.lookback = repo, base, sha, github, lookback
        self._lines: list[tuple[str, list[tuple[str, str]]]] | None = None
        self._checks: dict[str, dict] = {}
        self._jobs: dict[int, dict] = {}
        self._run_jobs: dict[int, list[dict]] = {}
        self._workflow_runs: dict[int, list[dict]] = {}
        self._run_workflow: dict[int, int | None] = {}
        self._logs: dict[int, str] = {}
        self.notes: list[str] = []
        # Per head job name, the first base commit or run read where that job was red.
        self.reds: dict[str, str] = {}
        self.tip_is_merge_base = False
        self.tip: str | None = None
        self.merge_base: str | None = None
        # Base commits read that predate the merge-base, and whether a commit contains it.
        self._stale: set[str] = set()
        self._contains: dict[str, bool] = {}
        # Whether the base tip or the commits just before it had a verdict for the job judged last.
        self.tip_verdict = False

    def history(self, ref: str) -> list[str]:
        listed = self.github.json(f"repos/{self.repo}/commits?sha={ref}&per_page={self.lookback + 1}")
        return [commit["sha"] for commit in listed if isinstance(commit, dict) and isinstance(commit.get("sha"), str)]

    def lines(self) -> list[tuple[str, list[tuple[str, str]]]]:
        """[(line name, [(commit, label), ...])] for the base tip and the merge-base."""
        if self._lines is not None:
            return self._lines
        self._lines = []
        try:
            tip_history = self.history(self.base)
        except RateLimited:
            raise
        except Refused as error:
            self.notes.append(f"could not list {self.base} commits ({error})")
            return self._lines
        if not tip_history:
            self.notes.append(f"GitHub listed no {self.base} commits")
            return self._lines
        tip = self.tip = tip_history[0]
        self._lines.append(("base tip", [(commit, "base tip" if index == 0 else f"base tip~{index}")
                                         for index, commit in enumerate(tip_history)]))
        try:
            compared = self.github.json(f"repos/{self.repo}/compare/{tip}...{self.sha}?per_page=1")
            merge_base = ((compared or {}).get("merge_base_commit") or {}).get("sha")
        except RateLimited:
            raise
        except Refused as error:
            merge_base = None
            self.notes.append(f"could not read the merge-base of {short(tip)} and {short(self.sha)} ({error})")
        self.merge_base = merge_base
        if merge_base in tip_history:
            self._stale.update(tip_history[tip_history.index(merge_base) + 1:])
        if merge_base and merge_base != tip:
            try:
                history = self.history(merge_base) if merge_base not in tip_history else \
                    tip_history[tip_history.index(merge_base):]
            except RateLimited:
                raise
            except Refused as error:
                history = [merge_base]
                self.notes.append(f"could not list commits before merge-base {short(merge_base)} ({error})")
            self._lines.append(("merge-base", [(commit, "merge-base" if index == 0 else f"merge-base~{index}")
                                               for index, commit in enumerate(history)]))
            self._stale.update(history[1:])
        elif merge_base == tip:
            self.tip_is_merge_base = True
        return self._lines

    def checks(self, commit: str) -> dict:
        if commit not in self._checks:
            try:
                self._checks[commit] = verdict_checks(self.repo, commit, self.github)
            except RateLimited:
                raise
            except Refused as error:
                self.notes.append(f"could not read check runs on {short(commit)} ({error})")
                self._checks[commit] = {}
        return self._checks[commit]

    def job_url_ids(self, check: dict) -> tuple[int, int] | None:
        url = check.get("details_url", "")
        match = re.fullmatch(r"https://github\.com/" + re.escape(self.repo) + r"/actions/runs/(\d+)/job/(\d+)", url)
        return (int(match[1]), int(match[2])) if match else None

    def workflows_running(self, name: str) -> list:
        """The workflows whose runs on the base commits already read have a job `name`, skipped or not."""
        found = []
        for _, commits in self.lines():
            for commit, _ in commits:
                for check in matching(name, list(self._checks.get(commit, {}).values()))[0]:
                    ids = self.job_url_ids(check)
                    if not ids:
                        continue
                    if ids[0] not in self._run_workflow:
                        try:
                            run = self.github.json(f"repos/{self.repo}/actions/runs/{ids[0]}")
                        except RateLimited:
                            raise
                        except Refused as error:
                            self.notes.append(f"could not read base run {ids[0]} ({error})")
                            run = None
                        self._run_workflow[ids[0]] = run.get("workflow_id") if isinstance(run, dict) else None
                    workflow = self._run_workflow[ids[0]]
                    if workflow is not None and workflow not in found:
                        found.append(workflow)
        return found

    def job(self, check: dict, commit: str) -> dict | None:
        ids = self.job_url_ids(check)
        if not ids:
            return None
        job_id = ids[1]
        if job_id not in self._jobs:
            try:
                self._jobs[job_id] = self.github.json(f"repos/{self.repo}/actions/jobs/{job_id}")
            except RateLimited:
                raise
            except Refused as error:
                self.notes.append(f"could not read base job {job_id} ({error})")
                self._jobs[job_id] = {}
        job = self._jobs[job_id]
        if job.get("head_sha") not in (None, commit) or job.get("status") != "completed":
            return None
        return job

    def log(self, job: dict) -> str:
        if "_pooled" in job:
            return "\n".join(self.log(shard) for shard in job["_pooled"])
        if job["id"] not in self._logs:
            self._logs[job["id"]] = self.github.log(self.repo, job)
        return self._logs[job["id"]]

    def candidates(self, jobs: list[dict], how: str) -> list[dict]:
        """The base jobs to compare one by one; a sharded job's failed shards count as one."""
        if not how.startswith(" (every shard"):
            return jobs
        failed = [job for job in jobs if job.get("conclusion") == "failure"]
        if not failed:
            return jobs[:1]
        return failed if len(failed) == 1 else [pooled(failed)]

    def run_jobs(self, run: int) -> list[dict]:
        if run not in self._run_jobs:
            self._run_jobs[run] = [found for page in self.github.json(
                f"repos/{self.repo}/actions/runs/{run}/jobs?filter=latest&per_page=100", paginate=True)
                for found in page.get("jobs") or []]
        return self._run_jobs[run]

    def workflow_runs(self, workflow) -> list[dict]:
        if workflow not in self._workflow_runs:
            listing = f"repos/{self.repo}/actions/workflows/{workflow}/runs?branch={self.base}&status=completed&per_page=20"
            # Dispatched runs are read on their own too: a job that base pushes skip (feat-cmux-next's
            # Swift suite) gets its base verdict only from a dispatched run, such as the scheduled tip
            # Swift suite, which twenty pushes on a busy base would push out of the first listing.
            listed = {}
            for page in (self.github.json(listing), self.github.json(f"{listing}&event=workflow_dispatch")):
                for run in page.get("workflow_runs") or []:
                    listed.setdefault(run.get("id"), run)
            runs = [run for run in listed.values()
                    if run.get("event") not in ("pull_request", "pull_request_target")
                    and run.get("conclusion") != "skipped"]
            # Newest first by creation, which GitHub returns but does not document: the newest run
            # with a verdict decides, and one older than the merge-base is stale.
            self._workflow_runs[workflow] = sorted(
                runs, key=lambda run: run.get("created_at") or "", reverse=True)  # stable: ties keep GitHub's order
        return self._workflow_runs[workflow]


def predates(base: Base, commit: str) -> bool:
    """Whether a base commit read in lines() is older than the merge-base."""
    base.lines()
    return commit in base._stale


def contains_merge_base(base: Base, sha: str | None) -> bool:
    """Whether a base run's commit has the merge-base in its history, so it saw every base change the
    head has. Unknown when the merge-base could not be read: then it counts, as before."""
    base.lines()
    if not base.merge_base:
        return True
    if not sha:
        return False
    if sha in (base.merge_base, base.tip):
        return True
    if sha in base._stale:
        return False
    if sha not in base._contains:
        try:
            status = base.github.json(f"repos/{base.repo}/compare/{base.merge_base}...{sha}?per_page=1").get("status")
            base._contains[sha] = status in ("ahead", "identical")
        except RateLimited:
            raise
        except Refused as error:
            base.notes.append(f"could not compare run commit {short(sha)} with the merge-base ({error})")
            base._contains[sha] = True
    return base._contains[sha]


def stale_run(base: Base, run: dict, file: str) -> str:
    return (f"the newest {base.base} run of {file} with a verdict for it, run {run['id']} at "
            f"{short(run.get('head_sha'))} ({run.get('created_at') or run.get('updated_at') or 'time unknown'}), "
            f"predates the merge-base {short(base.merge_base)} (base tip {short(base.tip)}), so it cannot say "
            "whether this red came from the base")


def dispatch_hint(base: Base, workflow, path: str) -> str:
    """The run already going at the base tip, or the command that starts one. Never dispatched here."""
    file = path.rsplit("/", 1)[-1] if path else str(workflow)
    if base.tip and workflow is not None:
        try:
            listed = base.github.json(f"repos/{base.repo}/actions/workflows/{workflow}/runs?branch={base.base}"
                                      f"&head_sha={base.tip}&per_page=5")
        except RateLimited:
            raise
        except Refused as error:
            base.notes.append(f"could not list runs at the base tip {short(base.tip)} ({error})")
            listed = {}
        if pending := [run for run in listed.get("workflow_runs") or [] if run.get("status") != "completed"]:
            return (f"run {pending[0]['id']} of {file} at the base tip {short(base.tip)} is "
                    f"{pending[0].get('status')}: retry when it finishes")
    return (f"dispatch {file} on {base.base} for a base verdict, then retry when it finishes "
            f"(gh workflow run {file} --repo {base.repo} --ref {base.base}), or fix it on this head")


def verdict_at(head: Head, base: Base, commit: str) -> tuple[list[dict], str]:
    """The base jobs at `commit` with a verdict for the head job, and how the name matched."""
    checks = list(base.checks(commit).values())
    found, how = matching_shards(head.name, checks)
    jobs = []
    for check in found:
        job = base.job(check, commit)
        if job and job.get("conclusion") in VERDICTS and not refused_at_setup(job):
            jobs.append(job)
    return jobs, how


def judge_on_commits(head: Head, base: Base) -> tuple[str | None, list[str], bool]:
    """(audit line or None, reasons it did not excuse, whether any base commit had a verdict)."""
    reasons, had_verdict = [], False
    base.tip_verdict = False
    for line, commits in base.lines():
        for commit, label in commits:
            jobs, how = verdict_at(head, base, commit)
            if not jobs:
                continue
            where = f"{label} {short(commit)}"
            # Older than the merge-base: a red it shares is the head's inheritance, but its green or
            # different red cannot say the head's red is its own; the red may have landed since.
            stale = predates(base, commit)
            found = []
            for job in base.candidates(jobs, how):
                if job.get("conclusion") != "failure":
                    found.append(f"green on {where} ({job.get('name')}{how}: {job_url(base.repo, job)})")
                    continue
                base.reds.setdefault(head.name, f"{where} ({job_url(base.repo, job)})")
                if why := head.mismatch(job, base.log(job), f"{where} ({job_url(base.repo, job)})"):
                    found.append(why)
                    continue
                return (f"excused '{head.name}': {base.base} {where} fails the same way "
                        f"({job.get('name')}{how}: {job_url(base.repo, job)}): {head.what()}"), reasons + found, True
            if stale:
                reasons.append(f"{where} predates the merge-base {short(base.merge_base)}, too old to judge a red "
                               f"the base may have gained since ({'; '.join(found)})")
            else:
                had_verdict = True
                base.tip_verdict = base.tip_verdict or line == "base tip"
                reasons.extend(found)
            break
        else:
            before = ", ".join(short(commit) for commit, _ in commits[1:])
            also = ", also the merge-base" if line == "base tip" and base.tip_is_merge_base else ""
            reasons.append(f"no verdict at the {line} ({short(commits[0][0])}{also})"
                           + (f" or the {len(commits) - 1} commits before it ({before})" if before else ""))
    if not base.lines():
        reasons.append(f"no {base.base} commits to compare with ({'; '.join(base.notes) or 'none listed'})")
    return None, reasons, had_verdict


def judge_on_base_runs(head: Head, base: Base, workflows: list, path: str = "") -> tuple[str | None, str | None, bool]:
    """Per workflow, the newest base run that has a verdict for the head job decides; any excusing one excuses.
    `path` is the head job's own workflow file (the first of `workflows`)."""
    reasons, had_verdict = [], False
    for index, workflow in enumerate(workflows):
        excused, reason, verdict = judge_on_workflow_runs(head, base, workflow, path if index == 0 else "")
        if excused:
            return excused, None, True
        reasons.append(reason)
        had_verdict = had_verdict or verdict
    return None, "; ".join(reason for reason in reasons if reason), had_verdict


def judge_on_workflow_runs(head: Head, base: Base, workflow, path: str = "") -> tuple[str | None, str | None, bool]:
    """The newest base run of `workflow` that has a verdict for the head job decides. One older than
    the merge-base still excuses a red it shares; otherwise it is stale, not a verdict."""
    for candidate_run in base.workflow_runs(workflow):
        found, how = matching_shards(head.name, base.run_jobs(candidate_run["id"]))
        found = [job for job in found if job.get("conclusion") in VERDICTS and not refused_at_setup(job)]
        if not found:
            continue
        where = f"{base.base} run {candidate_run['id']}"
        reasons = []
        for job in base.candidates(found, how):
            if job.get("conclusion") != "failure":
                reasons.append(f"'{head.name}' is not red on {where} ({job.get('conclusion')}{how}); fix it on this head")
                continue
            base.reds.setdefault(head.name, f"{where} ({job_url(base.repo, job)})")
            if why := head.mismatch(job, base.log(job), where):
                reasons.append(f"'{head.name}': {why}")
                continue
            url = candidate_run.get("html_url") or f"https://github.com/{base.repo}/actions/runs/{candidate_run['id']}"
            return f"excused '{head.name}': {where} fails the same way{how} ({url}): {head.what()}", None, True
        if not contains_merge_base(base, candidate_run.get("head_sha")):
            file = path.rsplit("/", 1)[-1] if path else f"workflow {workflow}"
            seen = "; ".join(sorted({"green" if job.get("conclusion") != "failure" else "red another way"
                                     for job in base.candidates(found, how)}))
            return None, f"'{head.name}': {stale_run(base, candidate_run, file)} (it is {seen} there)", False
        return None, "; ".join(reasons), True
    runs = base.workflow_runs(workflow)
    return None, (f"no completed {base.base} run of its workflow or of workflow {workflow} has a verdict for it "
                  f"({len(runs)} non-pull_request {base.base} runs of workflow {workflow} read)"), False


def judge(repo: str, base: str, sha: str, runs: list[int], github, *, checks: list[str] = (),
          lookback: int = LOOKBACK, pr: int | None = None) -> list[str]:
    """Audit lines for every excused failure; raises Refused naming every one that is not."""
    audit: list[str] = []
    changed: set[str] | None = None
    refusals: list[str] = []
    evidence = Base(repo, base, sha, github, lookback)
    jobs = head_jobs(repo, sha, runs, list(checks), github)
    if not jobs:
        # A red run or check with no failed job to show has nothing the base can excuse.
        raise Refused(f"no failed job found on the head {short(sha)} to compare with the base")
    judged = {job["id"] for job in jobs}
    # Status jobs: (job, the jobs it reports red, the failed jobs of its run judged in its place,
    # the jobs each reported id names).
    statuses: list[tuple[dict, list[str], list[dict], dict[str, list[dict]]]] = []
    for job in jobs:  # grows: a status job adds the failed jobs it reports
        name = job.get("name", "")
        if job.get("conclusion") != "failure":
            refusals.append(f"'{name}' is {job.get('conclusion')} at {short(sha)}: it has no verdict to compare "
                            "with the base; re-run it")
            continue
        if refused_at_setup(job):
            refusals.append(f"'{name}' was refused at setup by its runner at {short(sha)}; it gets re-run, never excused")
            continue
        head_log = github.log(repo, job)
        if refused_at_setup(job, head_log):
            refusals.append(f"'{name}' was refused at setup by its runner at {short(sha)}; it gets re-run, never excused")
            continue
        try:
            head = Head(repo, job, head_log)
        except RateLimited:
            raise
        except Refused as cut_short:
            refusals.append(f"{cut_short} (at {short(sha)}, {job_url(repo, job)})")
            continue
        if test_reds.is_test_red(head.own, name) and (head.own.crashes or head.own.truncated):
            refusals.append(f"'{name}' at {short(sha)} ({head.url}): " + "; ".join(head.own.crashes + head.own.truncated[:1])[:800]
                            + " (a crash or a cut-short run is never a base red)")
            continue
        if head.lint and not head.printed:
            refusals.append(f"'{name}' at {short(sha)} ({head.url}): its failed steps printed nothing to compare "
                            "with the base")
            continue
        reported = [] if head.lint or head.tests or head.errors or head.crash else reported_red(head_log)
        if reported:
            prefix = caller_prefix(name)
            under = [found for found in head_jobs(repo, sha, [job["run_id"]], [], github)
                     if found["id"] != job["id"] and (not prefix or caller_prefix(found.get("name", "")) == prefix)]
            if not under:
                refusals.append(f"'{name}' at {short(sha)} ({head.url}) reports {', '.join(reported)} red, but its run "
                                f"has no failed job{f' under {prefix.strip()}' if prefix else ''} to compare with the base")
                continue
            matches = report_matches(reported, under, bool(prefix))
            if missing := [job_id for job_id, found in matches.items() if not found]:
                refusals.append(f"'{name}' at {short(sha)} ({head.url}) prints {', '.join(missing)}: failure, which "
                                "names no failed job of its run; nothing to compare with the base")
                continue
            jobs.extend(found for found in under if found["id"] not in judged)
            judged.update(found["id"] for found in under)
            statuses.append((job, reported, under, matches))
            continue
        if head.by_output and not head.printed:
            refusals.append(f"'{name}' at {short(sha)} ({head.url}): "
                            f"{head.output_error or 'its failed steps printed nothing to compare with the base'}")
            continue
        excused, commit_reasons, had_verdict = judge_on_commits(head, evidence)
        if excused:
            audit.append(excused)
            continue
        run_reason, run_verdict = None, False
        if not evidence.tip_verdict:
            # The base tip line's verdict is newer than any run found by searching: a green tip is
            # green. An older merge-base verdict is not, so a path-filtered job still searches.
            head_run = github.json(f"repos/{repo}/actions/runs/{job['run_id']}")
            workflow, path = head_run.get("workflow_id"), head_run.get("path") or ""
            workflows = [workflow] + [found for found in evidence.workflows_running(name) if found != workflow]
            excused, run_reason, run_verdict = judge_on_base_runs(head, evidence, workflows, path)
            if excused:
                audit.append(excused)
                continue
        tried = [f"{base} commits: {'; '.join(commit_reasons)}"] if commit_reasons else []
        if run_reason:
            tried.append(run_reason)
        if pr is not None:
            # A red the base fixed after the head's run, or one printed differently, is still not
            # this PR's when every file its failed steps name is outside the diff and the base had
            # the job red too (2026-10-24: #24997's web bundles red named only base files).
            red_at = evidence.reds.get(name)
            try:
                if red_at is None:
                    raise Refused(f"no {base} commit or run read has it red")
                if changed is None:
                    changed = changed_files(repo, pr, github)
                named = outside_the_diff(job, head_log, changed)
            except RateLimited:
                raise
            except (Refused, ValueError, KeyError, TypeError, AttributeError) as why:
                # An unreadable file list refuses too, but keeps the base comparison's reasons.
                tried.append(f"not outside the diff of #{pr}: {why or type(why).__name__}")
            else:
                audit.append(f"excused '{name}': its failed steps name only files #{pr} does not change "
                             f"({'; '.join(named)[:400]}), and {base} has it red at {red_at}")
                continue
        if not had_verdict and not run_verdict:
            # No verdict at all implies none on the base tip line, so the run search above set workflow.
            tried.append(dispatch_hint(evidence, workflow, path))
            refusals.append(f"'{name}' at {short(sha)} ({head.url}): no {base} verdict to compare with: "
                            + " | ".join(tried))
        else:
            refusals.append(f"'{name}' at {short(sha)} ({head.url}) is not red the same way on {base}: "
                            + " | ".join(tried))
    by_id = {job["id"]: matches for job, _, _, matches in statuses}

    def grounded(job_id: int, seen: frozenset = frozenset()) -> bool:
        """Each job id it reports names a judged job, or a status job grounded the same way.
        Status jobs naming only each other (two legs of a job each ending in `x: failure`)
        are not: none of them was compared with the base."""
        return job_id not in seen and all(
            any(found["id"] not in by_id or grounded(found["id"], seen | {job_id}) for found in named)
            for named in by_id[job_id].values())

    for job, reported, under, _ in statuses:
        name = job.get("name", "")
        judged_under = [found for found in under if found["id"] not in by_id]
        if not judged_under or not grounded(job["id"]):
            refusals.append(f"'{name}' at {short(sha)} ({job_url(repo, job)}) reports {', '.join(reported)} red, "
                            "but every failed job of its run is a status job; nothing to compare with the base")
            continue
        audit.append(f"excused '{name}': it only reports {', '.join(reported)} red; its run's failed jobs "
                     f"({', '.join(sorted(found.get('name', '') for found in judged_under))}) are judged on their own")
    if refusals:
        notes = f" [{'; '.join(dict.fromkeys(evidence.notes))}]" if evidence.notes else ""
        raise Refused("\n".join(refusals) + notes)
    return audit


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", required=True)
    parser.add_argument("--base", required=True)
    parser.add_argument("--sha", required=True)
    parser.add_argument("--run", type=int, action="append", default=[], help="a failed workflow run on the head")
    parser.add_argument("--check", action="append", default=[], help="a red required check on the head")
    parser.add_argument("--pull", dest="pr", type=int,
                        help="the pull request, so a red naming only files it does not change is excused")
    args = parser.parse_args(argv)
    try:
        audit = judge(args.repo, args.base, args.sha, args.run, GitHub(), checks=args.check, pr=args.pr)
    except RateLimited as error:
        print(f"rate-limited: {error}", file=sys.stderr)
        return 3
    except (Refused, KeyError, ValueError) as error:
        print(f"not excused: {error}", file=sys.stderr)
        return 1
    print("\n".join(audit))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
