#!/usr/bin/env python3
"""The post-merge batch tier: the base's deferred checks run once per pile of merges, not once per merge.

RFD 0023 (cmuxterm-hq docs/rfd/0023-ci-10x.md), Leo's third direction: "everything else runs
once post-merge, batched". About every 100 merges (NEXT_POST_MERGE_EVERY_MERGES, default 100; 0 turns
the count off), or once the window has passed when fewer have landed (vars.NEXT_POST_MERGE_WINDOW_MINUTES,
default 240), the newest feat-cmux-next tip gets one run of
every suite in .github/post-merge-batch.json, covering every squash commit since the last tested
tip. A job that was green on the last tip where it ran and is red now is bisected over the
covered commits, running only that job, and the culprit gets a revert pull request through
normal landing (never merged here).

Subcommands (each run by .github/workflows/cmux-next-post-merge.yml, except tick):

  tick    main's schedule shim (cmux-next-post-merge-dispatch.yml) runs this every 30 min, and a
          batch run's judge job runs it as its last step (--self-run-id), so a finished batch starts
          the next one at once when the merges have piled up: "is there an untested tip?" in two or
          three API calls. It dispatches a batch run when the tip is not the newest batch run's
          commit, no other batch run is in flight, and the tip is at least NEXT_POST_MERGE_EVERY_MERGES
          commits ahead of the newest batch run's commit (one compare call) or that run started at
          least a window ago. Nothing waits or loops; a skipped tick costs seconds.
          Each tick also starts the hourly full tier (cmux-next-hourly-full-tier.yml, scripts/ci/hourly_full_tier.py)
          when it is due (hourly_kick): no run in flight, the newest one at least HOURLY_MINUTES old and not at the
          tip. Its failure never stops the batch tick.
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
import hashlib
import json
import os
import re
import subprocess
import sys
import time
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MANIFEST = ROOT / ".github" / "post-merge-batch.json"
WORKFLOW = "cmux-next-post-merge.yml"
DEFAULT_WINDOW_MINUTES = 240
# A batch run starts once the tip is this many commits (squash merges) ahead of the newest batch run's commit
# (Leo, 2026-11-21: "de facto, im asking for 99% fewer minutes of ci time, period."; at about 40 merges an hour
# that is a batch every 15 min, one run covering ten merges). The window above stays the fallback for a quiet base.
DEFAULT_EVERY_MERGES = 100
# A batch run's run-name starts with this; a probe's with PROBE (the workflow's run-name).
BATCH = "batch"
PROBE = "probe"
# Runs read back to find the last batch run where a job ran, a page at a time (GitHub's largest page).
RUNS_PAGE = 100
# The judge reads back this many batch runs (about a day at one every ~55 min), paging past the probes between them,
# at most MAX_RUNS_PAGES pages. One page was the whole reach before 2026-11-27: at 01:57Z its 100 runs were 94 probes
# and 6 batch runs (5.5 h), so a red older than that had no green in reach and stuck_reds skipped it; the 01:2xZ batch
# run 45919537854 called 25 of its 28 reds "a known red, no bisect" (cmuxterm-hq goals/base-batch-reverts-culprit.md).
LOOKBACK_BATCHES = 24
MAX_RUNS_PAGES = 8
# At most this many new reds start a bisect from one batch run; the rest are named only.
MAX_CHAINS = 4
# At most this many stuck reds (red on two or more batch runs in a row, see stuck_reds) start a bisect from one batch
# run, after the new reds. Before 2026-11-26 a red that outlived one batch run was "a known red, no bisect" forever: the
# 06:29Z batch run 45768539377 skipped 43 of its 48 reds that way, and live base reds went 62 to 91 in 22 h (cmuxterm-hq
# goals/base-batch-reverts-culprit.md).
# Raised from 4 on 2026-11-27: 67 live base reds drained four at a time while the Linux pool sat idle (0.275 busy).
MAX_STUCK_CHAINS = 12
# Flake-aware confirm (Henderson et al., "Flake Aware Culprit Finding", ICST 2023; LUCI Bisection): a bisect's culprit
# rests on one red run of it and one green run of its parent, so one flaky run named the wrong commit. Before its revert
# opens, the culprit runs CONFIRM_RUNS more times (each must fail) and its parent CONFIRM_RUNS more times (each must
# pass), all at once in one round; any disagreeing run makes it a flake, with no revert.
CONFIRM_RUNS = 2
# A stuck red is bisected again at most this many times, so a red no bisect can pin (an outside service, a red on
# every commit) costs a bounded number of probe chains. A bisect counts once its first probe was judged: before
# 2026-11-27 this counted red batch runs instead, so the six reds whose chains died on the judge's rate limit
# (cmux#60709) were capped for good without one finished bisect.
MAX_REBISECTS = 2
# A red with no green batch run in the LOOKBACK_BATCHES reach had no bisect ever: stuck_reds needs a last green. Run
# 45971503699 (11-27 09:xxZ) called eight reds "a known red, no bisect" (acpmux-sim-sweep, cmux-tui-sdks protocol
# contract, CmuxMobileKit tests ...), red since a commit three days back (0e0818af, 11-24), past the reach. Only for such
# a red, the judges read this many batch runs further back, older than the reach's oldest run, to find its last green.
DEEP_LOOKBACK_BATCHES = 72
# A probe run with no verdict (cancelled, runner lost) is tried again this many times. Two: drill-8 lost two
# runners within the hour (runs 44966393364 and 44980687386).
MAX_PROBE_RETRIES = 2
# The origin's failing step names travel in a probe's `step` input joined by this.
STEP_SEP = "|"
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


# next-autoland's hand-off label (cmuxterm-hq tools/fleet-reconcilers/next_autoland.py LABEL): on it, the PR is
# ready, is reviewed and lands like any agent PR once its checks pass, and it starts the full CI tier
# (scripts/ci/head_tier.py LAND_LABEL). Goal base-batch-reverts-culprit: a confirmed culprit's revert lands
# with no person. A teammate's held revert never gets it (TEAMMATE_HOLD): it waits for them.
LAND_LABEL = "ready-to-land"


def hand_off(repo: str, number: int, author: str, api=None) -> str:
    """Labels the revert or swap-out pull request `number` LAND_LABEL unless `author` (a teammate) holds it. Returns
    the line for the run summary. A refused label leaves the pull request open for normal landing: it is the record."""
    if author:
        return f"Held for {author}: not labelled {LAND_LABEL}."
    try:
        (api or gh_api)(f"repos/{repo}/issues/{number}/labels", method="POST", fields={"labels": [LAND_LABEL]})
    except RuntimeError as err:
        print(f"label {LAND_LABEL} on #{number}: {err}", file=sys.stderr)
        return f"Could not label it {LAND_LABEL} ({str(err)[-160:]}); it waits for normal landing."
    return f"Labelled {LAND_LABEL}: next-autoland lands it once it is reviewed and green."


# ---------------------------------------------------------------------------- GitHub and git


# The repository's workflow token shares one rate limit with every workflow in the repo; when it is
# spent, a call waits for the reset instead of failing the job, up to this many seconds in all
# (--api-wait-seconds). Batch run 44878722147's judge died on it (2026-11-21).
API_WAIT_BUDGET = {"seconds": 0.0}
RATE_LIMITED = re.compile(r"rate limit|HTTP 429|secondary rate", re.I)
# A read GitHub answers with a 5xx (or a dropped connection) is tried again after these waits before the call
# fails. Before this one such answer to a probe's read of its origin run refused the probe ("origin run ... is
# unreadable") and ended the bisect: 3 of 20 probe judges on 11-26 23:00-00:15Z (runs 45909196492, 45910256924,
# 45910283297), each a red that then stayed live with no culprit (cmuxterm-hq goals/base-batch-reverts-culprit.md).
READ_RETRY_WAITS = (5, 20)
TRANSIENT_READ = re.compile(r"HTTP 5\d\d|Server Error|connection reset|timed out|timeout|unexpected EOF", re.I)


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


def _distinct(*tokens: str) -> list[str]:
    return [t for i, t in enumerate(tokens) if t and t not in tokens[:i]] or [""]


def read_tokens() -> list[str]:
    """Tokens a read may use, in order: the route App's (GH_READ_TOKEN, its own budget) first, then the job's
    GH_TOKEN, whose budget every workflow in the repository shares and which is often spent, then
    GH_FALLBACK_TOKEN (a token on yet another budget, set by a caller that has one)."""
    env = os.environ.get
    return _distinct(env("GH_READ_TOKEN", ""), env("GH_TOKEN", ""), env("GH_FALLBACK_TOKEN", ""))


def write_tokens() -> list[str]:
    """Tokens a write may use, in order: GH_TOKEN, then GH_FALLBACK_TOKEN. A rate-limited write never ran, so
    trying it on another budget is safe. main's cmux-next-post-merge-dispatch.yml ticks on the cmux bot App's
    token with the job token as the fallback: from 2026-11-27 23:55Z every tick for over 2 h ended "tick
    skipped: ... API rate limit exceeded for installation ID 175618676" (the bot App, which every post-merge
    read had moved onto) with the job token, on its own budget, never tried, and no batch ran."""
    env = os.environ.get
    return _distinct(env("GH_TOKEN", ""), env("GH_FALLBACK_TOKEN", ""))


def gh_api(path: str, *, method: str = "GET", fields: dict | None = None, run=subprocess.run, sleep=time.sleep, clock=time.time, reset_at=_core_reset, tokens=None) -> object:
    """One GitHub API call through gh. A call tries each of read_tokens() (a read) or write_tokens() (a write) in
    turn when one is rate limited. Fields go as JSON on stdin. Once every token is rate limited it waits for the reset and
    retries within API_WAIT_BUDGET."""
    argv = ["gh", "api", "-X", method, path]
    data = None
    if fields is not None:
        argv += ["--input", "-"]
        data = json.dumps(fields)
    if tokens is None:
        tokens = read_tokens() if method == "GET" else write_tokens()
    while True:
        for i, token in enumerate(tokens):
            env = {**os.environ, "GH_TOKEN": token} if token else None
            out = run(argv, input=data, capture_output=True, text=True, env=env)
            for wait in READ_RETRY_WAITS if method == "GET" else ():
                text = (out.stderr or out.stdout or "").strip()
                if not out.returncode or RATE_LIMITED.search(text) or not TRANSIENT_READ.search(text):
                    break
                print(f"gh api {method} {path}: {text[-200:]}; retrying in {wait} s", file=sys.stderr)
                sleep(wait)
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


def start_branch(repo: str, branch: str, sha: str, api=None, sleep=time.sleep, waits: tuple[int, ...] = (15, 45), token: str = "") -> None:
    """Creates branch at sha, a commit GitHub already has, through the REST API, with the push token. The revert
    then reaches it as an update. With the job token, a git push that creates the branch timed out every time
    (drill-5 run 44897813534, drill-6 run 44906887225, four tries each) and this call got HTTP 502 (drill-7 run
    44932473656). A branch left by an earlier try is reused; a GitHub 5xx is retried."""
    api = api or gh_api  # looked up per call, so a test's patch of gh_api reaches it
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

    def probe_only(self, display: str) -> str:
        """The `only` a bisect probe of the red job named display runs with: its manifest id, else lone_only(display),
        which no callee job's `inputs.only == '<id>'` condition matches, so the probe runs the suite's ungated jobs
        (its router, the red job itself when it is ungated) and none of its gated ones. cmd_judge falls back to the
        whole suite when the red job did not run that way. POST_MERGE_PROBE_WHOLE_SUITE=1 restores the old whole-suite
        probe for every job with no manifest id."""
        return self.job_id(display) or ("" if os.environ.get("POST_MERGE_PROBE_WHOLE_SUITE") == "1" else lone_only(display))


# A probe of a red job with no manifest id ran the whole suite before 2026-11-27: `cmux-tui-spec / changes` (a ~1 min
# routing check) bisected with 13 whole-suite runs of ~80 runner-min each in 4.3 h (run 46048381428 and its chain),
# and `web / webviews-test-history` with three whole-web-suite runs of ~450 runner-min each at one commit, none with a
# verdict (runs 46032681534, 46038183456, 46043521712: the job runs only at the batch's own tip, so a probe always
# skipped it and was tried again).
LONE_PREFIX = "lone-"


def lone_only(display: str) -> str:
    """The `only` value naming one id-less job: 'lone-' and its name's letters and digits, '-'-joined."""
    return LONE_PREFIX + (re.sub(r"[^a-z0-9]+", "-", job_base(display).lower()).strip("-") or "job")


