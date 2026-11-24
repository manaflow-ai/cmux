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
DEFAULT_WINDOW_MINUTES = 120
# A batch run's run-name starts with this; a probe's with PROBE (the workflow's run-name).
BATCH = "batch"
PROBE = "probe"
# Runs read back to find the last batch run where a job ran (one page; about 2.5 days at 12 a day,
# plus probes).
RUNS_PAGE = 60
# At most this many new reds start a bisect from one batch run; the rest are named only.
MAX_CHAINS = 4
# A probe run with no verdict (cancelled, runner lost) is tried again this many times. Two: drill-8 lost two
# runners within the hour (runs 44966393364 and 44980687386).
MAX_PROBE_RETRIES = 2
# A batch run on the tip whose judge never succeeded (its plan or judge lost a runner) is run again by the tick
# until this many batch runs sit on that tip.
MAX_TIP_BATCHES = 2
SHA_RE = re.compile(r"^[0-9a-f]{40}$")
PR_RE = re.compile(r"\(#(\d+)\)\s*$")
PIECES_DRILL = "lane/post-merge-drill-pieces-"
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


WORKFLOWS_TOKEN_ISSUE = "https://github.com/manaflow-ai/cmuxterm-hq/issues/18499"


class WorkflowsTokenMissing(SystemExit):
    """The swap-out or revert changes a workflow file and the job has no workflows-write token: it stops with the
    command that does it by hand and the issue that grants the permission, never a silent skip."""


def touches_workflows(files) -> list[str]:
    return [f for f in files if f.startswith(".github/workflows/")]


def push_token(files=(), command: str = "") -> str:
    """The token that creates and pushes the swap-out, probe or revert branch. WORKFLOWS_TOKEN (workflows write,
    minted apart) whenever the job has one: every such branch starts at a feat-cmux-next or drill commit, whose
    workflow files differ from main's, and GitHub refuses a contents-only token that creates a ref there whatever
    the diff touches ("Resource not accessible by integration (HTTP 403)" on POST git/refs: drill 9's piece probe,
    run 45096141472, job 137440066365). PUSH_TOKEN (contents write only) is the fallback when that mint failed
    (the routing App had no Workflows permission and the combined mint failed every revert job, run 45021631601,
    hq#18499); then a diff that touches .github/workflows/** stops here with `command`."""
    token = os.environ.get("WORKFLOWS_TOKEN", "")
    if token:
        return token
    workflow_files = touches_workflows(files)
    if not workflow_files:
        return os.environ.get("PUSH_TOKEN") or os.environ.get("GH_TOKEN", "")
    raise WorkflowsTokenMissing(
        f"This change touches workflow files ({', '.join(workflow_files)}) and the job has no workflows-write token "
        f"(the \"Mint the workflows push token\" step failed or did not run). Grant the routing App Workflows: Read and "
        f"write ({WORKFLOWS_TOKEN_ISSUE}, hq#18499) and rerun this job, or do it by hand:\n\n    {command}"
    )


def push_url(template: str, token: str) -> str:
    """--push-url with its {token} filled; a plain remote name or URL is used as it is."""
    return template.replace("{token}", token)


def publish(args: argparse.Namespace, branch: str, start: str, refspec: str, files, command: str) -> None:
    """Creates branch at start and pushes refspec to it with the token the files need (push_token)."""
    token = push_token(files, command)
    start_branch(args.repo, branch, start, token=token)
    push_branch(push_url(args.push_url, token), refspec)


def start_branch(repo: str, branch: str, sha: str, api=gh_api, sleep=time.sleep, waits: tuple[int, ...] = (15, 45), token: str = "") -> None:
    """Creates branch at sha, a commit GitHub already has, through the REST API, with the push token. The revert
    then reaches it as an update. With the job token, a git push that creates the branch timed out every time
    (drill-5 run 44897813534, drill-6 run 44906887225, four tries each) and this call got HTTP 502 (drill-7 run
    44932473656). A branch left by an earlier try is reused; a GitHub 5xx is retried."""
    for wait in (*waits, None):
        try:
            api(f"repos/{repo}/git/refs", method="POST", fields={"ref": f"refs/heads/{branch}", "sha": sha}, tokens=[token or push_token()])
            return
        except RuntimeError as error:
            text = str(error)
            if "already exists" in text:
                return
            if wait is None or not re.search(r"HTTP 5\d\d", text):
                raise
            sleep(wait)


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


