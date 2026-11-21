#!/usr/bin/env python3
"""The post-merge batch tier: the base's deferred checks run on the clock, not once per merge.

RFD 0023 (cmuxterm-hq docs/rfd/0023-ci-10x.md), Leo's third direction: "everything else runs
once post-merge, batched". About every two hours (the window is one variable,
vars.NEXT_POST_MERGE_WINDOW_MINUTES, default 120) the newest feat-cmux-next tip gets one run of
every suite in .github/post-merge-batch.json, covering every squash commit since the last tested
tip. A job that was green on the last tip where it ran and is red now is bisected over the
covered commits, running only that job, and the culprit gets a revert pull request through
normal landing (never merged here).

Subcommands (each run by .github/workflows/cmux-next-post-merge.yml, except tick):

  tick    main's schedule shim (cmux-next-post-merge-dispatch.yml) runs this every 30 min:
          "is there an untested tip?" in two API calls. It dispatches a batch run when the tip
          is not the newest batch run's commit, no batch run is in flight, and the newest one
          started at least a window ago. Nothing waits or loops; a skipped tick costs seconds.
  plan    which suites this run calls: on a batch run, every suite whose paths the commits since
          the last batch run touched (all of them when there is none); on a probe, the one suite.
  judge   after the suites: on a batch run, each red job that was green on the newest earlier
          batch run where it ran starts a bisect (first a probe on this commit, which a flake
          fails to repeat); on a probe run, the next probe, or the culprit.
  revert  opens the revert pull request for a culprit (the workflow's last step).

The bisect state travels in the probe run's inputs (suite, job, sha, good, bad), so a chain of
probe runs needs no store: each probe's judge dispatches the next. Probes of a range of N
commits take about log2(N) runs of one job; a range of one commit needs none.
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import os
import re
import subprocess
import sys
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MANIFEST = ROOT / ".github" / "post-merge-batch.json"
WORKFLOW = "cmux-next-post-merge.yml"
WEB_WORKFLOW = "cmux-next-web.yml"  # its coalescing tick (web_tick)
WEB_TICK_BRANCH = "feat-cmux-next"
DEFAULT_WINDOW_MINUTES = 120
# A batch run's run-name starts with this; a probe's with PROBE (the workflow's run-name).
BATCH = "batch"
PROBE = "probe"
# Runs read back to find the last batch run where a job ran (one page; about 2.5 days at 12 a day,
# plus probes).
RUNS_PAGE = 60
# At most this many new reds start a bisect from one batch run; the rest are named only.
MAX_CHAINS = 4
# A probe run with no verdict (cancelled, runner lost) is tried again this many times.
MAX_PROBE_RETRIES = 1
SHA_RE = re.compile(r"^[0-9a-f]{40}$")
PR_RE = re.compile(r"\(#(\d+)\)\s*$")
# Core teammates (cmuxterm-hq culprit_revert's TEAMMATE_CORE_TEAM, minus Leo, whose login his agents also merge
# under). A revert of their merge opens held: no agent lands, labels or closes a teammate's PR, so the revert is
# theirs to land or close (hq#16262).
TEAMMATES = frozenset({"austinywang", "azooz2003-bit", "lawrencecchen", "lucasr1b"})
TEAMMATE_HOLD = ("HOLD: {login}'s merge. This revert is ready for {login} to land or close; no agent merges it "
                 "(a teammate's PR is never merged, labelled or closed by an agent).")


# ---------------------------------------------------------------------------- GitHub and git


# The repository's workflow token shares one rate limit with every workflow in the repo; when it is
# spent, a call waits for the reset instead of failing the job, up to this many seconds in all
# (--api-wait-seconds). Batch run 44878722147's judge died on it (2026-11-21).
API_WAIT_BUDGET = {"seconds": 0.0}
RATE_LIMITED = re.compile(r"rate limit|HTTP 429|secondary rate", re.I)


def rate_limit_wait(now: float, reset: float | None, left: float) -> float:
    """Seconds to sleep before retrying a rate-limited call: until the reset plus a little, at
    least 15 s, never more than the budget left (0 = give up)."""
    if left <= 0:
        return 0.0
    want = (reset - now + 5) if reset else 60.0
    return max(0.0, min(max(want, 15.0), left))


def _core_reset() -> float | None:
    """When the token's core limit resets (gh api rate_limit is not counted against it)."""
    out = subprocess.run(["gh", "api", "rate_limit"], capture_output=True, text=True)
    try:
        return float(json.loads(out.stdout)["resources"]["core"]["reset"])
    except (ValueError, KeyError, TypeError):
        return None


