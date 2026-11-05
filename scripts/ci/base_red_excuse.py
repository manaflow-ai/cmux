#!/usr/bin/env python3
"""Excuse a red check that fails the same way on the base branch.

Run via scripts/gh-merge-green before it refuses a red cmux-next run or a red
required check. A failed job on the PR head is excused only when the same job
of the same workflow, on the latest completed run of the base branch that has
a verdict, also failed, and the head's failed steps and failing test names are
all among the base's. Error lines are compared only when no test failed (a
compile error, say), and warnings never are: they vary run to run (SwiftPM's
cache warnings refused #18147 on 2026-10-07). Names are compared, not counts:
the base may fail more. A runner refusal (no steps, a failed setup step, or the glaeda
hook's refusal), a cancelled or timed-out job, and a failure with no test or
error line to compare are never excused. A job whose runner was lost (test_reds.lost_runner: GitHub's "lost
communication with the server" annotation, a step left unfinished, no log stored) is refused as infra, not a
verdict: never the PR's own red, it needs a re-run like a cancelled job. One base red then no longer freezes
every pull request into that base (2026-10-07: four base reds, and the PRs
fixing them deadlocked on each other's reds).

A job that runs tests is judged per test by scripts/ci/test_reds.py, the one
classifier for "red on the base, so not ours" (2026-10-28: cmux#26346 landed
with its own test helper crash because the job was red on the base too). A
failing test the base's run does not fail is the head's; a crash (signal,
abort, EXC_*, Fatal error) is the head's whatever the base shows; and a run
whose per-test results are cut short (no summary, ended early, stuck) is the
head's, since nothing in it can be compared.

A failing test is the base's when it failed on any of the newest BASE_WINDOW base verdicts for its job, not only
the newest (2026-11-01). The newest verdict still decides whether the job is red on the base at all: when it is
not a failure, nothing older is read (fixed_on_base, below). When it is, a head failing test, failed step or error
line that the newest red run lacks is looked for in the older verdicts, newest first, at most BASE_WINDOW verdicts
within BASE_WINDOW_HOURS of the newest, and only back to the first green one: a green base run means every
test passed there, so an older red may predate a fix and never counts. A crash, a cut-short run, the
Chromium check, a process signal and the panic ratchet are judged against the newest alone, as before. Why: the
feat-cmux-next tip Swift suite fails 59 to 106 tests on every run and the set churns:
modelModeAndOptionPicksGoToThisChat() failed on run 41282022128, passed on 41298073172 and failed again on
41303556638, and 56 of the 115 tests that failed on the last six runs failed on only one of them. So a pull
request's test that is flaky on the base read as its own red whenever the newest run happened to pass it, and
reviewed PRs sat. The audit line names the run each such test failed on.

A compile check that gave no verdict (the build fleet's "no result", "No build-fleet verdict") is never a
base red, even with the base's identical line: nothing compiled the head. It is set aside only when the
same head has a real compile pass (a green Mac Release compile or a cmux-next/compile success). Error
lines are compared with commit shas masked, so a real red that names each run's own commit still matches.
"""
from __future__ import annotations

# This check is a deterministic version comparison. Blacksmith's Actions log
# exposes only the generic exit annotation, so there is no useful output line
# for the normal signature matcher to compare. Its failed step is the stable
# failure identity; compare that step on the base just like a test name.
CHROMIUM_CURRENCY_JOB = "Shipped Chromium is at most one stable milestone behind"
CHROMIUM_CURRENCY_STEP = "Pinned Chromium against Chrome stable"

import argparse
import base64
import importlib.util
import json
import re
import sys
from datetime import datetime, timedelta
from pathlib import Path

_spec = importlib.util.spec_from_file_location("main_fix_evidence", Path(__file__).with_name("main_fix_evidence.py"))
_evidence = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_evidence)
Refused, job_for, latest_checks = _evidence.Refused, _evidence.job_for, _evidence.latest_checks
# A read GitHub rate-limited, where the evidence reader tells it apart (main's main_fix_evidence.py): exit 3, which
# gh-merge-green reports as a rate limit rather than a red. A reader without it raises Refused (exit 1).
RateLimited = getattr(_evidence, "RateLimited", ())


class RateLimitedRead(Exception):
    """A read GitHub rate-limited, as judge() re-raises it so the comparison cannot swallow it.

    main's RateLimited is a Refused, and the comparison turns a Refused from a read into a refusal of its
    own ("no rollup red is excused", say) in a dozen places, so a rate limit read as a verdict on the red
    and main() returned 1 where gh-merge-green expects 3. This is not a Refused, so only main() catches it.
    """


def rate_limited_classes() -> tuple:
    """What main() reports as a rate limit, as one flat tuple. A reader without RateLimited leaves it the empty
    tuple, and `except ((), RateLimitedRead)` is a TypeError on every other refusal ("catching classes that do not
    inherit from BaseException"), which would break the ordinary exit-1 path. Read at call time, so a caller that
    loads a reader with RateLimited (main's) is honoured."""
    return ((RateLimited,) if isinstance(RateLimited, type) else tuple(RateLimited)) + (RateLimitedRead,)


def rate_limit_aware(github):
    """GITHUB with every rate-limited read raised as RateLimitedRead instead (above). Reads are
    looked up on each call, so a caller that replaces one (the tests' fakes) is still read."""
    class Aware:
        def __getattr__(self, name: str):
            attribute = getattr(github, name)
            if not callable(attribute):
                return attribute

            def read(*args, **kwargs):
                try:
                    return attribute(*args, **kwargs)
                except RateLimited as error:
                    raise RateLimitedRead(str(error)) from None

            return read

    return Aware()


ESCAPE_FLAG = "--allow-escape-sequences"
UNKNOWN_ESCAPE_FLAG = f"unknown flag: {ESCAPE_FLAG}"
REQUEST_FAILED = "GitHub evidence request failed: "


# Notes an agent host's gh wrappers write before the real gh's own stderr (a wait on a repeated read).
WRAPPER_NOTE_PREFIXES = ("glaeda-gh:", "gh-quota:")


def escape_flag_unknown(stderr: str) -> bool:
    """Whether an old gh rejected the optional ANSI-output flag itself: gh's first line, after any
    wrapper notes, is exactly the refusal. Another unknown flag first still refuses."""
    lines = [line.strip() for line in (stderr or "").strip().splitlines()]
    gh_lines = [line for line in lines if not line.startswith(WRAPPER_NOTE_PREFIXES)]
    return bool(gh_lines) and gh_lines[0] == UNKNOWN_ESCAPE_FLAG


class GitHub(_evidence.GitHub):
    """GitHub client for red attribution, including logs of finished jobs in live runs."""

    def log(self, repo: str, job: dict) -> str:
        # `gh run view --log` waits for every job in the run. The Actions job
        # endpoint serves a finished job while sibling jobs remain queued.
        route = f"repos/{repo}/actions/jobs/{job['id']}/logs"
        # Request ANSI-capable output first; old gh versions reject the flag, while modern
        # versions reject coloured output without it. Either way, normalize bytes in Python.
        try:
            return self.run(["api", ESCAPE_FLAG, route])
        except Refused as error:
            said = str(error)
            if not (said.startswith(REQUEST_FAILED) and escape_flag_unknown(said[len(REQUEST_FAILED):])):
                raise
        return self.run(["api", route])

    def json(self, route: str, *, paginate: bool = False, per_page: int = 100):
        # A run's job list carries every job's steps; see JOBS_PAGE.
        if paginate and "/jobs?" in route:
            per_page = min(per_page, JOBS_PAGE)
        return super().json(route, paginate=paginate, per_page=per_page)
_spec = importlib.util.spec_from_file_location("test_reds", Path(__file__).with_name("test_reds.py"))
test_reds = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(test_reds)