def piece_swap():
    """scripts/ci/piece_swap.py: hot swap out, a first red's pieces instead of its whole commit."""
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import piece_swap as module

    return module


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


def tick_decision(tip: str, runs: list[dict], now: datetime, window_minutes: int, judged=lambda run_id: True) -> tuple[str, str]:
    """(action, reason): action is 'dispatch' or 'skip'. judged(run id): that run's judge succeeded; a batch on
    the tip that tested nothing (drill-8 run 44966393364: its plan lost its runner) does not count as testing it."""
    batches = [r for r in runs if is_batch(r)]
    live = [r for r in batches if r.get("status") != "completed"]
    if live:
        return "skip", f"batch run {live[0].get('id')} is {live[0].get('status')} on {str(live[0].get('head_sha'))[:11]}"
    if not batches:
        return "dispatch", "no batch run yet"
    newest = batches[0]
    if newest.get("head_sha") == tip:
        on_tip = [r for r in batches if r.get("head_sha") == tip]
        if len(on_tip) < MAX_TIP_BATCHES and not judged(newest["id"]):
            return "dispatch", f"batch run {newest.get('id')} on tip {tip[:11]} gave no verdict (its plan or judge lost a runner)"
        return "skip", f"tip {tip[:11]} is tested (run {newest.get('id')})"
    # A batch that gave no verdict tested nothing, so it opens no window, whether or not the tip moved since:
    # run 45105503067's plan failed its fetch at 03:21Z on 2026-11-23, the tip moved on within a minute, and
    # no suite ran on the base until the window closed two hours later, while a stale Cargo.lock sat there.
    if not judged(newest["id"]):
        return "dispatch", f"batch run {newest.get('id')} on {str(newest.get('head_sha'))[:11]} gave no verdict (its plan or judge failed); tip {tip[:11]} is untested"
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


def tick(args: argparse.Namespace) -> int:
    # No web tick: the batch's `web` suite gives the base its web verdict, so cmux-next-web.yml's coalescing
    # tick (#49173) would run the same checks a second time.
    tip = gh_api(f"repos/{args.repo}/commits/{args.branch}")["sha"]
    runs = list_runs(args.repo, args.branch)
    def judged(run_id: int) -> bool:
        return any(j.get("name") == "judge" and j.get("conclusion") == "success" for j in run_jobs(args.repo, run_id))

    action, reason = tick_decision(tip, runs, datetime.now(timezone.utc), window_minutes(args.window_minutes), judged)
    print(f"{action}: {reason}")
    if action == "dispatch" and not args.dry_run:
        gh_api(
            f"repos/{args.repo}/actions/workflows/{WORKFLOW}/dispatches",
            method="POST",
            fields={"ref": args.branch, "inputs": {"mode": "batch", "reason": "tick"}},
        )
    return 0


# ---------------------------------------------------------------------------- plan