def read_tokens() -> list[str]:
    """Tokens a read may use, in order: the route App's (GH_READ_TOKEN, its own budget) first, then the job's
    GH_TOKEN, whose budget every workflow in the repository shares and which is often spent."""
    return [t for t in (os.environ.get("GH_READ_TOKEN", ""), os.environ.get("GH_TOKEN", "")) if t] or [""]


def gh_api(path: str, *, method: str = "GET", fields: dict | None = None, run=subprocess.run, sleep=time.sleep, clock=time.time, reset_at=_core_reset, tokens=None) -> object:
    """One GitHub API call through gh. A read tries each of read_tokens() in turn when one is rate limited; a
    write uses GH_TOKEN. Fields go as JSON on stdin. Once every token is rate limited it waits for the reset and
    retries within API_WAIT_BUDGET."""
    argv = ["gh", "api", "-X", method, path]
    data = None
    if fields is not None:
        argv += ["--input", "-"]
        data = json.dumps(fields)
    if tokens is None:
        tokens = read_tokens() if method == "GET" else [os.environ.get("GH_TOKEN", "")]
    while True:
        for i, token in enumerate(tokens):
            env = {**os.environ, "GH_TOKEN": token} if token else None
            out = run(argv, input=data, capture_output=True, text=True, env=env)
            if not out.returncode:
                return json.loads(out.stdout) if out.stdout.strip() else None
            text = (out.stderr or out.stdout).strip()
            if not RATE_LIMITED.search(text):
                raise RuntimeError(f"gh api {method} {path}: {text[-400:]}")
            if i + 1 < len(tokens):
                print(f"gh api {method} {path}: rate limited; trying the next token", file=sys.stderr)
        pause = rate_limit_wait(clock(), reset_at(), API_WAIT_BUDGET["seconds"])
        if pause <= 0:
            raise RuntimeError(f"gh api {method} {path}: {text[-400:]}")
        print(f"gh api {method} {path}: rate limited; retrying in {pause:.0f} s", file=sys.stderr)
        API_WAIT_BUDGET["seconds"] -= pause
        sleep(pause)


def git(*argv: str, cwd: Path | None = None) -> str:
    out = subprocess.run(["git", *argv], cwd=cwd or ROOT, capture_output=True, text=True)
    if out.returncode:
        raise RuntimeError(f"git {' '.join(argv[:3])}: {(out.stderr or out.stdout).strip()[-400:]}")
    return out.stdout


def start_branch(repo: str, branch: str, sha: str, api=gh_api) -> None:
    """Creates branch at sha, a commit GitHub already has, through the REST API. The revert then reaches it as an
    update, which GitHub checks for workflow changes over that one commit; a git push that creates the branch is
    checked against the whole branch and timed out every time on this repository (drill-5 run 44897813534,
    drill-6 run 44906887225, four tries each). A branch left by an earlier try is reused."""
    try:
        api(f"repos/{repo}/git/refs", method="POST", fields={"ref": f"refs/heads/{branch}", "sha": sha})
    except RuntimeError as error:
        if "already exists" not in str(error):
            raise


def push_branch(url: str, refspec: str, run=git, sleep=time.sleep, waits: tuple[int, ...] = (15, 45, 90)) -> None:
    """Pushes refspec, retrying GitHub's own timeout. A token with no `workflows` scope makes GitHub check
    whether the push changes a workflow file, and that check can time out on this repository ("Unable to
    determine if workflow can be created or updated due to timeout"; drill-5's revert, run 44897813534).
    Any other refusal raises at once."""
    for wait in (*waits, None):
        try:
            run("push", "--quiet", url, refspec)
            return
        except RuntimeError as error:
            if wait is None or "due to timeout" not in str(error):
                raise
            sleep(wait)


def first_parent_range(good: str, bad: str, *, cwd: Path | None = None) -> list[str]:
    """The commits after good up to bad, oldest first, along the branch's first parents."""
    out = git("rev-list", "--first-parent", "--reverse", f"{good}..{bad}", cwd=cwd)
    return [line for line in out.split() if SHA_RE.match(line)]


