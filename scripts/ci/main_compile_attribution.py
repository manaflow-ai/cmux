#!/usr/bin/env python3
"""Name the merge that stopped main's app or tests from compiling, within minutes.

Nothing here gates a merge. It runs after the fact, reads builds that already
happen, and makes a red main actionable.

The fast lane is seed-derived-data.yml: every push to main already compiles
the app-host test product (the app and cmuxTests, build-for-testing, no test
run) incrementally on the trusted warm minis first, Blacksmith beside them.
Its seed job's `Build` step is the compile verdict for that commit, so this
adds no Mac time per merge. A seed job whose Build fails dispatches the
attribution at once, instead of waiting for the slowest pool to finish the run.
main-compile-probe.yml compiles one main commit the seeds skipped, only when a
break's range holds more than one merge; its `Compile` step is read the same way.

`analyze` (read-only token) walks main's first-parent history back from its
head to the newest commit whose compile is known, reading each commit's seed
and probe runs:

  green    a run that concluded success (a seed skipped by decide builds the
           inputs of an earlier green seed, so it is green too), or any job
           whose compile step succeeded
  red      a job whose compile step failed with source `error:` lines (the
           errors are the evidence; a Build failure with none is a machine
           failure, not a verdict, and stays unknown)
  unknown  cancelled, replaced while pending, or still running

For each compiler error at the newest red commit it finds where the error
first appeared: the known commit before it lacks the error (or is green).
Errors are keyed by file and message, not line, so an unrelated edit above
them does not make an old error look new. A range of one merge names that
pull request (confirmed). A longer range names the merges whose diff touched
an erroring file, or a symbol an error names (suspected), and lists the
commits in it to probe, so the next analysis narrows it to one.

`report` (write token) comments once on each culprit pull request with the
errors, pinging the author and merger, and dispatches the probes. Its job name
is the headline (`culprit: Seed DerivedData red since #N by @a, merged by
@m`), which ci-dash reads from the build controller's webhook feed. `plan-fix`
decides whether the fixer runs (a culprit, main's head still red with the same
errors, and nobody's open pull request already fixing it); the fixer (a Claude
run limited to reading and editing files) makes a minimal fix-forward, and
`finish` opens it as a pull request with auto-merge (its own CI is the fast
check), or, when the fixer declines, a labeled revert pull request of a
confirmed culprit, which a person merges.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable, Mapping

sys.path.insert(0, str(Path(__file__).resolve().parent))
from guard_attribution import (  # noqa: E402
    GitHub,
    Writer,
    code,
    fence,
    pr_for_commit,
    short,
    upsert_comment,
    who,
)

ROOT = Path(__file__).resolve().parents[2]
SEED_WORKFLOW = "Seed DerivedData"
SEED_WORKFLOW_FILE = "seed-derived-data.yml"
PROBE_WORKFLOW = "Main compile probe"
PROBE_WORKFLOW_FILE = "main-compile-probe.yml"
# The step whose outcome is the compile verdict, per workflow file.
COMPILE_STEPS = {SEED_WORKFLOW_FILE: "Build", PROBE_WORKFLOW_FILE: "Compile"}
# How far back from main's head a green commit is looked for.
MAX_WINDOW = 40
# Probes one analysis may dispatch, and per break.
MAX_PROBES = 4
# Errors shown in one comment.
MAX_ERRORS_SHOWN = 20
# A failed job whose log is not downloadable yet (the job is finishing).
LOG_WAIT_SECONDS = 150
CULPRIT_MARKER = "<!-- main-compile-culprit pr={pr} errors={digest} -->"
FIX_MARKER = "<!-- main-compile-fix culprit={pr} -->"
REVERT_LABEL = "compile-revert"
FIX_BRANCH_PREFIX = "compile-fix/"
REVERT_BRANCH_PREFIX = "compile-revert/"

TIMESTAMP = re.compile(r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d+)?Z ?")
ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
# `/private/tmp/cmux-ci/src/cmuxTests/X.swift:61:27: error: message`. Only
# errors in a source file count: `error: No space left on device` and the like
# are the machine, not the commit.
SOURCE_ERROR = re.compile(
    r"^(?P<path>/\S+?\.(?:swift|mm|m|c|cc|cpp|h|hpp|metal)):(?P<line>\d+):(?:(?P<col>\d+):)? "
    r"error: (?P<message>.+?)\s*$"
)
# The canonical source root (compile-app-host-test-product.sh) or a workspace.
SOURCE_ROOT = re.compile(r"^.*?/(?:cmux-ci(?:-\d+)?/src|_work/[^/]+/[^/]+)/")
QUOTED = re.compile(r"'([A-Za-z_][A-Za-z0-9_]{2,})")
PR_SUBJECT = re.compile(r"\(#(\d+)\)\s*$")


# ---------------------------------------------------------------- parsing


@dataclass(frozen=True)
class CompileError:
    path: str
    line: int
    message: str

    @property
    def key(self) -> str:
        return f"{self.path}: {self.message}"

    def render(self) -> str:
        return f"{self.path}:{self.line}: error: {self.message}"


def relative_path(path: str) -> str:
    return SOURCE_ROOT.sub("", path, count=1)


def parse_errors(log: str) -> dict[str, CompileError]:
    """Distinct source errors in a compile log, first occurrence per key, in log order."""
    found: dict[str, CompileError] = {}
    for raw in log.splitlines():
        line = ANSI.sub("", raw)
        # A job log line is `<job>\t<step>\t<time> text` from `gh run view --log`,
        # or `<time> text` from the jobs API.
        line = line.rsplit("\t", 1)[-1]
        line = TIMESTAMP.sub("", line)
        match = SOURCE_ERROR.match(line.strip())
        if not match:
            continue
        error = CompileError(relative_path(match["path"]), int(match["line"]), match["message"])
        found.setdefault(error.key, error)
    return found


def digest(keys: Iterable[str]) -> str:
    return hashlib.sha256("\n".join(sorted(keys)).encode()).hexdigest()[:12]


# ---------------------------------------------------------------- compile states


@dataclass
class State:
    sha: str
    state: str  # green, red, unknown
    errors: dict[str, CompileError] = field(default_factory=dict)
    run_url: str | None = None
    job_url: str | None = None
    source: str | None = None  # workflow file
    finished_at: str | None = None


def step_outcome(job: Mapping, step_name: str) -> str | None:
    for step in job.get("steps") or []:
        if step.get("name") == step_name:
            return step.get("conclusion")
    return None


def job_verdict(job: Mapping, step_name: str) -> str:
    """green, red (the compile step failed), or unknown."""
    outcome = step_outcome(job, step_name)
    if outcome == "success":
        return "green"
    if outcome == "failure":
        return "red"
    return "unknown"


class Source:
    """What analyze reads from GitHub; a fixture in the tests."""

    def __init__(self, gh: GitHub):
        self.gh = gh

    def runs(self, workflow_file: str) -> list[dict]:
        try:
            body = self.gh.get(f"repos/{self.gh.repo}/actions/workflows/{workflow_file}/runs?branch=main&per_page=100")
        except RuntimeError as error:
            if "HTTP 404" in str(error):  # a workflow not on the default branch yet
                return []
            raise
        return list((body or {}).get("workflow_runs", []))  # type: ignore[union-attr]

    def jobs(self, run_id: int) -> list[dict]:
        body = self.gh.get(f"repos/{self.gh.repo}/actions/runs/{run_id}/jobs?filter=latest&per_page=30")
        return list((body or {}).get("jobs", []))  # type: ignore[union-attr]

    def job(self, job_id: int) -> dict:
        return self.gh.get(f"repos/{self.gh.repo}/actions/jobs/{job_id}")  # type: ignore[return-value]

    def log(self, job_id: int) -> str:
        return str(self.gh.request("GET", f"repos/{self.gh.repo}/actions/jobs/{job_id}/logs", text=True))


def wait_for_log(source: Source, job: Mapping, wait_seconds: float) -> str:
    """A job's log; a job still finishing its post steps has none yet, so wait for it."""
    deadline = time.monotonic() + wait_seconds
    current = dict(job)
    while True:
        if current.get("status") == "completed":
            try:
                return source.log(int(current["id"]))
            except RuntimeError:
                if time.monotonic() >= deadline:
                    return ""
        if time.monotonic() >= deadline:
            return ""
        time.sleep(15)
        try:
            current = source.job(int(current["id"]))
        except RuntimeError:
            pass