SETUP_STEPS = frozenset({"Set up job", "Set up runner"})
# Rollups: jobs that only report other jobs' results, judged by those jobs, never by themselves. Only which
# jobs are rollups is named here (workflow file, job id); the rest is derived from the workflows into
# ROLLUPS_FILE by `base_red_excuse.py --write-rollups` (derive_rollups): each rollup's check name (its
# `name:`), the jobs under it (its `needs:`, followed through their own `needs:`), and for a routed rollup
# (ci-guards.yml's Guard status) the route input each needed job runs on (its `if:`). The file is read with
# no YAML parser, so every host that runs this script reads the same contract; tests/test_base_red_excuse.py
# fails when it differs from the workflows. Anything in a workflow or in the file that does not have the
# expected shape is refused, never guessed at: a rollup red is then never excused.
RUN_ROLLUPS = (("ci.yml", "ci-status"),)  # red when a job under it is red: the whole run's red jobs are judged
ROUTED_ROLLUPS = (("ci-guards.yml", "guard-status"),)  # also reports each needed job's route (validate_guard_routes)
# Jobs a routed rollup needs only to place its runner (their outputs pick its runs-on): no guard verdict of their
# own, so the contract leaves them out of its routes (ci-guards.yml portable-placement, #34849).
ROLLUP_PLACEMENT_JOBS = frozenset({"portable-placement"})
ROLLUPS_FILE = Path(__file__).with_name("base_red_rollups.json")
WORKFLOWS = Path(__file__).resolve().parents[2] / ".github" / "workflows"
# The repo whose workflows sit beside this script: its contract is ROLLUPS_FILE.
HOME_REPO = "manaflow-ai/cmux"
# Rollups of the other repos this script judges (--repo), named the same way: (workflow file, job id). Their workflows
# are not in this checkout, so the contract is derived when a red is judged, from the repo's own workflow files at the
# base (derive_rollups over the contents API, load_rollups). A repo not named here has no rollups: every red job of it
# is judged as itself. cmuxterm-hq's Skill documentation tests only reports its shards (skills-tests.yml), and was
# refused on every HQ PR as "no failing test or error line to match" (2026-11-04: hq#7038, hq#7039).
OTHER_REPO_ROLLUPS = {
    "manaflow-ai/cmuxterm-hq": {"run": (("skills-tests.yml", "tests"),), "routed": ()},
}
ROUTE_IF = re.compile(r"\$\{\{ *inputs\.(\w+) *== *'true' *\}\}")
# A route report the Guard status prints: always read, even for a job the contract does not name (refused as unknown).
ROUTE_REPORT = r"workflow-guard-[\w-]+|linux_guard_\w+"
HOOK_REFUSAL = "glaeda-cmux-runner-hook: refused"
VERDICTS = frozenset({"success", "failure"})
# How far back the base lookup reads. A feat-cmux-next push skips swift-test, so its base verdict comes
# from the tip Swift suite (main's cmux-next-tip-swift-suite-dispatch.yml, about one run an hour), and
# DEV daily dispatches land between those runs every few minutes: on 2026-10-28, 16 of the base's 20
# newest completed runs were DEV daily runs, and the tip suite run fell out of a 20-run window, so
# no Swift red on any PR could be compared. One page of 100 runs reaches back hours; job listings
# are read newest first, at most BASE_JOB_READS per workflow, so a long run of runs with no verdict
# for the job stays bounded.
BASE_RUNS_PAGE = 100
BASE_JOB_READS = 40
# A run's job list carries every job's steps. GitHub answered the 34-job web run 41098664586's list with
# HTTP 502 at 100 and 50 per page, every time, and at 30 it answered (2026-10-30).
JOBS_PAGE = 30
# A job no feat-cmux-next push runs gets its base verdict from a dispatch: main's tip suite dispatcher
# (cmux-next-tip-swift-suite-dispatch.yml), cmux-next-base-tier-kick.yml (the base Mac tier, at most
# once every 15 minutes on the tip, cmuxterm-hq#5424), each a run named `<title><tested sha>`, or a hand
# dispatch. Base pushes land every minute or two, so the window above can miss them (2026-10-30: no
# daemon-test verdict on the base for hours, #27692). When it does, the base's newest completed dispatches
# are read too, newest first, and the first with a verdict for the job decides, a green one included: an
# older red never stands over a newer green. A suite that never runs the job (DEV daily runs, the other
# suites) is skipped unread, here and in the window above. At most TIP_SUITE_JOB_READS job lists; none of
# them with a verdict refuses as before.
SUITES = {
    "cmux-next tip Swift suite · ": frozenset({"cmux-next swift test"}),
    "cmux-next tip daemon suite · ": frozenset({"cmux-next daemon tests"}),
    # cmux-next.yml base_tier: path routing's base_tier branch routes these, and nothing else. Its generated
    # files are checked on the generated-files job itself (path routing's generated_host), never folded.
    "cmux-next base tier · ": frozenset({
        "cmux-next daemon tests", "cmux-next generated files", "cmux app scheme compile (Debug)",
        "cmux-next crash ends the app",
    }),
    # cmux-next.yml dispatches that route neither swift-test nor daemon-test (path routing's dev_daily branch).
    "cmux NEXT DEV daily": frozenset(),
}
# The base-red window (2026-11-01): how many of the newest base verdicts for a job a head's failing test may have
# failed on. Only the newest decides whether the job is red on the base at all; the window only widens which
# failing tests count as the base's (see the module docstring). The tip Swift suite runs about every 1.5 to 2 hours
# and one page of BASE_RUNS_PAGE dispatches reaches back about 11 hours (DEV daily runs land about 9 an hour), so 5
# verdicts (about 8 to 10 hours of the suite) fit in that page with TIP_SUITE_JOB_READS to spare for a lost run.
# Older verdicts are read only when the newer ones leave a head test unexcused, one log each, and never one more
# than BASE_WINDOW_HOURS older than the newest.
BASE_WINDOW = 5
BASE_WINDOW_HOURS = 24
TIP_SUITE_JOB_READS = BASE_WINDOW + 2
# The jobs of the cmux-tui tree tiers (cmux_next_tree_notify.TIERS: daemon, scheme). A tip daemon suite or base tier
# dispatch whose tree has not published yet skips them and leaves them to the same-tree run its publish dispatches,
# which carries the same `<title><tested sha>` name. So a suite run with a newer run of the same name (queued,
# running or done) is that first run: it is skipped unread for these jobs and never spends a job-list read. On
# 2026-10-31 the base tier's six newest completed dispatches were all such first runs, and the tip daemon suite
# run with the verdict, behind them, was never read: no pull request's daemon-test red could be compared.
TREE_JOBS = frozenset({"cmux-next daemon tests", "cmux app scheme compile (Debug)", "cmux-next crash ends the app"})


def deferred_first_runs(runs: list[dict]) -> set[int]:
    """The ids of suite runs in RUNS (newest first) that have a newer run of the same name: first runs whose
    tree jobs went to that later same-tree run."""
    seen: set[str] = set()
    deferred: set[int] = set()
    for run in runs:
        title = run.get("display_title") or ""
        if not suite_jobs(run):
            continue
        if title in seen:
            deferred.add(run["id"])
        seen.add(title)
    return deferred


def suite_jobs(run: dict) -> frozenset[str] | None:
    """The jobs a base run's suite can carry, or None for a run of no known suite (a push, a hand dispatch)."""
    title = run.get("display_title") or ""
    return next((jobs for prefix, jobs in SUITES.items() if title.startswith(prefix)), None)


# The jobs some suite above is the base verdict for. Only these are ever skipped: every other job (checks,
# web bundles, the placement jobs) may run in any suite, so a suite run's verdict for it always counts.
SUITE_JOBS = frozenset().union(*SUITES.values())


# A cancelled base tier run is one the base tier kick found superseded before any of its Mac jobs started
# (cmux_next_base_tier.py cancel_superseded): it has no verdict, and read here it would only spend the
# lookup limits that reach the run that has one.
BASE_TIER_TITLE = "cmux-next base tier · "


def never_carries(run: dict, name: str) -> bool:
    """Whether RUN's suite never runs job NAME, so it has no verdict for it to read."""
    if run.get("conclusion") == "cancelled" and (run.get("display_title") or "").startswith(BASE_TIER_TITLE):
        return True
    jobs = suite_jobs(run)
    return name in SUITE_JOBS and jobs is not None and name not in jobs


def tested_sha(run: dict) -> str:
    """The commit a cmux-next.yml run tested: the sha its name ends in (a same-tree run tests it after the
    branch moved on), else its head_sha."""
    match = re.search(r" · ([0-9a-f]{40})$", run.get("display_title") or "")
    return match.group(1) if match else str(run.get("head_sha") or "")


ANSI = re.compile(r"\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1b\\))")
ERROR = re.compile(r"##\[error\]|\berror:")
WARNING = re.compile(r"##\[warning\]|\bwarning:")
# Release-notary helpers report successful validations as `ok: ... (error: ...)`.
# The parenthesized diagnostic is expected output, not a failed check; only
# error annotations outside a successful `ok:` wrapper are evidence.
SUCCESS_DIAGNOSTIC = re.compile(r"^\s*ok:\s+.*\berror:", re.IGNORECASE)
# Summaries carry counts, and a test's own lines already name it.
GENERIC = re.compile(r"Process completed with exit code|red tests?:|✘ Test |Test Case '|\.\.\. FAILED$")
SUMMARY_FAILURE = re.compile(
    r"(?i)\b(?:changed|stale|missing|mismatch|not stamped|not found|out of date|invalid|unavailable|"
    r"cannot|could not|failure|failed|fail|does not match|not match)\b"
)
STAMP = re.compile(r"^\d{4}-\d\d-\d\dT[\d:.]+Z ?")
# SwiftPM's line for a killed test helper, and the hang sampler's ::error lines for it.
CRASH = re.compile(r"exited with unexpected signal code (\d+)|the test helper died on signal (\d+)")
CRASH_LINE = re.compile(r"exited with unexpected signal code|the test helper died on signal|"
                        r"no \"Test run with\" summary line")
# A commit sha inside an error line: a full 40-hex sha, or 7 to 39 hex digits right after a word that
# names a commit (commit, sha, tree, revision). The same red on the head and the base names each run's
# own commit; any other hex id (an artifact, a hash) is compared as it is. A full 40-hex id right after
# a word that names a stored thing rather than a commit (ARTIFACT) is such an id: two different digests
# stayed one error line while every bare 40-hex token was masked, so a real red could pass as a base red
# (cmux#35902, from the review of #35893). A commit the line does not name as an artifact still masks,
# whatever word introduces it: a base red often names each run's own tree or stamp with no keyword at
# all ("source stamp <40-hex> != <40-hex>"), which is why the bare case cannot ask for one.
ARTIFACT = r"(?i:artifacts?|artefacts?|assets?|digests?|checksums?|hashe?s?|packs?|bundles?|archives?|images?|layers?)"
# What may stand between such a word and its id: spaces, one `:` or `=`, and an opening quote or bracket
# (`artifact: <40-hex>`, `checksum=<40-hex>`, `digest (<40-hex>)`), which the literal space alone missed
# (cmux#35941 F1); or an opening quote or bracket on its own, with no space or `:` before it
# (`artifact(<40-hex>)`, `pack"<40-hex>"`, `bundle[<40-hex>]`), which still fell to the bare branch
# (cmux#35941 F3). A separator of some kind is always required, so a bare 40-hex still masks.
NAMED = r"(?:(?:[ \t]+|[ \t]*[:=][ \t]*)[(\[`'\"]?|[(\[`'\"])"
SHA = re.compile(rf"(?P<artifact>\b{ARTIFACT}{NAMED}[0-9a-f]{{40}}\b)"
                 r"|\b[0-9a-f]{40}\b"
                 r"|\b(?P<commit>(?:commit|sha|tree|revision) `?)[0-9a-f]{7,39}\b")
# A compile check that gave no verdict (the build-fleet controller unreachable, timed out, or a result
# for another head): nothing compiled the head, so it is never a base red, whatever the base shows
# (2026-10-28: the fleet Release compile's "no result" was red on PRs and on the base alike while the
# controller was wedged). It is set aside only when another job compiled that same head: COMPILE_PASSES.
# Only the job's own ::error annotation counts (`##[error]` at the start of the line): the log also
# echoes the step's script, which spells these words out on every run, a real compile red included.
# Fail closed: of compile-status's own lines, only "(fail)" is a real compile red; every other state (no result,
# unavailable, mismatch, unreadable, pending, "last: ...", a pass it could not post) and a status it could not
# post at all are no verdict.
NO_VERDICT = re.compile(r"^##\[error\]\s*(?:cmux-next/compile is not a pass for \S+ \((?!fail\))|"
                        r"could not post the pending status|bad head sha |No build-fleet verdict for `)")
# The jobs that can end without a verdict: an unreadable log of one is never comparable either.
NO_VERDICT_JOBS = frozenset({"cmux-next fleet Release compile", "cmux-next app compile (build fleet)"})
# The shared generated-files check only reads the verdict produced by the Swift or daemon job that built
# the package.  A failed prerequisite (especially a cancelled-before-start runner job) leaves that value
# empty, so this check has no result of its own.  It must be rerun together with its host job; comparing its
# fail-closed diagnostic with the base would turn missing evidence into an apparent PR red.
GENERATED_VERDICT_JOB = "cmux-next generated files (shared build)"
GENERATED_NO_VERDICT = re.compile(
    r"^##\[error\]\s*(?:swift-test|daemon-test) \(cancelled\) gave no generated files verdict:"
)
# A real compile pass at the head: the Mac Release compile (a check run), or the fleet's cmux-next/compile
# commit status.
COMPILE_PASS_CHECKS = ("cmux-next Release compile (Xcode 26)",)
COMPILE_PASS_STATUS = "cmux-next/compile"
# The Mac Release compile's steps that compile (or reuse a pass for the same inputs).
COMPILE_STEPS = frozenset({"Release compile", "Reuse that pass"})