def changed_files(base: str, head: str, *, cwd: Path | None = None) -> list[str]:
    return [line for line in git("diff", "--no-renames", "--name-only", base, head, cwd=cwd).splitlines() if line]


# ---------------------------------------------------------------------------- the manifest


@dataclass
class Suite:
    key: str
    workflow: str
    paths: list[str]
    jobs: dict[str, str] = field(default_factory=dict)  # job id -> display name

    def reached(self, files: list[str]) -> bool:
        if not self.paths:
            return True
        return any(fnmatch.fnmatchcase(f, p) or (p.endswith("/**") and f.startswith(p[:-2])) for f in files for p in self.paths)

    def job_id(self, display: str) -> str:
        """The `only` value for a red job's display name (its name inside the suite; a matrix leg's
        name is the job's name and its matrix values in parentheses). Empty: run the whole suite."""
        for job_id, name in self.jobs.items():
            if display == name or display.startswith(name + " ("):
                return job_id
        return ""


def load_manifest(path: Path = MANIFEST) -> dict[str, Suite]:
    data = json.loads(path.read_text())
    return {
        key: Suite(key=key, workflow=spec["workflow"], paths=list(spec.get("paths") or []), jobs=dict(spec.get("jobs") or {}))
        for key, spec in data["suites"].items()
    }


# ---------------------------------------------------------------------------- runs


def is_batch(run: dict) -> bool:
    return (run.get("display_title") or run.get("name") or "").split(" ", 1)[0] == BATCH


def list_runs(repo: str, branch: str, api=gh_api) -> list[dict]:
    """This workflow's runs on branch, newest first (one page)."""
    data = api(f"repos/{repo}/actions/workflows/{WORKFLOW}/runs?branch={branch}&per_page={RUNS_PAGE}")
    runs = list((data or {}).get("workflow_runs") or [])
    runs.sort(key=lambda r: (r.get("created_at") or "", r.get("id") or 0), reverse=True)
    return runs


def run_jobs(repo: str, run_id: int, api=gh_api) -> list[dict]:
    jobs: list[dict] = []
    page = 1
    while True:
        data = api(f"repos/{repo}/actions/runs/{run_id}/jobs?per_page=100&page={page}") or {}
        batch = list(data.get("jobs") or [])
        jobs += batch
        if len(batch) < 100 or page >= 5:
            return jobs
        page += 1


def suite_verdicts(jobs: list[dict], suites: dict[str, Suite]) -> dict[str, tuple[str, str]]:
    """The finished suite jobs of a run: full job name -> (suite key, conclusion). A called
    workflow's job is named '<caller job name> / <its own name>'; the caller job's name is the
    suite key."""
    out: dict[str, tuple[str, str]] = {}
    for job in jobs:
        name = job.get("name") or ""
        head, sep, _ = name.partition(" / ")
        if not sep or head not in suites:
            continue
        if job.get("status") != "completed":
            continue
        out[name] = (head, job.get("conclusion") or "")
    return out


def parse_time(value: str) -> datetime:
    return datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)


# ---------------------------------------------------------------------------- tick


def tick_decision(tip: str, runs: list[dict], now: datetime, window_minutes: int) -> tuple[str, str]:
    """(action, reason): action is 'dispatch' or 'skip'."""
    batches = [r for r in runs if is_batch(r)]
    live = [r for r in batches if r.get("status") != "completed"]
    if live:
        return "skip", f"batch run {live[0].get('id')} is {live[0].get('status')} on {str(live[0].get('head_sha'))[:11]}"
    if not batches:
        return "dispatch", "no batch run yet"
    newest = batches[0]
    if newest.get("head_sha") == tip:
        return "skip", f"tip {tip[:11]} is tested (run {newest.get('id')})"
    age = (now - parse_time(newest["created_at"])).total_seconds() / 60
    if age < window_minutes:
        return "skip", f"last batch run {newest.get('id')} started {age:.0f} min ago, window {window_minutes} min"
    return "dispatch", f"tip {tip[:11]} is untested; last batch run {newest.get('id')} on {str(newest.get('head_sha'))[:11]}, {age:.0f} min ago"


def window_minutes(value: str | None) -> int:
    try:
        minutes = int(str(value or "").strip())
    except ValueError:
        return DEFAULT_WINDOW_MINUTES
    return minutes if minutes > 0 else DEFAULT_WINDOW_MINUTES


