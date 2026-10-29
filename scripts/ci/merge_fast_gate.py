#!/usr/bin/env python3
"""The fast gate gh-merge-green applies to pull requests into feat-cmux-next.

    merge_fast_gate.py OWNER/REPO NUMBER SHA [--base BRANCH] [--next-covered]
        [--next-workflow FILE --ci-workflow FILE --web-workflow FILE]
        [--timeout SECONDS] [--interval SECONDS]

It waits only for the PR's fast lanes on the exact head, not the full suites:
path routing, the cmux-next fast tier, and the compile of each touched area that
routing started (the Swift canary, the app scheme Debug compile, the web
react-apps-check). The full suites run after the merge, and the culprit bot and
the base sheriff revert or fix forward. A check that already finished red in a
gating family (web, app size, crash) or in a full-gate lane (ci-status, the
Release compile, the swift test) still blocks unless the base has it; one still
running does not. A fast lane that was cancelled, timed out or never started has
no verdict to waive and refuses. God-file, l10n and concurrency lint and risk
evidence are waited for, as in the full gate: a red risk evidence refuses, and a
red lint check is printed as a red that the base comparison or a human --override
can excuse.
gh-merge-green --full keeps the old wait for every check.

The gate keys on check names, so with the workflow files of the exact head it
first refuses when a name it waits for is no longer a job name there.

Each poll is one GraphQL read (`gh pr view --json`), never a REST loop. It
refuses when the head or the base branch changed while it waited.
Prints `waited=<seconds>` and `checked=<names>`, then `red=<name>` for each
completed red that gh-merge-green may still excuse when the base has it.
When the --timeout budget runs out it prints `waited=<seconds>` and a
`waiting=<name> (<state>)` line for each lane not done, so the caller's summary
names them (2026-10-20: a wait that ran out with a lane still QUEUED read
"nothing reported; waited 0m00s"). A rate-limited read refuses at once with the
reset time instead of polling on.
Exit 0: pass (maybe with reds to excuse); 1: refused (the reason on stderr);
3: GitHub rate-limited the read (the reset time on stderr).
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import re
import subprocess
import sys
import time
from pathlib import Path
from typing import Callable

ROUTING = "cmux-next path routing"
FAST_TIER = "cmux-next fast tier"
DEBUG_COMPILE = "cmux app scheme compile (Debug)"
REACT = "react-apps-check"
# cmux-next.yml jobs the gate waits for by name.
NEXT_LANES = (ROUTING, FAST_TIER, "cmux-next Swift canary", DEBUG_COMPILE)
FAST = re.compile(r"^(cmux-next fast tier( \(cargo\))?|cmux-next Swift canary|cmux app scheme compile \(Debug\)|(.* / )?react-apps-check)$")
GATING = re.compile(r"react-apps-check|web status|app[- ]?size|size[- ]cap|crash", re.I)
# The full gate's own lanes on feat-cmux-next. The fast gate does not wait for them,
# but one that already finished red is judged as the full gate judges it.
FULL_LANES = {"ci-status", "cmux-next Release compile (Xcode 26)", "cmux-next swift test"}
KNOWN = {*NEXT_LANES, *FULL_LANES}
LINT = re.compile(r"god[ -]?files?|l10n|locali[sz]ation|concurrency", re.I)
LINT_JOB = "a god-file, l10n or concurrency lint job"
# Always waited for, as in the full gate (#21692). A red lint check goes to
# gh-merge-green like other reds: the base comparison excuses it when the base prints
# every finding too (#22128), or a human waives it with --override. Risk evidence reads
# only the description, so a red one refuses and the risk:waived label is its waiver
# (docs/ci/risk-tiers.md).
WAITED_FOR = re.compile(LINT.pattern + r"|^risk evidence$", re.I)
PASSING = {"SUCCESS", "NEUTRAL", "SKIPPED"}
# Like the full gate's cancelled cmux-next run: nothing ran, so --override has nothing to waive.
NO_VERDICT = {"CANCELLED", "TIMED_OUT", "STARTUP_FAILURE", "STALE"}
WEB_FALLBACK_PREFIXES = ("web/", "webviews/", "config/", "Resources/markdown-viewer/", "workers/")


class Refused(Exception):
    pass


class WaitRanOut(Refused):
    """The --timeout budget ran out with lanes not done; `waiting` names each with its state."""

    def __init__(self, message: str, waited: float, waiting: list[str]):
        super().__init__(message)
        self.waited, self.waiting = waited, waiting


class RateLimited(Refused):
    pass


def _load_rate_limit():
    spec = importlib.util.spec_from_file_location("_merge_fast_gate_rate_limit", Path(__file__).with_name("gh_rate_limit.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


_rate = _load_rate_limit()


def read_limits() -> dict:
    return _rate.read_limits()


def _load_web_change() -> Callable[[str], bool]:
    """ci.yml's web job runs when detect_ci_change_areas.py routes a file to web; use that
    router (this checkout's copy, not the PR's). If it cannot load, every file counts as
    web, and the wait ends when the web caller finishes or skips."""
    path = Path(__file__).with_name("detect_ci_change_areas.py")
    try:
        spec = importlib.util.spec_from_file_location("_merge_fast_gate_change_areas", path)
        module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = module
        spec.loader.exec_module(module)
        return module.is_web_change
    except Exception:
        return lambda _path: True


is_web_change = _load_web_change()


def gh_json(*args: str) -> dict:
    try:
        out = subprocess.run(["gh", *args], capture_output=True, text=True, timeout=60)
    except subprocess.TimeoutExpired:
        raise Refused("reading the pull request took over 60s") from None
    if out.returncode != 0:
        if _rate.is_rate_limited(out.stderr):
            # Every later poll would fail the same way: refuse now and say when the quota resets.
            raise RateLimited(f"GitHub rate-limited the pull request read ({out.stderr.strip()[:200]}); "
                              + _rate.describe(read_limits(), after_limit=True))
        raise Refused(f"cannot read the pull request ({out.stderr.strip()[:200]})")
    return json.loads(out.stdout)


def canonical(name: str) -> str:
    """A job whose name is an expression can report under its raw text, as
    `inputs.dev_daily == true && '...' || 'cmux app scheme compile (Debug)'` did on #21981.
    Such a check is the lane it names."""
    if name in KNOWN:
        return name
    for quoted in re.findall(r"'([^']+)'", name):
        if quoted in KNOWN:
            return quoted
    return name


def latest(rollup: list[dict]) -> dict[str, tuple[str, str]]:
    """name -> (status, conclusion), upper case. The rollup is not ordered by time, so of
    several CheckRuns of one name (a rerun) the latest startedAt wins, then completedAt,
    then list order; one not started yet (no startedAt, not completed) counts as newest."""
    checks: dict[str, tuple[str, str]] = {}
    newest: dict[str, tuple] = {}
    for index, item in enumerate(rollup):
        if item.get("__typename") == "StatusContext" or "context" in item:
            state = (item.get("state") or "").upper()
            checks[item.get("context", "")] = ("COMPLETED" if state not in ("PENDING", "EXPECTED") else "IN_PROGRESS",
                                               {"ERROR": "FAILURE"}.get(state, state))
            continue
        name = canonical(item.get("name", ""))
        status = (item.get("status") or "").upper()
        started = item.get("startedAt") or ("￿" if status != "COMPLETED" else "")
        key = (started, item.get("completedAt") or "", index)
        if name in newest and newest[name] > key:
            continue
        newest[name] = key
        checks[name] = (status, (item.get("conclusion") or "").upper())
    return checks


def evaluate(checks: dict[str, tuple[str, str]], files: list[str], touches_next: bool) -> tuple[list[str], list[str], list[str]]:
    """(fast lanes to wait for, fast lanes seen, completed gating reds). touches_next: the
    change is inside cmux-next.yml's pull_request paths, so a cmux-next run is coming."""
    waiting, seen, reds = [], [], []
    if touches_next and ROUTING not in checks:
        waiting.append(ROUTING)
    for name, (status, conclusion) in sorted(checks.items()):
        if WAITED_FOR.search(name):
            seen.append(name)
            if status != "COMPLETED":
                waiting.append(name)
            elif conclusion not in PASSING and conclusion != "FAILURE" and LINT.search(name):
                raise Refused(f"'{name}' is {conclusion.lower()} on the exact head: no verdict to compare "
                              "with the base or waive with --override; rerun it")
            elif conclusion not in PASSING and not LINT.search(name):
                raise Refused(f"'{name}' is {conclusion.lower()} on the exact head; risk evidence is "
                              "never waived or base-excused")
            elif conclusion not in PASSING:
                reds.append(name)
            continue
        fast = name == ROUTING or bool(FAST.match(name))
        if fast:
            if conclusion == "SKIPPED":
                # On a PR, cmux-next.yml skips the fast tier only when push-head-preflight
                # is not current (a runner failure or its timeout): no verdict, not a pass.
                if name == FAST_TIER and touches_next:
                    raise Refused(f"'{name}' was skipped on the exact head: no verdict to waive, "
                                  "and --override cannot bypass that; rerun it")
                continue
            seen.append(name)
            if status != "COMPLETED":
                waiting.append(name)
            elif conclusion in NO_VERDICT:
                raise Refused(f"'{name}' is {conclusion.lower()} on the exact head: no verdict to waive, "
                              "and --override cannot bypass that; rerun it")
            elif conclusion not in PASSING:
                reds.append(name)
        elif status == "COMPLETED" and conclusion not in PASSING and (GATING.search(name) or name in FULL_LANES):
            reds.append(name)
    routed = checks.get(ROUTING, ("", ""))[0] == "COMPLETED"
    if touches_next and routed and FAST_TIER not in checks:
        waiting.append(FAST_TIER)
    # react-apps-check runs behind ci.yml's web caller job: wait for it when the change
    # routes to web, or when the caller is already running. The caller finishing without
    # one means none is coming: a red caller is a red.
    status, conclusion = checks.get("web", ("", ""))
    if not any(n.endswith(REACT) for n in checks) and (
            (status and status != "COMPLETED") or any(is_web_change(f) for f in files)):
        if status != "COMPLETED":
            waiting.append(REACT)
        elif conclusion not in PASSING:
            reds.append("web")
    return waiting, seen, reds


