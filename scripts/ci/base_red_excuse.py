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

A compile check that gave no verdict (the build fleet's "no result", "No build-fleet verdict") is never a
base red, even with the base's identical line: nothing compiled the head. It is set aside only when the
same head has a real compile pass (a green Mac Release compile or a cmux-next/compile success). Error
lines are compared with commit shas masked, so a real red that names each run's own commit still matches.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import re
import sys
from pathlib import Path

_spec = importlib.util.spec_from_file_location("main_fix_evidence", Path(__file__).with_name("main_fix_evidence.py"))
_evidence = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_evidence)
Refused, job_for, latest_checks = _evidence.Refused, _evidence.job_for, _evidence.latest_checks


# gh 2.6x and later refuse `gh api` output holding terminal escape sequences (a job log's ANSI colours)
# unless given ESCAPE_FLAG. A gh too old to know the flag (Ubuntu 24.04's 2.45) refuses the flag itself,
# reads nothing, and says exactly UNKNOWN_ESCAPE_FLAG on its first stderr line; that gh also prints escape
# sequences unasked, so that one answer, and no other, is asked again without the flag. Any other failure
# (HTTP, auth, quota, timeout, a different unknown flag) still refuses: 2026-10-30, every job log read on
# a gh 2.45 host failed after #28397 added the flag, so no red there could be compared with the base.
ESCAPE_FLAG = "--allow-escape-sequences"
UNKNOWN_ESCAPE_FLAG = f"unknown flag: {ESCAPE_FLAG}"
REQUEST_FAILED = "GitHub evidence request failed: "  # main_fix_evidence.GitHub.run's prefix to gh's stderr


def escape_flag_unknown(stderr: str) -> bool:
    """True only when gh's STDERR is an old gh's refusal of ESCAPE_FLAG itself (its first line, exactly)."""
    lines = (stderr or "").strip().splitlines()
    return bool(lines) and lines[0].strip() == UNKNOWN_ESCAPE_FLAG


class GitHub(_evidence.GitHub):
    """GitHub client for red attribution, including logs of finished jobs in live runs."""

    def log(self, repo: str, job: dict) -> str:
        # `gh run view --log` waits for every job in the run. The Actions job
        # endpoint serves a finished job while sibling jobs remain queued.
        # gh refuses to print a log holding escape sequences (ANSI colours) unless asked;
        # a gh too old to know the flag is asked again without it (escape_flag_unknown).
        route = f"repos/{repo}/actions/jobs/{job['id']}/logs"
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
TIP_SUITE_JOB_READS = 6


def suite_jobs(run: dict) -> frozenset[str] | None:
    """The jobs a base run's suite can carry, or None for a run of no known suite (a push, a hand dispatch)."""
    title = run.get("display_title") or ""
    return next((jobs for prefix, jobs in SUITES.items() if title.startswith(prefix)), None)


# The jobs some suite above is the base verdict for. Only these are ever skipped: every other job (checks,
# web bundles, the placement jobs) may run in any suite, so a suite run's verdict for it always counts.
SUITE_JOBS = frozenset().union(*SUITES.values())


def never_carries(run: dict, name: str) -> bool:
    """Whether RUN's suite never runs job NAME, so it has no verdict for it to read."""
    jobs = suite_jobs(run)
    return name in SUITE_JOBS and jobs is not None and name not in jobs


def tested_sha(run: dict) -> str:
    """The commit a cmux-next.yml run tested: the sha its name ends in (a same-tree run tests it after the
    branch moved on), else its head_sha."""
    match = re.search(r" · ([0-9a-f]{40})$", run.get("display_title") or "")
    return match.group(1) if match else str(run.get("head_sha") or "")


ERROR = re.compile(r"##\[error\]|\berror:")
WARNING = re.compile(r"##\[warning\]|\bwarning:")
# Summaries carry counts, and a test's own lines already name it.
GENERIC = re.compile(r"Process completed with exit code|red tests?:|✘ Test |Test Case '|\.\.\. FAILED$")
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
        found.append(STAMP.sub("", text).strip())
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
        if ERROR.search(text) and not GENERIC.search(text) and not WARNING.search(text) and not CRASH_LINE.search(text):
            errors.add(re.sub(r"\d+", "#", mask_shas(text.replace("##[error]", "").strip())))
    return steps, tests, errors


def no_verdict(log: str) -> str | None:
    """The line where a compile check says it gave no verdict, if it does."""
    return next((text for text in lines_of(log) if NO_VERDICT.match(text)), None)


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