def cmd_tick(args: argparse.Namespace) -> int:
    # A tick that cannot read GitHub (a spent rate limit, a 5xx) skips: the next tick, 30 min on, asks again, and a
    # red scheduled run would only pile up while the quota is drained.
    try:
        return tick(args)
    except RuntimeError as err:
        print(f"::warning::tick skipped: {err}")
        return 0


def web_tick(args: argparse.Namespace) -> None:
    """Dispatches cmux-next-web.yml's coalescing tick on the branch tip: its coalesce job decides in seconds, running
    the web checks only when their 120-minute window has passed and the tip is not covered, so a quiet tail's pushes
    (which yielded inside the window) are checked without any job sleeping on a runner (web_coalesce.py wait)."""
    if args.branch != WEB_TICK_BRANCH:
        return
    print(f"web tick: dispatching {WEB_WORKFLOW} on {args.branch}")
    if not args.dry_run:
        gh_api(f"repos/{args.repo}/actions/workflows/{WEB_WORKFLOW}/dispatches", method="POST",
               fields={"ref": args.branch, "inputs": {"tick": "true"}})


def tick(args: argparse.Namespace) -> int:
    try:
        web_tick(args)
    except RuntimeError as err:  # its own failure never skips the batch tick below
        print(f"::warning::web tick skipped: {err}")
    tip = gh_api(f"repos/{args.repo}/commits/{args.branch}")["sha"]
    runs = list_runs(args.repo, args.branch)
    action, reason = tick_decision(tip, runs, datetime.now(timezone.utc), window_minutes(args.window_minutes))
    print(f"{action}: {reason}")
    if action == "dispatch" and not args.dry_run:
        gh_api(
            f"repos/{args.repo}/actions/workflows/{WORKFLOW}/dispatches",
            method="POST",
            fields={"ref": args.branch, "inputs": {"mode": "batch", "reason": "tick"}},
        )
    return 0


# ---------------------------------------------------------------------------- plan


def plan_batch(sha: str, runs: list[dict], suites: dict[str, Suite], files_since, judged=lambda run_id: True) -> dict:
    """The suites a batch run calls: every one the commits since the newest earlier batch run reach.
    Only a run whose judge succeeded counts: one whose plan died (drill run 44881749105, rate limit)
    tested nothing, and planning past it skipped the suites its commits reached."""
    earlier = [r for r in runs if is_batch(r) and r.get("status") == "completed" and r.get("head_sha") != sha]
    tested = next((r for r in earlier if judged(r["id"])), None)
    base = tested["head_sha"] if tested else ""
    files = files_since(base) if base else None
    picked = [key for key, suite in suites.items() if files is None or suite.reached(files)]
    return {"base": base, "suites": picked, "files": None if files is None else len(files)}


def write_outputs(path: str | None, values: dict[str, str]) -> None:
    if not path:
        return
    with open(path, "a") as out:
        for key, value in values.items():
            out.write(f"{key}={value}\n")


def summary(path: str | None, text: str) -> None:
    print(text)
    if path:
        with open(path, "a") as out:
            out.write(text + "\n")


def cmd_plan(args: argparse.Namespace) -> int:
    suites = load_manifest(Path(args.manifest))
    if args.mode == PROBE:
        if args.suite not in suites or not SHA_RE.match(args.probe_sha or ""):
            raise SystemExit(f"probe needs a known suite and a commit sha (got {args.suite!r}, {args.probe_sha!r})")
        write_outputs(args.github_output, {"suites": f" {args.suite} ", "sha": args.probe_sha, "only": args.only or "", "base": ""})
        summary(args.summary, f"Probe: `{args.suite}` job `{args.only or '(all)'}` at `{args.probe_sha}`.")
        return 0
    def judged(run_id: int) -> bool:
        return any(j.get("name") == "judge" and j.get("conclusion") == "success" for j in run_jobs(args.repo, run_id))

    try:
        plan = plan_batch(args.sha, list_runs(args.repo, args.branch), suites, lambda base: changed_files(base, args.sha), judged)
    except RuntimeError as err:
        # Past the wait budget the runs are unreadable: run every suite rather than none, so the
        # tip is still tested; the next batch's judge compares against this run as usual.
        print(f"plan: earlier batch runs unreadable, running every suite: {err}", file=sys.stderr)
        summary(args.summary, "- Earlier batch runs could not be read (rate limit): every suite runs.")
        plan = plan_batch(args.sha, [], suites, lambda base: [])
    write_outputs(
        args.github_output,
        {"suites": " " + " ".join(plan["suites"]) + " ", "sha": args.sha, "only": "", "base": plan["base"]},
    )
    covered = f"since `{plan['base'][:11]}` ({plan['files']} files changed)" if plan["base"] else "with no earlier batch run (every suite)"
    summary(args.summary, f"Batch on `{args.sha[:11]}` {covered}: {', '.join(plan['suites']) or 'no suite reached'}.")
    return 0