def job_names(text: str) -> list[tuple[str, list[str], str]]:
    """(job id, names it can report under, uses) for each job of a workflow, by
    indentation (the workflows are ours). An expression name yields its quoted strings."""
    jobs: list[tuple[str, list[str], str]] = []
    in_jobs = False
    current = None
    for line in (text or "").splitlines():
        if re.match(r"^jobs:\s*$", line):
            in_jobs = True
            continue
        if not in_jobs or not line.strip() or line.lstrip().startswith("#"):
            continue
        if not line.startswith(" "):
            break
        job = re.match(r"^  ([A-Za-z0-9_-]+):\s*$", line)
        if job:
            current = [job.group(1), [job.group(1)], ""]
            jobs.append(current)
            continue
        if current is None:
            continue
        field = re.match(r"^    (name|uses):\s*(.+?)\s*$", line)
        if not field:
            continue
        value = field.group(2)
        if field.group(1) == "uses":
            current[2] = value
        elif "${{" in value:
            current[1] = re.findall(r"'([^']+)'", value)
        else:
            current[1] = [value.strip("\"'")]
    return [tuple(job) for job in jobs]


def missing_job_names(next_workflow: str, ci_workflow: str | None, web_workflow: str | None) -> list[str]:
    """The names the gate waits for that no job reports under on this head."""
    names = {name for _, job, _ in job_names(next_workflow) for name in job}
    missing = [lane for lane in NEXT_LANES if lane not in names]
    if not any(LINT.search(name) for name in names):
        missing.append(LINT_JOB)
    if ci_workflow is not None or web_workflow is not None:
        caller = any("web" in job and uses.endswith("ci-web.yml") for _, job, uses in job_names(ci_workflow or ""))
        react = any(REACT in job for _, job, _ in job_names(web_workflow or ""))
        if not (caller and react):
            missing.append(f"web / {REACT}")
    return missing