def run_state(source: Source, run: Mapping, workflow_file: str, log_wait: float) -> State:
    sha = str(run.get("head_sha"))
    base = State(sha, "unknown", run_url=run.get("html_url"), source=workflow_file,
                 finished_at=run.get("updated_at"))
    if run.get("status") == "completed" and run.get("conclusion") == "success":
        base.state = "green"
        return base
    step = COMPILE_STEPS[workflow_file]
    try:
        jobs = source.jobs(int(run["id"]))
    except RuntimeError:
        return base
    verdicts = [(job, job_verdict(job, step)) for job in jobs]
    green = next((job for job, verdict in verdicts if verdict == "green"), None)
    if green is not None:
        base.state, base.job_url = "green", green.get("html_url")
        return base
    for job, verdict in verdicts:
        if verdict != "red":
            continue
        errors = parse_errors(wait_for_log(source, job, log_wait))
        if errors:
            return State(sha, "red", errors, run.get("html_url"), job.get("html_url"), workflow_file,
                         job.get("completed_at") or run.get("updated_at"))
    return base


def merge(states: Iterable[State]) -> State:
    """One commit's verdict from its seed and probe runs: a real compile error wins, then green."""
    states = list(states)
    red = [s for s in states if s.state == "red"]
    if red:
        return max(red, key=lambda s: len(s.errors))
    green = [s for s in states if s.state == "green"]
    if green:
        return green[0]
    return states[0] if states else State("", "unknown")