# ---------------------------------------------------------------------------- judge


@dataclass
class Probe:
    suite: str
    job: str  # the red job's full name in a batch run ('<suite> / <name>')
    only: str
    sha: str
    good: str
    bad: str  # empty: the first probe, which confirms the red on the batch's own commit
    origin: str  # the batch run that found the red
    tries: int = 0

    def inputs(self) -> dict[str, str]:
        return {
            "mode": PROBE,
            "suite": self.suite,
            "job": self.job,
            "only": self.only,
            "sha": self.sha,
            "good": self.good,
            "bad": self.bad,
            "origin": self.origin,
            "tries": str(self.tries),
        }


def new_reds(sha: str, verdicts: dict[str, tuple[str, str]], runs: list[dict], jobs_of) -> tuple[list[tuple[str, str, str]], list[str]]:
    """Red jobs of this batch run that were green on the newest earlier batch run where they
    finished: (job name, suite, good sha). Also the notes for the reds that are not new.
    jobs_of(run id) gives that run's verdicts, or (verdicts, judged): a red on a run whose judge
    job did not succeed counts as no verdict, so it is still bisected later."""
    reds = [name for name, (_, conclusion) in sorted(verdicts.items()) if conclusion == "failure"]
    earlier = [r for r in runs if is_batch(r) and r.get("status") == "completed" and r.get("head_sha") != sha]
    found: list[tuple[str, str, str]] = []
    notes: list[str] = []
    cache: dict[int, dict[str, tuple[str, str]]] = {}
    for name in reds:
        suite = verdicts[name][0]
        last = None
        for run in earlier:
            if run["id"] not in cache:
                cache[run["id"]] = jobs_of(run["id"])
            got = cache[run["id"]]
            judged = True
            if isinstance(got, tuple):
                got, judged = got
            before = got.get(name)
            # A red on a run whose judge never finished was never bisected: look past it.
            if before and before[1] == "failure" and not judged:
                continue
            if before and before[1] in ("success", "failure"):
                last = (run, before[1])
                break
        if last is None:
            notes.append(f"`{name}` is red with no earlier batch verdict: no bisect.")
        elif last[1] == "failure":
            notes.append(f"`{name}` was already red on `{last[0]['head_sha'][:11]}` (run {last[0]['id']}): a known red, no bisect.")
        else:
            found.append((name, suite, last[0]["head_sha"]))
    return found, notes