def state_of(name: str, checks: dict[str, tuple[str, str]]) -> str:
    """`name (queued)`: a lane the gate still waits for, with its state on the head."""
    status = checks.get(name, ("", ""))[0] or next(
        (status for other, (status, _) in checks.items() if other.endswith(f" / {name}")), "")
    return f"{name} ({status.lower() if status else 'not reported yet'})"


def run(repo: str, number: str, sha: str, timeout: float, interval: float, touches_next: bool,
        read: Callable[..., dict] | None = None, clock: Callable[[], float] = time.monotonic,
        sleep: Callable[[float], None] = time.sleep, base: str | None = None,
        files: list[str] | None = None) -> tuple[float, list[str], list[str]]:
    """files: the caller's full changed-file list; `gh pr view --json files` stops at 100."""
    read = read or gh_json
    start = clock()
    while True:
        pr = read("pr", "view", number, "--repo", repo, "--json", "headRefOid,baseRefName,statusCheckRollup,files")
        if pr.get("headRefOid") != sha:
            raise Refused(f"the head moved to {pr.get('headRefOid')} while waiting on {sha}")
        if base is not None and pr.get("baseRefName") != base:
            raise Refused(f"the base changed to {pr.get('baseRefName')} (from {base}) while waiting on {sha}")
        changed = files if files is not None else [f.get("path", "") for f in pr.get("files") or []]
        checks = latest(pr.get("statusCheckRollup") or [])
        waiting, seen, reds = evaluate(checks, changed, touches_next)
        if not waiting:
            return clock() - start, seen, reds
        if clock() - start >= timeout:
            states = [state_of(name, checks) for name in waiting]
            waited = clock() - start
            raise WaitRanOut(f"the --wait budget of {int(timeout)}s ran out after {int(waited)}s, "
                             f"still waiting on {', '.join(states)}", waited, states)
        sleep(interval)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("repo")
    parser.add_argument("number")
    parser.add_argument("sha")
    parser.add_argument("--base", help="the base branch the gate was chosen for; a change refuses")
    parser.add_argument("--timeout", type=float, default=2400)
    parser.add_argument("--interval", type=float, default=30)
    parser.add_argument("--next-covered", action="store_true",
                        help="the change is inside cmux-next.yml's pull_request paths")
    parser.add_argument("--next-workflow", help="cmux-next.yml of the exact head")
    parser.add_argument("--ci-workflow", help="ci.yml of the exact head")
    parser.add_argument("--web-workflow", help="ci-web.yml of the exact head")
    parser.add_argument("--files-from", help="the full changed-file list, one path per line")
    args = parser.parse_args(argv)
    try:
        if args.next_workflow is not None:
            read_text = lambda path: Path(path).read_text() if path else None  # noqa: E731
            missing = missing_job_names(read_text(args.next_workflow), read_text(args.ci_workflow),
                                        read_text(args.web_workflow))
            if missing:
                raise Refused(f"the fast gate keys on {', '.join(missing)}, which no job in the head's "
                              "cmux-next.yml, ci.yml or ci-web.yml reports as; update merge_fast_gate.py or merge with --full")
        files = None
        if args.files_from is not None:
            files = [line for line in Path(args.files_from).read_text().splitlines() if line]
        waited, seen, reds = run(args.repo, args.number, args.sha, args.timeout, args.interval, args.next_covered,
                                 base=args.base, files=files)
    except RateLimited as error:
        print(f"rate-limited: {error}", file=sys.stderr)
        return 3
    except WaitRanOut as error:
        print(f"waited={int(error.waited)}")
        for name in error.waiting:
            print(f"waiting={name}")
        print(error, file=sys.stderr)
        return 1
    except Refused as error:
        print(error, file=sys.stderr)
        return 1
    print(f"waited={int(waited)}")
    print("checked=" + ", ".join(seen))
    for name in reds:
        print(f"red={name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