# ---------------------------------------------------------------- git


def git(*args: str, root: Path = ROOT, check: bool = True) -> str:
    result = subprocess.run(["git", "-C", str(root), *args], text=True, capture_output=True)
    if check and result.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)}: {result.stderr.strip()[:300]}")
    return result.stdout.strip()


def first_parents(head: str, limit: int = MAX_WINDOW, root: Path = ROOT) -> list[str]:
    """Main's first-parent commits from head back, newest first."""
    return git("rev-list", "--first-parent", f"--max-count={limit}", head, root=root).split()


def changed_files(sha: str, root: Path = ROOT) -> list[str]:
    return git("diff-tree", "--no-commit-id", "--name-only", "-r", "--first-parent", "-m", sha,
               root=root, check=False).split()


def diff_text(sha: str, root: Path = ROOT) -> str:
    return git("show", "--format=", "--first-parent", "-m", sha, root=root, check=False)


# ---------------------------------------------------------------- attribution


@dataclass
class Break:
    base: str | None  # the known commit before the range, or None when none is known
    head: str  # the first commit known to show these errors
    commits: list[str]  # the range, oldest first
    errors: list[CompileError]
    evidence: State
    confirmed: bool = False
    culprits: list[dict] = field(default_factory=list)
    probes: list[str] = field(default_factory=list)


def suspects(commits: list[str], errors: list[CompileError],
             files_of=changed_files, text_of=diff_text) -> tuple[list[str], dict[str, int]]:
    """Commits in a range ranked by how directly their diff reaches the errors.

    2: edits a file an error is in. 1: its diff names a symbol an error quotes.
    Only the top score is returned, and nothing when every score is 0.
    """
    paths = {e.path for e in errors}
    symbols = {m for e in errors for m in QUOTED.findall(e.message)}
    scores: dict[str, int] = {}
    for sha in commits:
        files = set(files_of(sha))
        score = 2 if files & paths else 0
        if not score and symbols:
            text = text_of(sha)
            score = 1 if any(re.search(rf"\b{re.escape(s)}\b", text) for s in symbols) else 0
        scores[sha] = score
    top = max(scores.values(), default=0)
    return ([sha for sha in commits if scores[sha] == top] if top else []), scores