def _check_matcher(job_id: str, job: dict, where: str) -> dict:
    """How the Actions jobs of JOB (id JOB_ID in a workflow) are named: {"exact": [...], "prefixes": [...]}. A job
    with no `name:` is named by its id; a called workflow's jobs are '<name> / <its job>'; a matrix job whose
    name holds no expression gets ' (<values>)' after it; a name may hold an expression only as a last
    ' / ${{ ... }}' segment. Any other shape is refused."""
    name = job.get("name", job_id)
    if not isinstance(name, str) or not name.strip() or name != name.strip():
        raise Refused(f"{where}: job {job_id} has no usable name")
    if "${{" in name:
        static, sep, expr = name.partition(" / ${{")
        if not sep or "${{" in static or not expr.endswith("}}") or "${{" in expr or "uses" in job:
            raise Refused(f"{where}: job {job_id}'s name {name!r} is not a fixed name with one last ' / ${{{{ }}}}' part")
        return {"exact": [], "prefixes": [static + " / "]}
    if "uses" in job:
        if (job.get("strategy") or {}).get("matrix"):
            raise Refused(f"{where}: job {job_id} calls a workflow over a matrix")
        return {"exact": [], "prefixes": [name + " / "]}
    if (job.get("strategy") or {}).get("matrix"):
        return {"exact": [name], "prefixes": [name + " ("]}
    return {"exact": [name], "prefixes": []}


def _needs(jobs: dict, job_id: str, where: str) -> list[str]:
    needs = jobs[job_id].get("needs", [])
    needs = [needs] if isinstance(needs, str) else needs
    if not isinstance(needs, list) or not all(isinstance(n, str) and isinstance(jobs.get(n), dict) for n in needs):
        raise Refused(f"{where}: job {job_id}'s needs {needs!r} are not jobs of its workflow")
    return needs


def derive_rollups(workflows: Path = WORKFLOWS, *, run=RUN_ROLLUPS, routed=ROUTED_ROLLUPS, read=None) -> dict:
    """The rollups contract (ROLLUPS_FILE) derived from the workflow files; refuses any shape it does not know.
    RUN and ROUTED name the rollups (another repo's, OTHER_REPO_ROLLUPS); READ(file) gives a workflow's text when it
    is not under WORKFLOWS (another repo's, at its base)."""
    try:
        import yaml  # noqa: PLC0415 - only deriving reads YAML; judging this repo reads ROLLUPS_FILE
    except ImportError:
        raise Refused("no YAML parser to read the workflows' rollups; no rollup red is excused") from None

    if read is None:
        def read(file: str) -> str:
            return (workflows / file).read_text()
    out: dict = {"run": {}, "routed": {}}
    for kind, declared in (("run", run), ("routed", routed)):
        for file, job_id in declared:
            where = f".github/workflows/{file}"
            try:
                doc = yaml.safe_load(read(file))
            except (OSError, Refused, yaml.YAMLError) as error:
                raise Refused(f"{where}: unreadable ({error})") from None
            jobs = doc.get("jobs") if isinstance(doc, dict) else None
            if not isinstance(jobs, dict) or not isinstance(jobs.get(job_id), dict):
                raise Refused(f"{where}: no job {job_id}")
            check = _check_matcher(job_id, jobs[job_id], where)
            if check["prefixes"] or len(check["exact"]) != 1:
                raise Refused(f"{where}: rollup {job_id} has no fixed name")
            name = check["exact"][0]
            if name in out["run"] or name in out["routed"]:
                raise Refused(f"{where}: two rollups are named {name!r}")
            needs = _needs(jobs, job_id, where)
            if not needs:
                raise Refused(f"{where}: rollup {job_id} needs no job")
            if kind == "run":
                under, todo = {}, list(needs)
                while todo:
                    need = todo.pop()
                    if need not in under:
                        under[need] = _check_matcher(need, jobs[need], where)
                        todo.extend(_needs(jobs, need, where))
                out["run"][name] = {"workflow": file, "job": job_id, "under": dict(sorted(under.items()))}
                continue
            triggers = doc.get(True, doc.get("on"))
            inputs = (triggers.get("workflow_call") or {}).get("inputs") if isinstance(triggers, dict) else None
            if not isinstance(triggers, dict) or set(triggers) != {"workflow_call"} or not isinstance(inputs, dict):
                raise Refused(f"{where}: a routed rollup's workflow must be called only, with inputs")
            routes = {}
            for need in needs:
                if need in ROLLUP_PLACEMENT_JOBS:
                    continue
                condition = jobs[need].get("if")
                route = None
                if condition is not None:
                    match = ROUTE_IF.fullmatch(condition.strip()) if isinstance(condition, str) else None
                    if match is None or match.group(1) not in inputs:
                        raise Refused(f"{where}: job {need}'s if {condition!r} is not one route input == 'true'")
                    route = match.group(1)
                routes[need] = {"route": route, **_check_matcher(need, jobs[need], where)}
            out["routed"][name] = {"workflow": file, "job": job_id, "routes": routes}
    return out


def _matcher_ok(matcher: object) -> bool:
    return (isinstance(matcher, dict) and set(matcher) >= {"exact", "prefixes"}
            and all(isinstance(matcher[k], list) and all(isinstance(v, str) and v for v in matcher[k])
                    for k in ("exact", "prefixes")))


_ROLLUPS: dict | None = None
# Other repos' contracts, derived by load_rollups: {repo: contract}.
_REPO_ROLLUPS: dict[str, dict] = {}
NO_ROLLUPS = {"run": {}, "routed": {}}


def load_rollups(repo: str, base: str, github) -> None:
    """Derive REPO's rollups contract from its own workflow files at BASE, once. HOME_REPO's is ROLLUPS_FILE."""
    if repo == HOME_REPO or repo in _REPO_ROLLUPS or repo not in OTHER_REPO_ROLLUPS:
        return
    declared = OTHER_REPO_ROLLUPS[repo]

    def read(file: str) -> str:
        found = github.json(f"repos/{repo}/contents/.github/workflows/{file}?ref={base}")
        if not isinstance(found, dict) or found.get("encoding") != "base64" or not isinstance(found.get("content"), str):
            raise Refused(f"{repo}@{base}: .github/workflows/{file} is not a file the contents API served in full")
        try:
            return base64.b64decode(found["content"]).decode()
        except (ValueError, UnicodeDecodeError) as error:
            raise Refused(f"{repo}@{base}: .github/workflows/{file}: {error}") from None

    try:
        _REPO_ROLLUPS[repo] = derive_rollups(run=declared["run"], routed=declared["routed"], read=read)
    except Refused as error:
        raise Refused(f"{repo} rollups at {base}: {error}; no rollup red is excused") from None


def rollups(repo: str = HOME_REPO) -> dict:
    """REPO's rollups contract. HOME_REPO's is ROLLUPS_FILE, checked for shape; refused (so no rollup red is
    excused) when missing or malformed. Another repo's is the one load_rollups derived (refused when it has not), and a
    repo with no rollups named in OTHER_REPO_ROLLUPS has none."""
    if repo != HOME_REPO:
        if repo not in OTHER_REPO_ROLLUPS:
            return NO_ROLLUPS
        if repo not in _REPO_ROLLUPS:
            raise Refused(f"{repo}: its rollups were not read from its workflows; no rollup red is excused")
        return _REPO_ROLLUPS[repo]
    global _ROLLUPS
    if _ROLLUPS is None:
        try:
            data = json.loads(ROLLUPS_FILE.read_text())
        except (OSError, ValueError) as error:
            raise Refused(f"{ROLLUPS_FILE.name}: unreadable ({error}); no rollup red is excused") from None
        run, routed = (data.get("run"), data.get("routed")) if isinstance(data, dict) else (None, None)
        ok = (isinstance(run, dict) and isinstance(routed, dict) and run and routed
              and all(isinstance(r, dict) and isinstance(r.get("under"), dict) and r["under"]
                      and all(_matcher_ok(m) for m in r["under"].values()) for r in run.values())
              and all(isinstance(r, dict) and isinstance(r.get("routes"), dict) and r["routes"]
                      and all(_matcher_ok(m) and (m.get("route") is None or isinstance(m.get("route"), str))
                              for m in r["routes"].values()) for r in routed.values()))
        if not ok:
            raise Refused(f"{ROLLUPS_FILE.name}: not a rollups contract; no rollup red is excused")
        _ROLLUPS = data
    return _ROLLUPS


def matches(matcher: dict, name: str, prefix: str = "") -> bool:
    """Whether Actions job NAME is one of the jobs MATCHER names, under a caller's PREFIX ('guards / ')."""
    return (any(name == prefix + exact for exact in matcher["exact"])
            or any(name.startswith(prefix + start) for start in matcher["prefixes"]))


def routed_rollup(name: str, repo: str = HOME_REPO) -> tuple[dict, str] | None:
    """(the routed rollup check NAME is, the caller prefix it runs under), or None. A routed rollup's workflow is
    only ever called, so its check is '<caller> / <name>' (a bare name is still one, with no prefix)."""
    for rollup, contract in rollups(repo)["routed"].items():
        if name == rollup or name.endswith(" / " + rollup):
            return contract, name[:-len(rollup)]
    return None


def is_aggregate(name: str, repo: str = HOME_REPO) -> bool:
    """Whether a check of REPO reports other jobs rather than running work itself."""
    return name in rollups(repo)["run"] or routed_rollup(name, repo) is not None


def _sub_shas(text: str, keep: list | None = None) -> str:
    """TEXT with its commit shas masked (SHA). With KEEP, each id the pattern preserves is set aside there and
    left as a marker of letters alone, so a later pass over TEXT's numbers cannot touch its digits."""
    def masked(match: re.Match[str]) -> str:
        if (named := match.group("artifact")) is not None:
            if keep is None:
                return named
            keep.append(named)
            return _marker(len(keep) - 1)
        return (match.group("commit") or "") + "<sha>"

    return SHA.sub(masked, text)


def _marker(index: int) -> str:
    """A placeholder for the id at INDEX of a keep list: letters between two NULs, so no number masking,
    and nothing test_reds.volatile rewrites, is in it."""
    letters = ""
    index += 1
    while index:
        index, rest = divmod(index - 1, 26)
        letters = chr(ord("a") + rest) + letters
    return f"\0{letters}\0"


def mask_shas(text: str) -> str:
    """TEXT with its commit shas masked, leaving every other hex id as it is (SHA)."""
    return _sub_shas(text)


def normalise_error(text: str) -> str:
    """An error line as compared with the base's: the annotation prefix dropped, commit shas, run-to-run tokens
    (test_reds.volatile: run-named temp dirs, the runner's checkout root, times) and then
    every number masked, so the same red on two runs is one line and a different red is not. An id mask_shas
    preserves keeps its digits: they are the whole of what tells two digests apart (cmux#35941 F2)."""
    kept: list = []
    said = _sub_shas(text.replace("##[error]", "").strip(), keep=kept)
    said = re.sub(r"\d+", "#", test_reds.volatile(said))
    for index, id_ in enumerate(kept):
        said = said.replace(_marker(index), id_)
    return said


