#!/usr/bin/env python3
"""Queued runs that still ask for a saturated runner label their workflow was routed off (category g).

A workflow run uses the workflow file at its own ref: a pull request run, the copy in the merge commit GitHub made
when the run was created, and every re-run of any of its attempts reuses that commit. So when a commit on main moves
a workflow off a saturated label, every run created before it, and every re-run of one, keeps asking for the old
label, and the queue stays saturated for as long as stale branches keep re-running. On 2026-11-28 cmux#64299
(merged 10:13:39Z) moved "iOS simulator screenshot loop" off GitHub's hosted macos-26, and at 11:15Z the label still
had 9 queued jobs, oldest 68 min: run 46126603464 attempt 3, PR #63559, whose head was from 08:36Z, still asked for
macos-26. Nothing said why; it took a hand read of `tools/ci-queue-why` and a hand base merge of the pull request.

The queue janitor (queue_janitor.py, which already reads every in-flight macOS run's jobs and labels, knows each
pool's queue, has main's workflow files checked out and holds cmux-bot's pull-requests: write token) calls this on
every sweep. For each queued, unassigned job on a pool over the janitor's threshold:

  1. the run's reference copy is the workflow file on the branch it follows (run_target_branch(): main, or
     another branch whose files the sweep checked out); a run whose copy is not on disk is left alone;
  2. each of the job's specific labels (not `self-hosted`, `macOS`, `ARM64`, ...) that appears nowhere in that copy's
     literal text (literal_text(): comments and `${{ }}` expressions left out, since cmux#64299 kept `macos-26` in
     both) is a label the branch no longer asks for;
  3. the routing change is the newest commit on that branch that touched the file and removed a line naming the
     label (routing_change(): one commit listing and at most COMMIT_READS commit reads per (file, label), cached
     for the sweep). No such commit (the label is computed, or the run's own branch added it): left alone;
  4. the run predates it when it was created before that commit's date (a re-run keeps its first attempt's
     created_at, and its ref). A run created after it follows a copy that has the change: left alone.

Then the remedy (decide()):
  - the run is at an open pull request's head: base-merge that pull request (PUT .../pulls/N/update-branch, at
    most once per pull request a sweep, MAX_BASE_MERGES a sweep, as cmux-bot only). The run becomes right once the
    branch has the change: the merge is a new head, whose runs follow the new copy, and category b sheds the old
    head's runs as superseded on the next sweep. Never a cancel at an open head (OPEN_HEAD_RULE), with one
    exception: a core teammate's pull request (TEAMMATES), or one whose author is unread, is never merged into, so
    its stale run is shed instead and the base merge stays the teammate's;
  - the pull request is merged or closed, or the run is no longer its head: moot work, shed (cancelled) like any
    superseded run, at most MAX_SHEDS a sweep, unless another category already cancels it this sweep;
  - no pull request could be told apart: left alone and reported.

Every sweep that finds any says so, per label and routing change, as an ::warning:: annotation and a step summary
section ("N queued runs ask for LABEL from refs that predate the routing change in SHA"), and in the pool snapshot
under STALE_ROUTES_KEY, so a saturation red can name it. The pattern page is cmuxterm-hq's
docs/handbook/queued-job-keeps-its-old-route.md ("Form: a route changed in the workflow file").
"""

from __future__ import annotations

import dataclasses
import datetime as dt
import re
import urllib.parse
from pathlib import Path
from typing import Any, Callable, Iterable, Mapping, Sequence