def attribute(window: list[str], states: Mapping[str, State], files_of=changed_files,
              text_of=diff_text) -> tuple[str, State | None, list[Break]]:
    """(state, newest known commit, breaks) over main's window, given newest first."""
    known = [sha for sha in window if states.get(sha) and states[sha].state in ("green", "red")]
    if not known:
        return "unknown", None, []
    newest = states[known[0]]
    if newest.state == "green":
        return "green", newest, []
    breaks: list[Break] = []
    order = {sha: i for i, sha in enumerate(window)}  # 0 is main's head
    remaining = dict(newest.errors)
    # Walk the known commits from newest to oldest; each error belongs to the
    # oldest red commit of the unbroken run of known commits that show it.
    chain = known
    for index, sha in enumerate(chain):
        if not remaining:
            break
        state = states[sha]
        older = chain[index + 1] if index + 1 < len(chain) else None
        older_state = states[older] if older else None
        if state.state != "red":
            break
        # Errors this commit shows that the older known one does not: they appeared in (older, sha].
        appeared = [key for key in remaining if key in state.errors and
                    (older_state is None or older_state.state == "green" or key not in older_state.errors)]
        if not appeared:
            continue
        lo = order[older] if older else len(window)
        commits = list(reversed(window[order[sha]:lo]))
        errors = [state.errors[key] for key in appeared]
        brk = Break(older if older_state is not None else None, sha, commits, errors, state)
        brk.confirmed = len(commits) == 1 and older_state is not None
        if brk.confirmed:
            brk.culprits = [{"sha": commits[0]}]
        else:
            top, _ = suspects(commits, errors, files_of, text_of)
            brk.culprits = [{"sha": s} for s in top]
            brk.probes = [c for c in commits if c != sha and
                          (c not in states or states[c].state not in ("green", "red"))]
        breaks.append(brk)
        for key in appeared:
            remaining.pop(key, None)
    return "red", newest, breaks


def probe_order(commits: list[str], limit: int) -> list[str]:
    """Which unknown commits to probe first: the middle, then the rest outward."""
    if len(commits) <= limit:
        return commits
    mid = len(commits) // 2
    picked = [commits[mid]]
    step = 1
    while len(picked) < limit:
        for i in (mid - step, mid + step):
            if 0 <= i < len(commits) and len(picked) < limit:
                picked.append(commits[i])
        step += 1
    return picked


# ---------------------------------------------------------------- analyze


def collect_states(source: Source, window: list[str], log_wait: float) -> tuple[dict[str, State], dict[str, dict]]:
    """Known compile states over the window, stopping at the first green commit, and in-flight probes."""
    runs: dict[str, list[tuple[str, dict]]] = {}
    probes_in_flight: dict[str, dict] = {}
    for workflow_file in (SEED_WORKFLOW_FILE, PROBE_WORKFLOW_FILE):
        for run in source.runs(workflow_file):
            if run.get("event") not in ("push", "workflow_dispatch"):
                continue
            sha = str(run.get("head_sha"))
            if workflow_file == PROBE_WORKFLOW_FILE:
                # A probe runs on main's definition; its commit is in the run name.
                match = re.search(r"\b([0-9a-f]{40})\b", str(run.get("display_title") or run.get("name") or ""))
                if not match:
                    continue
                sha = match[1]
                if run.get("status") != "completed":
                    probes_in_flight[sha] = run
            elif run.get("event") != "push":
                continue
            runs.setdefault(sha, []).append((workflow_file, run))
    states: dict[str, State] = {}
    for sha in window:
        if sha not in runs:
            continue
        state = merge(run_state(source, run, wf, log_wait) for wf, run in runs[sha])
        state.sha = sha
        states[sha] = state
        if state.state == "green":
            break
    return states, probes_in_flight


def describe(gh: GitHub | None, sha: str) -> dict:
    return pr_for_commit(gh, ROOT, sha)


def analyze(source: Source, gh: GitHub | None, head: str, log_wait: float = LOG_WAIT_SECONDS) -> dict:
    window = first_parents(head)
    states, in_flight = collect_states(source, window, log_wait)
    state, newest, breaks = attribute(window, states)
    report: dict = {
        "head": head,
        "state": state,
        "newest_known": newest.sha if newest else None,
        "newest_run": (newest.job_url or newest.run_url) if newest else None,
        "breaks": [],
        "probes": [],
    }
    budget = MAX_PROBES
    for brk in breaks:
        culprits = [describe(gh, c["sha"]) for c in brk.culprits]
        wanted = [c for c in probe_order(brk.probes, MAX_PROBES) if c not in in_flight]
        chosen = wanted[:budget]
        budget -= len(chosen)
        report["probes"] += chosen
        report["breaks"].append({
            "base": brk.base,
            "head": brk.head,
            "commits": brk.commits,
            "confirmed": brk.confirmed,
            "culprits": culprits,
            "errors": [e.render() for e in brk.errors],
            "error_keys": [e.key for e in brk.errors],
            "files": sorted({e.path for e in brk.errors}),
            "evidence": brk.evidence.job_url or brk.evidence.run_url,
            "probing": sorted(set(brk.probes) & set(in_flight)) + chosen,
        })
    report["headline"] = headline(report)
    return report