def lines_of(log: str) -> list[str]:
    """The text of each `job<TAB>step<TAB>stamp text` line of `gh run view --log`."""
    found = []
    for line in log.splitlines():
        parts = line.split("\t", 2)
        # `gh run view --log` prefixes each line with job and step columns.
        # The job-log API does not; preserve tabs in raw command output.
        text = parts[2] if len(parts) == 3 and STAMP.match(parts[2]) else line
        found.append(ANSI.sub("", STAMP.sub("", text)).strip())
    return found


def signature(job: dict, log: str) -> tuple[set[str], set[str], set[str]]:
    """(failed step names, failing test names, error lines with numbers masked), from what the steps printed: the
    runner's echo of each step's script is never a test or an error (test_reds.echoed; 2026-10-30, cmux#28145 was
    excused because the base's log echoed the same `echo "::error::..."` lines of its step's script)."""
    steps = {step["name"] for step in job.get("steps") or []
             if step.get("conclusion") not in (None, "success", "skipped")}
    tests = test_reds.failed_names(test_reds.lines_of(log))
    errors: set[str] = set()
    skip = test_reds.echoed(test_reds.log_lines(log))
    for n, text in enumerate(lines_of(log)):
        if n in skip or text.startswith(test_reds.TAP_MARKER):
            continue
        if ((ERROR.search(text)
             or (not tests and ("default" in job.get("name", "").lower()
                                or "snapshot" in job.get("name", "").lower())
                 and SUMMARY_FAILURE.search(text)))
                and not GENERIC.search(text) and not WARNING.search(text) and not CRASH_LINE.search(text)
                and not SUCCESS_DIAGNOSTIC.search(text)):
            errors.add(normalise_error(text))
    return steps, tests, errors


def no_verdict(log: str) -> str | None:
    """The line where a compile check says it gave no verdict, if it does."""
    return next((text for text in lines_of(log) if NO_VERDICT.match(text)), None)


def generated_no_verdict(log: str) -> str | None:
    """The shared generated-files check's fail-closed prerequisite diagnostic, if it printed one.

    ``test_reds.lines_of`` removes the runner's echoed shell script, which also contains the ``echo
    ::error::`` branch.  Only the live annotation is evidence that the prerequisite produced no verdict.
    """
    return next((text for text in test_reds.lines_of(log) if GENERATED_NO_VERDICT.match(text)), None)


def compile_pass_at(repo: str, sha: str, github) -> str | None:
    """What compiled SHA itself and passed: the newest Mac Release compile job at SHA that ran (its
    `Release compile` or `Reuse that pass` step succeeded), or a cmux-next/compile success."""
    candidates = []
    # Every attempt (filter=all): one rerun into startup_failure ran no jobs and must not hide the pass before it.
    for page in github.json(f"repos/{repo}/commits/{sha}/check-runs?filter=all&per_page=100", paginate=True):
        for check in page.get("check_runs") or []:
            if (check.get("name") in COMPILE_PASS_CHECKS and check.get("head_sha") == sha
                    and check.get("app", {}).get("slug") == "github-actions" and check.get("status") == "completed"
                    and check.get("conclusion") != "skipped"):
                candidates.append(check)
    # Newest first; the same name is also release-compile-fast-admission's (a Linux wrapper that compiles
    # nothing), so only a job with the Mac compile's own steps counts, and the newest such attempt decides.
    for check in sorted(candidates, key=lambda found: found.get("id", -1), reverse=True):
        # The check run's own Actions job, from its details link (a check run id is not a job id).
        link = re.fullmatch(r"https://github\.com/" + re.escape(repo) + r"/actions/runs/(\d+)/job/(\d+)",
                            check.get("details_url") or "")
        if not link:
            continue
        job = github.json(f"repos/{repo}/actions/jobs/{link[2]}")
        if (job.get("head_sha") != sha or job.get("name") != check.get("name")
                or job.get("run_id") != int(link[1])):
            continue
        steps = {step.get("name"): step.get("conclusion") for step in job.get("steps") or []}
        if not COMPILE_STEPS & steps.keys():
            continue
        if job.get("conclusion") == "success" and any(steps.get(name) == "success" for name in COMPILE_STEPS):
            return f"'{check['name']}' (job {link[2]})"
        break
    status = github.json(f"repos/{repo}/commits/{sha}/status")
    for found in status.get("statuses") or []:
        if found.get("context") == COMPILE_PASS_STATUS:
            # The combined status lists the newest per context.
            if found.get("state") == "success":
                return f"the {COMPILE_PASS_STATUS} status"
            break
    return None


# The Rust panic ratchet (scripts/cmux-next/rust_panic_ratchet.py, run by .github/scripts/cmux-tui-clippy-changed.py).
# Its error line names the packages the run checked, and a base run may check the whole workspace while a PR checks
# only its changed packages, so that line never matches (2026-10-31: cmux#26849's run 41176610742 failed on two rows
# that base run 41176544319 failed on word for word, and was refused). Its red is judged by the rows of its RED
# block instead (ratchet_red): each head row `CRATE: clippy::LINT N > WHERE` must be on the base with the same
# crate, lint and WHERE (`baseline M` or `new crate (must be 0)`) and a count at least the head's; every other
# line of the block but a hit location must be on the base word for word. A red with no row is never excused.
RATCHET_SCOPE = re.compile(r"^the panic ratchet is red for .+; its log above names each new hit")
RATCHET_RED, RATCHET_END = "rust-panic-ratchet: RED", "Fix the hit "
RATCHET_ROW = re.compile(r"^(\S+): clippy::(\w+) (\d+) > (baseline \d+|new crate \(must be 0\))$")
RATCHET_HIT = re.compile(r"^[^\s:]+\.rs:\d+:\d+$")


def ratchet_red(log: str) -> tuple[dict[tuple[str, str, str], int], set[str]]:
    """({(crate, lint, where): count} of the ratchet's RED rows, its other RED lines), hit locations left out."""
    rows: dict[tuple[str, str, str], int] = {}
    other: set[str] = set()
    skip = test_reds.echoed(test_reds.log_lines(log))
    inside = False
    for n, text in enumerate(lines_of(log)):
        if n in skip:
            continue
        if text == RATCHET_RED:
            inside = True
        elif inside and (text.startswith(RATCHET_END) or text.startswith("##[")):
            inside = False
        elif inside and text:
            if row := RATCHET_ROW.match(text):
                crate, lint, count, where = row.groups()
                key = (crate, lint, where)
                rows[key] = max(rows.get(key, 0), int(count))
            elif not RATCHET_HIT.match(text):
                other.add(text)
    return rows, other


def ratchet_unmatched(head_log: str, base_log: str) -> list[str]:
    """The head's panic ratchet failures its base run does not have (empty when every one is covered)."""
    head_rows, head_other = ratchet_red(head_log)
    if not head_rows:
        raise Refused("the panic ratchet is red with no per-lint row to compare with the base "
                      "(a clippy run that did not finish, say)")
    base_rows, base_other = ratchet_red(base_log)
    missing = [f"{crate}: clippy::{lint} {count} > {where}" + (
                   f" (the base has {base_rows[(crate, lint, where)]})" if (crate, lint, where) in base_rows else "")
               for (crate, lint, where), count in sorted(head_rows.items())
               if base_rows.get((crate, lint, where), -1) < count]
    return missing + sorted(head_other - base_other)


def crash_signals(log: str) -> set[str]:
    """The signals a test helper died on, from SwiftPM's or the hang sampler's lines."""
    return {first or second for first, second in CRASH.findall(log)}


def refused_at_setup(job: dict, log: str | None = None) -> bool:
    steps = job.get("steps") or []
    if not steps or any(step.get("name") in SETUP_STEPS and step.get("conclusion") == "failure" for step in steps):
        return True
    return log is not None and HOOK_REFUSAL in log


def validate_guard_routes(repo: str, sha: str, guard: dict, children: list[dict], github) -> None:
    """A Guard status red must report only failed routes backed by concrete children.

    The wrapper also validates routing inputs and required-but-skipped jobs.
    Those failures cannot be waived by an unrelated child that is red on base.
    Children returned by head_jobs are still compared with base by judge.
    """
    name = guard["name"]
    found = routed_rollup(name, repo)
    if found is None:
        raise Refused(f"'{name}': not a routed rollup of {ROLLUPS_FILE.name}")
    contract, prefix = found
    routed = contract["routes"]
    if guard.get("head_sha") not in (None, sha):
        raise Refused(f"'{name}': job is not for the exact SHA {sha}")
    if guard.get("status") != "completed" or guard.get("conclusion") != "failure":
        raise Refused(f"'{name}': no completed failure verdict for its routes")
    text = github.log(repo, guard)
    if refused_at_setup(guard, text):
        raise Refused(f"'{name}' was refused at setup by its runner")
    steps, _, errors = signature(guard, text)
    if steps != {"Check routed guard jobs"}:
        raise Refused(f"'{name}': non-routing failed steps: {'; '.join(sorted(steps))}")
    if errors:
        raise Refused(f"'{name}': routing error: {'; '.join(sorted(errors))[:600]}")
    report = test_reds.read(text)
    if report.crashes or report.truncated:
        raise Refused(f"'{name}': routing process crashed or ended early")
    routes = []
    lines = lines_of(text)
    inputs = {route["route"] for route in routed.values() if route["route"]}
    report = rf"({ROUTE_REPORT}|{'|'.join(re.escape(key) for key in sorted(set(routed) | inputs))}): (.+)"
    # The runner's preamble (token permissions, and a called workflow's echoed `Inputs`, whose `linux_guard_tests: true`
    # reads like a route report) ends at its `Complete job name:` line; no step prints before it.
    started = next((at for at, line in enumerate(lines) if line.startswith("Complete job name: ")), None)
    for line in lines if started is None else lines[started + 1:]:
        match = re.fullmatch(report, line)
        if not match:
            continue
        route, result = match.groups()
        result_match = re.fullmatch(r"failure(?: \(route ([\w]+)=(true|false)\))?", result)
        if not result_match:
            raise Refused(f"'{name}': {route}: {result}")
        reported_route, enabled = result_match.groups()
        if route not in routed:
            raise Refused(f"'{name}': unknown routed job {route}")
        expected_route = routed[route]["route"]
        if reported_route is not None and (reported_route != expected_route or enabled != "true"):
            raise Refused(f"'{name}': route {reported_route} does not map to {route} (expected {expected_route}=true)")
        if reported_route is None and expected_route is not None:
            raise Refused(f"'{name}': {route} has no route mapping in its failure report")
        if not any(child.get("conclusion") == "failure" and matches(routed[route], child.get("name", ""), prefix)
                   for child in children):
            raise Refused(f"'{name}': no failed child for routed failure {route}")
        routes.append(route)
    if not routes:
        raise Refused(f"'{name}': no routed failure report to compare with its children")