# The pool snapshot key (queue_janitor's macos-pool-load artifact) this sweep's findings ride under.
STALE_ROUTES_KEY = "stale_routes"
# Base merges and sheds a sweep may make. A base merge is one write and pushes one merge commit; a shed is a cancel.
# Measured: at 11:45Z on 2026-11-28, 11 of the 23 queued or running ios-sim-screenshot-loop.yml runs asked for
# macos-26 from refs older than cmux#64299; each was a distinct pull request. A sweep runs every 5 minutes and the
# repository paces base merges at 8 per 600 s, so 3 a sweep (6 per 600 s) stays under that pace and clears 11 open
# pull requests in four sweeps; 10 sheds a sweep clears a label's whole queue (DEFAULT_THRESHOLD 6 a pool) in one.
MAX_BASE_MERGES = 3
MAX_SHEDS = 10
# Core teammates (red_autofix.TEAMMATES; tests/test_ci_stale_route_runs.py keeps the two equal). No automation
# merges into a teammate's branch, so a teammate's stale run is shed, never base-merged.
TEAMMATES = frozenset({"austinywang", "azooz2003-bit", "lawrencecchen", "lucasr1b"})
# Commits read (one GET each) per (file, label) when looking for the routing change, newest first.
# Bound by GitHub's 24 h queue limit, not a measurement: a run queued now was created within a day, so only that
# day's commits to the file can postdate it, and 8 is more than any workflow file here takes in a day.
COMMIT_READS = 8
# Distinct (file, label) lookups a sweep may make; each is one listing plus up to COMMIT_READS reads.
MAX_LOOKUPS = 4
# Labels that name no pool: a job asks for them beside the one that does, and a workflow may not spell them.
GENERIC_LABELS = frozenset({"self-hosted", "macos", "linux", "windows", "x64", "arm64", "arm", "x86"})

QUEUED = frozenset({"queued", "waiting", "pending", "requested"})


@dataclasses.dataclass(frozen=True)
class Change:
    """The commit on `branch` that took `label` out of `path`."""
    sha: str
    at: dt.datetime
    branch: str


@dataclasses.dataclass
class StaleRoute:
    run: Mapping[str, Any]
    label: str
    change: Change
    action: str  # "base-merge", "shed" or "keep"
    note: str
    pr: Mapping[str, Any] | None = None


def parse_time(value: Any) -> dt.datetime | None:
    if not value:
        return None
    try:
        return dt.datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError:
        return None


def unassigned(job: Mapping[str, Any]) -> bool:
    return job.get("status") in QUEUED and not job.get("runner_id") and not job.get("runner_name")


def specific_labels(job: Mapping[str, Any]) -> list[str]:
    return [str(label) for label in job.get("labels") or () if str(label).lower() not in GENERIC_LABELS]


EXPRESSION = re.compile(r"\$\{\{.*?\}\}", re.S)
COMMENT = re.compile(r"(^|\s)#.*$", re.M)


def literal_text(text: str) -> str:
    """A workflow file's text without its comments and `${{ }}` expressions: what it asks for in every run.

    cmux#64299 kept `macos-26` in the file twice after routing the screenshot loop off it: in a comment, and as the
    fork-only arm of the new `runs-on:` expression. Neither sends a same-repository run there, so neither counts."""
    return COMMENT.sub(r"\1", EXPRESSION.sub("", text or ""))


def names_label(text: str, label: str) -> bool:
    """Whether a workflow file's literal text (literal_text()) names `label` as a whole word (labels are
    case-insensitive)."""
    return re.search(rf"(?<![\w.-]){re.escape(label)}(?![\w.-])", literal_text(text), re.I) is not None


def patch_removes_label(patch: str, label: str) -> bool:
    """A unified diff that drops a line naming `label` and adds none that names it."""
    removed = added = False
    for line in (patch or "").splitlines():
        if line.startswith("---") or line.startswith("+++"):
            continue
        if line.startswith("-") and names_label(line[1:], label):
            removed = True
        elif line.startswith("+") and names_label(line[1:], label):
            added = True
    return removed and not added