# ---------------------------------------------------------------- rendering


def headline(report: Mapping) -> str:
    """The report job's name, read by ci-dash from the webhook feed."""
    if report.get("state") != "red":
        return f"main compiles ({short(report.get('newest_known'))})" if report.get("state") == "green" else "report"
    named = [c for b in report.get("breaks") or [] for c in b.get("culprits") or [] if c.get("pr")]
    if not named:
        return f"culprit: {SEED_WORKFLOW} red, unattributed"
    names = list(dict.fromkeys(who(c) for c in named))
    return (f"culprit: {SEED_WORKFLOW} red since " + "; ".join(names[:2]))[:200]


def mentions(culprit: Mapping) -> str:
    people = [culprit.get("merger"), culprit.get("author")]
    return " ".join(f"@{p}" for p in dict.fromkeys(p for p in people if p))


def render_culprit_comment(report: Mapping, brk: Mapping, culprit: Mapping, links: Mapping[str, str]) -> str:
    marker = CULPRIT_MARKER.format(pr=culprit["pr"], digest=digest(brk["error_keys"]))
    shown = brk["errors"][:MAX_ERRORS_SHOWN]
    more = len(brk["errors"]) - len(shown)
    if brk["confirmed"]:
        how = (f"The compile of the commit before it (`{short(brk['base'])}`) passed and its own merge commit "
               f"`{short(brk['head'])}` fails, so this pull request is the cause (possibly with a semantic "
               "conflict against something merged earlier that its own CI did not see).")
    else:
        others = [c for c in brk["commits"] if c != culprit.get("sha")]
        how = (f"These errors first show up in a range of {len(brk['commits'])} merges "
               f"(`{short(brk['base']) or '?'}..{short(brk['head'])}`), and this pull request's diff is the one that "
               f"reaches them. The other merges in that range ({', '.join(f'`{short(c)}`' for c in others)}) are "
               "being compiled on their own to confirm.")
    lines = [
        marker,
        f"### main no longer compiles after this merge",
        "",
        f"{mentions(culprit)}: after `{short(culprit.get('sha'))}` landed on main, the app-host test product "
        f"(the app and `cmuxTests`, build-for-testing) stops compiling. {how}",
        "",
        f"Evidence: {brk['evidence']}",
        "",
        fence("\n".join(shown) + (f"\n... and {more} more" if more > 0 else "")),
        "",
    ]
    if links.get("fix"):
        lines.append(f"A fix-forward is open and will merge itself once its CI passes: {links['fix']}")
    elif links.get("revert"):
        lines.append(f"The fix is not mechanical, so a revert is open for a person to merge or close: {links['revert']}")
    elif links.get("existing"):
        lines.append(f"Nothing blocks merging meanwhile, and no automatic fix is opened: {links['existing']}.")
    else:
        lines.append("Nothing blocks merging meanwhile. A fix-forward (or, failing that, a revert) is attempted "
                     "automatically unless an open pull request already fixes this.")
    lines += ["", "<sub>main_compile_attribution.py: post-merge, nothing here gates a merge.</sub>"]
    return "\n".join(lines) + "\n"


def summary(report: Mapping) -> str:
    out = [f"## Main compile attribution: {report['state']} at `{short(report.get('newest_known'))}`", ""]
    if report.get("newest_run"):
        out.append(f"Newest known compile: {report['newest_run']}")
    for brk in report.get("breaks") or []:
        names = ", ".join(who(c) for c in brk["culprits"]) or "unattributed"
        verdict = "confirmed" if brk["confirmed"] else "suspected"
        out += ["", f"### {verdict}: {names}",
                f"Range `{short(brk['base']) or '?'}..{short(brk['head'])}` ({len(brk['commits'])} commits), "
                f"{len(brk['errors'])} errors. Evidence: {brk['evidence']}"]
        if brk.get("probing"):
            out.append("Probing: " + ", ".join(f"`{short(c)}`" for c in brk["probing"]))
        out.append(fence("\n".join(brk["errors"][:MAX_ERRORS_SHOWN])))
    return "\n".join(out) + "\n"


# ---------------------------------------------------------------- report and fix planning