def load_manifest(path: Path = MANIFEST) -> dict[str, Suite]:
    data = json.loads(path.read_text())
    return {
        key: Suite(key=key, workflow=spec["workflow"], paths=list(spec.get("paths") or []), jobs=dict(spec.get("jobs") or {}))
        for key, spec in data["suites"].items()
    }


# ---------------------------------------------------------------------------- runs


def is_batch(run: dict) -> bool:
    return (run.get("display_title") or run.get("name") or "").split(" ", 1)[0] == BATCH


def list_runs(repo: str, branch: str, api=None, before: int = 0, batches: int = 0, created_before: str = "") -> list[dict]:
    """This workflow's runs on branch, newest first: one page, or with batches, the runs older than run id before
    (all, when 0) back to and including the batches-th batch run among them, paging at most MAX_RUNS_PAGES pages.
    A batch run's judge and its probes' judges pass the same before and batches, so they read the same batch runs."""
    api = api or gh_api  # looked up per call, so a test's patch of gh_api reaches it
    runs: list[dict] = []
    for page in range(1, (MAX_RUNS_PAGES if batches else 1) + 1):
        data = api(f"repos/{repo}/actions/workflows/{WORKFLOW}/runs?branch={branch}&per_page={RUNS_PAGE}"
                   + (f"&created=%3C{created_before}" if created_before else "")
                   + (f"&page={page}" if page > 1 else ""))
        got = list((data or {}).get("workflow_runs") or [])
        runs += got
        older = [r for r in runs if not before or (r.get("id") or 0) < before]
        if not batches or len(got) < RUNS_PAGE or sum(map(is_batch, older)) >= batches:
            break
    seen: set = set()
    runs = [r for r in runs if not (r.get("id") in seen or seen.add(r.get("id")))]
    runs.sort(key=lambda r: (r.get("created_at") or "", r.get("id") or 0), reverse=True)
    if not batches:
        return runs
    out, count = [], 0
    for r in runs:
        if before and (r.get("id") or 0) >= before:
            continue
        if count >= batches:
            break
        out.append(r)
        count += is_batch(r)
    return out


def run_jobs(repo: str, run_id: int, api=None) -> list[dict]:
    api = api or gh_api  # looked up per call, so a test's patch of gh_api reaches it
    jobs: list[dict] = []
    page = 1
    while True:
        data = api(f"repos/{repo}/actions/runs/{run_id}/jobs?per_page=100&page={page}") or {}
        batch = list(data.get("jobs") or [])
        jobs += batch
        if len(batch) < 100 or page >= 5:
            return jobs
        page += 1


def job_base(name: str) -> str:
    """A job's name without its matrix leg: 'gallery-health / health (3)' -> 'gallery-health / health'."""
    return re.sub(r" \([^()]*\)$", "", name)


# gallery-health's red states go with its bisect's probes up to this length (a dispatch input holds 65,535
# characters); past it, or with any red shard unnamed, a probe renders the whole gallery as before.
GALLERY_SUITE = "gallery-health"
STATES_CAP = 20000
WHOLE = "WHOLE"
# The step that judges a shard's red states: a red leg that failed elsewhere only (bun install on a runner whose temp
# dir it could not write, 6 of 22 legs of run 46058976708) rendered nothing, so it names no state and adds none.
GALLERY_JUDGE_STEP = "Judge the red states against the base"


def red_states(suite: str, name: str, verdicts: dict[str, tuple[str, str]], reds_dir: Path | None,
               steps: dict[str, frozenset] | None = None) -> str:
    """The red states (entry#variant, comma-joined) of every red matrix leg of name's gallery-health job on this
    batch run, from each leg's reds-N.txt (gallery-health.yml "Name the red states for a bisect probe"), so its
    probes render those alone: one shard, not the ~22 a whole render takes (~16k runner-min a day of probes, 11-27).
    "" (the whole render) for any other suite, or when a red leg named none (WHOLE: a crash or no health.json), has
    no file (the download failed, or no failing step is known) unless its failing steps are known and exclude the
    judge's (a setup red, before any render), or the list runs past STATES_CAP."""
    if suite != GALLERY_SUITE or reds_dir is None or not reds_dir.is_dir():
        return ""
    legs = [n for n, (s, c) in verdicts.items() if s == suite and c == "failure" and job_base(n) == job_base(name)]
    states: set[str] = set()
    for leg in legs:
        shard = re.search(r" \((\d+)\)$", leg)
        path = reds_dir / f"reds-{shard.group(1)}.txt" if shard else None
        if path is None or not path.is_file():
            if steps is not None and steps.get(leg) and GALLERY_JUDGE_STEP not in steps[leg]:
                continue
            return ""
        lines = [line.strip() for line in path.read_text(errors="replace").splitlines() if line.strip()]
        if not lines or WHOLE in lines or not all("#" in line and "," not in line for line in lines):
            return ""
        states.update(lines)
    joined = ",".join(sorted(states))
    return joined if len(joined) <= STATES_CAP else ""


def failing_steps(jobs: list[dict]) -> dict[str, frozenset]:
    """The failed steps of each failed job of a run: full job name -> step names."""
    out: dict[str, frozenset] = {}
    for job in jobs:
        if job.get("status") == "completed" and job.get("conclusion") == "failure":
            out[job.get("name") or ""] = frozenset(s.get("name") or "" for s in job.get("steps") or []
                                                    if s.get("conclusion") == "failure")
    return out


def red_step_names(steps: dict[str, frozenset], job: str) -> frozenset:
    """The failing steps of the job named job, its matrix legs merged."""
    base = job_base(job)
    names: frozenset = frozenset()
    for name, got in steps.items():
        if job_base(name) == base:
            names |= got
    return names


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


def tick_decision(tip: str, runs: list[dict], now: datetime, window_minutes: int, judged=lambda run_id: True,
                  every_merges: int = 0, ahead=lambda base: None, self_run_id: int = 0) -> tuple[str, str]:
    """(action, reason): action is 'dispatch' or 'skip'. judged(run id): that run's judge succeeded; a batch on
    the tip that tested nothing (drill-8 run 44966393364: its plan lost its runner) does not count as testing it.
    ahead(sha): how many commits the tip is ahead of sha (None when unknown); called only inside the window, where
    every_merges or more (when above 0) dispatch. self_run_id: the batch run whose judge step asks (it has judged,
    so it is neither in flight nor unjudged)."""
    batches = [r for r in runs if is_batch(r)]
    live = [r for r in batches if r.get("status") != "completed" and r.get("id") != self_run_id]
    if self_run_id:
        asked = judged
        judged = lambda run_id: run_id == self_run_id or asked(run_id)  # noqa: E731
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
        count = ahead(newest.get("head_sha")) if every_merges > 0 else None
        if count is not None and count >= every_merges:
            return "dispatch", f"tip {tip[:11]} is {count} commits ahead of batch run {newest.get('id')} on {str(newest.get('head_sha'))[:11]} (every {every_merges})"
        piled = f", {count} of {every_merges} merges" if count is not None else ""
        return "skip", f"last batch run {newest.get('id')} started {age:.0f} min ago, window {window_minutes} min{piled}"
    return "dispatch", f"tip {tip[:11]} is untested; last batch run {newest.get('id')} on {str(newest.get('head_sha'))[:11]}, {age:.0f} min ago"


