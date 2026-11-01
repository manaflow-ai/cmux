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
error line to compare are never excused. One base red then no longer freezes
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


ESCAPE_FLAG = "--allow-escape-sequences"
UNKNOWN_ESCAPE_FLAG = f"unknown flag: {ESCAPE_FLAG}"
REQUEST_FAILED = "GitHub evidence request failed: "


def escape_flag_unknown(stderr: str) -> bool:
    """Whether an old gh rejected the optional ANSI-output flag itself."""
    lines = (stderr or "").strip().splitlines()
    return bool(lines) and lines[0].strip() == UNKNOWN_ESCAPE_FLAG


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
ROLLUPS_FILE = Path(__file__).with_name("base_red_rollups.json")
WORKFLOWS = Path(__file__).resolve().parents[2] / ".github" / "workflows"
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
# own commit; any other hex id (an artifact, a hash) is compared as it is.
SHA = re.compile(r"\b[0-9a-f]{40}\b|\b((?:commit|sha|tree|revision) `?)[0-9a-f]{7,39}\b")
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


def derive_rollups(workflows: Path = WORKFLOWS) -> dict:
    """The rollups contract (ROLLUPS_FILE) derived from the workflow files; refuses any shape it does not know."""
    import yaml  # noqa: PLC0415 - only deriving the file reads YAML; judging reads the file

    out: dict = {"run": {}, "routed": {}}
    for kind, declared in (("run", RUN_ROLLUPS), ("routed", ROUTED_ROLLUPS)):
        for file, job_id in declared:
            where = f".github/workflows/{file}"
            try:
                doc = yaml.safe_load((workflows / file).read_text())
            except (OSError, yaml.YAMLError) as error:
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


def rollups() -> dict:
    """ROLLUPS_FILE, checked for shape; refused (so no rollup red is excused) when missing or malformed."""
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


def routed_rollup(name: str) -> tuple[dict, str] | None:
    """(the routed rollup check NAME is, the caller prefix it runs under), or None. A routed rollup's workflow is
    only ever called, so its check is '<caller> / <name>' (a bare name is still one, with no prefix)."""
    for rollup, contract in rollups()["routed"].items():
        if name == rollup or name.endswith(" / " + rollup):
            return contract, name[:-len(rollup)]
    return None


def is_aggregate(name: str) -> bool:
    """Whether a check reports other jobs rather than running work itself."""
    return name in rollups()["run"] or routed_rollup(name) is not None


def mask_shas(text: str) -> str:
    return SHA.sub(lambda match: (match.group(1) or "") + "<sha>", text)


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
        if n in skip:
            continue
        if ((ERROR.search(text)
             or (not tests and ("default" in job.get("name", "").lower()
                                or "snapshot" in job.get("name", "").lower())
                 and SUMMARY_FAILURE.search(text)))
                and not GENERIC.search(text) and not WARNING.search(text) and not CRASH_LINE.search(text)
                and not SUCCESS_DIAGNOSTIC.search(text)):
            errors.add(re.sub(r"\d+", "#", mask_shas(text.replace("##[error]", "").strip())))
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
    for page in github.json(f"repos/{repo}/commits/{sha}/check-runs?per_page=100", paginate=True):
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
    found = routed_rollup(name)
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


def validate_run_rollup(name: str, children: list[dict]) -> None:
    """Run rollup NAME (ci-status), red, needs a failed job under it (its needs, ROLLUPS_FILE): a red run whose only
    failed jobs are outside them did not turn it red, so its own verdict did, and nothing here can compare that."""
    under = rollups()["run"][name]["under"]
    if not any(child.get("conclusion") == "failure" and any(matches(m, child.get("name", "")) for m in under.values())
               for child in children):
        raise Refused(f"'{name}': no failed job under its needs ({', '.join(sorted(under))}) to compare with the base")