def plan_batch(sha: str, runs: list[dict], suites: dict[str, Suite], files_since, judged=lambda run_id: True, branch: str = "") -> dict:
    """The suites a batch run calls: every one the commits since the newest earlier batch run reach.
    Only a run whose judge succeeded counts: one whose plan died (drill run 44881749105, rate limit)
    tested nothing, and planning past it skipped the suites its commits reached. A hot swap out drill
    branch (lane/post-merge-drill-pieces-*) calls only the drill suite on every batch: its first batch is
    the green the drill's red is new against, and every other suite there is cost (the judge waits for
    the whole batch: run 45037084940 held the drill's red 85 minutes behind web shards)."""
    earlier = [r for r in runs if is_batch(r) and r.get("status") == "completed" and r.get("head_sha") != sha]
    tested = next((r for r in earlier if judged(r["id"])), None)
    base = tested["head_sha"] if tested else ""
    files = files_since(base) if base else None
    picked = [key for key, suite in suites.items() if files is None or suite.reached(files)]
    if branch.startswith(PIECES_DRILL) and "drill" in suites:
        picked = ["drill"]
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
        plan = plan_batch(args.sha, list_runs(args.repo, args.branch), suites, lambda base: changed_files(base, args.sha), judged, args.branch)
    except RuntimeError as err:
        # Past the wait budget the runs are unreadable: run every suite rather than none, so the
        # tip is still tested; the next batch's judge compares against this run as usual.
        print(f"plan: earlier batch runs unreadable, running every suite: {err}", file=sys.stderr)
        summary(args.summary, "- Earlier batch runs could not be read (rate limit): every suite runs.")
        plan = plan_batch(args.sha, [], suites, lambda base: [], branch=args.branch)
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
    pieces: str = ""  # hot swap out: piece_swap.State; sha is then the culprit with state.out swapped out

    def inputs(self) -> dict[str, str]:
        extra = {"pieces": self.pieces} if self.pieces else {}
        return extra | {
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
    # DISPATCH_TOKEN: the revert job's GITHUB_TOKEN (actions: write), whose GH_TOKEN may be the App's, which has none.
    token = os.environ.get("DISPATCH_TOKEN") or os.environ.get("GH_TOKEN", "")
    api(f"repos/{repo}/actions/workflows/{WORKFLOW}/dispatches", method="POST", fields={"ref": branch, "inputs": probe.inputs()}, tokens=[token])


def piece_probe_refusal(probe: Probe, state, branch: str, origin: dict | None, found, covered, tree=None) -> str:
    """A piece probe tests the bisect's culprit with some of its pieces swapped out. Its culprit must pass
    probe_refusal as the bisect's own last probe would (a new red on the origin batch run, in the commits it
    covered), and its commit must be exactly the culprit with state.out swapped out: the same tree, rebuilt here.
    tree(sha) gives a commit's tree (None: not readable)."""
    refusal = probe_refusal(Probe(probe.suite, probe.job, probe.only, state.culprit, probe.good, state.culprit, probe.origin), branch, origin, found, covered)
    if refusal:
        return refusal
    if probe.bad != state.culprit:
        return f"bad `{probe.bad[:11]}` is not the piece state's culprit `{state.culprit[:11]}`"
    ps = piece_swap()
    tree = tree or _tree
    pieces = {p.id: p for p in ps.split(ps.changed(state.culprit), ps.load_classifier())}
    if not set(state.candidates) <= set(pieces):
        return f"the piece state names pieces `{state.culprit[:11]}` does not have"
    files = [f for i in state.out for f in pieces[i].files]
    want = ps.swap_out_commit(state.culprit, state.culprit, files, "expected probe")
    if not want or tree(want) != tree(probe.sha):
        return f"probe commit `{probe.sha[:11]}` is not `{state.culprit[:11]}` with {', '.join(state.out)} swapped out"
    return ""


def _tree(sha: str) -> str | None:
    for attempt in range(2):
        try:
            return git("rev-parse", f"{sha}^{{tree}}").strip()
        except RuntimeError:
            if attempt:
                return None
            subprocess.run(["git", "fetch", "--quiet", "origin", sha], cwd=ROOT)
    return None


def judge_pieces(args: argparse.Namespace, probe: Probe, state, conclusion: str) -> dict[str, str]:
    """After a piece probe: the next piece state for the revert job to build and dispatch, the one piece
    named, or piece "-" (no piece: the whole revert pull request, as before)."""
    ps = piece_swap()
    found = {"culprit": state.culprit, "job": probe.job, "good": probe.good, "origin": probe.origin}
    narrowed = ps.narrow(state.candidates, state.out, conclusion)
    if narrowed is None:
        if probe.tries < MAX_PROBE_RETRIES:
            again = Probe(**{**probe.__dict__, "tries": probe.tries + 1})
            summary(args.summary, f"Piece probe gave no verdict with {', '.join(state.out)} out; running it again.")
            if not args.dry_run:
                dispatch_probe(args.repo, args.branch, again)
            return {}
        summary(args.summary, "Piece probe gave no verdict twice: no piece named; the whole revert pull request opens.")
        return found | {"piece": "-"}
    summary(args.summary, f"`{probe.job}` was {conclusion} at `{state.culprit[:11]}` with {', '.join(state.out)} swapped out: "
                          f"the red is in {', '.join(narrowed) or 'none of the pieces'}.")
    if len(narrowed) == 1:
        summary(args.summary, f"The piece: `{narrowed[0]}` ({state.probes + 1} probe(s)).")
        return found | {"piece": narrowed[0]}
    limit = ps.load_config().get("max_probes", 4)
    if not narrowed or state.probes + 1 >= limit:
        summary(args.summary, f"No single piece after {state.probes + 1} probe(s) (limit {limit}): the whole revert pull request opens.")
        return found | {"piece": "-"}
    nxt = ps.State(state.culprit, narrowed, ps.halve(narrowed), state.probes + 1)
    return found | {"pieces": nxt.dump()}


def cmd_judge(args: argparse.Namespace) -> int:
    suites = load_manifest(Path(args.manifest))
    jobs = run_jobs(args.repo, args.run_id)
    verdicts = suite_verdicts(jobs, suites)
    out: dict[str, str] = {"culprit": "", "job": "", "good": "", "origin": "", "pieces": "", "piece": ""}
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

    probe = Probe(args.suite, args.job, args.only, args.probe_sha, args.good, args.bad, args.origin, int(args.tries or 0), args.pieces or "")
    try:
        origin = gh_api(f"repos/{args.repo}/actions/runs/{probe.origin}") if probe.origin.isdigit() else None
    except RuntimeError:
        origin = None
    found: list[tuple[str, str, str]] = []
    if origin and is_batch(origin):
        before = [r for r in list_runs(args.repo, args.branch) if (r.get("id") or 0) < origin["id"]]
        found, _ = new_reds(origin.get("head_sha") or "", jobs_of(origin["id"])[0], before, jobs_of)
    state = None
    if probe.pieces:
        try:
            state = piece_swap().State.parse(probe.pieces)
        except ValueError as err:
            state = None
            refusal = str(err)
        else:
            refusal = piece_probe_refusal(probe, state, args.branch, origin, found, first_parent_range)
    else:
        refusal = probe_refusal(probe, args.branch, origin, found, first_parent_range)
    if refusal:
        summary(args.summary, f"Probe refused: {refusal}. No next probe and no culprit.")
        write_outputs(args.github_output, out)
        return 1
    # The probe ran one suite job (or the whole suite when the red job had no manifest id):
    # its verdict is the job with the red job's name, else the worst of the suite's jobs.
    mine = {n: c for n, (s, c) in verdicts.items() if s == probe.suite}
    conclusion = mine.get(probe.job) or ("failure" if "failure" in mine.values() else "success" if mine and all(c in ("success", "skipped") for c in mine.values()) else "")
    if state is not None:
        out.update(judge_pieces(args, probe, state, conclusion))
        write_outputs(args.github_output, out)
        return 0
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


SWAPOUT_MARK = "<!-- post-merge piece swap-out {culprit} {job} -->"


def swapouts_opened(repo: str, api=gh_api) -> list[datetime]:
    """When each recent swap-out pull request opened (the breaker's count)."""
    pulls = api(f"repos/{repo}/pulls?state=all&sort=created&direction=desc&per_page=50") or []
    return [parse_time(p["created_at"]) for p in pulls if str((p.get("head") or {}).get("ref") or "").startswith("swapout/")]


def swap_out(args: argparse.Namespace, culprit: str, subject: str, pr: str) -> bool:
    """Hot swap out (scripts/ci/piece_swap.py) before the whole revert: True when it acted (a piece probe
    dispatched, a swap-out pull request opened or already there); False hands the culprit to the whole
    revert pull request below, as before (the class is not listed, NEXT_PIECE_SWAP=0, a take-back, the
    breaker, a conflict)."""
    ps = piece_swap()
    pieces = ps.split(ps.changed(culprit), ps.load_classifier())
    by_id = {p.id: p for p in pieces}
    config = ps.load_config()
    suite_key = args.job.partition(" / ")[0]
    suites = load_manifest(Path(args.manifest))
    if args.piece:
        if args.piece not in by_id:
            summary(args.summary, f"Hot swap out: `{culprit[:11]}` has no piece `{args.piece}`; whole revert.")
            return False
        return open_swapout(args, culprit, subject, pr, by_id[args.piece], pieces, config)
    if args.pieces:
        state = ps.State.parse(args.pieces)
        if state is None or state.culprit != culprit or not set(state.candidates) <= set(by_id):
            raise SystemExit(f"bad piece state {args.pieces!r} for {culprit}")
        return dispatch_piece_probe(args, culprit, state, by_id, suites[suite_key])
    ok, why = ps.decide(pieces, config, os.environ)
    if ok and ps.is_take_back(subject):
        ok, why = False, "the culprit is itself a take-back (no ping-pong)"
    if not ok:
        summary(args.summary, f"Hot swap out: no ({why}); the whole revert pull request opens as before.")
        return False
    suspects = ps.suspects(pieces, suites[suite_key].paths if suite_key in suites else []) or pieces
    ids = [p.id for p in suspects]
    summary(args.summary, f"Hot swap out: `{culprit[:11]}` has {len(pieces)} piece(s); the red suite `{suite_key}` reads "
                          f"{len(ids)}: {', '.join(ids)}.")
    if len(ids) == 1:
        return open_swapout(args, culprit, subject, pr, by_id[ids[0]], pieces, config)
    return dispatch_piece_probe(args, culprit, ps.State(culprit, ids, ps.halve(ids), 0), by_id, suites[suite_key])


def dispatch_piece_probe(args: argparse.Namespace, culprit: str, state, by_id: dict, suite: Suite) -> bool:
    """Builds the culprit with state.out swapped out, pushes it to a probe branch and dispatches the red job on it."""
    ps = piece_swap()
    files = [f for i in state.out for f in by_id[i].files]
    sha = ps.swap_out_commit(culprit, culprit, files, f"Swap out {', '.join(state.out)} of {culprit[:12]} (piece probe)")
    if not sha:
        summary(args.summary, f"Hot swap out: {', '.join(state.out)} do not swap out of `{culprit[:11]}`; whole revert.")
        return False
    probe = Probe(suite.key, args.job, suite.job_id(args.job.partition(" / ")[2]), sha, args.good, culprit, args.origin, 0, state.dump())
    ref = ps.probe_branch(culprit, state.out)
    summary(args.summary, f"Piece probe {state.probes + 1}: `{args.job}` at `{culprit[:11]}` with {', '.join(state.out)} swapped out "
                          f"(`{sha[:11]}` on {ref}); of {len(state.candidates)} suspect piece(s).")
    if not args.dry_run:
        publish(args, ref, culprit, f"+{sha}:refs/heads/{ref}", files,
                f"python3 scripts/ci/piece_swap.py out {culprit} " + " ".join(f"--piece {i}" for i in state.out))
        dispatch_probe(args.repo, args.branch, probe)
    return True


def open_swapout(args: argparse.Namespace, culprit: str, subject: str, pr: str, piece, pieces: list, config: dict) -> bool:
    """The swap-out pull request: the branch tip with only this piece of the culprit reversed. Never merged here."""
    ps = piece_swap()
    branch = ps.branch_name(culprit, args.job, pr)
    owner = args.repo.split("/")[0]
    seen = gh_api(f"repos/{args.repo}/pulls?state=all&head={owner}:{branch}") or []
    if seen:  # one per (job, first red): an owner who closed it is not asked again
        summary(args.summary, f"Hot swap out: already {seen[0].get('state')} for this job and first red: {seen[0]['html_url']}")
        return True
    if ps.breaker_open(swapouts_opened(args.repo), datetime.now(timezone.utc), config.get("max_per_hour", 3)):
        summary(args.summary, f"Hot swap out: the breaker is open ({config.get('max_per_hour', 3)} swap-out pull requests in the last hour); whole revert.")
        return False
    title = f'Swap out {piece.id} of "{subject}" (post-merge batch: {args.job} red on {args.branch})'
    sha = ps.swap_out_commit(git("rev-parse", "HEAD").strip(), culprit, piece.files, title)
    if not sha:
        summary(args.summary, f"Hot swap out: `{piece.id}` does not swap out of {args.branch}'s tip cleanly; whole revert.")
        return False
    who = f"#{pr}" if pr else f"`{culprit[:12]}`"
    kept = [p.id for p in pieces if p.id != piece.id]
    author = merged_by_teammate(args.repo, pr)
    origin = f"{args.server_url}/{args.repo}/actions/runs/{args.origin}" if args.origin else "(unknown)"
    this = f"{args.server_url}/{args.repo}/actions/runs/{args.run_id}"
    body = "\n\n".join(
        ([TEAMMATE_HOLD.format(login=author)] if author else [])
        + [
            f"Swaps out one piece of {who} (`{culprit}`), not the whole commit: `{piece.id}` ({piece.cls}, swaps {piece.swap}; "
            f"{', '.join(f'`{f}`' for f in piece.files)}). The post-merge batch run {origin} found `{args.job}` red on {args.branch}, "
            f"the bisect named {who} as its first red commit, and the piece drill-down ({this}) named this piece.",
            "Stays in: " + (", ".join(f"`{k}`" for k in kept) or "(no other piece)") + ".",
            f"Swap it back in: revert this pull request's commit. The whole revert, the owner's fallback (proposed, never run here):\n\n"
            f"```\n{ps.whole_revert_command(culprit, args.branch, ps.parents(culprit))}\n```",
            "Opened by cmux-next-post-merge.yml (scripts/ci/post_merge_batch.py revert, scripts/ci/piece_swap.py); it never merges. "
            "Off: repository variable NEXT_PIECE_SWAP=0.",
        ]
    )
    if args.dry_run:
        summary(args.summary, f"Would open {branch}: {title}")
        return True
    publish(args, branch, git("rev-parse", "HEAD").strip(), f"+{sha}:refs/heads/{branch}", piece.files,
            f"python3 scripts/ci/piece_swap.py out {culprit} --piece {piece.id} --onto origin/{args.branch}")
    created = gh_api(f"repos/{args.repo}/pulls", method="POST", fields={"head": branch, "base": args.branch, "title": title, "body": body})
    summary(args.summary, f"Swap-out pull request: {created['html_url']}")
    write_outputs(args.github_output, {"url": created["html_url"]})
    if pr:
        mark = SWAPOUT_MARK.format(culprit=culprit, job=args.job)
        try:
            comments = gh_api(f"repos/{args.repo}/issues/{pr}/comments?per_page=100") or []
            if not any(mark in (c.get("body") or "") for c in comments):
                gh_api(f"repos/{args.repo}/issues/{pr}/comments", method="POST", fields={
                    "body": f"{mark}\nPost-merge `{args.job}` went red at this PR's merge; the piece is `{piece.id}`. "
                            f"{created['html_url']} swaps only that piece out; {', '.join(kept) or 'nothing else'} stays in."})
        except RuntimeError as err:  # the pull request is the record; the heads-up is a courtesy
            print(f"swap-out comment on #{pr}: {err}", file=sys.stderr)
    return True


def cmd_revert(args: argparse.Namespace) -> int:
    """Commits the revert of the culprit on the branch tip and opens its pull request. Never
    merges it. Exits 0 with a note when a revert is already open or the revert conflicts."""
    culprit = args.culprit
    if not SHA_RE.match(culprit):
        raise SystemExit(f"bad culprit {culprit!r}")
    subject = git("log", "-1", "--format=%s", culprit).strip()
    match = PR_RE.search(subject)
    pr = match.group(1) if match else ""
    if args.piece != "-" and swap_out(args, culprit, subject, pr):
        return 0
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
        publish(args, branch, git("rev-parse", "HEAD^").strip(), f"+HEAD:refs/heads/{branch}", changed_files(f"{culprit}^", culprit),
                piece_swap().whole_revert_command(culprit, args.branch, len(parents)))
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
        p.add_argument("--pieces", default="")

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
    p.add_argument("--pieces", default="", help="hot swap out: the next piece probe's state (piece_swap.State)")
    p.add_argument("--piece", default="", help="hot swap out: the named piece; '-' skips hot swap out")
    p.set_defaults(func=cmd_revert)

    args = parser.parse_args(argv)
    # Within each job's timeout-minutes (judge 15, plan 10); the tick's shim is short and skips on a refusal.
    budgets = {"judge": 600.0, "plan": 420.0, "revert": 900.0}
    API_WAIT_BUDGET["seconds"] = args.api_wait_seconds if args.api_wait_seconds is not None else budgets.get(args.cmd, 120.0)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