def window_minutes(value: str | None) -> int:
    try:
        minutes = int(str(value or "").strip())
    except ValueError:
        return DEFAULT_WINDOW_MINUTES
    return minutes if minutes > 0 else DEFAULT_WINDOW_MINUTES


def every_merges(value: str | None) -> int:
    """NEXT_POST_MERGE_EVERY_MERGES: unset or unreadable is the default; 0 turns the count off (the window alone)."""
    try:
        count = int(str(value or "").strip())
    except ValueError:
        return DEFAULT_EVERY_MERGES
    return max(count, 0)


def ahead_by(repo: str, base: str, tip: str, api=None) -> int | None:
    """Commits tip has that base has not (one compare call, one commit listed); None when GitHub cannot say."""
    api = api or gh_api  # looked up per call, so a test's patch of gh_api reaches it
    if not base or not SHA_RE.match(str(base)):
        return None
    try:
        data = api(f"repos/{repo}/compare/{base}...{tip}?per_page=1") or {}
    except RuntimeError as err:
        print(f"::warning::compare {str(base)[:11]}...{tip[:11]}: {err}; the window decides")
        return None
    count = data.get("ahead_by")
    return count if isinstance(count, int) else None


HOURLY_WORKFLOW = "cmux-next-hourly-full-tier.yml"
HOURLY_MINUTES = 55  # the 30-minute schedule's ticks land at most an hour apart: :11 and :41


def hourly_decision(tip: str, runs: list[dict], now: datetime, minutes: int = HOURLY_MINUTES) -> tuple[str, str]:
    """Whether to start the hourly full tier at TIP. RUNS: its runs, newest first."""
    if any(r.get("status") != "completed" for r in runs):
        return "skip", "an hourly full tier run is in flight"
    if not runs:
        return "dispatch", "no hourly full tier run yet"
    newest = runs[0]
    if newest.get("head_sha") == tip:
        return "skip", "the tip has not moved since the last hourly full tier run"
    age = (now - parse_time(newest.get("created_at") or "")).total_seconds() / 60
    if age < minutes:
        return "skip", f"the last hourly full tier run is {age:.0f} min old"
    return "dispatch", f"the tip moved since {str(newest.get('head_sha') or '')[:10]}, {age:.0f} min ago"