def head_jobs(repo: str, sha: str, runs: list[int], checks: list[str], github) -> list[dict]:
    jobs: dict[int, dict] = {}
    for run in runs:
        guards = []
        run_rollups = []
        children = []
        for page in github.json(f"repos/{repo}/actions/runs/{run}/jobs?filter=latest&per_page=100", paginate=True):
            for job in page.get("jobs") or []:
                if is_aggregate(job.get("name", "")):
                    if job.get("conclusion") not in ("success", "skipped", "neutral", None):
                        (run_rollups if job.get("name") in rollups()["run"] else guards).append(job)
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
            validate_run_rollup(rollup["name"], children)
    if checks:
        latest = latest_checks(repo, sha, github)
        aggregate_jobs = []
        aggregate_runs = []
        for name in checks:
            if name not in latest:
                raise Refused(f"{name}: has not run on exact head {sha}")
            job = job_for(repo, latest[name], sha, github)
            if is_aggregate(name):
                if name in rollups()["run"]:
                    aggregate_runs.append((name, job["run_id"]))
                    continue
                # The check-run can remain failed while its Actions job has
                # been retried or replaced.  Never discard this exact job and
                # rescan the run: a green/missing aggregate must not allow its
                # child failures to be excused.
                if job.get("conclusion") != "failure":
                    raise Refused(f"'{name}': exact aggregate job is {job.get('conclusion')}, not failure")
                aggregate_jobs.append(job)
            else:
                jobs[job["id"]] = job
        for name, run in aggregate_runs:
            found = head_jobs(repo, sha, [run], [], github)
            if not found:
                raise Refused(f"run {run}: its aggregate check failed with no failed job to compare with the base")
            validate_run_rollup(name, found)
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


class Final(Refused):
    """A refusal no older base verdict can lift: it is judged against the newest verdict alone."""


def compare_window(repo: str, base: str, name: str, head: tuple, head_log: str, window: list,
                   chromium_without_diagnostics: bool) -> str:
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
    verdict = test_reds.classify_any(head_log, [(f"{base} run {run['id']}", text) for run, text, _ in window], name)
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
    if not head_tests:
        compared.append(("errors", head_errors, base_errors))
    for kind, head, seen in compared:
        if missing := sorted(head - seen):
            raise Refused(f"'{name}': {kind} not on {base} {runs}: {'; '.join(missing)[:600]}")
    rows = [f"{crate}: clippy::{lint} {count} > {where}"
            for (crate, lint, where), count in sorted(ratchet_red(head_log)[0].items())] if ratchet else []
    what = ("; ".join(test if on[test] == base_run["id"] else f"{test} (red on run {on[test]})"
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


def judge(repo: str, base: str, sha: str, runs: list[int], github, *, checks: list[str] = ()) -> list[str]:
    """Audit lines for every excused failure; raises Refused on the first that is not."""
    audit: list[str] = []
    base_runs: dict[int, list[dict]] = {}
    base_jobs: dict[int, list[dict]] = {}
    job_reads: dict[int, int] = {}
    jobs = head_jobs(repo, sha, runs, list(checks), github)
    if not jobs:
        # A red run or check with no failed job to show has nothing the base can excuse.
        raise Refused("no failed job found on the head to compare with the base")
    for job in jobs:
        name = job.get("name", "")
        if job.get("conclusion") != "failure":
            raise Refused(f"'{name}' is {job.get('conclusion')}: it has no verdict to compare with the base; re-run it")
        if refused_at_setup(job):
            raise Refused(f"'{name}' was refused at setup by its runner; it gets re-run, never excused")
        head_log = github.log(repo, job)
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
        workflow = github.json(f"repos/{repo}/actions/runs/{job['run_id']}").get("workflow_id")
        if workflow not in base_runs:
            listed = github.json(f"repos/{repo}/actions/workflows/{workflow}/runs?branch={base}&status=completed"
                                 f"&per_page={BASE_RUNS_PAGE}")
            base_runs[workflow] = [run for run in listed.get("workflow_runs") or []
                                   if run.get("event") != "pull_request" and run.get("conclusion") != "skipped"]
        # The newest base run where this job has a verdict decides whether it is red on the base.
        verdicts = base_verdicts(repo, base, workflow, name, github, base_runs, base_jobs, job_reads)
        base_run, base_job = next(verdicts, (None, None))
        if base_run is None:
            raise Refused(f"'{name}': no completed {base} run of its workflow has a verdict for it to compare with "
                          f"(read the {BASE_RUNS_PAGE} newest, up to {BASE_JOB_READS} job lists, "
                          f"and its tip suite runs)")
        if base_job.get("conclusion") != "failure":
            try:
                audit.append(fixed_on_base(repo, base, sha, name, head_log, base_run, github))
            except Refused as why:
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
                audit.append(compare_window(repo, base, name, head, head_log, window, chromium_without_diagnostics))
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
    args = parser.parse_args(argv)
    try:
        audit = judge(args.repo, args.base, args.sha, args.run, GitHub(), checks=args.check)
    except (Refused, KeyError, ValueError) as error:
        print(f"not excused: {error}", file=sys.stderr)
        return 1
    print("\n".join(audit))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