def fix_target(report: Mapping) -> dict | None:
    """The break the fixer works on: the newest one with a named culprit."""
    for brk in report.get("breaks") or []:
        named = [c for c in brk.get("culprits") or [] if c.get("pr")]
        if named and (brk["confirmed"] or len(named) == 1):
            return {"break": brk, "culprit": named[0]}
    return None


def already_fixing(open_prs: Iterable[Mapping], culprit_pr: int, merged_at: str | None) -> Mapping | None:
    """An open pull request that already answers this break: ours, or one that names the culprit."""
    for pr in open_prs:
        ref = str((pr.get("head") or {}).get("ref") or "")
        if ref.startswith((FIX_BRANCH_PREFIX, REVERT_BRANCH_PREFIX)) and f"-{culprit_pr}" in ref:
            return pr
        text = f"{pr.get('title') or ''}\n{pr.get('body') or ''}"
        if re.search(rf"#{culprit_pr}\b", text) and (not merged_at or str(pr.get("created_at") or "") >= merged_at):
            return pr
    return None


def command_analyze(args: argparse.Namespace) -> int:
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN") or ""
    gh = GitHub(os.environ.get("GITHUB_REPOSITORY", "manaflow-ai/cmux"), token)
    head = args.head or git("rev-parse", "HEAD")
    report = analyze(Source(gh), gh, head, args.log_wait)
    target = fix_target(report)
    if target:
        pull = gh.pull(int(target["culprit"]["pr"]))
        target["culprit"]["merged_at"] = pull.get("merged_at")
        target["culprit"]["merge_sha"] = pull.get("merge_commit_sha") or target["culprit"]["sha"]
        open_prs = list(gh.get(f"repos/{gh.repo}/pulls?state=open&per_page=100&sort=created&direction=desc") or [])
        busy = already_fixing(open_prs, int(target["culprit"]["pr"]), pull.get("merged_at"))
        # The fixer works on main's head: only when head itself is the red commit analyzed.
        stale = report.get("newest_known") != head
        target["skip"] = (f"open pull request #{busy['number']} already addresses #{target['culprit']['pr']}"
                          if busy else "main's head has no compile result yet" if stale else "")
        report["fix"] = target
    Path(args.out).write_text(json.dumps(report, indent=2) + "\n")
    Path(args.summary_out).write_text(summary(report)) if args.summary_out else None
    output = os.environ.get("GITHUB_OUTPUT")
    if output:
        fix = report.get("fix") or {}
        with open(output, "a") as handle:
            handle.write(f"state={report['state']}\n")
            handle.write(f"headline={report['headline']}\n")
            handle.write(f"probes={' '.join(report['probes'])}\n")
            handle.write(f"fix={'true' if fix and not fix.get('skip') else 'false'}\n")
    print(summary(report))
    print(f"GitHub API calls: {gh.calls}")
    return 0


def command_report(args: argparse.Namespace) -> int:
    report = json.loads(Path(args.report).read_text())
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN") or ""
    repo = os.environ.get("GITHUB_REPOSITORY", "manaflow-ai/cmux")
    gh = GitHub(repo, token) if token else None
    writer = Writer(gh, args.dry_run)
    skip = str((report.get("fix") or {}).get("skip") or "")
    links = {"fix": args.fix_pr or "", "revert": args.revert_pr or "",
             "existing": skip if skip.startswith("open pull request") else ""}
    for brk in report.get("breaks") or []:
        for culprit in brk.get("culprits") or []:
            if not culprit.get("pr"):
                continue
            body = render_culprit_comment(report, brk, culprit, links)
            existing = gh.comments(int(culprit["pr"])) if gh else []
            upsert_comment(writer, repo, int(culprit["pr"]), body.splitlines()[0], body, existing)
    if writer.log:
        print("\n\n".join(writer.log))
    return 0