def next_step(probe: Probe, conclusion: str, commits: list[str]) -> tuple[str, Probe | str | None]:
    """After a probe finished with conclusion: ('probe', next Probe), ('culprit', sha),
    ('flake', None), ('lost', None) or ('retry', Probe). commits: good..bad (or good..sha for the
    confirming probe), oldest first."""
    if conclusion not in ("success", "failure"):
        if probe.tries < MAX_PROBE_RETRIES:
            return "retry", Probe(**{**probe.__dict__, "tries": probe.tries + 1})
        return "lost", None
    good, bad = probe.good, probe.bad
    if not bad:  # the confirming probe, on the batch's own commit
        if conclusion == "success":
            return "flake", None
        bad = probe.sha
    elif conclusion == "failure":
        bad = probe.sha
    else:
        good = probe.sha
    span = commits_between(commits, good, bad)
    if len(span) <= 1:
        return "culprit", bad
    mid = span[(len(span) - 1) // 2]
    return "probe", Probe(probe.suite, probe.job, probe.only, mid, good, bad, probe.origin)


def commits_between(commits: list[str], good: str, bad: str) -> list[str]:
    """The commits after good up to and including bad, from the full covered list."""
    try:
        start = commits.index(good) + 1 if good in commits else 0
        end = commits.index(bad) + 1
    except ValueError:
        return [bad]
    return commits[start:end]


def probe_refusal(probe: Probe, branch: str, origin: dict | None, found: list[tuple[str, str, str]], covered) -> str:
    """Why a probe's inputs are not a bisect this workflow started, or "" when they are. A dispatch can name
    any sha, good and bad, so they are checked against the batch run that found the red (origin): it is a
    finished batch run of this workflow on branch; the job is a new red there (red on that run, green on
    the newest earlier batch run where it finished: found, from new_reds); and the probe's sha, good and
    bad lie in the commits that run covered, last green (exclusive) to its own commit. covered(good, head)
    gives first_parent_range."""
    if not origin:
        return f"origin run {probe.origin or '(none)'} is unreadable"
    if not is_batch(origin) or not str(origin.get("path") or "").endswith(WORKFLOW) or origin.get("head_branch") != branch:
        return f"origin run {origin.get('id')} is not a batch run of {WORKFLOW} on {branch}"
    head = origin.get("head_sha") or ""
    green = next((good for name, suite, good in found if name == probe.job and suite == probe.suite), None)
    if green is None:
        return f"`{probe.job}` is not a new red on origin run {origin.get('id')} (`{head[:11]}`)"
    try:
        span = covered(green, head)
    except (RuntimeError, subprocess.CalledProcessError):
        span = []
    for label, sha in (("sha", probe.sha), ("bad", probe.bad)):
        if (sha or label == "sha") and sha not in span:
            return f"{label} `{sha[:11]}` is not in the commits origin run {origin.get('id')} covered (`{green[:11]}`..`{head[:11]}`)"
    if probe.good != green and probe.good not in span:
        return f"good `{probe.good[:11]}` is not in the commits origin run {origin.get('id')} covered (`{green[:11]}`..`{head[:11]}`)"
    if not probe.bad and probe.sha != head:
        return f"the confirming probe's sha `{probe.sha[:11]}` is not origin run {origin.get('id')}'s commit `{head[:11]}`"
    return ""


def dispatch_probe(repo: str, branch: str, probe: Probe, api=gh_api) -> None:
    api(f"repos/{repo}/actions/workflows/{WORKFLOW}/dispatches", method="POST", fields={"ref": branch, "inputs": probe.inputs()})


def cmd_judge(args: argparse.Namespace) -> int:
    suites = load_manifest(Path(args.manifest))
    jobs = run_jobs(args.repo, args.run_id)
    verdicts = suite_verdicts(jobs, suites)
    out: dict[str, str] = {"culprit": "", "job": "", "good": "", "origin": ""}
    def jobs_of(rid: int) -> tuple[dict[str, tuple[str, str]], bool]:
        earlier = run_jobs(args.repo, rid)
        judged = any(j.get("name") == "judge" and j.get("conclusion") == "success" for j in earlier)
        return suite_verdicts(earlier, suites), judged

    if args.mode != PROBE:
        runs = list_runs(args.repo, args.branch)
        found, notes = new_reds(args.sha, verdicts, runs, jobs_of)
        for note in notes:
            summary(args.summary, f"- {note}")
        if not found:
            summary(args.summary, f"No new red on `{args.sha[:11]}` ({len(verdicts)} suite jobs finished).")
        for name, suite, good in found[:MAX_CHAINS]:
            inner = name.partition(" / ")[2]
            probe = Probe(suite, name, suites[suite].job_id(inner), args.sha, good, "", str(args.run_id))
            summary(args.summary, f"- New red `{name}`: green on `{good[:11]}`; probing `{args.sha[:11]}` once to confirm, then bisecting.")
            if not args.dry_run:
                dispatch_probe(args.repo, args.branch, probe)
        for name, _, good in found[MAX_CHAINS:]:
            summary(args.summary, f"- New red `{name}` (green on `{good[:11]}`): over the {MAX_CHAINS}-bisect cap, named only.")
        write_outputs(args.github_output, out)
        return 0

    probe = Probe(args.suite, args.job, args.only, args.probe_sha, args.good, args.bad, args.origin, int(args.tries or 0))
    try:
        origin = gh_api(f"repos/{args.repo}/actions/runs/{probe.origin}") if probe.origin.isdigit() else None
    except RuntimeError:
        origin = None
    found: list[tuple[str, str, str]] = []
    if origin and is_batch(origin):
        before = [r for r in list_runs(args.repo, args.branch) if (r.get("id") or 0) < origin["id"]]
        found, _ = new_reds(origin.get("head_sha") or "", jobs_of(origin["id"])[0], before, jobs_of)
    refusal = probe_refusal(probe, args.branch, origin, found, first_parent_range)
    if refusal:
        summary(args.summary, f"Probe refused: {refusal}. No next probe and no culprit.")
        write_outputs(args.github_output, out)
        return 1
    # The probe ran one suite job (or the whole suite when the red job had no manifest id):
    # its verdict is the job with the red job's name, else the worst of the suite's jobs.
    mine = {n: c for n, (s, c) in verdicts.items() if s == probe.suite}
    conclusion = mine.get(probe.job) or ("failure" if "failure" in mine.values() else "success" if mine and all(c in ("success", "skipped") for c in mine.values()) else "")
    head = probe.bad or probe.sha
    commits = first_parent_range(probe.good, head)
    step, value = next_step(probe, conclusion, commits)
    if step in ("probe", "retry"):
        assert isinstance(value, Probe)
        summary(args.summary, f"`{probe.job}` was {conclusion or 'unfinished'} at `{probe.sha[:11]}`; next probe `{value.sha[:11]}` (good `{value.good[:11]}`, bad `{value.bad[:11]}`).")
        if not args.dry_run:
            dispatch_probe(args.repo, args.branch, value)
    elif step == "culprit":
        assert isinstance(value, str)
        summary(args.summary, f"`{probe.job}` first went red at `{value}` (last green `{(probe.good if conclusion == 'failure' else probe.sha)[:11]}`).")
        out.update(culprit=value, job=probe.job, good=probe.good if conclusion == "failure" else probe.sha, origin=probe.origin)
    elif step == "flake":
        summary(args.summary, f"`{probe.job}` passed again at `{probe.sha[:11]}`: the batch red did not repeat (a flake); no bisect.")
    else:
        summary(args.summary, f"`{probe.job}` gave no verdict at `{probe.sha[:11]}` twice; the bisect stops here.")
    write_outputs(args.github_output, out)
    return 0


# ---------------------------------------------------------------------------- revert


def revert_title(subject: str, job: str, branch: str) -> str:
    return f'Revert "{subject}" (post-merge batch: {job} red on {branch})'


def merged_by_teammate(repo: str, pr: str, api=gh_api) -> str:
    """The culprit PR's author when a core teammate wrote it (their revert opens held), else "". An
    unreadable author counts as a teammate: a held revert costs a human glance, an agent landing a
    teammate's revert breaks the rule."""
    if not pr:
        return ""
    try:
        login = ((api(f"repos/{repo}/pulls/{pr}") or {}).get("user") or {}).get("login") or ""
    except RuntimeError:
        return "the culprit's author (unread)"
    return login if login in TEAMMATES else ""


def cmd_revert(args: argparse.Namespace) -> int:
    """Commits the revert of the culprit on the branch tip and opens its pull request. Never
    merges it. Exits 0 with a note when a revert is already open or the revert conflicts."""
    culprit = args.culprit
    if not SHA_RE.match(culprit):
        raise SystemExit(f"bad culprit {culprit!r}")
    subject = git("log", "-1", "--format=%s", culprit).strip()
    match = PR_RE.search(subject)
    pr = match.group(1) if match else ""
    branch = f"revert/pr-{pr}" if pr else f"revert/post-merge-{culprit[:12]}"
    existing = gh_api(f"repos/{args.repo}/pulls?state=open&head={args.repo.split('/')[0]}:{branch}") or []
    if existing:
        summary(args.summary, f"A revert is already open: {existing[0]['html_url']}")
        return 0
    if subprocess.run(["git", "merge-base", "--is-ancestor", culprit, "HEAD"], cwd=ROOT).returncode:
        summary(args.summary, f"`{culprit[:11]}` is not on this checkout's {args.branch}; left to its owner.")
        return 0
    parents = git("rev-list", "--parents", "-n1", culprit).split()[1:]
    mainline = ["-m", "1"] if len(parents) > 1 else []
    result = subprocess.run(["git", "revert", "--no-edit", *mainline, culprit], cwd=ROOT, capture_output=True, text=True)
    if result.returncode:
        subprocess.run(["git", "revert", "--abort"], cwd=ROOT)
        summary(args.summary, f"Reverting `{culprit[:11]}` conflicts with the tip of {args.branch}; left to its owner.")
        return 0
    if not args.dry_run:
        start_branch(args.repo, branch, git("rev-parse", "HEAD^").strip())
        push_branch(args.push_url, f"+HEAD:refs/heads/{branch}")
    origin = f"{args.server_url}/{args.repo}/actions/runs/{args.origin}" if args.origin else "(unknown)"
    this = f"{args.server_url}/{args.repo}/actions/runs/{args.run_id}"
    who = f"#{pr}" if pr else f"`{culprit[:12]}`"
    author = merged_by_teammate(args.repo, pr)
    land = (
        f"This revert is {author}'s to land or close; no agent lands it."
        if author
        else "The base-break rule restores the base first: land this through normal landing, then reland the change with its fix."
    )
    body = "\n\n".join(
        ([TEAMMATE_HOLD.format(login=author)] if author else [])
        + [
            f"Reverts {who} (`{culprit}`): the post-merge batch run {origin} found `{args.job}` red on {args.branch}; "
            f"it was green at `{args.good}`, and the bisect over the commits between (only that job) names {who} as the first red one ({this}).",
            f"{land} If the red is not this change's (a flake that repeated, an outside service), close this and say so.",
            "Opened by cmux-next-post-merge.yml (scripts/ci/post_merge_batch.py revert); it never merges a revert.",
        ]
    )
    title = revert_title(subject, args.job, args.branch)
    if args.dry_run:
        summary(args.summary, f"Would open {branch}: {title}")
        return 0
    created = gh_api(
        f"repos/{args.repo}/pulls",
        method="POST",
        fields={"head": branch, "base": args.branch, "title": title, "body": body},
    )
    summary(args.summary, f"Revert pull request: {created['html_url']}")
    write_outputs(args.github_output, {"url": created["html_url"]})
    return 0


# ---------------------------------------------------------------------------- main


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = parser.add_subparsers(dest="cmd", required=True)

    def common(p: argparse.ArgumentParser) -> None:
        p.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", "manaflow-ai/cmux"))
        p.add_argument("--branch", default="feat-cmux-next")
        p.add_argument("--manifest", default=str(MANIFEST))
        p.add_argument("--github-output", default=os.environ.get("GITHUB_OUTPUT"))
        p.add_argument("--summary", default=os.environ.get("GITHUB_STEP_SUMMARY"))
        p.add_argument("--dry-run", action="store_true")
        p.add_argument("--api-wait-seconds", type=float, default=None, help="total wait for a spent rate limit (judge 600, plan 420, revert 300, tick 120)")

    def probe_args(p: argparse.ArgumentParser) -> None:
        p.add_argument("--mode", choices=[BATCH, PROBE], default=BATCH)
        p.add_argument("--sha", default=os.environ.get("GITHUB_SHA", ""))
        p.add_argument("--suite", default="")
        p.add_argument("--job", default="")
        p.add_argument("--only", default="")
        p.add_argument("--probe-sha", default="")
        p.add_argument("--good", default="")
        p.add_argument("--bad", default="")
        p.add_argument("--origin", default="")
        p.add_argument("--tries", default="0")

    p = sub.add_parser("tick")
    common(p)
    p.add_argument("--window-minutes", default=os.environ.get("NEXT_POST_MERGE_WINDOW_MINUTES"))
    p.set_defaults(func=cmd_tick)

    p = sub.add_parser("plan")
    common(p)
    probe_args(p)
    p.set_defaults(func=cmd_plan)

    p = sub.add_parser("judge")
    common(p)
    probe_args(p)
    p.add_argument("--run-id", type=int, required=True)
    p.set_defaults(func=cmd_judge)

    p = sub.add_parser("revert")
    common(p)
    p.add_argument("--culprit", required=True)
    p.add_argument("--job", required=True)
    p.add_argument("--good", default="")
    p.add_argument("--origin", default="")
    p.add_argument("--run-id", default=os.environ.get("GITHUB_RUN_ID", ""))
    p.add_argument("--server-url", default=os.environ.get("GITHUB_SERVER_URL", "https://github.com"))
    p.add_argument("--push-url", default="origin")
    p.set_defaults(func=cmd_revert)

    args = parser.parse_args(argv)
    # Within each job's timeout-minutes (judge 15, plan 10); the tick's shim is short and skips on a refusal.
    budgets = {"judge": 600.0, "plan": 420.0, "revert": 900.0}
    API_WAIT_BUDGET["seconds"] = args.api_wait_seconds if args.api_wait_seconds is not None else budgets.get(args.cmd, 120.0)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