def routing_change(get: Callable[[str], Any], repo: str, branch: str, path: str, label: str, *,
                   reads: int = COMMIT_READS) -> Change | None:
    """The newest commit on `branch` touching `path` that removed `label` from it (patch_removes_label()), or None.

    `get` is one GET (the janitor's client). One listing of the file's commits, then each commit's detail until a
    match, at most `reads` of them."""
    query = urllib.parse.urlencode({"sha": branch, "path": path, "per_page": str(reads)})
    listed = get(f"/repos/{repo}/commits?{query}") or []
    for entry in listed[:reads]:
        sha = entry.get("sha")
        if not sha:
            continue
        detail = get(f"/repos/{repo}/commits/{sha}") or {}
        for changed in detail.get("files") or ():
            if path not in (changed.get("filename"), changed.get("previous_filename")):
                continue
            if changed.get("status") == "removed" or patch_removes_label(changed.get("patch") or "", label):
                commit = detail.get("commit") or {}
                at = parse_time((commit.get("committer") or {}).get("date")) or parse_time(
                    (commit.get("author") or {}).get("date"))
                if at is not None:
                    return Change(str(sha), at, branch)
    return None


def reference_branch(run: Mapping[str, Any]) -> str | None:
    """The branch whose workflow copy a run follows: its pull request's base, a push's or dispatch's branch."""
    for pr in run.get("pull_requests") or ():
        base = (pr.get("base") or {}).get("ref") if isinstance(pr, Mapping) else None
        if base:
            return str(base)
    if run.get("event") == "pull_request":
        # A same-repository pull request run names no pull request once it closed; its base is unknown.
        return None
    if run.get("event") in ("push", "workflow_dispatch") and run.get("head_branch"):
        return str(run["head_branch"])
    return None


def read_copy(copies: Mapping[str, Path], branch: str, path: str) -> str | None:
    """The text of `path` in `branch`'s checked-out workflow files: "" when the branch no longer has the file, None
    when the sweep has no copy of that branch."""
    directory = copies.get(branch)
    if directory is None or not directory.is_dir():
        return None
    target = directory / Path(path).name
    try:
        return target.read_text(encoding="utf-8")
    except FileNotFoundError:
        return ""
    except OSError:
        return None


@dataclasses.dataclass(frozen=True)
class Suspect:
    run: Mapping[str, Any]
    label: str
    branch: str
    path: str


def find_suspects(runs: Sequence[Mapping[str, Any]], jobs_by_run: Mapping[int, Sequence[Mapping[str, Any]]],
                  saturated: Iterable[str], copies: Mapping[str, Path], *,
                  pool_of: Callable[[Mapping[str, Any]], Iterable[str]],
                  protected: Callable[[Mapping[str, Any]], str | None] = lambda run: None) -> list[Suspect]:
    """Runs with a queued, unassigned job on a saturated pool that asks for a label its reference copy no longer
    names. Reads only files on disk; one suspect per run (its first such label)."""
    hot = set(saturated)
    out: list[Suspect] = []
    for run in runs:
        if run.get("status") not in (*QUEUED, "in_progress") or protected(run):
            continue
        path = str(run.get("path") or "")
        branch = reference_branch(run)
        if not path.startswith(".github/workflows/") or branch is None:
            continue
        text = read_copy(copies, branch, path)
        if text is None:
            continue
        found = None
        for job in jobs_by_run.get(run.get("id"), ()):
            if not unassigned(job) or not hot.intersection(pool_of(job)):
                continue
            found = next((label for label in specific_labels(job) if not names_label(text, label)), None)
            if found:
                break
        if found:
            out.append(Suspect(run, found, branch, path))
    return out


def pr_author(pr: Mapping[str, Any]) -> str:
    """The pull request's author login ("" when the read had none)."""
    author = pr.get("author")
    return str(author.get("login") or "") if isinstance(author, Mapping) else ""