def validate_run_rollup(name: str, children: list[dict], repo: str = HOME_REPO) -> None:
    """Run rollup NAME (ci-status), red, needs a failed job under it (its needs, ROLLUPS_FILE): a red run whose only
    failed jobs are outside them did not turn it red, so its own verdict did, and nothing here can compare that."""
    under = rollups(repo)["run"][name]["under"]
    if not any(child.get("conclusion") == "failure" and any(matches(m, child.get("name", "")) for m in under.values())
               for child in children):
        raise Refused(f"'{name}': no failed job under its needs ({', '.join(sorted(under))}) to compare with the base")


# A status-only check (2026-11-02, cmux#30294): a same-tree run reports its verdict as a commit status on the
# head it tested ('cmux-next daemon tests (same-tree)', cmux-next.yml's "Report the same-tree result on the tested
# commit"), so the head has no check run of that name and every such red was refused as "has not run on exact
# head", even when the base failed the same tests. The status is judged by the job that gave it: the job of the
# same name without the " (same-tree)" suffix, in the run its target_url links (else the newest run that tested
# the head and has that job). It is then compared per test like any job; a run that cannot be found is refused.
SAME_TREE_SUFFIX = " (same-tree)"


def status_job(repo: str, sha: str, name: str, github, base: str | None = None) -> dict | str | None:
    """The completed Actions job behind commit status NAME on SHA, or None when SHA has no status NAME. A red
    status no Actions job gave (Vercel's) is the audit line of base_status when BASE shares it, else refused."""
    statuses = github.json(f"repos/{repo}/commits/{sha}/status?per_page=100").get("statuses") or []
    # The combined status lists the newest per context.
    status = next((found for found in statuses if found.get("context") == name), None)
    if status is None:
        return None
    state, job_name = status.get("state"), name.removesuffix(SAME_TREE_SUFFIX)
    if state == "pending":
        raise Refused(f"'{name}': its status is still pending on {sha}")
    url = status.get("target_url") or ""
    match = re.fullmatch(r"https://github\.com/" + re.escape(repo) + r"/actions/runs/(\d+)(?:/job/\d+)?/?", url)
    if match:
        runs = [github.json(f"repos/{repo}/actions/runs/{match[1]}")]
        if tested_sha(runs[0]) != sha:
            raise Refused(f"'{name}': its status links run {match[1]}, which tested {tested_sha(runs[0])[:12]}, "
                          f"not {sha}")
    else:
        listed = github.json(f"repos/{repo}/actions/runs?head_sha={sha}&per_page=100")
        runs = [run for run in listed.get("workflow_runs") or [] if tested_sha(run) == sha]
    for run in runs:
        found = next((job for job in last_real_jobs(repo, run["id"], github) if job.get("name") == job_name), None)
        if found is None:
            continue
        if found.get("status") != "completed":
            raise Refused(f"'{name}': job '{job_name}' in run {run['id']} has not completed")
        if found.get("conclusion") == "success" or state == "success":
            raise Refused(f"'{name}': its status is {state} but job '{job_name}' in run {run['id']} is "
                          f"{found.get('conclusion')}; nothing to compare with the base")
        return found
    if not match and base and state in ("failure", "error"):
        return base_status(repo, base, name, state, status.get("description") or "", github)
    where = f"run {match[1]} (its target_url)" if match else f"any run that tested {sha}"
    raise Refused(f"'{name}': a status ({state}: {status.get('description') or 'no description'}) with no job "
                  f"'{job_name}' in {where} to compare with the base")


# A status no Actions job gave (2026-11-04, cmuxterm-hq#7039): Vercel posts "Deployment rate limited — retry in 24
# hours." on every commit, the base's included, while its build limit lasts, and there is no job or log behind it to
# compare per test. It is the base's only when the newest of the BASE_STATUS_COMMITS newest base commits that has a
# status of that context has it in the same state with the same description; one the base does not share, or shares
# with another description, stays the head's.
BASE_STATUS_COMMITS = 10


def base_status(repo: str, base: str, name: str, state: str, description: str, github) -> str:
    """The audit line excusing jobless status NAME (STATE, DESCRIPTION) when the base has the same, else Refused."""
    if not description:
        raise Refused(f"'{name}': a status ({state}) with no description and no job: nothing to compare with the base")
    for commit in github.json(f"repos/{repo}/commits?sha={base}&per_page={BASE_STATUS_COMMITS}") or []:
        statuses = github.json(f"repos/{repo}/commits/{commit['sha']}/status?per_page=100").get("statuses") or []
        found = next((found for found in statuses if found.get("context") == name), None)
        if found is None:
            continue
        if (found.get("state"), found.get("description") or "") != (state, description):
            raise Refused(f"'{name}': a status ({state}: {description}) with no job, and {base} {commit['sha']} has "
                          f"it {found.get('state')}: {found.get('description') or 'no description'}")
        return f"excused '{name}': base {commit['sha']} status {state} \"{description}\""
    raise Refused(f"'{name}': a status ({state}: {description}) with no job, and none of the {BASE_STATUS_COMMITS} "
                  f"newest {base} commits has a status '{name}' to compare with")


# A run's jobs as its last real attempt left them (cmux#35906, 2026-11-05). GitHub's latest-attempt views
# (jobs?filter=latest, and check-runs with no filter) show only the newest attempt, and an attempt that ended in
# startup_failure runs no jobs: after two such reruns of run 41931705470 they showed no job at all, its 'publish
# tree-addressed cmux-tui' red included, and the head read as having no red. Such an attempt is no result, never a
# green, so every attempt is read (filter=all) and each job name keeps the jobs of the newest attempt that ran it. A
# real rerun (red, then green) still decides; a run whose only attempt ran nothing has no jobs, which is no result.
def last_real_jobs(repo: str, run: int, github) -> list[dict]:
    jobs = [job for page in github.json(f"repos/{repo}/actions/runs/{run}/jobs?filter=all&per_page=100", paginate=True)
            for job in page.get("jobs") or []]
    newest: dict[str, int] = {}
    for job in jobs:
        newest[job.get("name", "")] = max(newest.get(job.get("name", ""), 0), job.get("run_attempt") or 1)
    return [job for job in jobs if (job.get("run_attempt") or 1) == newest[job.get("name", "")]]


def head_jobs(repo: str, sha: str, runs: list[int], checks: list[str], github, *, base: str | None = None,
              excused: list[str] | None = None) -> list[dict]:
    """Failed head jobs; a check that is a jobless status red the base shares adds its line to EXCUSED."""
    jobs: dict[int, dict] = {}
    for run in runs:
        guards = []
        run_rollups = []
        children = []
        for job in last_real_jobs(repo, run, github):
            if is_aggregate(job.get("name", ""), repo):
                if job.get("conclusion") not in ("success", "skipped", "neutral", None):
                    (run_rollups if job.get("name") in rollups(repo)["run"] else guards).append(job)
                continue
            if job.get("status") == "completed" and job.get("conclusion") not in ("success", "skipped", "neutral"):
                if job.get("head_sha") not in (None, sha):
                    raise Refused(f"{job.get('name')}: job is not for the exact SHA {sha}")
                jobs[job["id"]] = job
                children.append(job)
        for guard in guards:
            if not children:
                raise Refused(f"run {run}: its aggregate check failed with no failed job to compare with the base")
            validate_guard_routes(repo, sha, guard, children, github)
        for rollup in run_rollups:
            validate_run_rollup(rollup["name"], children, repo)
    if checks:
        latest = latest_checks(repo, sha, github)
        aggregate_jobs = []
        aggregate_runs = []
        for name in checks:
            if name not in latest:
                if (job := status_job(repo, sha, name, github, base if excused is not None else None)) is None:
                    raise Refused(f"{name}: has not run on exact head {sha}")
                if isinstance(job, str):
                    excused.append(job)
                    continue
                jobs[job["id"]] = job
                continue
            job = job_for(repo, latest[name], sha, github)
            if is_aggregate(name, repo):
                # The check-run can remain failed while its Actions job has
                # been retried or replaced.  Never discard this exact job and
                # rescan the run: a green/missing aggregate must not allow its
                # child failures to be excused (a run rollup like ci-status too).
                if job.get("conclusion") != "failure":
                    raise Refused(f"'{name}': exact aggregate job is {job.get('conclusion')}, not failure")
                if name in rollups(repo)["run"]:
                    aggregate_runs.append((name, job["run_id"]))
                    continue
                aggregate_jobs.append(job)
            else:
                jobs[job["id"]] = job
        for name, run in aggregate_runs:
            found = head_jobs(repo, sha, [run], [], github)
            if not found:
                raise Refused(f"run {run}: its aggregate check failed with no failed job to compare with the base")
            validate_run_rollup(name, found, repo)
            jobs.update((job["id"], job) for job in found)
        for guard in aggregate_jobs:
            found = head_jobs(repo, sha, [guard["run_id"]], [], github)
            if not found:
                raise Refused(f"run {guard['run_id']}: its aggregate check failed with no failed job to compare with the base")
            validate_guard_routes(repo, sha, guard, found, github)
            jobs.update((job["id"], job) for job in found)
    return list(jobs.values())


def tip_suite_verdicts(repo: str, base: str, workflow, name: str, github, base_jobs: dict[int, list[dict]]):
    """(run, job) for each completed suite run of BASE with a verdict for job NAME, newest first, read lazily."""
    # Every status, so a first run's same-tree run is seen while it still queues or runs (TREE_JOBS).
    listed = github.json(f"repos/{repo}/actions/workflows/{workflow}/runs?branch={base}&event=workflow_dispatch"
                         f"&per_page={BASE_RUNS_PAGE}")
    runs = listed.get("workflow_runs") or []
    deferred = deferred_first_runs(runs) if name in TREE_JOBS else set()
    candidates = [run for run in runs
                  if run.get("status") == "completed" and run.get("conclusion") != "skipped"
                  and not never_carries(run, name) and run["id"] not in deferred]
    for run in candidates[:TIP_SUITE_JOB_READS]:
        if run["id"] not in base_jobs:
            base_jobs[run["id"]] = [found for page in github.json(
                f"repos/{repo}/actions/runs/{run['id']}/jobs?filter=latest&per_page=100", paginate=True)
                for found in page.get("jobs") or []]
        found = next((found for found in base_jobs[run["id"]] if found.get("name") == name), None)
        if found is not None and found.get("conclusion") in VERDICTS and not refused_at_setup(found):
            yield run, found