def tip_suite_verdict(repo: str, base: str, workflow, name: str, github,
                      base_jobs: dict[int, list[dict]]) -> tuple[dict | None, dict | None]:
    """The newest completed suite run of BASE with a verdict for job NAME, and that job."""
    listed = github.json(f"repos/{repo}/actions/workflows/{workflow}/runs?branch={base}&event=workflow_dispatch"
                         f"&status=completed&per_page={BASE_RUNS_PAGE}")
    candidates = [run for run in listed.get("workflow_runs") or []
                  if run.get("conclusion") != "skipped" and not never_carries(run, name)]
    for run in candidates[:TIP_SUITE_JOB_READS]:
        if run["id"] not in base_jobs:
            base_jobs[run["id"]] = [found for page in github.json(
                f"repos/{repo}/actions/runs/{run['id']}/jobs?filter=latest&per_page=100", paginate=True)
                for found in page.get("jobs") or []]
        found = next((found for found in base_jobs[run["id"]] if found.get("name") == name), None)
        if found is not None and found.get("conclusion") in VERDICTS and not refused_at_setup(found):
            return run, found
    return None, None


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
        if name in NO_VERDICT_JOBS and (said := no_verdict(head_log)) is not None:
            proof = compile_pass_at(repo, sha, github)
            if proof is None:
                raise Refused(f"'{name}' gave no compile verdict ({said[:300]}) and nothing else compiled {sha}: "
                              "a no-verdict compile is never a base red; re-run it once the fleet answers")
            audit.append(f"ignored '{name}': it gave no compile verdict, but {proof} compiled {sha} and passed")
            continue
        own = test_reds.read(head_log)
        if test_reds.is_test_red(own, name) and (own.crashes or own.truncated):
            raise Refused(f"'{name}': " + "; ".join(own.crashes + own.truncated[:1])[:800]
                          + " (a crash or a cut-short run is never a base red)")
        workflow = github.json(f"repos/{repo}/actions/runs/{job['run_id']}").get("workflow_id")
        if workflow not in base_runs:
            listed = github.json(f"repos/{repo}/actions/workflows/{workflow}/runs?branch={base}&status=completed"
                                 f"&per_page={BASE_RUNS_PAGE}")
            base_runs[workflow] = [run for run in listed.get("workflow_runs") or []
                                   if run.get("event") != "pull_request" and run.get("conclusion") != "skipped"]
        # The newest base run where this job has a verdict decides: a base push
        # run's Mac job is often cancelled by the next push, or refused by a mini.
        base_run = base_job = None
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
                base_run, base_job = candidate_run, found
                break
        if base_run is None and name in SUITE_JOBS:
            base_run, base_job = tip_suite_verdict(repo, base, workflow, name, github, base_jobs)
        if base_run is None:
            raise Refused(f"'{name}': no completed {base} run of its workflow has a verdict for it to compare with "
                          f"(read the {BASE_RUNS_PAGE} newest, up to {BASE_JOB_READS} job lists, "
                          f"and its tip suite runs)")
        if base_job.get("conclusion") != "failure":
            raise Refused(f"'{name}' is not red on {base} run {base_run['id']} ({base_job.get('conclusion')}); "
                          "fix it on this head")
        head_steps, head_tests, head_errors = signature(job, head_log)
        head_crash = crash_signals(head_log)
        if not head_tests and not head_errors and not head_crash:
            raise Refused(f"'{name}': no failing test or error line to match; nothing to compare with the base")
        base_log = github.log(repo, base_job)
        base_steps, base_tests, base_errors = signature(base_job, base_log)
        verdict = test_reds.classify(head_log, base_log, name, f"{base} run {base_run['id']}")
        if verdict is not None and verdict.own:
            raise Refused(f"'{name}': " + "; ".join(verdict.reasons)[:800])
        # Not a test job (a compile or tool that died on a signal): the base must have died the same way.
        if missing := sorted(head_crash - crash_signals(base_log)):
            raise Refused(f"'{name}': the process died on signal {', '.join(missing)}, "
                          f"and {base} run {base_run['id']} did not")
        # The ratchet's error line names the run's packages, not its red: its rows are compared instead (RATCHET_SCOPE).
        ratchet = {error for error in head_errors if RATCHET_SCOPE.match(error)}
        if ratchet:
            try:
                unmatched = ratchet_unmatched(head_log, base_log)
            except Refused as error:
                raise Refused(f"'{name}': {error}") from None
            if unmatched:
                raise Refused(f"'{name}': panic ratchet failures not on {base} run {base_run['id']}: "
                              f"{'; '.join(unmatched)[:600]}")
            head_errors = head_errors - ratchet
        compared = [("failed steps", head_steps, base_steps), ("failing tests", head_tests, base_tests)]
        if not head_tests:
            compared.append(("errors", head_errors, base_errors))
        for kind, head, seen in compared:
            if missing := sorted(head - seen):
                raise Refused(f"'{name}': {kind} not on {base} run {base_run['id']}: {'; '.join(missing)[:600]}")
        rows = [f"{crate}: clippy::{lint} {count} > {where}"
                for (crate, lint, where), count in sorted(ratchet_red(head_log)[0].items())] if ratchet else []
        what = "; ".join(sorted(head_tests)) or "; ".join(rows + sorted(head_errors))
        url = base_run.get("html_url") or f"https://github.com/{repo}/actions/runs/{base_run['id']}"
        # The base verdict is the newest one, not necessarily the base tip's: the base tier runs at most
        # once every 15 minutes, so name the commit and time it is from.
        at = f" at {tested_sha(base_run)[:10]}" if tested_sha(base_run) else ""
        when = f", {base_run['created_at']}" if base_run.get("created_at") else ""
        audit.append(f"excused '{name}': {base} run {base_run['id']}{at} (the newest {base} verdict for it{when}) "
                     f"fails the same way ({url}): {what[:400]}")
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