def decide(suspect: Suspect, change: Change | None, prs: Sequence[Mapping[str, Any]], *,
           resolve: Callable[[Mapping[str, Any], Sequence[Mapping[str, Any]]], Mapping[str, Any] | None]
           ) -> StaleRoute | None:
    """The remedy for one suspect, or None when it is not a stale-ref run (no routing change, or the run follows a
    copy that has it). Pure."""
    run = suspect.run
    if change is None:
        return None
    created = parse_time(run.get("created_at"))
    if created is None or created >= change.at:
        return None
    pr = resolve(run, prs) if prs else None
    if pr is None or pr.get("openPullRequestsUnread"):
        return StaleRoute(run, suspect.label, change, "keep", "no pull request told apart", pr)
    state = str(pr.get("state") or "").upper()
    if state in ("MERGED", "CLOSED"):
        return StaleRoute(run, suspect.label, change, "shed", f"PR #{pr.get('number')} is {state.lower()}", pr)
    if state != "OPEN":
        return StaleRoute(run, suspect.label, change, "keep", f"PR #{pr.get('number')} state {state or 'unknown'}", pr)
    if pr.get("headRefOid") != run.get("head_sha"):
        return StaleRoute(run, suspect.label, change, "shed",
                          f"PR #{pr.get('number')} moved past this run's head", pr)
    author = pr_author(pr)
    if not author:
        return StaleRoute(run, suspect.label, change, "shed",
                          f"PR #{pr.get('number')}'s author is unread: shed, never merged into", pr)
    if author in TEAMMATES:
        return StaleRoute(run, suspect.label, change, "shed",
                          f"PR #{pr.get('number')} is {author}'s: shed, the base merge is theirs", pr)
    return StaleRoute(run, suspect.label, change, "base-merge",
                      f"PR #{pr.get('number')} predates {change.sha[:10]}: base merge", pr)


def plan(suspects: Sequence[Suspect], prs_by_branch: Mapping[str, Sequence[Mapping[str, Any]]], *,
         lookup: Callable[[str, str, str], Change | None],
         resolve: Callable[[Mapping[str, Any], Sequence[Mapping[str, Any]]], Mapping[str, Any] | None],
         max_lookups: int = MAX_LOOKUPS, max_base_merges: int = MAX_BASE_MERGES, max_sheds: int = MAX_SHEDS,
         already_cancelled: Iterable[int] = ()) -> list[StaleRoute]:
    """Every suspect's decision, oldest run first, under the caps. `lookup(branch, path, label)` is routing_change()
    for this sweep; it is called once per distinct (branch, path, label), at most `max_lookups` times."""
    cache: dict[tuple[str, str, str], Change | None] = {}
    done = set(already_cancelled)
    merged_prs: set[Any] = set()
    out: list[StaleRoute] = []
    merges = sheds = 0
    for suspect in sorted(suspects, key=lambda s: (str(s.run.get("created_at") or ""), s.run.get("id") or 0)):
        key = (suspect.branch, suspect.path, suspect.label)
        if key not in cache:
            if len(cache) >= max_lookups:
                continue
            cache[key] = lookup(*key)
        decision = decide(suspect, cache[key], prs_by_branch.get(str(suspect.run.get("head_branch") or ""), ()),
                          resolve=resolve)
        if decision is None:
            continue
        if decision.action == "base-merge":
            number = (decision.pr or {}).get("number")
            if number in merged_prs:
                decision.action, decision.note = "keep", f"PR #{number} base-merged for another run this sweep"
            elif merges >= max_base_merges:
                decision.action, decision.note = "keep", f"over {max_base_merges} base merges this sweep"
            else:
                merges += 1
                merged_prs.add(number)
        elif decision.action == "shed":
            if decision.run.get("id") in done:
                decision.action, decision.note = "keep", f"{decision.note}; another category cancels it"
            elif sheds >= max_sheds:
                decision.action, decision.note = "keep", f"{decision.note}; over {max_sheds} sheds this sweep"
            else:
                sheds += 1
        out.append(decision)
    return out