def base_verdicts(repo: str, base: str, workflow, name: str, github, base_runs: dict, base_jobs: dict,
                  job_reads: dict):
    """(run, job) for each completed BASE run with a verdict for job NAME, newest first, read lazily: the window of
    BASE_RUNS_PAGE runs (at most BASE_JOB_READS job lists per workflow), then, for a SUITE_JOBS job, the base's
    dispatches (tip_suite_verdicts). A base push run's Mac job is often cancelled by the next push, or refused by a
    mini, so a run with no verdict for the job is passed over."""
    seen: set[int] = set()
    for candidate_run in base_runs[workflow]:
        if never_carries(candidate_run, name):
            continue
        if candidate_run["id"] not in base_jobs:
            if job_reads.get(workflow, 0) >= BASE_JOB_READS:
                break
            job_reads[workflow] = job_reads.get(workflow, 0) + 1
            base_jobs[candidate_run["id"]] = [found for page in github.json(
                f"repos/{repo}/actions/runs/{candidate_run['id']}/jobs?filter=latest&per_page=100", paginate=True)
                for found in page.get("jobs") or []]
        found = next((found for found in base_jobs[candidate_run["id"]] if found.get("name") == name), None)
        if found is not None and found.get("conclusion") in VERDICTS and not refused_at_setup(found):
            seen.add(candidate_run["id"])
            yield candidate_run, found
    if name in SUITE_JOBS:
        for run, found in tip_suite_verdicts(repo, base, workflow, name, github, base_jobs):
            if run["id"] not in seen:
                seen.add(run["id"])
                yield run, found


# A stale base pass (2026-11-02): base_red_excuse.py read only completed base runs, and a base run completes when its
# slowest job does. Between 09:13Z and 09:23Z every feat-cmux-next run from #31930 on was still running, so the newest
# completed run was 41418052327 at c47a99fcb9, before #31930 and before cmux#31338's merge-base e3c495d3 (#31931). Its
# 'cmux-next guards / defaults-snapshot' passed, and the real base red #31930 caused there was refused as the PR's own.
# So the base window lists runs of every status, and a finished job in a running run is a verdict. And a pass that
# tested a commit before the PR's merge-base says nothing about the base the PR was built on: a red then waits for a
# newer verdict (before_merge_base) instead of being called the PR's own.


def before_merge_base(repo: str, base: str, sha: str, base_run: dict, github, cache: dict[str, str]) -> str | None:
    """Why BASE_RUN tested a commit older than the merge-base of SHA with BASE, or None when it did not (or that
    cannot be told). CACHE holds the merge-base, read once per judge."""
    if sha not in cache:
        diff = github.json(f"repos/{repo}/compare/{base}...{sha}?per_page=1")
        cache[sha] = ((diff.get("merge_base_commit") or {}).get("sha")) or ""
    merge_base, tested = cache[sha], tested_sha(base_run)
    if not re.fullmatch(r"[0-9a-f]{40}", merge_base) or not re.fullmatch(r"[0-9a-f]{40}", tested):
        return None
    if tested == merge_base:
        return None
    status = github.json(f"repos/{repo}/compare/{merge_base}...{tested}?per_page=1").get("status")
    if status in ("ahead", "identical"):
        return None
    return f"tested {tested[:12]}, which is {status or 'not after'} the merge-base {merge_base[:12]}"


def created(run: dict) -> datetime | None:
    try:
        return datetime.fromisoformat(str(run.get("created_at")).replace("Z", "+00:00"))
    except ValueError:
        return None


# Fixed on the base (2026-10-31): a pull request whose merge-base is older than a base fix keeps the red the fix
# removed. The release-notary and workflow guard tests (tests/*.py, run by unittest or pytest) read the workflows,
# the scripts and the release manifests, not the pull request's product code, so a red one that passes on the newest
# base was the base's at the merge-base: cmux#27584, #27918, #27905 and #27775 were stranded as their own reds by
# test_every_part_of_bun_run_check_runs_in_the_warn_branch and test_cmux_next_follows_the_committed_target_graph.
# A failing test is excused as fixed on the base only when all of these hold:
#   (a) the newest base verdict for its job is a pass, at a commit strictly after the pull request's merge-base;
#   (b) it is a tests/*.py guard test whose file the log names (a pytest id, or the unittest traceback's own frame),
#       every failed step of the job is such a test's (or the job's own `red check:` rollup of them), and the pull
#       request's diff from its merge-base touches neither that file nor any path the test reads. Only a test whose
#       file is declared in GUARD_READS qualifies (GUARD_READS_DEFAULT plus its own product paths): an undeclared
#       test may read anything (tests/test_docs_deploy_auth_guard.py reads web/), so it is refused, never guessed;
#   (c) the run is whole: a crash or a cut-short run never counts (refused before this is asked).
# Only a declared guard job (GUARD_JOBS) qualifies, and each failing test must be one its failed step's own script
# runs (the step's echo names the test file) with a whole test-run summary printed: a Swift, cargo or webview job, or
# product code printing a `FAILED tests/x.py::...` line, is never fixed on the base.
TOP_LEVEL = "top-level files"  # every path with no directory: package.json, .gitmodules, the entitlements, ...
RELEASE_MANIFESTS = (TOP_LEVEL, "release-notes/", "homebrew-cmux/", "cmux.xcodeproj/", "Resources/", "ghostty-next",
                     "vendor/")
GUARD_READS_DEFAULT = (".github/", "scripts/", "tests/") + RELEASE_MANIFESTS
# The guard tests that can be fixed on the base, by file, with the product paths each reads beyond the default. A
# test is declared here only after its reads are checked; any other test's red is refused.
GUARD_READS = {
    # cmux_next_route and the warn-branch check read the CmuxNext target graph, webviews/package.json and the
    # cmux-tui and Native Cargo manifests.
    "tests/test_cmux_next_checks_workflow.py": ("Packages/", "webviews/", "cmux-tui/", "Native/"),
    # focused_tests.plan reads the tree: Swift imports, the CmuxNext target graph, the webviews import graph, Cargo.
    "tests/test_car_guards.py": ("Packages/", "webviews/", "cmux-tui/", "Native/"),
}
# The jobs that run the declared guard tests: cmux-next.yml's checks job, and ci-guards.yml's release-notary group
# (its check is '<caller> / workflow-guard-tests / release-notary').
GUARD_JOBS = frozenset({"cmux-next checks (god files, concurrency, crash safety, l10n)"})
GUARD_JOB_SUFFIXES = ("workflow-guard-tests / release-notary",)
GUARD_TEST_FILE = re.compile(r"tests/[\w.-]+\.py")
# A finished test run: unittest's `Ran N tests in`, or pytest's closing `==== ... in Ns ====` line.
TEST_RUN_SUMMARY = re.compile(r"^Ran \d+ tests? in [\d.]+s$|^=+ .*\bin [\d.]+s\b.*=+$")
# A traceback frame in a tests/*.py file: `File "/…/tests/test_x.py", line 12, in test_y`.
TRACEBACK_FRAME = re.compile(r'^\s*File "(?:[^"]*/)?(tests/[\w.-]+\.py)", line \d+, in (\w+)$')
# The cmux-next checks job's last step (`Fail on any red check`) names each red step it rolls up.
ROLLUP_RED = re.compile(r"^##\[error\]red check: \S")
# A compare lists at most 300 files: a longer diff cannot be shown to stay out of a test's paths.
COMPARE_FILES_CAP = 300


def guard_job(name: str) -> bool:
    return name in GUARD_JOBS or any(name == end or name.endswith(" / " + end) for end in GUARD_JOB_SUFFIXES)


def guard_test_file(name: str, output: list[str]) -> str | None:
    """The tests/*.py file failing test NAME is in, from its pytest id or its own unittest traceback frame in OUTPUT
    (the failed step's printed lines); None when it is no such test or the log does not name one file for it."""
    if "::" in name:
        path = name.split("::", 1)[0]
        return path if GUARD_TEST_FILE.fullmatch(path) else None
    method = name.split(" ", 1)[0]
    frames = {m.group(1) for text in output for m in [TRACEBACK_FRAME.match(text)] if m and m.group(2) == method}
    return frames.pop() if len(frames) == 1 else None


def guard_tests(log: str) -> dict[str, str]:
    """{failing test: its tests/*.py file} for a job whose every failed step is a guard test's; raises Refused naming
    the first step or test that is not."""
    lines = test_reds.log_lines(log)
    skip = test_reds.echoed(lines)
    starts = [n for n in sorted(skip) if test_reds.ECHO_START.match(lines[n])]
    found: dict[str, str] = {}
    tested_steps = rolled_up = 0
    for start, end in zip([0] + starts, starts + [len(lines)]):
        output = [lines[n] for n in range(start, end) if n not in skip]
        script = [lines[n] for n in range(start, end) if n in skip]
        errors = [text for text in output if test_reds.STEP_ERROR.match(text)]
        if not errors:
            continue
        rollup = [text for text in errors if ROLLUP_RED.match(text)]
        if rollup and all(ROLLUP_RED.match(text) or test_reds.PROCESS_EXIT.match(text) for text in errors):
            rolled_up += len(rollup)
            continue
        names = test_reds.failed_names(output)
        if not names:
            raise Refused(f"a failed step names no failing test ({errors[0][:200]})")
        if not any(TEST_RUN_SUMMARY.match(text) for text in output):
            raise Refused(f"the failed step naming {sorted(names)[0]} printed no test-run summary")
        for name in sorted(names):
            path = guard_test_file(name, output)
            if path is None:
                raise Refused(f"{name} is not a tests/*.py guard test whose file its log names")
            if not any(path in text for text in script):
                raise Refused(f"{name}: its failed step's script does not run {path}")
            found[name] = path
        tested_steps += 1
    if not found:
        raise Refused("no failing guard test")
    if rolled_up > tested_steps:
        raise Refused(f"its rollup names {rolled_up} red checks and only {tested_steps} failed with a guard test")
    return found


def touches(path: str, read: str) -> bool:
    if read == TOP_LEVEL:
        return "/" not in path
    return path.startswith(read) if read.endswith("/") else path == read or path.startswith(read + "/")