def hourly_kick(args: argparse.Namespace, tip: str, now: datetime, api=None) -> str:
    """Start cmux-next-hourly-full-tier.yml on the branch when hourly_decision says so; any API error is a warning."""
    api = api or gh_api
    try:
        data = api(f"repos/{args.repo}/actions/workflows/{HOURLY_WORKFLOW}/runs?branch={args.branch}&per_page=5")
        runs = sorted((data or {}).get("workflow_runs") or [],
                      key=lambda r: (r.get("created_at") or "", r.get("id") or 0), reverse=True)
        action, reason = hourly_decision(tip, runs, now)
        print(f"hourly full tier: {action}: {reason}")
        if action == "dispatch" and not args.dry_run:
            api(f"repos/{args.repo}/actions/workflows/{HOURLY_WORKFLOW}/dispatches", method="POST",
                fields={"ref": args.branch})
        return action
    except (RuntimeError, ValueError, KeyError, TypeError) as err:
        print(f"::warning::hourly full tier kick skipped: {err}")
        return "error"


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
    hourly_kick(args, tip, datetime.now(timezone.utc))
    runs = list_runs(args.repo, args.branch)
    def judged(run_id: int) -> bool:
        return any(j.get("name") == "judge" and j.get("conclusion") == "success" for j in run_jobs(args.repo, run_id))

    self_run_id = int(getattr(args, "self_run_id", 0) or 0)
    action, reason = tick_decision(
        tip, runs, datetime.now(timezone.utc), window_minutes(args.window_minutes), judged,
        every_merges(getattr(args, "every_merges", None)), lambda base: ahead_by(args.repo, base, tip), self_run_id,
    )
    print(f"{action}: {reason}")
    if action == "dispatch" and not args.dry_run:
        gh_api(
            f"repos/{args.repo}/actions/workflows/{WORKFLOW}/dispatches",
            method="POST",
            fields={"ref": args.branch, "inputs": {"mode": "batch", "reason": "next" if self_run_id else "tick"}},
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


# The plan's look for an earlier verdict of the same probe waits this long at most on a spent rate limit, then
# runs the suite as before: a probe never waits on the lookup longer than a short render would take to start.
REUSE_LOOKUP_WAIT = 60.0


def reusable_run(args: argparse.Namespace, suites: dict[str, Suite]) -> tuple[str, str]:
    """The earlier run of this same probe (same title: suite, job, commit) whose verdict this run reads instead of
    running the suite again, and why; ("", "") when it runs the suite. The dispatch's own reuse input wins (a judge
    that already had the verdict but could not read its origin run sends it). A confirm run never reuses: its whole
    point is another render. A hot swap out probe never does either: its tree is not the commit's. Gallery-health
    commit 72157adeb82 rendered twice (runs 45955682014 and 45961171063, 11-27, 7 runner-hours each) for one verdict."""
    if getattr(args, "confirm", "") or getattr(args, "pieces", ""):
        return "", ""
    if str(getattr(args, "reuse", "") or "").isdigit():
        return str(args.reuse), "the dispatch named it"
    probe = Probe(args.suite, getattr(args, "job", "") or "", args.only or "", args.probe_sha, args.good or "", "", "",
                  states=getattr(args, "states", "") or "")
    budget = API_WAIT_BUDGET["seconds"]
    API_WAIT_BUDGET["seconds"] = min(budget, REUSE_LOOKUP_WAIT)
    try:
        runs = list_runs(args.repo, args.branch)

        def jobs_of(rid: int) -> tuple[dict[str, tuple[str, str]], bool]:
            return suite_verdicts(run_jobs(args.repo, rid), suites), True

        known = known_verdict(runs, probe, jobs_of)
    except RuntimeError as err:
        print(f"plan: earlier probe runs unreadable, running the suite: {err}", file=sys.stderr)
        return "", ""
    finally:
        API_WAIT_BUDGET["seconds"] = budget
    if not known:
        return "", ""
    return str(known[1]["id"]), f"it was already {known[0]} there"


def cmd_plan(args: argparse.Namespace) -> int:
    suites = load_manifest(Path(args.manifest))
    if args.mode == PROBE:
        if args.suite not in suites or not SHA_RE.match(args.probe_sha or ""):
            raise SystemExit(f"probe needs a known suite and a commit sha (got {args.suite!r}, {args.probe_sha!r})")
        reuse, why = reusable_run(args, suites)
        write_outputs(args.github_output, {"suites": " " if reuse else f" {args.suite} ", "sha": args.probe_sha, "only": args.only or "",
                                           "base": args.good if SHA_RE.match(args.good or "") else "", "reuse": reuse,
                                           "states": getattr(args, "states", "") or ""})
        if reuse:
            summary(args.summary, f"Probe: `{args.suite}` job `{args.only or '(all)'}` at `{args.probe_sha}` reuses run {reuse}'s verdict ({why}); no suite runs.")
        else:
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
        {"suites": " " + " ".join(plan["suites"]) + " ", "sha": args.sha, "only": "", "base": plan["base"], "states": ""},
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
    confirm: str = ""  # flake-aware confirm: 'red-N' (sha is the culprit, bad) or 'green-N' (sha is its parent, good)
    step: str = ""  # the origin red's failing step names (STEP_SEP-joined): a probe is red only if it fails one of them
    reuse: str = ""  # an earlier run of this same probe whose suite jobs give this run's verdict (no suite runs again)
    states: str = ""  # gallery-health: the origin's red states (entry#variant, comma-joined), the only ones rendered

    @property
    def states_key(self) -> str:
        """A short hash of states for the run's title: probes of other states at one commit are other probes."""
        return hashlib.sha1(self.states.encode()).hexdigest()[:10] if self.states else ""

    def inputs(self) -> dict[str, str]:
        extra = {"pieces": self.pieces} if self.pieces else {}
        extra |= {"confirm": self.confirm} if self.confirm else {}
        extra |= {"step": self.step} if self.step else {}
        extra |= {"reuse": self.reuse} if self.reuse else {}
        extra |= {"states": self.states, "states_key": self.states_key} if self.states else {}
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


def another_red(name: str, steps: dict[str, frozenset] | None, steps_of, run_id: int) -> bool:
    """Whether an earlier run's red of job name is a different red from this run's: both runs' failing steps for the
    job are known and share none. Run 46058976708 (11-27) failed web-typecheck on `Install dependencies` (a runner's
    bun install) while the batch before it had failed it on `Typecheck` (tests/vm-image-pin-cmux-tui.test.ts): the
    two read as one stuck red, so the bisect chased the install step for seven probes and four confirm runs
    (46070818999..46070828334) to "a flake, quarantined", and the typecheck red behind it was a known red, never
    bisected. A different red is no verdict for this one: new_reds and stuck_reds look past it."""
    if steps is None or steps_of is None:
        return False
    mine, theirs = red_step_names(steps, name), red_step_names(steps_of(run_id), name)
    return bool(mine and theirs and not mine & theirs)


def new_reds(sha: str, verdicts: dict[str, tuple[str, str]], runs: list[dict], jobs_of,
             suites: dict[str, "Suite"] | None = None, steps: dict[str, frozenset] | None = None,
             steps_of=None) -> tuple[list[tuple[str, str, str]], list[str]]:
    """Red jobs of this batch run that were green on the newest earlier batch run where they
    finished: (job name, suite, good sha). Also the notes for the reds that are not new.
    jobs_of(run id) gives that run's verdicts, or (verdicts, judged): a red on a run whose judge
    job did not succeed counts as no verdict, so it is still bisected later. Matrix legs of one suite job with the same
    good are one bisect, as in stuck_reds: legs share a probe title and concurrency group, so a chain per leg cancelled
    all but one while pending and each spent a MAX_CHAINS slot (gallery-health's 22 shards, run 45942875725)."""
    reds = [name for name, (_, conclusion) in sorted(verdicts.items()) if conclusion == "failure"]
    earlier = [r for r in runs if is_batch(r) and r.get("status") == "completed" and r.get("head_sha") != sha]
    found: list[tuple[str, str, str]] = []
    notes: list[str] = []
    cache: dict[int, dict[str, tuple[str, str]]] = {}
    seen: set[tuple[str, str, str]] = set()
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
            # A red on other steps than this one's (another_red) is no verdict on this red: look past it.
            if before and before[1] == "failure" and another_red(name, steps, steps_of, run["id"]):
                continue
            if before and before[1] in ("success", "failure"):
                last = (run, before[1])
                break
        if last is None:
            notes.append(f"`{name}` is red with no earlier batch verdict: no bisect.")
        elif last[1] == "failure":
            notes.append(f"`{name}` was already red on `{last[0]['head_sha'][:11]}` (run {last[0]['id']}): a known red, no bisect.")
        else:
            only = suites[suite].probe_only(name.partition(" / ")[2]) if suites and suite in suites else job_base(name)
            key = (suite, only, last[0]["head_sha"])
            if key not in seen:
                seen.add(key)
                found.append((name, suite, last[0]["head_sha"]))
    return found, notes


def stuck_reds(sha: str, verdicts: dict[str, tuple[str, str]], runs: list[dict], jobs_of,
               suites: dict[str, "Suite"], chain_start=None, steps: dict[str, frozenset] | None = None,
               steps_of=None, skipped: dict[str, str] | None = None) -> list[tuple[str, str, str, str]]:
    """The reds new_reds calls known that get a bisect anyway: (job name, suite, good sha, bad sha).

    A job red on this batch run and on the newest earlier judged batch run where it finished has a last green batch
    run further back (good) and a first red one after it (bad): the culprit is in good..bad. It is bisected there,
    with no confirming probe (two batch runs already agree it is red), unless a probe of the same suite job started
    after the first red batch run is still running, or MAX_REBISECTS bisects of it already started and were judged
    (chain_start(good, bad) is a bisect's first probe sha; a probe whose judge died is not a bisect done). Matrix legs
    of one suite job with the same good and bad are one bisect (gallery-health's 21 shards were 21 known reds).
    runs: this workflow's runs, newest first, none newer than the judging run, so a probe's judge reading the same
    runs (cmd_judge, before its origin) agrees with the batch run that dispatched it.
    skipped, when given, gets each red that is not bisected and why: the summary said only "a known red, no bisect"
    for 23 of run 45987000605's 25 known reds, so nobody could tell a red past the reach from a capped one."""
    skip = skipped if skipped is not None else {}
    reds = [name for name, (_, conclusion) in sorted(verdicts.items()) if conclusion == "failure"]
    earlier = [r for r in runs if is_batch(r) and r.get("status") == "completed" and r.get("head_sha") != sha]
    probes = [r for r in runs if (r.get("display_title") or "").split(" ", 1)[0] == PROBE]
    cache: dict[int, object] = {}
    out: list[tuple[str, str, str, str]] = []
    seen: set[tuple[str, str, str, str]] = set()
    for name in reds:
        suite = verdicts[name][0]
        first = green = None
        for run in earlier:
            if run["id"] not in cache:
                cache[run["id"]] = jobs_of(run["id"])
            got, judged = cache[run["id"]] if isinstance(cache[run["id"]], tuple) else (cache[run["id"]], True)
            before = got.get(name)
            if not before or before[1] not in ("success", "failure"):
                continue
            if before[1] == "failure":
                if judged and not another_red(name, steps, steps_of, run["id"]):
                    first = run
                continue
            green = run
            break
        if first is None:
            continue  # a new red: new_reds bisects it
        if green is None:
            skip[name] = f"no green batch run in reach ({len(earlier)} read), red since `{first['head_sha'][:11]}` or before"
            continue
        only = suites[suite].probe_only(name.partition(" / ")[2]) if suite in suites else ""
        key = (suite, only, green["head_sha"], first["head_sha"])
        if key in seen:
            continue
        prefix = f"{PROBE} {suite} {only or 'all'} at "
        mine = [p for p in probes if (p.get("display_title") or "").startswith(prefix)
                and (p.get("created_at") or "") > (first.get("created_at") or "")]
        # A lone probe that fell back to the whole suite (cmd_judge) goes on as `all`: a running one is this job's chain too.
        running = mine + ([p for p in probes if (p.get("display_title") or "").startswith(f"{PROBE} {suite} all at ")
                           and (p.get("created_at") or "") > (first.get("created_at") or "")] if only.startswith(LONE_PREFIX) else [])
        if any(p.get("status") != "completed" for p in running):
            skip[name] = "a probe of it is still running"
            continue
        start = chain_start(green["head_sha"], first["head_sha"]) if chain_start else ""
        done = 0
        for p in mine:
            if start and not (p.get("display_title") or "").endswith(f" at {start}"):
                continue
            if p["id"] not in cache:
                cache[p["id"]] = jobs_of(p["id"])
            got = cache[p["id"]]
            if not isinstance(got, tuple) or got[1]:
                done += 1
        if done >= MAX_REBISECTS:
            skip[name] = (f"{done} bisects of `{green['head_sha'][:11]}..{first['head_sha'][:11]}` already ran with no revert;"
                          " a person should read them")
            continue
        seen.add(key)
        out.append((name, suite, green["head_sha"], first["head_sha"]))
    return out


def unreached_reds(sha: str, verdicts: dict[str, tuple[str, str]], runs: list[dict], jobs_of) -> list[str]:
    """The reds of verdicts that some earlier judged batch run in runs also had red and none had green: their last green
    is past the reach, so stuck_reds cannot bisect them without deeper runs (DEEP_LOOKBACK_BATCHES)."""
    earlier = [r for r in runs if is_batch(r) and r.get("status") == "completed" and r.get("head_sha") != sha]
    out = []
    for name in sorted(n for n, (_, c) in verdicts.items() if c == "failure"):
        seen = set()
        for run in earlier:
            got = jobs_of(run["id"])
            got, judged = got if isinstance(got, tuple) else (got, True)
            before = got.get(name)
            if before and before[1] in ("success", "failure") and (judged or before[1] == "success"):
                seen.add(before[1])
            if "success" in seen:
                break
        if seen == {"failure"}:
            out.append(name)
    return out


def with_deeper_runs(repo: str, branch: str, sha: str, verdicts: dict[str, tuple[str, str]], runs: list[dict], jobs_of) -> list[dict]:
    """runs, plus DEEP_LOOKBACK_BATCHES batch runs older than its oldest when a red of verdicts has no green in it. The batch
    judge and each probe's judge call it on the same runs and verdicts for the job, so both read the same deeper runs."""
    if not runs or not unreached_reds(sha, verdicts, runs, jobs_of):
        return runs
    oldest = min((r.get("created_at") or "") for r in runs)
    if not oldest:
        return runs
    have = {r.get("id") for r in runs}
    deeper = list_runs(repo, branch, batches=DEEP_LOOKBACK_BATCHES, created_before=oldest)
    return runs + [r for r in deeper if r.get("id") not in have and (r.get("created_at") or "") < oldest]


def with_skip_reason(note: str, skipped: dict[str, str]) -> str:
    """A known-red note with why stuck_reds did not bisect it, when it said."""
    for name, why in skipped.items():
        if note.startswith(f"`{name}` was already red") and note.endswith("no bisect."):
            return f"{note[:-1]}: {why}."
    return note


def stuck_chain_start(good: str, bad: str) -> str:
    """The sha a stuck red's bisect over good..bad starts at (stuck_probe's): stuck_reds counts finished bisects by it,
    in the batch judge and in each probe's judge alike, so both agree on whether the bisect is capped."""
    return stuck_probe("", "", "", good, bad, "", first_parent_range(good, bad)).sha


def stuck_probe(name: str, suite: str, only: str, good: str, bad: str, origin: str, commits: list[str], step: str = "",
                states: str = "") -> Probe:
    """The first probe of a stuck red's bisect: the middle of good..bad (bad itself when that is one commit, which
    re-confirms it: next_step reads a pass there as a flake)."""
    span = commits_between(commits, good, bad)
    mid = span[(len(span) - 1) // 2] if span else bad
    return Probe(suite, name, only, mid, good, bad, origin, step=step, states=states)


def next_step(probe: Probe, conclusion: str, commits: list[str]) -> tuple[str, Probe | str | None]:
    """After a probe finished with conclusion: ('probe', next Probe), ('culprit', sha),
    ('flake', None), ('lost', None) or ('retry', Probe). commits: good..bad (or good..sha for the
    confirming probe), oldest first."""
    if conclusion == "skipped":
        # The job's own condition skipped it at this commit (probe_conclusion reads a skip behind a lost or red
        # job as no verdict): the same inputs skip it again. Probes 716208d2c92 and d98c77aec8a (compile-fleet,
        # 11-27) each ran three times, every run skipped, before the bisect stopped all the same.
        return "lost", None
    if conclusion not in ("success", "failure"):
        if probe.tries < MAX_PROBE_RETRIES:
            return "retry", Probe(**{**probe.__dict__, "tries": probe.tries + 1, "reuse": ""})  # no verdict to reuse: run it
        return "lost", None
    good, bad = probe.good, probe.bad
    if bad and probe.sha == bad and conclusion == "success":  # a stuck red's one-commit range, re-confirmed: it passed
        return "flake", None
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
    # The origin red's failing step travels with every probe of the chain (#61284 set it on the first only).
    # So do its red states: every probe of a gallery-health chain renders the origin's reds alone.
    return "probe", Probe(probe.suite, probe.job, probe.only, mid, good, bad, probe.origin, step=probe.step, states=probe.states)


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
    if probe.confirm:
        # A confirm run tests the culprit (bad) or its parent (good) again: bad is in the covered commits and good
        # is the commit just before it there (or the last green, when bad is the first covered commit).
        side = probe.confirm.split("-", 1)[0]
        if probe.bad not in span:
            return f"bad `{probe.bad[:11]}` is not in the commits origin run {origin.get('id')} covered (`{green[:11]}`..`{head[:11]}`)"
        at = span.index(probe.bad)
        if probe.good != (span[at - 1] if at else green):
            return f"good `{probe.good[:11]}` is not the parent of the confirmed culprit `{probe.bad[:11]}`"
        if probe.sha != {"red": probe.bad, "green": probe.good}.get(side):
            return f"confirm `{probe.confirm}` probe's sha `{probe.sha[:11]}` is not its culprit or parent"
        return ""
    for label, sha in (("sha", probe.sha), ("bad", probe.bad)):
        if (sha or label == "sha") and sha not in span:
            return f"{label} `{sha[:11]}` is not in the commits origin run {origin.get('id')} covered (`{green[:11]}`..`{head[:11]}`)"
    if probe.good != green and probe.good not in span:
        return f"good `{probe.good[:11]}` is not in the commits origin run {origin.get('id')} covered (`{green[:11]}`..`{head[:11]}`)"
    if not probe.bad and probe.sha != head:
        return f"the confirming probe's sha `{probe.sha[:11]}` is not origin run {origin.get('id')}'s commit `{head[:11]}`"
    return ""


# GitHub answers a workflow dispatch with a 5xx now and then (HTTP 500 "Failed to run workflow dispatch", 502
# "Server Error"); before this retry one such answer ended the judge and with it the bisect: nothing dispatched the
# next probe, so the red stayed unbisected (cmux runs 45834479312 and 45839196986, 11-26).
SERVER_ERROR = re.compile(r"HTTP 5\d\d|Server Error", re.I)
DISPATCH_WAITS = (15, 45)


def probe_title(probe: Probe) -> str:
    """The probe run's title (the workflow's run-name for a probe dispatch)."""
    return (f"{PROBE} {probe.suite} {probe.only or 'all'} at {probe.sha}" + (f" confirm {probe.confirm}" if probe.confirm else "")
            + (f" states {probe.states_key}" if probe.states else ""))


def probe_conclusion(verdicts: dict[str, tuple[str, str]], probe: Probe, steps: dict[str, frozenset] | None = None) -> str:
    """A probe run's verdict: the job with the red job's name, else the worst of the suite's jobs
    (the probe ran the whole suite when the red job had no manifest id); "" when it gave none.

    A failure counts only when it is the origin's red: steps (this run's failing steps per job, see failing_steps) must
    include one of probe.step's names. A probe that failed on other steps only, with some failing step known, reproduced
    a different red, so it is "success" for this bisect: the culprit is where the origin's own red began. Run 45971256912
    (ef869a7bc39, gallery-health) failed on composer layout flakes, not the gallery:build break the batch run found, and the
    bisect chased that for four probes."""
    verdict = probe_verdict(verdicts, probe)
    if verdict == "failure" and probe.step and steps is not None:
        mine = {n for n, (s, _) in verdicts.items() if s == probe.suite}
        got: frozenset = frozenset()
        for name, names in steps.items():
            if name in mine and (job_base(name) == job_base(probe.job) or probe.job not in verdicts):
                got |= names
        if got and not got & set(probe.step.split(STEP_SEP)):
            return "success"
    return verdict


def probe_verdict(verdicts: dict[str, tuple[str, str]], probe: Probe) -> str:
    mine = {n: c for n, (s, c) in verdicts.items() if s == probe.suite}
    if probe.job not in mine:
        # A matrix leg ("s / health (0)") that never ran is listed by its bare name ("s / health"): the matrix
        # did not expand. Probe run 45969411338 (gallery-health, 11-27): its plan lost its runner, health showed as
        # skipped by its bare name, and the suite's worst job (the lost plan, a failure) was read as the leg's red,
        # so the bisect moved to c5385caf with c6ff1246 judged bad on no evidence.
        bare = re.sub(r" \([^()]*\)$", "", probe.job)
        if bare != probe.job and bare in mine:
            mine[probe.job] = mine[bare]
    if probe.only.startswith(LONE_PREFIX) and mine.get(probe.job) not in ("success", "failure"):
        return ""  # the lone job did not run alone (its own condition wants the whole suite): cmd_judge runs the suite
    if mine.get(probe.job) == "skipped" and any(c not in ("success", "skipped") for c in mine.values()):
        return ""  # skipped behind a job that failed or lost its runner: no verdict, worth running again
    return mine.get(probe.job) or ("failure" if "failure" in mine.values() else "success" if mine and all(c in ("success", "skipped") for c in mine.values()) else "")


def whole_suite_skip(verdicts: dict[str, tuple[str, str]], probe: Probe, steps: dict[str, frozenset]) -> bool:
    """A whole-suite probe (only empty) whose red job was skipped while every other job of the suite finished on its
    own: none cancelled and every failed one failed a named step (a lost runner fails with none). The job's own
    condition skipped it, so running the same probe again skips it again."""
    mine = {n: c for n, (s, c) in verdicts.items() if s == probe.suite}
    if probe.only or probe.pieces or mine.get(probe.job) != "skipped":
        return False
    return all(c in ("success", "skipped") or (c == "failure" and steps.get(n)) for n, c in mine.items())


def known_verdict(runs: list[dict], probe: Probe, jobs_of, steps_of=None) -> tuple[str, dict] | None:
    """A finished probe run of the same title (suite, job, commit) from an earlier bisect, and its verdict, if it
    gave one: a bisect the next batch starts again then reads it instead of running the same probe again (the
    web-tests chain of 11-26 re-probed 95ef861, 1d3e443, a36597a, 2861d8b and 11d8c59 an hour after the first).
    "skipped" counts too: the job's own condition skipped it there, and would again."""
    # A states probe also reads the whole render's verdict at the same commit: it rendered those states too.
    titles = {probe_title(probe), probe_title(Probe(**{**probe.__dict__, "states": ""}))}
    for run in runs:
        if (run.get("display_title") or "") in titles and run.get("status") == "completed":
            conclusion = probe_conclusion(jobs_of(run["id"])[0], probe, steps_of(run["id"]) if steps_of else None)
            if conclusion in ("success", "failure", "skipped"):
                return conclusion, run
    return None


def first_unknown_probe(runs: list[dict], probe: Probe, commits: list[str], jobs_of, steps_of=None) -> tuple[Probe | None, list[str]]:
    """The batch judge's first probe of a bisect, past the probes an earlier bisect already ran: while a probe's
    verdict is known and the next step is another probe, take that one. A known verdict that would end the bisect
    (a culprit or a flake) keeps its probe, so that probe's judge names it as before; a known skip gives None (the
    same probe would skip again). A stuck red's bisect starts again about hourly and re-ran the same middle
    commits: 7f0fe7d8a65 (rust-workspaces) four times, 716208d2c92 (compile-fleet) four, 11-27."""
    notes: list[str] = []
    for _ in range(len(commits) + 1):  # each known verdict narrows the range, so this ends
        known = known_verdict(runs, probe, jobs_of, steps_of)
        if not known:
            break
        step, value = next_step(probe, known[0], commits)
        if step == "lost":
            notes.append(f"`{probe.job}` was already skipped at `{probe.sha[:11]}` (probe run {known[1]['id']}); no probe.")
            return None, notes
        if step != "probe":
            break
        assert isinstance(value, Probe)
        notes.append(f"`{probe.job}` was already {known[0]} at `{probe.sha[:11]}` (probe run {known[1]['id']}); probing `{value.sha[:11]}` instead.")
        probe = value
    return probe, notes


def dispatch_probe(repo: str, branch: str, probe: Probe, api=None, sleep=time.sleep) -> None:
    """Dispatch one probe. A 5xx may still have started the run, so before each retry this looks for a probe
    run of the same title (the workflow's run-name) on the branch, and stops if one is there."""
    # DISPATCH_TOKEN: the revert job's GITHUB_TOKEN (actions: write), whose GH_TOKEN may be the App's, which has none.
    api = api or gh_api  # looked up per call, so a test's patch of gh_api reaches it
    token = os.environ.get("DISPATCH_TOKEN") or os.environ.get("GH_TOKEN", "")
    title = probe_title(probe)
    for attempt, wait in enumerate((*DISPATCH_WAITS, None)):
        if attempt:
            listed = api(f"repos/{repo}/actions/workflows/{WORKFLOW}/runs?branch={branch}&event=workflow_dispatch&per_page=20")
            if any((r.get("display_title") or "") == title and r.get("status") != "completed" for r in (listed or {}).get("workflow_runs", [])):
                print(f"dispatch of `{title}` answered 5xx but its run started", file=sys.stderr)
                return
        try:
            api(f"repos/{repo}/actions/workflows/{WORKFLOW}/dispatches", method="POST", fields={"ref": branch, "inputs": probe.inputs()}, tokens=[token])
            return
        except RuntimeError as e:
            if wait is None or not SERVER_ERROR.search(str(e)):
                raise
            print(f"dispatch of `{title}`: {e}; retrying in {wait}s", file=sys.stderr)
            sleep(wait)


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


def confirm_probes(job: Probe, culprit: str, parent: str) -> list[Probe]:
    """The confirm round for a bisect's culprit: CONFIRM_RUNS runs at the culprit (red-N) and at its parent (green-N)."""
    return [Probe(job.suite, job.job, job.only, sha, parent, culprit, job.origin, confirm=f"{side}-{n}", step=job.step, states=job.states)
            for n in range(1, CONFIRM_RUNS + 1) for side, sha in (("red", culprit), ("green", parent))]


def judge_confirm(probe: Probe, conclusion: str, run_id: int, runs: list[dict], jobs_of, steps_of=None) -> tuple[str, str]:
    """After one confirm run: ('culprit'|'flake'|'unsure'|'wait', why). Every confirm run's judge reads the
    round's other runs (newest run per title: a retry replaces its run). Any verdict against its side (the culprit
    passed, or its parent failed) is a flake. With no flake, only the judge that sees every run of the round
    settled decides, and of those only the newest run's, or any once the newest run has finished, so the round
    opens one revert. jobs_of(run id) gives (verdicts, judged)."""
    want = {"red": "failure", "green": "success"}
    seen = {probe.confirm: (conclusion, run_id, True)}
    for other in confirm_probes(probe, probe.bad, probe.good):
        if other.confirm == probe.confirm:
            continue
        title = probe_title(other)
        run = next((r for r in runs if (r.get("display_title") or "") == title), None)
        if run is None:
            seen[other.confirm] = ("", 0, False)
            continue
        got, judged = jobs_of(run["id"])
        verdict = probe_conclusion(got, other, steps_of(run["id"]) if steps_of else None)
        seen[other.confirm] = (verdict, int(run["id"]), judged or run.get("status") == "completed")
    against = [c for c, (v, _, _) in seen.items() if v in ("success", "failure") and v != want[c.split("-", 1)[0]]]
    if against:
        return "flake", f"confirm run(s) {', '.join(sorted(against))} disagreed with the bisect"
    pending = [c for c, (v, _, done) in seen.items() if v not in ("success", "failure", "skipped") and not done]
    if pending:
        return "wait", f"waiting on confirm run(s) {', '.join(sorted(pending))}"
    newest = max(seen.values(), key=lambda v: v[1])
    if newest[1] != run_id and not newest[2]:
        return "wait", f"every confirm run has a verdict; run {newest[1]}'s judge decides"
    sides = {c.split("-", 1)[0] for c, (v, _, _) in seen.items() if v == want[c.split("-", 1)[0]]}
    if sides != {"red", "green"}:
        return "unsure", "a side of the confirm round gave no verdict"
    return "culprit", f"{len(seen)} confirm runs agree"


CONFIRM_REUSE_ENV = "POST_MERGE_CONFIRM_REUSE"


def confirm_reuse_on() -> bool:
    """POST_MERGE_CONFIRM_REUSE=0 (vars.POST_MERGE_CONFIRM_REUSE) turns earlier_confirm_round off: every culprit's
    confirm round renders again, as before."""
    return (os.environ.get(CONFIRM_REUSE_ENV) or "1").strip() != "0"


JOB_PROBES_ENV = "POST_MERGE_JOB_PROBES_PER_DAY"
# A red on every commit (an outside service, a base break no single merge made) is never pinned, yet each new batch red
# made a new (good, bad) key, so MAX_REBISECTS bounded nothing: 11-27 19:20Z-23:55Z spent 98 probe runs on 8 suite jobs,
# 52 of them confirm runs failing on both sides (rust-workspaces 17, web-tests 16, gallery-health 15, ...), about 70
# probes a day per red job and 23k-34k runner minutes a day for the workflow. A suite job whose probes started this
# many times in the last 24 h starts no new bisect from a batch run; a chain already running goes on. 0 turns it off.
DEFAULT_JOB_PROBES_PER_DAY = 12


def job_probes_per_day() -> int:
    """vars.POST_MERGE_JOB_PROBES_PER_DAY: the daily probe cap per suite job, DEFAULT_JOB_PROBES_PER_DAY when unset; 0 is no cap."""
    raw = (os.environ.get(JOB_PROBES_ENV) or "").strip()
    return int(raw) if raw.isdigit() else DEFAULT_JOB_PROBES_PER_DAY


def job_probes_today(runs: list[dict], suite: str, only: str, now: datetime) -> int:
    """Probe runs of suite job only (all its confirm and states runs too) created in the 24 h before now."""
    prefix = f"{PROBE} {suite} {only or 'all'} at "
    count = 0
    for r in runs:
        if not (r.get("display_title") or "").startswith(prefix):
            continue
        try:
            if (now - parse_time(r.get("created_at") or "")).total_seconds() < 86400:
                count += 1
        except ValueError:
            continue
    return count


def over_probe_cap(runs: list[dict], suites: dict, suite: str, name: str, now: datetime) -> int:
    """The suite job's probe count today when it is at or over job_probes_per_day(), else 0."""
    cap = job_probes_per_day()
    if cap <= 0 or suite not in suites:
        return 0
    only = suites[suite].probe_only(name.partition(" / ")[2])
    n = job_probes_today(runs, suite, only, now)
    return n if n >= cap else 0


def runs_for_confirm(args: argparse.Namespace) -> list[dict]:
    if not confirm_reuse_on():
        return []
    try:
        return list_runs(args.repo, args.branch)
    except RuntimeError:
        return []


def earlier_confirm_round(round_: list[Probe], runs: list[dict], jobs_of, steps_of=None) -> tuple[str, str] | None:
    """The verdict of an earlier confirm round with the same titles (suite, job, culprit, parent, side-N) when every
    one of its runs finished with a verdict: ('culprit'|'flake'|'unsure', why), read as judge_confirm reads a round.
    None (dispatch the round) when any run of it is missing, unfinished or gave no verdict, or reuse is off. A stuck
    red's re-bisect lands on the same culprit and re-rendered the same four runs: web agent-pane-real-acpmux's round
    at 4dbaa78f/e8f78400 ran three times on 11-27 (15:23Z, 16:21Z, 19:21Z), 80 of 466 probe runs that day were
    repeats of a finished confirm title."""
    if not round_ or not runs or not confirm_reuse_on():
        return None
    first, found = round_[0], None
    for p in round_:
        title = probe_title(p)
        run = next((r for r in runs if (r.get("display_title") or "") == title), None)  # newest per title
        if run is None or run.get("status") != "completed":
            return None
        verdict = probe_conclusion(jobs_of(run["id"])[0], p, steps_of(run["id"]) if steps_of else None)
        if verdict not in ("success", "failure", "skipped"):
            return None
        if p is first:
            found = (verdict, int(run["id"]))
    assert found is not None
    step, why = judge_confirm(first, found[0], found[1], runs, jobs_of, steps_of)
    return (step, why) if step in ("culprit", "flake", "unsure") else None


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
    # A probe that reuses an earlier run of itself (reusable_run) ran no suite: that run's jobs are its verdict.
    reuse = str(getattr(args, "reuse", "") or "") if args.mode == PROBE else ""
    jobs = run_jobs(args.repo, int(reuse) if reuse.isdigit() else args.run_id)
    verdicts = suite_verdicts(jobs, suites)
    out: dict[str, str] = {"culprit": "", "job": "", "good": "", "origin": "", "pieces": "", "piece": ""}
    memo: dict[int, tuple[dict[str, tuple[str, str]], bool]] = {}
    step_memo: dict[int, dict[str, frozenset]] = {args.run_id: failing_steps(jobs)}

    def jobs_of(rid: int) -> tuple[dict[str, tuple[str, str]], bool]:
        # new_reds and stuck_reds walk the same earlier runs: read each run's jobs once.
        if rid not in memo:
            earlier = run_jobs(args.repo, rid)
            step_memo[rid] = failing_steps(earlier)
            judged = any(j.get("name") == "judge" and j.get("conclusion") == "success" for j in earlier)
            memo[rid] = (suite_verdicts(earlier, suites), judged)
        return memo[rid]

    def steps_of(rid: int) -> dict[str, frozenset]:
        jobs_of(rid)
        return step_memo[rid]

    if args.mode != PROBE:
        reds_dir = Path(args.reds_dir) if getattr(args, "reds_dir", "") else None
        # Only runs older than this one, as a probe's judge reads them (before its origin), so both agree.
        runs = list_runs(args.repo, args.branch, before=int(args.run_id or 0), batches=LOOKBACK_BATCHES)
        found, notes = new_reds(args.sha, verdicts, runs, jobs_of, suites, steps_of(args.run_id), steps_of)
        deep = with_deeper_runs(args.repo, args.branch, args.sha, verdicts, runs, jobs_of)
        skipped: dict[str, str] = {}
        stuck = stuck_reds(args.sha, verdicts, deep, jobs_of, suites, chain_start=stuck_chain_start,
                           steps=steps_of(args.run_id), steps_of=steps_of, skipped=skipped)
        stuck_names = {name for name, *_ in stuck}
        notes = [n for n in notes if not any(n.startswith(f"`{name}` was already red") for name in stuck_names)]
        notes = [with_skip_reason(n, skipped) for n in notes]
        for note in notes:
            summary(args.summary, f"- {note}")
        if not found:
            summary(args.summary, f"No new red on `{args.sha[:11]}` ({len(verdicts)} suite jobs finished).")
        now = datetime.now(timezone.utc)
        capped = [(name, n) for name, suite, *_ in found + stuck if (n := over_probe_cap(runs, suites, suite, name, now))]
        capped_names = {name for name, _ in capped}
        for name, n in capped:
            summary(args.summary, f"- Red `{name}`: its suite job ran {n} probes in 24 h (cap {job_probes_per_day()}, "
                                  f"vars.{JOB_PROBES_ENV}), named only, no new bisect.")
        found = [f for f in found if f[0] not in capped_names]
        stuck = [s for s in stuck if s[0] not in capped_names]
        for name, suite, good in found[:MAX_CHAINS]:
            inner = name.partition(" / ")[2]
            probe = Probe(suite, name, suites[suite].probe_only(inner), args.sha, good, "", str(args.run_id),
                          step=STEP_SEP.join(sorted(red_step_names(steps_of(args.run_id), name))),
                          states=red_states(suite, name, verdicts, reds_dir, steps_of(args.run_id)))
            summary(args.summary, f"- New red `{name}`: green on `{good[:11]}`; probing `{args.sha[:11]}` once to confirm, then bisecting.")
            if not args.dry_run:
                dispatch_probe(args.repo, args.branch, probe)
        for name, _, good in found[MAX_CHAINS:]:
            summary(args.summary, f"- New red `{name}` (green on `{good[:11]}`): over the {MAX_CHAINS}-bisect cap, named only.")
        for name, suite, good, bad in stuck[:MAX_STUCK_CHAINS]:
            inner = name.partition(" / ")[2]
            span = first_parent_range(good, bad)
            probe, known_notes = first_unknown_probe(runs, stuck_probe(name, suite, suites[suite].probe_only(inner), good, bad, str(args.run_id), span,
                                                      STEP_SEP.join(sorted(red_step_names(steps_of(args.run_id), name))),
                                                      red_states(suite, name, verdicts, reds_dir, steps_of(args.run_id))), span, jobs_of, steps_of)
            for note in known_notes:
                summary(args.summary, f"  - {note}")
            if probe is None:
                summary(args.summary, f"- Stuck red `{name}`: green on `{good[:11]}`, red since `{bad[:11]}`; its probe is known to skip, no bisect.")
                continue
            summary(args.summary, f"- Stuck red `{name}`: green on `{good[:11]}`, red since `{bad[:11]}`; bisecting there from `{probe.sha[:11]}`.")
            if not args.dry_run:
                dispatch_probe(args.repo, args.branch, probe)
        for name, _, good, bad in stuck[MAX_STUCK_CHAINS:]:
            summary(args.summary, f"- Stuck red `{name}` (green on `{good[:11]}`, red since `{bad[:11]}`): over the {MAX_STUCK_CHAINS}-bisect cap, named only.")
        write_outputs(args.github_output, out)
        return 0

    probe = Probe(args.suite, args.job, args.only, args.probe_sha, args.good, args.bad, args.origin, int(args.tries or 0),
                  args.pieces or "", getattr(args, "confirm", "") or "", getattr(args, "step", "") or "",
                  reuse if reuse.isdigit() else "", getattr(args, "states", "") or "")
    found: list[tuple[str, str, str]] = []
    try:
        origin = gh_api(f"repos/{args.repo}/actions/runs/{probe.origin}") if probe.origin.isdigit() else None
        if origin and is_batch(origin):
            before = list_runs(args.repo, args.branch, before=origin["id"], batches=LOOKBACK_BATCHES)
            # Only the probe's own job: probe_refusal reads found for it alone, and new_reds and stuck_reds walk each
            # red job on its own. All of the origin's reds walked back to the deepest one's green: at the 24-batch
            # lookback (cmux#60187) that was every batch run, two job pages each, in every probe's judge (run
            # 45931127675: 24 runs for any probe, 9 for its web-typecheck job, 2 for cmux-rd-host), and the
            # installation's rate limit ended the web-typecheck chain at its culprit (probe 45897849727, 11-26 21:37Z).
            origin_verdicts = {name: v for name, v in jobs_of(origin["id"])[0].items() if name == probe.job}
            found, _ = new_reds(origin.get("head_sha") or "", origin_verdicts, before, jobs_of, suites,
                                steps_of(origin["id"]), steps_of)
            if not probe.step:  # a chain begun before the step travelled: the origin's red names it
                probe.step = STEP_SEP.join(sorted(red_step_names(steps_of(origin["id"]), probe.job)))
            # The same chain_start as the batch judge: without it every judged probe of the job since its first red
            # counted as a finished bisect, so a chain two steps in was refused as "not a new red" (probe run
            # 45971486391, 11-27 09:10Z: web / Web tests (1/4) at 27712e0b, the culprit step the batch had dispatched).
            deep = with_deeper_runs(args.repo, args.branch, origin.get("head_sha") or "", origin_verdicts, before, jobs_of)
            found += [(name, suite, good) for name, suite, good, _ in stuck_reds(origin.get("head_sha") or "", origin_verdicts, deep, jobs_of, suites,
                                                                                  chain_start=stuck_chain_start,
                                                                                  steps=steps_of(origin["id"]),
                                                                                  steps_of=steps_of)]
    except RuntimeError as err:
        # GitHub would not answer (a rate limit spent past the wait budget, a lasting 5xx). That says nothing
        # about the probe's inputs, yet refusing here ended the bisect, and the next batch began the same one
        # again from its first probe (probe run 45910283297, 11-26 23:34Z: "origin run 45901639171 is
        # unreadable" after the full 600 s budget; its web-tests chain was re-probed commit for commit an hour
        # later). Run the same probe again instead: its judge checks the inputs once GitHub answers.
        if probe.tries < MAX_PROBE_RETRIES:
            # The suite already gave its verdict here: the next run reads it (reuse) and only judges again, instead
            # of rendering the same commit once more. Probe run 45955682014 (gallery-health at 72157adeb82, 11-27)
            # had its verdict, hit the rate limit reading its origin, and its retry 45961171063 re-rendered all 21
            # legs (7 runner-hours) for no new verdict.
            had = probe_conclusion(verdicts, probe) in ("success", "failure", "skipped") and not probe.pieces and not probe.confirm
            again = Probe(**{**probe.__dict__, "tries": probe.tries + 1, "reuse": (probe.reuse or str(args.run_id)) if had else ""})
            how = f"judging it again on this run's verdict (reuse {again.reuse})" if had else "running the probe again"
            summary(args.summary, f"The origin run could not be read ({str(err)[-200:]}); {how} at `{probe.sha[:11]}`.")
            if not args.dry_run:
                dispatch_probe(args.repo, args.branch, again)
            write_outputs(args.github_output, out)
            return 0
        origin, found = None, []
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
    conclusion = probe_conclusion(verdicts, probe, failing_steps(jobs))
    if state is None and probe.only.startswith(LONE_PREFIX) and not conclusion:
        # The id-less red job did not run without the rest of its suite (it needs a gated job, or its condition wants
        # `only` empty): this probe and the rest of its chain run the whole suite, as every such probe did before.
        whole = Probe(**{**probe.__dict__, "only": "", "reuse": ""})
        summary(args.summary, f"`{probe.job}` did not run alone at `{probe.sha[:11]}`; probing the whole suite there.")
        if not args.dry_run:
            dispatch_probe(args.repo, args.branch, whole)
        write_outputs(args.github_output, out)
        return 0
    if not conclusion and whole_suite_skip(verdicts, probe, failing_steps(jobs)):
        # Skipped by its own condition in a whole-suite run with nothing lost: the same run skips it again. The
        # retries of webviews-test-history's probe at fa7ee53af71 ran the whole web suite three times (~1,350 runner-min).
        summary(args.summary, f"`{probe.job}` was skipped at `{probe.sha[:11]}` by its own condition (the whole suite ran, no runner lost).")
        conclusion = "skipped"
    if conclusion == "success" and probe_verdict(verdicts, probe) == "failure":
        summary(args.summary, f"`{probe.job}` failed at `{probe.sha[:11]}` on other steps than the origin's ({probe.step}): "
                              "a different red, counted as good for this bisect.")
    if state is not None:
        out.update(judge_pieces(args, probe, state, conclusion))
        write_outputs(args.github_output, out)
        return 0
    if probe.confirm:
        if conclusion not in ("success", "failure", "skipped") and probe.tries < MAX_PROBE_RETRIES:
            again = Probe(**{**probe.__dict__, "tries": probe.tries + 1})
            summary(args.summary, f"Confirm run `{probe.confirm}` gave no verdict at `{probe.sha[:11]}`; running it again.")
            if not args.dry_run:
                dispatch_probe(args.repo, args.branch, again)
        else:
            try:
                runs = list_runs(args.repo, args.branch)
            except RuntimeError:
                runs = []
            step, why = judge_confirm(probe, conclusion, int(args.run_id or 0), runs, jobs_of, steps_of)
            if step == "culprit":
                summary(args.summary, f"`{probe.job}` first went red at `{probe.bad}` (last green `{probe.good[:11]}`): {why}.")
                out.update(culprit=probe.bad, job=probe.job, good=probe.good, origin=probe.origin)
            elif step == "flake":
                summary(args.summary, f"`{probe.job}` at `{probe.bad[:11]}`: {why}: a flake, quarantined; no revert.")
            elif step == "unsure":
                summary(args.summary, f"`{probe.job}` likely went red at `{probe.bad[:11]}`, but {why}: named only, no revert.")
            else:
                summary(args.summary, f"Confirm run `{probe.confirm}` was {conclusion or 'unfinished'} at `{probe.sha[:11]}`; {why}.")
        write_outputs(args.github_output, out)
        return 0
    head = probe.bad or probe.sha
    commits = first_parent_range(probe.good, head)
    step, value = next_step(probe, conclusion, commits)
    try:
        runs = list_runs(args.repo, args.branch) if step == "probe" else []
    except RuntimeError:
        runs = []
    for _ in range(len(commits)):  # each known verdict narrows the range, so this ends
        known = known_verdict(runs, value, jobs_of, steps_of) if step == "probe" and isinstance(value, Probe) else None
        if not known:
            break
        summary(args.summary, f"`{value.job}` was already {known[0]} at `{value.sha[:11]}` (probe run {known[1]['id']}); not probing it again.")
        conclusion, probe = known[0], value
        step, value = next_step(value, known[0], commits)
    if step in ("probe", "retry"):
        assert isinstance(value, Probe)
        summary(args.summary, f"`{probe.job}` was {conclusion or 'unfinished'} at `{probe.sha[:11]}`; next probe `{value.sha[:11]}` (good `{value.good[:11]}`, bad `{value.bad[:11]}`).")
        if not args.dry_run:
            dispatch_probe(args.repo, args.branch, value)
    elif step == "culprit":
        assert isinstance(value, str)
        parent = probe.good if conclusion == "failure" else probe.sha
        if CONFIRM_RUNS:
            round_ = confirm_probes(probe, value, parent)
            earlier = earlier_confirm_round(round_, runs_for_confirm(args), jobs_of, steps_of)
            if earlier is not None:
                # Every run of this same confirm round (culprit, parent, job) already finished with a verdict on an
                # earlier bisect: its judge reads them instead of rendering the culprit and its parent again.
                step, why = earlier
                summary(args.summary, f"`{probe.job}` first went red at `{value}` (last green `{parent[:11]}`); an earlier "
                                      f"confirm round of it already finished: {why}.")
                if step == "culprit":
                    out.update(culprit=value, job=probe.job, good=parent, origin=probe.origin)
                write_outputs(args.github_output, out)
                return 0
            summary(args.summary, f"`{probe.job}` first went red at `{value}` (last green `{parent[:11]}`); confirming with "
                                  f"{CONFIRM_RUNS} more runs of each before any revert.")
            if not args.dry_run:
                for again in round_:
                    dispatch_probe(args.repo, args.branch, again)
        else:
            summary(args.summary, f"`{probe.job}` first went red at `{value}` (last green `{parent[:11]}`).")
            out.update(culprit=value, job=probe.job, good=parent, origin=probe.origin)
    elif step == "flake":
        summary(args.summary, f"`{probe.job}` passed again at `{probe.sha[:11]}`: the batch red did not repeat (a flake); no bisect.")
    elif conclusion == "skipped":
        summary(args.summary, f"`{probe.job}` was skipped at `{probe.sha[:11]}` (its own condition; the same probe would skip again): the bisect stops here.")
    else:
        summary(args.summary, f"`{probe.job}` gave no verdict at `{probe.sha[:11]}` twice; the bisect stops here.")
    write_outputs(args.github_output, out)
    return 0


# ---------------------------------------------------------------------------- revert


def takes_back_line(pr: str, job: str, branch: str, piece: str = "") -> list[str]:
    """The `Takes back #N: <why>` line risk_tier.py's risk evidence needs before a pull request undoing a recent
    merge may land (TAKES_BACK there). Without it every batch revert and swap-out went red on risk evidence and
    never merged: all 8 the batch opened 11-22..27 (cmux#62601, #62421, #62292, ...); each red was fixed forward."""
    if not pr:
        return []
    what = f"its `{piece}` piece" if piece else "it"
    return [f"Takes back #{pr}: the post-merge batch bisected `{job}` red on {branch} to it and confirmed it; this undoes {what} so the base is green again."]


def revert_title(subject: str, job: str, branch: str) -> str:
    return f'Revert "{subject}" (post-merge batch: {job} red on {branch})'


def merged_by_teammate(repo: str, pr: str, api=None) -> str:
    """The culprit PR's author when a core teammate wrote it (their revert opens held), else "". An
    unreadable author counts as a teammate: a held revert costs a human glance, an agent landing a
    teammate's revert breaks the rule."""
    api = api or gh_api  # looked up per call, so a test's patch of gh_api reaches it
    if not pr:
        return ""
    try:
        login = ((api(f"repos/{repo}/pulls/{pr}") or {}).get("user") or {}).get("login") or ""
    except RuntimeError:
        return "the culprit's author (unread)"
    return login if login in TEAMMATES else ""


SWAPOUT_MARK = "<!-- post-merge piece swap-out {culprit} {job} -->"
CONFLICT_MARK = "<!-- post-merge revert conflict {culprit} {job} -->"


def newer_verdict(repo: str, branch: str, origin: str, job: str, suites: dict, api=None) -> tuple[str, dict] | None:
    """The job's conclusion on the newest finished batch run of branch after the origin run, and that run;
    None when no newer batch run has finished the job."""
    runs = list_runs(repo, branch, api=api)
    newer = [r for r in runs if is_batch(r) and r.get("status") == "completed" and (r.get("id") or 0) > int(origin or 0)]
    for run in newer[:3]:
        got = suite_verdicts(run_jobs(repo, run["id"], api=api), suites).get(job)
        if got and got[1] in ("success", "failure"):
            return got[1], run
    return None


def revert_conflict(args: argparse.Namespace, culprit: str, pr: str, conflicted: list[str], api=None) -> str:
    """A culprit whose revert conflicts with the tip. Green again on a newer batch run: fixed forward, nothing to
    revert. Else the culprit's pull request gets one comment naming the job, the run and the later commits that
    touched the same files, so the base-break owner fixes it forward. Returns the run summary line."""
    api = api or gh_api
    try:
        seen = newer_verdict(args.repo, args.branch, args.origin, args.job, load_manifest(Path(args.manifest)), api=api)
    except RuntimeError as err:
        print(f"newer verdict of {args.job}: {err}", file=sys.stderr)
        seen = None
    if seen and seen[0] == "success":
        return (f"Reverting `{culprit[:11]}` conflicts with the tip, and `{args.job}` is green again on `{seen[1]['head_sha'][:11]}` "
                f"(run {seen[1]['id']}): fixed forward, nothing to revert.")
    later = git("log", "--format=%h %s", f"{culprit}..HEAD", "--", *conflicted).splitlines()[:5] if conflicted else []
    head = f"Reverting `{culprit[:11]}` conflicts with the tip of {args.branch}" + (f" in {', '.join(f'`{f}`' for f in conflicted[:5])}" if conflicted else "")
    if not pr or args.dry_run:
        return f"{head}; left to its owner{' (dry run: no comment)' if pr else ''}."
    origin = f"{args.server_url}/{args.repo}/actions/runs/{args.origin}" if args.origin else "(unknown)"
    this = f"{args.server_url}/{args.repo}/actions/runs/{args.run_id}"
    mark = CONFLICT_MARK.format(culprit=culprit, job=args.job)
    body = "\n\n".join([
        mark,
        f"Post-merge `{args.job}` went red on {args.branch} at this PR's merge (`{culprit[:12]}`): green at `{args.good[:12]}`, "
        f"the bisect ({this}, from {origin}) names this PR as its first red commit.",
        "Its revert conflicts with the tip, so no revert pull request opened. Later commits on the same files:\n\n"
        + ("\n".join(f"- {line}" for line in later) or "- (none found)"),
        "The base-break rule: fix it forward, or revert it by hand with the conflicts resolved. "
        "Opened by cmux-next-post-merge.yml (scripts/ci/post_merge_batch.py revert).",
    ])
    try:
        comments = api(f"repos/{args.repo}/issues/{pr}/comments?per_page=100") or []
        if any(mark in (c.get("body") or "") for c in comments):
            return f"{head}; #{pr} was already told."
        made = api(f"repos/{args.repo}/issues/{pr}/comments", method="POST", fields={"body": body})
    except RuntimeError as err:
        print(f"conflict comment on #{pr}: {err}", file=sys.stderr)
        return f"{head}; left to its owner (the comment on #{pr} failed: {str(err)[-160:]})."
    return f"{head}; told #{pr}'s owner: {(made or {}).get('html_url', '')}."


def swapouts_opened(repo: str, api=None) -> list[datetime]:
    """When each recent swap-out pull request opened (the breaker's count)."""
    api = api or gh_api  # looked up per call, so a test's patch of gh_api reaches it
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
            *takes_back_line(pr, args.job, args.branch, piece.id),
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
    summary(args.summary, f"Swap-out pull request: {created['html_url']}. {hand_off(args.repo, created['number'], author)}")
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
        conflicted = git("diff", "--name-only", "--diff-filter=U").split()
        subprocess.run(["git", "revert", "--abort"], cwd=ROOT)
        summary(args.summary, revert_conflict(args, culprit, pr, conflicted))
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
        else f"The base-break rule restores the base first: this carries `{LAND_LABEL}`, so it lands with no person once reviewed "
        "and green; then reland the change with its fix."
    )
    body = "\n\n".join(
        ([TEAMMATE_HOLD.format(login=author)] if author else [])
        + [
            f"Reverts {who} (`{culprit}`): the post-merge batch run {origin} found `{args.job}` red on {args.branch}; "
            f"it was green at `{args.good}`, and the bisect over the commits between (only that job) names {who} as the first red one ({this}).",
            *takes_back_line(pr, args.job, args.branch),
            f"{land} If the red is not this change's (a flake that repeated, an outside service), close this and say so.",
            "Opened by cmux-next-post-merge.yml (scripts/ci/post_merge_batch.py revert); it never merges a revert itself.",
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
    summary(args.summary, f"Revert pull request: {created['html_url']}. {hand_off(args.repo, created['number'], author)}")
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
        p.add_argument("--confirm", default="")
        p.add_argument("--step", default="")
        p.add_argument("--reuse", default="", help="probe: an earlier run of this probe whose verdict is read instead of running the suite")
        p.add_argument("--states", default="", help="probe: gallery-health's red states on the origin run, the only ones it renders")
        p.add_argument("--reds-dir", default="", help="batch: gallery-health's red states per shard (reds-N.txt), for its probes")

    p = sub.add_parser("tick")
    common(p)
    p.add_argument("--window-minutes", default=os.environ.get("NEXT_POST_MERGE_WINDOW_MINUTES"))
    p.add_argument("--every-merges", default=os.environ.get("NEXT_POST_MERGE_EVERY_MERGES"),
                   help=f"dispatch once the tip is this many commits past the last batch (default {DEFAULT_EVERY_MERGES}; 0: the window alone)")
    p.add_argument("--self-run-id", type=int, default=0, help="the batch run whose judge job ticks (its own run)")
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
