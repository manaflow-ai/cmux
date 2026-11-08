#!/usr/bin/env python3
"""Name the pull requests behind a red cmux-next push run on feat-cmux-next.

Pull requests run only the cmux-next tiers their change reaches, and every
feat-cmux-next push runs them all as a backstop (superseded pushes skip their
Mac jobs, so a burst of merges is checked once, at its newest commit). When a
push run fails, this finds, for each failed job, the newest earlier push run
where the same job passed, and updates the shared status comment on every pull
request merged in that range: one of them broke it, and its lane fixes forward.
The latest processed failure replaces the push-attribution section instead of
adding a timeline comment for each failed run.

When every first-parent commit has a completed, consistent verdict for a
failed job, a bounded midpoint search names the first failing merge and
notifies its PR author. The entire history must be monotonic; missing,
skipped, infrastructure, and non-monotonic evidence stays unresolved. This
reuses existing runs, while web red files also have an executing probe path
in web_coalesce.py. NEXT_PUSH_BISECT=0 disables the history search.

The run's code never executes here; it reads the Actions API and plain git.
Ranges and culprits come from the checkout's first-parent history (the workflow
fetches commits only): a squash merge's subject ends in "(#N)". Only a commit
git cannot name, or a range git cannot prove, asks the compare and pulls APIs.
GH_READ_TOKEN, when set, is used for the reads (the workflow mints a cmux-bot
token on trusted pushes, off the repository token's hourly budget); a refused
read retries on GH_TOKEN. Comments are always written with GH_TOKEN.

Usage: cmux_next_push_attribution.py --repo OWNER/NAME --run-id ID --sha SHA
       [--workflow cmux-next.yml] [--branch feat-cmux-next] [--dry-run]
       [--events push[,workflow_dispatch]] [--summary FILE]

--events adds workflow_dispatch runs of the branch to the scan: the tree jobs
(daemon tests, scheme compile) of a push whose same-tree cmux-tui was published
after its run probed it pass or fail in a same-tree mode dispatch run, and the
base Mac tier (daemon tests, generated files, scheme compile) runs only in the
`cmux-next base tier` dispatch, at most once every 15 minutes on the tip.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

import pr_status

MARKER = "<!-- cmux-next-push-attribution:{run_id} -->"
# Jobs that report rather than check.
IGNORED_JOBS = ("cmux-next push attribution", "cmux-next generated autofix")
SCANNED_RUNS = 40
# Past this many candidates a comment on each is noise (a job red for a long
# while): the run summary lists the range instead.
MAX_COMMENTED_PRS = 5
MAX_BISECT_COMMITS = SCANNED_RUNS
SHA = re.compile(r"[0-9a-f]{40}")
CHECK_STEP = re.compile(r"\b(tests?|compile|compilation|lint|checks?|verify|validate|crash|generated|exports|tier)\b", re.I)
INFRA_STEP = re.compile(r"\b(checkout|check out|set up|setup|install|restore|cache|download|upload|fetch|"
                        r"select xcode|admission|publish|promotion|fingerprint|look for|request)\b", re.I)


class JobVerdicts(dict[str, str]):
    """Legacy range conclusions plus stricter evidence for exact attribution."""

    def __init__(self, jobs: dict[str, str], proof: dict[str, str]):
        super().__init__(jobs)
        self.proof = proof


def checked_conclusion(job: dict) -> str:
    """Only a completed check step can prove green/red; setup failures cannot.

    Unknown step names stay unresolved. Range attribution retains the job's
    original conclusion, so this stricter proof never hides an existing red.
    """
    conclusion = job.get("conclusion")
    if job.get("status") != "completed" or conclusion not in ("success", "failure"):
        return ""
    steps = job.get("steps")
    if not isinstance(steps, list) or not steps:
        return ""
    if any(step.get("conclusion") in ("failure", "timed_out", "cancelled")
           and INFRA_STEP.search(step.get("name") or "") for step in steps):
        return ""
    return conclusion if any(
        step.get("status") == "completed" and step.get("conclusion") == conclusion
        and CHECK_STEP.search(step.get("name") or "") and not INFRA_STEP.search(step.get("name") or "")
        for step in steps
    ) else ""


# cmux-next.yml run names end in the commit the run tested: `cmux-next · <sha>` for a push, and
# `cmux-next base tier · <sha>` or `cmux-next tip daemon suite · <sha>` for a dispatch, whose
# same-tree run tests that commit after the branch moved on (its head_sha is the newer branch head).
TESTED_SHA = re.compile(r" · ([0-9a-f]{40})$")


def tested_sha(run: dict) -> str:
    """The commit a cmux-next.yml run tested: the sha its name ends in, else its head_sha."""
    match = TESTED_SHA.search(run.get("display_title") or run.get("name") or "")
    return match.group(1) if match else run["head_sha"]


def should_comment(numbers: list[int]) -> bool:
    return 0 < len(numbers) <= MAX_COMMENTED_PRS


def gh_api(path: str) -> object:
    read = os.environ.get("GH_READ_TOKEN", "")
    if read:
        try:
            output = subprocess.run(["gh", "api", path], check=True, capture_output=True, text=True,
                                    env={**os.environ, "GH_TOKEN": read}).stdout
            return json.loads(output)
        except subprocess.CalledProcessError:
            pass  # the read token may lack a permission: the workflow token answers
    output = subprocess.run(["gh", "api", path], check=True, capture_output=True, text=True).stdout
    return json.loads(output)


# A squash merge's subject ends in "(#N)"; a merge commit's starts "Merge pull request #N from".
PR_SUBJECT = re.compile(r"\(#([1-9][0-9]*)\)\s*$|^Merge pull request #([1-9][0-9]*) from ")
MAX_GIT_RANGE = 400


def subject_pr(subject: str) -> int | None:
    match = PR_SUBJECT.search(subject or "")
    return int(match.group(1) or match.group(2)) if match else None


def first_parent_chain(base: str, head: str) -> list[tuple[str, str]] | None:
    """(sha, subject) of BASE..HEAD along HEAD's first parents, oldest first, from local git.

    None when git cannot prove the range: a missing commit, BASE off HEAD's first-parent
    chain, or history the shallow fetch does not reach. Callers then ask the API.
    """
    if not SHA.fullmatch(base or "") or not SHA.fullmatch(head or "") or base == head:
        return None
    try:
        lines = subprocess.run(["git", "log", "--first-parent", f"--max-count={MAX_GIT_RANGE + 1}",
                                "--format=%H %s", head, "--"], check=True, capture_output=True,
                               text=True, timeout=60).stdout.splitlines()
    except (OSError, subprocess.SubprocessError):
        return None
    chain: list[tuple[str, str]] = []
    for line in lines:
        sha, _, subject = line.partition(" ")
        if sha == base:
            return list(reversed(chain))
        chain.append((sha, subject))
    return None


def run_jobs(repo: str, run_id: int) -> JobVerdicts:
    """One latest attempt, preserving range failures and separate check proof."""
    payload = gh_api(f"repos/{repo}/actions/runs/{run_id}/jobs?filter=latest&per_page=100")
    jobs = payload["jobs"]
    grouped: dict[str, list[dict]] = {}
    for job in jobs:
        grouped.setdefault(job["name"], []).append(job)
    found, proof = {}, {}
    for name, alternatives in grouped.items():
        active = [job for job in alternatives if job.get("conclusion") != "skipped"]
        conclusions = {job.get("conclusion") or "" for job in active if job.get("status") == "completed"}
        # Release compile admission and fallback share a name. The skipped
        # alternative must not erase the active failure in either API order.
        found[name] = next((value for value in ("failure", "timed_out", "success") if value in conclusions),
                           "skipped" if not active else "")
        proof[name] = checked_conclusion(active[0]) if len(active) == 1 else ""
    if payload.get("total_count", len(jobs)) > len(jobs):
        proof = {}  # retain legacy range data, never prove from truncated jobs
    return JobVerdicts(found, proof)


def failed_jobs(jobs: dict[str, str]) -> list[str]:
    return sorted(name for name, conclusion in jobs.items()
                  if conclusion in ("failure", "timed_out") and name not in IGNORED_JOBS)


def last_green(failed: list[str], earlier: list[tuple[str, dict[str, str]]]) -> str | None:
    """The newest earlier head SHA where every failed job passed.

    `earlier` is (head_sha, job conclusions), newest first. A job that was
    skipped (a superseded push) says nothing; only a pass counts. The range
    starts at the oldest of the per-job last passes, so it holds every
    candidate for each failed job.
    """
    found: dict[str, int] = {}
    for index, (_, jobs) in enumerate(earlier):
        for name in failed:
            if name not in found and jobs.get(name) == "success":
                found[name] = index
        if len(found) == len(failed):
            return earlier[max(found.values())][0]
    return None


def bisect_history(failed: list[str], runs: list[tuple[str, dict[str, str]]], lower: str,
                   commits: list[str], max_probes: int = 6) -> dict[str, dict]:
    """Bisect a complete, monotonic first-parent history of completed CI verdicts.

    The caller validates ``commits`` as the entire LOWER..HEAD chain. Every
    position must have explicit success/failure evidence, including a passing
    lower bound and failing head. Missing/ambiguous/infra evidence and any
    red-to-green transition leave that job unresolved. Midpoint lookups reuse
    completed CI runs; they never execute code or start duplicate builds.
    """
    out = {}
    for job in failed:
        item = {"method": "unresolved", "culprit": None, "green": None, "probes": []}
        out[job] = item
        if not commits or len(commits) > MAX_BISECT_COMMITS or lower in commits or len(set(commits)) != len(commits):
            item["reason"] = "no complete bounded first-parent range"
            continue
        verdicts = []
        for sha in [lower, *commits]:
            evidence = {jobs.get(job) for run_sha, jobs in runs if run_sha == sha and job in jobs}
            if len(evidence) != 1 or not evidence <= {"success", "failure"}:
                item["reason"] = f"missing, conflicting, or incomplete verdict at {sha}"
                break
            verdicts.append(next(iter(evidence)))
        else:
            if verdicts[0] != "success" or verdicts[-1] != "failure":
                item["reason"] = "lower bound is not green or head is not red"
                continue
            if any(a == "failure" and b == "success" for a, b in zip(verdicts, verdicts[1:])):
                item["reason"] = "failure is not monotonic across the range"
                continue
            lo, hi = 0, len(commits)
            order = [lower, *commits]
            while hi - lo > 1 and len(item["probes"]) < max_probes:
                mid = (lo + hi) // 2
                conclusion = verdicts[mid]
                item["probes"].append({"sha": order[mid], "conclusion": conclusion})
                if conclusion == "success":
                    lo = mid
                else:
                    hi = mid
            if hi - lo != 1:
                item["reason"] = "midpoint probe budget exhausted"
                continue
            item.update(method="bisect", culprit=order[hi], green=order[lo])
    return out


def never_passed(failed: list[str], earlier: list[tuple[str, dict[str, str]]]) -> list[str]:
    """Failed jobs with no pass in the scanned runs: red since before the range (or never
    run on a push before), so no merge in it is the culprit, and they must not hide the
    range of the jobs that did pass."""
    return [name for name in failed if not any(jobs.get(name) == "success" for _, jobs in earlier)]


def merged_pulls(repo: str, sha: str, branch: str) -> list[int]:
    return [pull["number"] for pull in gh_api(f"repos/{repo}/commits/{sha}/pulls")
            if pull.get("base", {}).get("ref") == branch and pull.get("merged_at")]


def merged_pulls_batch(repo: str, shas: list[str], branch: str) -> dict[str, list[int]]:
    """merged_pulls for many commits in one GraphQL query (a rebase merge's commits, autofix
    pushes); a failed query falls back to one REST read per commit."""
    if len(shas) > 100:
        return {**merged_pulls_batch(repo, shas[:100], branch), **merged_pulls_batch(repo, shas[100:], branch)}
    if not shas:
        return {}
    owner, _, name = repo.partition("/")
    fields = " ".join(f'c{i}: object(oid: "{sha}") {{ ... on Commit {{ associatedPullRequests(first: 10) '
                      f'{{ nodes {{ number mergedAt baseRefName }} }} }} }}' for i, sha in enumerate(shas))
    query = f'query($owner: String!, $name: String!) {{ repository(owner: $owner, name: $name) {{ {fields} }} }}'
    try:
        data = gh_api_graphql(query, owner=owner, name=name)["data"]["repository"]
        return {sha: [pull["number"] for pull in ((data.get(f"c{i}") or {}).get("associatedPullRequests") or {})
                      .get("nodes", []) if pull.get("baseRefName") == branch and pull.get("mergedAt")]
                for i, sha in enumerate(shas)}
    except (OSError, ValueError, KeyError, TypeError, AttributeError, subprocess.SubprocessError):
        return {sha: merged_pulls(repo, sha, branch) for sha in shas}


def gh_api_graphql(query: str, **variables: str) -> dict:
    args = ["graphql", "-f", f"query={query}", *[f"-f{k}={v}" for k, v in variables.items()]]
    read = os.environ.get("GH_READ_TOKEN", "")
    env = {**os.environ, "GH_TOKEN": read} if read else None
    output = subprocess.run(["gh", "api", *args], check=True, capture_output=True, text=True, env=env).stdout
    return json.loads(output)


def pull_requests(repo: str, base: str, head: str, branch: str) -> list[int]:
    numbers: list[int] = []
    chain = first_parent_chain(base, head)
    if chain is not None:
        # Each landing is one first-parent commit and a squash names its pull request; the
        # rest (a rebase merge's commits, a direct push) share one GraphQL lookup.
        unnamed = merged_pulls_batch(repo, [sha for sha, subject in chain if not subject_pr(subject)], branch)
        for sha, subject in chain:
            number = subject_pr(subject)
            for found in [number] if number else unnamed.get(sha, []):
                if found not in numbers:
                    numbers.append(found)
        return numbers
    compare = gh_api(f"repos/{repo}/compare/{base}...{head}")
    for commit in compare.get("commits", []):
        for number in merged_pulls(repo, commit["sha"], branch):
            if number not in numbers:
                numbers.append(number)
    return numbers


def compare_commits(repo: str, base: str, head: str) -> list[str]:
    """Validate and return the full first-parent BASE..HEAD chain, oldest first.

    GitHub returns compare commits chronologically, including side branches.
    Walk parent links from HEAD rather than reversing that list or treating
    branch commits as successive landings. Truncated, divergent, malformed, or
    oversized responses yield no range and can never name a culprit.
    """
    if not SHA.fullmatch(base or "") or not SHA.fullmatch(head or "") or base == head:
        return []
    chain = first_parent_chain(base, head)
    if chain is not None:
        return [sha for sha, _ in chain] if len(chain) <= MAX_BISECT_COMMITS else []
    compare = gh_api(f"repos/{repo}/compare/{base}...{head}")
    if not isinstance(compare, dict) or compare.get("status") != "ahead":
        return []
    if (compare.get("merge_base_commit") or {}).get("sha") != base:
        return []
    commits = compare.get("commits")
    if not isinstance(commits, list) or compare.get("total_commits") != len(commits) or len(commits) > 250:
        return []
    by_sha = {c.get("sha"): c for c in commits if isinstance(c, dict)}
    if len(by_sha) != len(commits):
        return []
    chain, current = [], head
    while current != base:
        if current in chain or len(chain) >= MAX_BISECT_COMMITS or not isinstance(current, str) or not SHA.fullmatch(current):
            return []
        commit = by_sha.get(current)
        parents = commit.get("parents") if commit else None
        if not isinstance(parents, list) or not parents or not isinstance(parents[0], dict):
            return []
        chain.append(current)
        current = parents[0].get("sha")
    return list(reversed(chain))


def pull_requests_for_commit(repo: str, sha: str, branch: str) -> list[int]:
    """Merged PRs whose merge commit or head commit is SHA, on BRANCH."""
    # The squash subject names it, from local git; only a commit it does not name asks the API.
    subject = ""
    if SHA.fullmatch(sha or ""):
        try:
            subject = subprocess.run(["git", "log", "-1", "--format=%s", sha, "--"], check=True,
                                     capture_output=True, text=True, timeout=20).stdout.strip()
        except (OSError, subprocess.SubprocessError):
            subject = ""
    number = subject_pr(subject)
    if number:
        return [number]
    found: list[int] = []
    for pull in gh_api(f"repos/{repo}/commits/{sha}/pulls"):
        if (pull.get("base", {}).get("ref") == branch and pull.get("merged_at")
                and pull.get("merge_commit_sha") == sha):
            number = pull.get("number")
            if isinstance(number, int) and number not in found:
                found.append(number)
    return found


def comment_body(run_url: str, sha: str, failed: list[str], good: str, numbers: list[int], run_id: int) -> str:
    others = ", ".join(f"#{n}" for n in numbers)
    return "\n".join([
        MARKER.format(run_id=run_id),
        f"The feat-cmux-next push run {run_url} at {sha[:10]} failed: {', '.join(failed)}.",
        f"Those jobs last passed at {good[:10]}. This pull request is one of {len(numbers)} merged since: {others}.",
        "If the failure is in your change, fix forward on feat-cmux-next. Pull requests run only the tiers "
        "their paths reach (docs/ci/cmux-next-tiers.md); label a batch PR full-ci to run them all before merging.",
    ])


def culprit_body(run_url: str, sha: str, job: str, verdict: dict, run_id: int, owner: str = "") -> str:
    """A comment only for a unique merged PR proved by midpoint search."""
    mention = f"@{owner} " if re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-]{0,38}", owner) else ""
    return "\n".join([
        f"<!-- cmux-next-push-culprit:{run_id}:{job} -->",
        f"{mention}`{job}` first failed at merged commit `{verdict['culprit']}` after green `{verdict['green']}`.",
        f"Bisected completed CI verdicts for every first-parent commit up to `{sha}` ({run_url}); "
        f"{len(verdict['probes'])} midpoint lookups. The verified history is monotonic.",
        "Skipped, missing, conflicting, infrastructure, or non-monotonic evidence stays unresolved.",
    ])


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", required=True)
    parser.add_argument("--run-id", type=int, required=True)
    parser.add_argument("--sha", required=True)
    parser.add_argument("--workflow", default="cmux-next.yml")
    parser.add_argument("--branch", default="feat-cmux-next")
    parser.add_argument("--server-url", default="https://github.com")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--summary", type=Path)
    parser.add_argument("--last-known-green", default="",
                        help="reconciler-published lower bound; malformed values are ignored")
    parser.add_argument("--events", default="push",
                        help="comma-separated run events to scan for the last pass (push, workflow_dispatch)")
    args = parser.parse_args(argv)

    def report(text: str) -> None:
        print(text)
        if args.summary:
            with args.summary.open("a", encoding="utf-8") as stream:
                stream.write(text + "\n")

    current_jobs = run_jobs(args.repo, args.run_id)
    failed = failed_jobs(current_jobs)
    if not failed:
        report("No failed check job in this run.")
        return 0
    events = [event for event in args.events.split(",") if event in ("push", "workflow_dispatch")] or ["push"]
    runs = sorted(
        (
            run
            for event in events
            for run in gh_api(
                f"repos/{args.repo}/actions/workflows/{args.workflow}/runs"
                f"?branch={args.branch}&event={event}&per_page={SCANNED_RUNS}"
            )["workflow_runs"]
        ),
        key=lambda run: run["id"],
        reverse=True,
    )[:SCANNED_RUNS]
    history = [
        (tested_sha(run), run_jobs(args.repo, run["id"]))
        for run in runs
        if run["id"] < args.run_id and run.get("status") == "completed"
    ]
    earlier = [(sha, jobs) for sha, jobs in history if sha != args.sha]
    long_red = never_passed(failed, earlier)
    if long_red:
        report(f"{', '.join(long_red)} did not pass in the last {SCANNED_RUNS} push runs; no culprit range for it.")
    failed = [name for name in failed if name not in long_red]
    good = last_green(failed, earlier) if failed else None
    if good is None:
        return 0
    numbers = pull_requests(args.repo, good, args.sha, args.branch)
    run_url = f"{args.server_url}/{args.repo}/actions/runs/{args.run_id}"
    lower = args.last_known_green if re.fullmatch(r"[0-9a-f]{40}", args.last_known_green or "") else good
    try:
        commit_order = compare_commits(args.repo, lower, args.sha) if os.environ.get("NEXT_PUSH_BISECT") != "0" else []
    except (OSError, ValueError, subprocess.SubprocessError, KeyError):
        commit_order = []
    evidence = [(args.sha, current_jobs.proof), *[(sha, jobs.proof) for sha, jobs in history]]
    verdicts = bisect_history(failed, evidence, lower, commit_order)
    exact: dict[int, list[tuple[str, dict]]] = {}
    for job, verdict in verdicts.items():
        report("cmux-next bisect: " + json.dumps({"job": job, "lower": lower, "head": args.sha, **verdict}, sort_keys=True))
        if verdict["method"] != "bisect":
            continue
        prs = pull_requests_for_commit(args.repo, verdict["culprit"], args.branch)
        if len(prs) == 1:
            exact.setdefault(prs[0], []).append((job, verdict))
        else:
            report(f"{job}: culprit unresolved at {verdict['culprit']} ({len(prs)} merged PRs or a direct push).")
    report(f"### cmux-next push attribution\n\nFailed: {', '.join(failed)}. Last passed at {good}. "
           f"Pull requests in range: {', '.join(f'#{n}' for n in numbers) or 'none'}.")
    for number, proofs in exact.items():
        pull = gh_api(f"repos/{args.repo}/pulls/{number}")
        owner = (pull.get("user") or {}).get("login", "") if isinstance(pull, dict) else ""
        body = "\n\n".join(culprit_body(run_url, args.sha, job, verdict, args.run_id, owner)
                            for job, verdict in proofs)
        if args.dry_run:
            print(f"--- would comment on exact culprit #{number}:\n{body}")
        else:
            pr_status.upsert(args.repo, number, "push-culprit", body,
                             legacy="<!-- cmux-next-push-culprit:")
    if not should_comment(numbers):
        if numbers:
            report(f"{len(numbers)} pull requests in range: no comments (more than {MAX_COMMENTED_PRS}). "
                   "The job has been red for a while; its owner needs the run, not each author.")
        return 0
    body = comment_body(run_url, args.sha, failed, good, numbers, args.run_id)
    for number in numbers:
        if args.dry_run:
            print(f"--- would comment on #{number}:\n{body}")
            continue
        pr_status.upsert(args.repo, number, "push-attribution", body,
                         legacy="<!-- cmux-next-push-attribution:")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