def prompt(report: Mapping) -> str:
    target = report["fix"]
    brk, culprit = target["break"], target["culprit"]
    return "\n".join([
        "main of this repository no longer compiles its app-host test product (the cmux app and the cmuxTests",
        f"bundle). The errors appeared with pull request #{culprit['pr']} ({culprit.get('title') or ''}), merge",
        f"commit {culprit.get('sha')}. The checkout is main's head {report['head']}.",
        "",
        "Compiler errors (paths relative to the checkout):",
        *brk["errors"][:MAX_ERRORS_SHOWN],
        "",
        "Make the smallest edit that makes this compile again when the cause is mechanical drift: a changed",
        "function or closure signature, a renamed or moved symbol, a missing import, a changed initializer, a",
        "`let` assigned twice, an argument label. Keep the intent of both sides: prefer adapting the call sites",
        "(usually tests) to the new API over changing the API back. Do not change behavior, delete tests, or",
        "touch files the errors do not lead to. Read `git show " + str(culprit.get("sha"))[:12] + "` style context",
        "with the Read and Grep tools only; you cannot run builds.",
        "",
        "If the fix is not mechanical (it needs a design decision, or you are unsure), edit nothing.",
        "Finish with the structured output: mechanical (whether you edited files for a mechanical fix) and",
        "summary (one or two sentences for the pull request).",
    ])


def command_prompt(args: argparse.Namespace) -> int:
    Path(args.out).write_text(prompt(json.loads(Path(args.report).read_text())))
    return 0


def fix_pr_body(report: Mapping, summary_text: str) -> tuple[str, str, str]:
    target = report["fix"]
    brk, culprit = target["break"], target["culprit"]
    title = f"fix(main): compile again after #{culprit['pr']}"
    branch = f"{FIX_BRANCH_PREFIX}{short(report['head'])}-{culprit['pr']}"
    body = "\n".join([
        FIX_MARKER.format(pr=culprit["pr"]),
        f"main stopped compiling after #{culprit['pr']} ({who(culprit)}). {summary_text.strip()}",
        "",
        f"Evidence: {brk['evidence']}",
        "",
        fence("\n".join(brk["errors"][:MAX_ERRORS_SHOWN])),
        "",
        "Opened by the main compile canary's fixer (main_compile_attribution.py) with auto-merge on: it merges",
        "as soon as its own CI (compile admission on the warm minis) passes. Close it to stop that.",
        "",
        "🤖 Generated with [Claude Code](https://claude.com/claude-code)",
    ])
    return title, branch, body


def revert_pr_body(report: Mapping, reason: str) -> tuple[str, str, str]:
    target = report["fix"]
    brk, culprit = target["break"], target["culprit"]
    title = f"Revert #{culprit['pr']}: main does not compile"
    branch = f"{REVERT_BRANCH_PREFIX}{culprit['pr']}"
    body = "\n".join([
        FIX_MARKER.format(pr=culprit["pr"]),
        f"Reverts #{culprit['pr']} ({who(culprit)}), after which main's app-host test product no longer compiles.",
        f"The fixer found no mechanical fix: {reason.strip() or 'no edit'}.",
        "",
        f"Evidence: {brk['evidence']}",
        "",
        fence("\n".join(brk["errors"][:MAX_ERRORS_SHOWN])),
        "",
        "Not set to merge by itself: merge it, or close it once a fix-forward lands.",
        "",
        "🤖 Generated with [Claude Code](https://claude.com/claude-code)",
    ])
    return title, branch, body


def command_pr_text(args: argparse.Namespace) -> int:
    report = json.loads(Path(args.report).read_text())
    title, branch, body = (fix_pr_body(report, args.summary) if args.kind == "fix"
                           else revert_pr_body(report, args.summary))
    Path(args.out).write_text(json.dumps({"title": title, "branch": branch, "body": body,
                                          "merge_sha": report["fix"]["culprit"].get("merge_sha"),
                                          "confirmed": report["fix"]["break"]["confirmed"]}) + "\n")
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("analyze")
    p.add_argument("--head", help="main commit to start from (default: HEAD)")
    p.add_argument("--out", required=True)
    p.add_argument("--summary-out")
    p.add_argument("--log-wait", type=float, default=LOG_WAIT_SECONDS)
    p.set_defaults(func=command_analyze)
    p = sub.add_parser("report")
    p.add_argument("--report", required=True)
    p.add_argument("--fix-pr")
    p.add_argument("--revert-pr")
    p.add_argument("--dry-run", action="store_true")
    p.set_defaults(func=command_report)
    p = sub.add_parser("prompt")
    p.add_argument("--report", required=True)
    p.add_argument("--out", required=True)
    p.set_defaults(func=command_prompt)
    p = sub.add_parser("pr-text")
    p.add_argument("--report", required=True)
    p.add_argument("--kind", choices=("fix", "revert"), required=True)
    p.add_argument("--summary", default="")
    p.add_argument("--out", required=True)
    p.set_defaults(func=command_pr_text)
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