def fixed_on_base(repo: str, base: str, sha: str, name: str, head_log: str, base_run: dict, github) -> str:
    """The audit line for a red job whose every failing test is fixed on the base (the rule above); raises Refused
    with the reason it is not. BASE_RUN is the newest base run with a verdict for the job, and that verdict passed."""
    if not guard_job(name):
        raise Refused(f"'{name}' is not a declared guard job (GUARD_JOBS); its tests may read product code")
    tests = guard_tests(head_log)
    tested = tested_sha(base_run)
    if not re.fullmatch(r"[0-9a-f]{40}", tested):
        raise Refused(f"{base} run {base_run['id']} names no commit it tested")
    diff = github.json(f"repos/{repo}/compare/{base}...{sha}")
    merge_base = ((diff.get("merge_base_commit") or {}).get("sha")) or ""
    files = diff.get("files")
    if not re.fullmatch(r"[0-9a-f]{40}", merge_base) or not isinstance(files, list):
        raise Refused(f"no merge-base and diff for {sha} against {base}")
    if len(files) >= COMPARE_FILES_CAP:
        raise Refused(f"the diff from its merge-base lists {len(files)} files, too many to show it stays out of "
                      "the tests' paths")
    after = github.json(f"repos/{repo}/compare/{merge_base}...{tested}?per_page=1")
    if after.get("status") != "ahead":
        raise Refused(f"the passing {base} run {base_run['id']} tested {tested[:12]}, which is not after the merge-base "
                      f"{merge_base[:12]} ({after.get('status')})")
    changed = sorted({path for found in files for path in (found.get("filename"), found.get("previous_filename"))
                      if isinstance(path, str) and path})
    if undeclared := sorted({path for path in tests.values() if path not in GUARD_READS}):
        raise Refused(f"{', '.join(undeclared)} declares no read paths (GUARD_READS), so a pass on the base proves "
                      "nothing about this PR")
    reads: list[str] = []
    for test, path in sorted(tests.items()):
        test_reads = (path,) + GUARD_READS_DEFAULT + GUARD_READS.get(path, ())
        if hit := [changed_path for changed_path in changed if any(touches(changed_path, r) for r in test_reads)]:
            raise Refused(f"{test} reads paths the PR changes: {'; '.join(hit[:5])}")
        reads.extend(r for r in test_reads if r not in reads)
    url = base_run.get("html_url") or f"https://github.com/{repo}/actions/runs/{base_run['id']}"
    return (f"excused '{name}': fixed on base (passes at {tested[:12]} in {base} run {base_run['id']}, after the "
            f"merge-base {merge_base[:12]}; PR does not touch {', '.join(reads)}) ({url}): "
            f"{'; '.join(sorted(tests))[:400]}")


# cmux-next-guards.yml's "cmux-next CI guard group" runs every routed guard step of ci-guards.yml (the workflow guard
# profile) on the change and again on its base, and fails only on a step red on the change and not on that base
# (scripts/ci/guards_new_reds.py). Its log names each red step on one plain line, `guard red step (KIND): STEP`: `new`
# (red on this change), `base` (red on the base too), `flaky`, or `tip` (a push judged at its tip). A pull request's
# red in it is judged per step, the way the job itself reports "N red on the base too": every step the head calls
# `new` must be red at the newest base run of the job, whatever that run's conclusion (a push judged against the
# previous tip lists a red that persists as `base` and stays green). A whole verdict is one with the closing summary
# line; anything else is refused. Before this the job was not a declared guard job (GUARD_JOBS), so a red in it was
# never excused, and the base's own reds in it stayed green on every push (18 steps, until #31366).
GUARD_GROUP_JOB = "cmux-next CI guard group"
GUARD_GROUP_STEP = "Run the ci guard group and the routed groups"
GUARD_RED_STEP = re.compile(r"^guard red step \((new|base|flaky|tip)\): (.+)$")
GUARD_SUMMARY = re.compile(r"^\d+ guard steps red (?:on this change|at the tip)\b")
# run_ci_guards.py's closing line. The red step lines are read only after the last one: a failing step's own output
# (printed above it) may quote them.
GUARD_RUN_DONE = re.compile(r"^cmux guards: \d+ steps passed, \d+ failed\b")


def guard_red_steps(log: str) -> dict[str, set[str]] | None:
    """{kind: red steps} from a guard group job's log, or None when it printed no closing summary (cut short)."""
    lines = test_reds.log_lines(log)
    skip = test_reds.echoed(lines)
    found: dict[str, set[str]] = {"new": set(), "base": set(), "flaky": set(), "tip": set()}
    done = whole = False
    for n, text in enumerate(lines):
        if n in skip:
            continue
        if GUARD_RUN_DONE.match(text):
            found, done, whole = {kind: set() for kind in found}, True, False
        elif not done:
            continue  # a cut-short run's step output may quote verdict lines; none count before the run finished
        elif match := GUARD_RED_STEP.match(text):
            found[match.group(1)].add(match.group(2).strip())
        elif GUARD_SUMMARY.match(text):
            whole = True
    return found if whole else None


def guard_group(repo: str, base: str, name: str, job: dict, head_log: str, base_run: dict, base_job: dict,
                github) -> str:
    """The audit line for a red guard group job whose every red step is red at the newest base verdict for the job
    (the rule above); raises Refused naming the first step that is not."""
    failed = {step["name"] for step in job.get("steps") or []
              if step.get("conclusion") not in (None, "success", "skipped")}
    if failed != {GUARD_GROUP_STEP}:
        raise Refused(f"'{name}': failed steps {sorted(failed)}, not only '{GUARD_GROUP_STEP}'; nothing to compare "
                      "step by step")
    head = guard_red_steps(head_log)
    if head is None:
        raise Refused(f"'{name}': its guard comparison printed no summary (a cut-short run is never a base red)")
    charged = head["new"] | head["tip"]
    if not charged:
        raise Refused(f"'{name}': red, but names no red step of its own; nothing to compare with the base")
    found = guard_red_steps(github.log(repo, base_job))
    url = base_run.get("html_url") or f"https://github.com/{repo}/actions/runs/{base_run['id']}"
    if found is None:
        raise Refused(f"'{name}': {base} run {base_run['id']} names no red steps with a closing summary ({url})")
    red_on_base = set().union(*found.values())
    if missing := sorted(charged - red_on_base):
        raise Refused(f"'{name}': guard steps red on this change and not on {base} run {base_run['id']} ({url}): "
                      f"{'; '.join(missing)[:600]}")
    at = f" at {tested_sha(base_run)[:10]}" if tested_sha(base_run) else ""
    return (f"excused '{name}': every red guard step is red on {base} run {base_run['id']}{at} "
            f"(the newest {base} verdict for it, {base_job.get('conclusion')}) ({url}): {'; '.join(sorted(charged))[:400]}")


class Final(Refused):
    """A refusal no older base verdict can lift: it is judged against the newest verdict alone."""


def compare_window(repo: str, base: str, name: str, head: tuple, head_log: str, window: list,
                   chromium_without_diagnostics: bool, *, flake_state: dict | None = None,
                   workflow: str = "") -> str:
    """The audit line for red job NAME (HEAD: its signature) when each of its failures is on some red base verdict of
    WINDOW (newest first: (run, log, signature)); raises Refused naming the first that is on none, Final when the
    newest verdict's log alone (the Chromium check, a process signal, the panic ratchet) refuses it."""
    base_run, base_log, _ = window[0]
    runs = f"run {base_run['id']}" if len(window) == 1 else "any of runs " + ", ".join(str(w[0]["id"]) for w in window)
    head_steps, head_tests, head_errors = head
    head_crash = crash_signals(head_log)
    base_steps, base_tests, base_errors, on = set(), set(), set(), {}
    for run, _, (steps, tests, errors) in window:
        base_steps, base_tests, base_errors = base_steps | steps, base_tests | tests, base_errors | errors
        for test in tests:
            on.setdefault(test, run["id"])
    if chromium_without_diagnostics and (window[0][2][1] or window[0][2][2] or crash_signals(base_log)):
        raise Final(f"'{name}': no failing test or error line to match; nothing to compare with the base")
    known = test_reds.flaky_failures(head_log, name, workflow, flake_state) if base == "feat-cmux-next" else {}
    base_tests |= known.keys()
    verdict = test_reds.classify_any(head_log, [(f"{base} run {run['id']}", text) for run, text, _ in window], name,
                                   flake_state=flake_state if base == "feat-cmux-next" else None, workflow=workflow)
    if verdict is not None and verdict.own:
        raise Refused(f"'{name}': " + "; ".join(verdict.reasons)[:800])
    # Not a test job (a compile or tool that died on a signal): the base must have died the same way.
    if missing := sorted(head_crash - crash_signals(base_log)):
        raise Final(f"'{name}': the process died on signal {', '.join(missing)}, "
                    f"and {base} run {base_run['id']} did not")
    # The ratchet's error line names the run's packages, not its red: its rows are compared instead (RATCHET_SCOPE).
    ratchet = {error for error in head_errors if RATCHET_SCOPE.match(error)}
    if ratchet:
        try:
            unmatched = ratchet_unmatched(head_log, base_log)
        except Refused as error:
            raise Final(f"'{name}': {error}") from None
        if unmatched:
            raise Final(f"'{name}': panic ratchet failures not on {base} run {base_run['id']}: "
                        f"{'; '.join(unmatched)[:600]}")
        head_errors = head_errors - ratchet
    compared = [("failed steps", head_steps, base_steps), ("failing tests", head_tests, base_tests)]
    # A crash-class rule line is a named failure, but its job also has steps that print only error lines
    # (the concurrency rule): those stay compared unless a real test failed.
    if not any(not test_reds.is_crash_rule_failure(test) for test in head_tests):
        compared.append(("errors", head_errors, base_errors))
    for kind, head, seen in compared:
        if missing := sorted(head - seen):
            raise Refused(f"'{name}': {kind} not on {base} {runs}: {'; '.join(missing)[:600]}")
    rows = [f"{crate}: clippy::{lint} {count} > {where}"
            for (crate, lint, where), count in sorted(ratchet_red(head_log)[0].items())] if ratchet else []
    what = ("; ".join(test if on.get(test) == base_run["id"] else
                      f"{test} ({known[test]})" if test in known else f"{test} (red on run {on[test]})"
                      for test in sorted(head_tests))
            or "; ".join(rows + sorted(head_errors)))
    url = base_run.get("html_url") or f"https://github.com/{repo}/actions/runs/{base_run['id']}"
    # The base verdict is the newest one, not necessarily the base tip's: the base tier runs at most
    # once every 15 minutes, so name the commit and time it is from.
    at = f" at {tested_sha(base_run)[:10]}" if tested_sha(base_run) else ""
    when = f", {base_run['created_at']}" if base_run.get("created_at") else ""
    older = (f" or one of the {len(window) - 1} red {base} verdict(s) before it (runs "
             f"{', '.join(str(w[0]['id']) for w in window[1:])})") if len(window) > 1 else ""
    return (f"excused '{name}': {base} run {base_run['id']}{at} (the newest {base} verdict for it{when}){older} "
            f"fails the same way ({url}): {what[:400]}")


class Infra(Refused):
    """A red that is the infrastructure's (test_reds.lost_runner: the runner was lost), not a verdict: never the
    pull request's own red, never excused, and it needs a re-run, like a cancelled job."""


def infra(name: str, job: dict, why: str) -> Infra:
    return Infra(f"'{name}' is infra, not a verdict (job {job.get('id')}: {why}); it is never this PR's own red "
                 "and needs a re-run, like a cancelled job")