def snapshot_entry(decisions: Sequence[StaleRoute]) -> list[dict[str, Any]]:
    """Per (label, routing change): the runs and pull requests, for the pool snapshot (STALE_ROUTES_KEY)."""
    groups: dict[tuple[str, str], dict[str, Any]] = {}
    for d in decisions:
        group = groups.setdefault((d.label, d.change.sha), {
            "label": d.label, "change": d.change.sha, "branch": d.change.branch,
            "changed_at": d.change.at.strftime("%Y-%m-%dT%H:%M:%SZ"), "runs": [], "base_merged": [], "shed": []})
        group["runs"].append(d.run.get("id"))
        if d.action == "base-merge":
            group["base_merged"].append((d.pr or {}).get("number"))
        elif d.action == "shed":
            group["shed"].append(d.run.get("id"))
    return list(groups.values())


def headline(group: Mapping[str, Any]) -> str:
    count = len(group["runs"])
    noun = "run asks" if count == 1 else "runs ask"
    return (f"{count} queued {noun} for {group['label']} from refs that predate the routing change in "
            f"{str(group['change'])[:10]} on {group['branch']}")


def render(decisions: Sequence[StaleRoute], results: Mapping[int, str], *, dry_run: bool) -> tuple[str, list[str]]:
    """The step summary section and the ::warning:: lines."""
    if not decisions:
        return "", []
    planned = list(decisions)
    warnings: list[str] = []
    lines = ["", "### Runs asking for a label their workflow was routed off (stale-ref routing)", ""]
    if not dry_run:  # what was done, not what was planned (act() may have kept or been refused)
        decisions = [d if str(results.get(int(d.run["id"]), "")).startswith(("base-merged", "shed"))
                     and not str(results.get(int(d.run["id"]), "")).startswith("shed failed")
                     else dataclasses.replace(d, action="keep") for d in decisions]
    for group in snapshot_entry(decisions):
        text = headline(group)
        extra = []
        if group["base_merged"]:
            extra.append(("would base-merge" if dry_run else "base-merged") + " PR "
                         + ", ".join(f"#{n}" for n in group["base_merged"]))
        if group["shed"]:
            extra.append(("would shed" if dry_run else "shed") + " run(s) " + ", ".join(map(str, group["shed"])))
        warnings.append(f"::warning title=stale-ref routing on {group['label']}::{text}"
                        + (f": {'; '.join(extra)}" if extra else "") + " (hq docs/handbook/queued-job-keeps-its-old-route.md)")
        lines.append(f"- {text}.")
    lines += ["", "| Decision | Run | Label | Note |", "| --- | --- | --- | --- |"]
    for d in planned:
        run_id = d.run.get("id")
        verb = results.get(run_id) or (("would " if dry_run else "") + d.action if d.action != "keep" else "keep")
        url = d.run.get("html_url") or f"run {run_id}"
        lines.append(f"| {verb} | {url} | `{d.label}` | {d.note} |".replace("\n", " "))
    return "\n".join(lines) + "\n", warnings


def act(decisions: Sequence[StaleRoute], *, update_branch: Callable[[int, str], None],
        cancel: Callable[[int], None], can_merge: bool) -> tuple[dict[int, str], int]:
    """Make the base merges and sheds. Returns {run id: what happened} and the number of failed cancels. A base merge
    GitHub refuses (a conflict, a head that moved) is reported in the summary, not counted as a failure: it is the
    pull request's own state, and the next sweep looks again."""
    results: dict[int, str] = {}
    failures = 0
    for d in decisions:
        run_id = int(d.run["id"])
        if d.action == "base-merge":
            if not can_merge:
                results[run_id] = "keep (base merge needs cmux-bot's token)"
                continue
            try:
                update_branch(int((d.pr or {})["number"]), str(d.run.get("head_sha") or ""))
                results[run_id] = f"base-merged PR #{(d.pr or {}).get('number')}"
            except RuntimeError as error:
                if type(error).__name__ == "RateLimited":
                    raise
                results[run_id] = f"base merge refused ({str(error)[:120]})"
        elif d.action == "shed":
            try:
                cancel(run_id)
                results[run_id] = "shed"
            except RuntimeError as error:
                if type(error).__name__ == "RateLimited":
                    raise
                results[run_id] = f"shed failed ({str(error)[:120]})"
                failures += 1
    return results, failures