def lost_runner_log(repo: str, name: str, job: dict, github) -> str:
    """JOB's log, after refusing a job that lost its runner (test_reds.lost_runner) as Infra. Its steps decide first, at
    no cost; a log GitHub cannot serve (a lost runner leaves none: BlobNotFound) has its check run's annotations read
    to tell a lost runner from an unreadable verdict, which stays the refusal it was."""
    if why := test_reds.lost_runner(job):
        raise infra(name, job, why)
    try:
        return github.log(repo, job)
    except Refused as error:
        try:
            notes = github.json(f"repos/{repo}/check-runs/{job['id']}/annotations")
        except (Refused, KeyError, ValueError):
            notes = []
        if why := test_reds.lost_runner(job, notes if isinstance(notes, list) else [], str(error)):
            raise infra(name, job, why) from None
        raise


def quarantined_only(job: dict, head_log: str, known: dict) -> bool:
    """A whole test-step red explained entirely by matching quarantines, with no additional failing step/error."""
    found = test_reds.read(head_log)
    steps, _, errors = signature(job, head_log)
    if (not found.failed or found.crashes or found.truncated or found.failed - known.keys()
            or not steps or any(not re.search(r"\btests?\b", step, re.I) for step in steps)):
        return False
    # A generic failed test-named step must not borrow a quarantined test from another step. gh run view labels
    # steps, while the live job-log endpoint has only timestamps: use its step windows, refusing ambiguous lines.
    metadata = [step for step in job.get("steps") or [] if step.get("conclusion") != "skipped"]
    names = [step.get("name") for step in metadata]
    if len(set(names)) != len(names):
        return False
    by_step: dict[str, list[str]] = {}
    for line in head_log.splitlines():
        parts = line.split("\t", 2)
        if len(parts) == 3 and STAMP.match(parts[2]):
            by_step.setdefault(parts[1], []).append(parts[2])
    if not by_step:
        def timestamp(value):
            try:
                parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
                return parsed if parsed.tzinfo else None
            except (AttributeError, TypeError, ValueError):
                return None
        windows = []
        for step in metadata:
            start, end = timestamp(step.get("started_at")), timestamp(step.get("completed_at"))
            if start is None or end is None or end < start:
                return False
            # Actions step metadata rounds to seconds. A line in a shared boundary second cannot identify its
            # step, so match every possible window and retain it only when there is exactly one owner.
            windows.append((step["name"], start, end + timedelta(seconds=1)))
        for line in head_log.splitlines():
            stamp = STAMP.match(line)
            when = timestamp(stamp.group().strip()) if stamp else None
            if when is None:
                continue
            owners = [name for name, start, end in windows if start <= when < end]
            if len(owners) == 1:
                by_step.setdefault(owners[0], []).append(line)
    for step in steps:
        result = test_reds.read("\n".join(by_step.get(step, [])))
        if not result.failed or result.crashes or result.truncated or result.failed - known.keys():
            return False
    normalized = normalise_error
    diagnostics = set()
    for observed in test_reds.observations(head_log):
        if observed["outcome"] != "fail":
            continue
        for line in observed["signature"].splitlines():
            # Bun stores its `error:` headline without that prefix, then its assertion block separated by ` / `.
            headline = line.split(" / ", 1)[0]
            diagnostics.update((normalized(line), normalized(headline), normalized("error: " + headline)))
    return errors <= diagnostics


def judge(repo: str, base: str, sha: str, runs: list[int], github, *, checks: list[str] = (),
          flake_state: dict | None = None) -> list[str]:
    """Audit lines for every excused failure; raises Refused on the first that is not, or RateLimitedRead
    when a read was rate-limited (no verdict on any red, so nothing below may excuse or charge one)."""
    github = rate_limit_aware(github)
    audit: list[str] = []
    base_runs: dict[int, list[dict]] = {}
    base_jobs: dict[int, list[dict]] = {}
    job_reads: dict[int, int] = {}
    merge_bases: dict[str, str] = {}
    load_rollups(repo, base, github)
    jobs = head_jobs(repo, sha, runs, list(checks), github, base=base, excused=audit)
    if not jobs and not audit:
        # A red run or check with no failed job to show has nothing the base can excuse.
        raise Refused("no failed job found on the head to compare with the base")
    for job in jobs:
        name = job.get("name", "")
        if job.get("conclusion") != "failure":
            raise Refused(f"'{name}' is {job.get('conclusion')}: it has no verdict to compare with the base; re-run it")
        if refused_at_setup(job):
            raise Refused(f"'{name}' was refused at setup by its runner; it gets re-run, never excused")
        head_log = lost_runner_log(repo, name, job, github)
        if refused_at_setup(job, head_log):
            raise Refused(f"'{name}' was refused at setup by its runner; it gets re-run, never excused")
        if name == GENERATED_VERDICT_JOB and (said := generated_no_verdict(head_log)) is not None:
            raise Refused(f"'{name}' gave no generated files verdict ({said[:300]}); "
                          "re-run its prerequisite and this dependent job together")
        if name in NO_VERDICT_JOBS and (said := no_verdict(head_log)) is not None:
            proof = compile_pass_at(repo, sha, github)
            if proof is None:
                raise Refused(f"'{name}' gave no compile verdict ({said[:300]}) and nothing else compiled {sha}: "
                              "a no-verdict compile is never a base red; re-run it once the fleet answers")
            audit.append(f"ignored '{name}': it gave no compile verdict, but {proof} compiled {sha} and passed")
            continue
        head_steps, head_tests, head_errors = signature(job, head_log)
        chromium_without_diagnostics = (name == CHROMIUM_CURRENCY_JOB
                                        and CHROMIUM_CURRENCY_STEP in head_steps
                                        and not (head_tests or head_errors or crash_signals(head_log)))
        own = test_reds.read(head_log)
        if own.crashes or (own.truncated and not chromium_without_diagnostics):
            raise Refused(f"'{name}': " + "; ".join(own.crashes + own.truncated[:1])[:800]
                          + " (a crash or a cut-short run is never a base red)")
        workflow_info = github.json(f"repos/{repo}/actions/runs/{job['run_id']}")
        workflow = workflow_info.get("workflow_id")
        # This supplement uses only measured base observations with an active public quarantine issue. It can
        # bridge a green base run; it never changes the deterministic comparison when state is absent or invalid.
        known = test_reds.flaky_failures(head_log, name, workflow_info.get("name", ""), flake_state)
        if base == "feat-cmux-next" and quarantined_only(job, head_log, known):
            audit.append(f"excused '{name}': quarantined base flakes: "
                         + "; ".join(f"{test} ({why})" for test, why in sorted(known.items())))
            continue
        if workflow not in base_runs:
            # Every status: a job's verdict is final once the job completes, so a base run still running its slower
            # jobs already answers for its finished ones (before_merge_base's note).
            listed = github.json(f"repos/{repo}/actions/workflows/{workflow}/runs?branch={base}"
                                 f"&per_page={BASE_RUNS_PAGE}")
            # Newest first, whatever order GitHub lists them in; a run in a PR's context (pull_request or
            # pull_request_target) is never the base's.
            base_runs[workflow] = sorted(
                (run for run in listed.get("workflow_runs") or []
                 if run.get("event") not in ("pull_request", "pull_request_target")
                 and run.get("conclusion") != "skipped"),
                key=lambda run: run.get("created_at") or "", reverse=True)
        # The newest base run where this job has a verdict decides whether it is red on the base.
        verdicts = base_verdicts(repo, base, workflow, name, github, base_runs, base_jobs, job_reads)
        base_run, base_job = next(verdicts, (None, None))
        if base_run is None:
            raise Refused(f"'{name}': no {base} run of its workflow has a verdict for it to compare with "
                          f"(read the {BASE_RUNS_PAGE} newest, up to {BASE_JOB_READS} job lists, "
                          f"and its tip suite runs)")
        if name == GUARD_GROUP_JOB:
            audit.append(guard_group(repo, base, name, job, head_log, base_run, base_job, github))
            continue
        if base_job.get("conclusion") != "failure":
            try:
                audit.append(fixed_on_base(repo, base, sha, name, head_log, base_run, github))
            except Refused as why:
                if (stale := before_merge_base(repo, base, sha, base_run, github, merge_bases)) is not None:
                    raise Refused(f"'{name}' has no {base} verdict at or after this PR's merge-base yet: the newest, "
                                  f"a pass in run {base_run['id']}, {stale}; re-check once a {base} run at or after "
                                  "the merge-base has a verdict for it") from None
                raise Refused(f"'{name}' is not red on {base} run {base_run['id']} ({base_job.get('conclusion')}), "
                              f"and not fixed on base: {why}; fix it on this head") from None
            continue
        head = signature(job, head_log)
        if not head[1] and not head[2] and not crash_signals(head_log) and not chromium_without_diagnostics:
            raise Refused(f"'{name}': no failing test or error line to match; nothing to compare with the base")
        # The window: the newest verdict first, then older red ones, up to BASE_WINDOW verdicts within
        # BASE_WINDOW_HOURS of it, read only while a head failure is on none so far. A green verdict ends it.
        def red(run: dict, found: dict) -> tuple:
            text = github.log(repo, found)
            return run, text, signature(found, text)
        window, newest, read = [red(base_run, base_job)], created(base_run), 1
        while True:
            try:
                audit.append(compare_window(repo, base, name, head, head_log, window, chromium_without_diagnostics,
                                            flake_state=flake_state, workflow=workflow_info.get("name", "")))
                break
            except Final:
                raise
            except Refused:
                run, found = next(verdicts, (None, None)) if read < BASE_WINDOW else (None, None)
                if (run is None or found.get("conclusion") != "failure"
                        or (newest and created(run) and newest - created(run) > timedelta(hours=BASE_WINDOW_HOURS))):
                    raise
                read += 1
                window.append(red(run, found))
    return audit


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    if argv is None:
        argv = sys.argv[1:]
    if argv == ["--write-rollups"]:
        ROLLUPS_FILE.write_text(json.dumps(derive_rollups(), indent=2, sort_keys=True) + "\n")
        return 0
    parser.add_argument("--repo", required=True)
    parser.add_argument("--base", required=True)
    parser.add_argument("--sha", required=True)
    parser.add_argument("--run", type=int, action="append", default=[], help="a failed workflow run on the head")
    parser.add_argument("--check", action="append", default=[], help="a red required check on the head")
    parser.add_argument("--flake-state", help="tap-tests/v1 JSON; TAP_TESTS_STATE=off disables base-flake quarantine")
    args = parser.parse_args(argv)
    try:
        audit = judge(args.repo, args.base, args.sha, args.run, GitHub(), checks=args.check,
                      flake_state=test_reds.load_flake_state(args.flake_state, fetch=True))
    except rate_limited_classes() as error:
        print(f"rate-limited: {error}", file=sys.stderr)
        return 3
    except Infra as error:
        print(f"not excused: infra, not a verdict: {error}", file=sys.stderr)
        return 1
    except (Refused, KeyError, ValueError) as error:
        print(f"not excused: {error}", file=sys.stderr)
        return 1
    print("\n".join(audit))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
