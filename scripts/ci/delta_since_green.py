#!/usr/bin/env python3
"""Route a pull request from its last green head when the new head only merged main.

RFC #14631, slice 2. When a pull request's head H2 is its previous head H1
plus one or more merges of main, and at most one commit on top (the conflict
resolution), the pull request's own changes already passed CI at H1. What can
change a test's outcome is what differs between H1 and the tree this run
tests, so ci.yml routes diff(H1, merge) instead of diff(main, merge).

H1 is the nearest commit on H2's first-parent chain with a conclusive
`ci-status` check run from a pull_request run of ci.yml that GitHub ties to
this pull request and base branch; every such run must have passed. Every commit
between them must be a merge whose second parent is on main, except H2 itself,
which may be one ordinary commit on top of such a merge.

Fail open. Anything unexpected (another shape, a red or missing verdict, a
force push, history too shallow, a pull request that edits CI policy, an
API error) prints why and leaves
`base_sha` empty, and ci.yml routes the usual pull request diff. The result
also never drops a file the pull request's own diff needs: every file the
pull request changes against main must either differ since H1 or have been
part of the pull request's diff at H1, which H1's green run covered.

Stdlib only: ci.yml runs the copy on the base revision, like the trusted
router, so a pull request cannot change how its own diff is chosen.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Iterable, Optional

# Commits on the head's first-parent chain examined for a green head.
MAX_CHAIN = 8
# Commits fetched behind the head and main to find the merge base and check
# that each merge brought in main. About two weeks of main (#14631).
HISTORY_DEPTH = 3000
CI_STATUS = "ci-status"
CI_WORKFLOW_PATH = ".github/workflows/ci.yml"
# CI policy: the router, its guards and the workflows. ci.yml classifies these
# (the trusted base router, the stdlib-shadow guard, guard-test self-selection)
# by whether they are in the diff. A pull request that changes any of them
# keeps its whole diff, so the delta can never hide them from that check.
CI_POLICY_PREFIXES = (".github/", "scripts/ci/")
CI_POLICY_TEST_PREFIXES = ("tests/test_ci_",)
CI_POLICY_FILES = frozenset({"tests/test-execution.toml"})
# The GitHub Actions app, which owns every workflow check suite.
ACTIONS_APP_ID = 15368
CONCLUSIVE = frozenset({"success", "failure", "timed_out", "action_required", "startup_failure"})
SHA = re.compile(r"[0-9a-f]{40}")

# oid -> "success", another conclusive conclusion, or None for no verdict.
Verdicts = Callable[[list[str]], dict[str, Optional[str]]]


class Skip(Exception):
    """The delta does not apply; the message says why."""


@dataclass(frozen=True)
class Commit:
    oid: str
    parents: tuple[str, ...]


@dataclass(frozen=True)
class Decision:
    base: Optional[str]
    reason: str


def short(oid: str) -> str:
    return oid[:10]


class Git:
    """The checkout, which may be shallow. Fetches use `remote`."""

    def __init__(self, cwd: Path, remote: str = "origin") -> None:
        self.cwd = cwd
        self.remote = remote

    def run(self, *args: str) -> str:
        return subprocess.run(
            ["git", "-c", "maintenance.auto=false", "-c", "gc.auto=0", *args],
            cwd=self.cwd, check=True, capture_output=True, text=True,
        ).stdout

    def succeeds(self, *args: str) -> bool:
        return subprocess.run(
            ["git", *args], cwd=self.cwd, capture_output=True, text=True,
        ).returncode == 0

    def fetch(self, *args: str) -> None:
        self.run("fetch", "--quiet", "--no-tags", "--no-write-fetch-head", *args)

    def first_parent_chain(self, head: str, count: int) -> list[Commit]:
        # rev-list honours the shallow boundary: a boundary commit lists no
        # parents instead of lazily fetching them.
        lines = self.run("rev-list", "--first-parent", "--parents", f"--max-count={count}", head).split("\n")
        chain = []
        for line in lines:
            if line.strip():
                oid, *parents = line.split()
                chain.append(Commit(oid, tuple(parents)))
        return chain

    def shallow(self) -> set[str]:
        path = Path(self.run("rev-parse", "--git-path", "shallow").strip())
        path = path if path.is_absolute() else self.cwd / path
        try:
            return set(path.read_text(encoding="utf-8").split())
        except FileNotFoundError:
            return set()

    def is_ancestor(self, ancestor: str, descendant: str) -> bool:
        return self.succeeds("merge-base", "--is-ancestor", ancestor, descendant)

    def merge_base(self, left: str, right: str) -> Optional[str]:
        result = subprocess.run(
            ["git", "merge-base", left, right], cwd=self.cwd, capture_output=True, text=True,
        )
        base = result.stdout.strip()
        return base if result.returncode == 0 and SHA.fullmatch(base) else None

    def tree(self, commit: str) -> str:
        return self.run("rev-parse", f"{commit}^{{tree}}").strip()

    def changed(self, base: str, head: str) -> set[str]:
        # Both sides of a rename, like ci.yml's own diff.
        output = self.run("diff", "--no-renames", "--name-only", base, head)
        return {line for line in output.splitlines() if line.strip()}


def find_green_head(chain: list[Commit], verdicts: Verdicts) -> tuple[Commit, list[Commit]]:
    """H1 and the merges between it and the head, from the head's first-parent chain."""
    head = chain[0]
    if len(head.parents) > 2:
        raise Skip(f"the head {short(head.oid)} is an octopus merge")
    if len(head.parents) == 1 and (len(chain) < 2 or len(chain[1].parents) != 2):
        raise Skip("the head is a new commit, not a merge of main")
    if not head.parents:
        raise Skip("the head's parents are outside the fetched history")
    # H1 is the first commit with a verdict. Past the head, only merges may
    # lack one, so the first commit that is not a merge is the last candidate.
    candidates: list[Commit] = []
    for commit in chain[1:]:
        candidates.append(commit)
        if len(commit.parents) != 2:
            break
    if not candidates:
        raise Skip("the head's parents are outside the fetched history")
    results = verdicts([commit.oid for commit in candidates])
    merges = [head] if len(head.parents) == 2 else []
    for commit in candidates:
        verdict = results.get(commit.oid)
        if verdict is not None:
            if verdict != "success":
                raise Skip(f"the last head CI judged, {short(commit.oid)}, was not green ({verdict})")
            if not merges:
                raise Skip(f"the head is a new commit on green {short(commit.oid)}, not a merge of main")
            return commit, merges
        if len(commit.parents) != 2:
            raise Skip(f"{short(commit.oid)} has no CI verdict and is not a merge of main")
        merges.append(commit)
    raise Skip(f"no green head within {len(candidates)} commits of the head")


def ci_policy_paths(paths: Iterable[str]) -> list[str]:
    return sorted(
        path for path in paths
        if path.startswith(CI_POLICY_PREFIXES) or path.startswith(CI_POLICY_TEST_PREFIXES)
        or path in CI_POLICY_FILES
    )


def decide(git: Git, merge_sha: str, head_sha: str, verdicts: Verdicts) -> Decision:
    for name, value in (("merge", merge_sha), ("head", head_sha)):
        if not SHA.fullmatch(value):
            raise Skip(f"the {name} sha {value!r} is not a full sha")
    tested = git.first_parent_chain(merge_sha, 1)
    if not tested or len(tested[0].parents) != 2 or tested[0].parents[1] != head_sha:
        raise Skip("the tested commit is not main merged with the pull request head")
    onto = tested[0].parents[0]
    own_now = git.changed(onto, merge_sha)
    policy = ci_policy_paths(own_now)
    if policy:
        listed = ", ".join(policy[:3]) + (", ..." if len(policy) > 3 else "")
        raise Skip(f"the pull request changes CI policy ({listed}), which routes from its whole diff")

    # Commits only, no trees: enough to read the chain's shape.
    git.fetch("--filter=tree:0", f"--depth={MAX_CHAIN + 2}", git.remote, head_sha)
    chain = git.first_parent_chain(head_sha, MAX_CHAIN + 1)
    green, merges = find_green_head(chain, verdicts)

    # The merge base and "each merge brought in main" need main's history.
    git.fetch("--filter=tree:0", f"--deepen={HISTORY_DEPTH}", git.remote, head_sha, onto)
    for merge in merges:
        if not git.is_ancestor(merge.parents[1], onto):
            raise Skip(f"merge {short(merge.oid)} brings in {short(merge.parents[1])}, which is not on main")
    base = git.merge_base(green.oid, onto)
    if base is None or base in git.shallow():
        raise Skip(f"the merge base of {short(green.oid)} and main is outside the fetched history")

    # Trees (not blobs) of the two commits the diffs below need. A commit that
    # is already local is skipped by fetch, so ask for the trees themselves.
    git.fetch("--filter=blob:none", git.remote, git.tree(green.oid), git.tree(base))
    delta = git.changed(green.oid, merge_sha)
    own_then = git.changed(base, green.oid)
    # A file the pull request changes now that neither differs since H1 nor
    # was changed at H1 was never tested with this content: a merge that kept
    # the pull request's side of a file only main had edited.
    uncovered = sorted(own_now - delta - own_then)
    if uncovered:
        listed = ", ".join(uncovered[:5]) + (", ..." if len(uncovered) > 5 else "")
        raise Skip(f"{len(uncovered)} files the pull request changes were not in its diff at "
                   f"{short(green.oid)} and did not change since: {listed}")
    return Decision(
        green.oid,
        f"delta since green head {short(green.oid)}: {len(delta)} files "
        f"(pull request diff: {len(own_now)} files)",
    )


def ci_status_runs(suites: Iterable[dict]) -> dict[int, str]:
    """Run id -> that run's latest conclusive ci-status conclusion, lowercased.

    Only pull_request runs of .github/workflows/ci.yml count, matched by file,
    not by name. Within one run the latest attempt wins, so a rerun can clear
    a flake. Cancelled, skipped, neutral, stale and in-progress runs say nothing.
    """
    latest: dict[int, tuple[str, str]] = {}
    for suite in suites:
        run = suite.get("workflowRun") or {}
        run_id = run.get("databaseId")
        if (run.get("event") != "pull_request" or not isinstance(run_id, int)
                or (run.get("file") or {}).get("path") != CI_WORKFLOW_PATH):
            continue
        for check in ((suite.get("checkRuns") or {}).get("nodes") or []):
            conclusion = (check.get("conclusion") or "").lower()
            started = check.get("startedAt") or ""
            if conclusion in CONCLUSIVE and (run_id not in latest or started > latest[run_id][0]):
                latest[run_id] = (started, conclusion)
    return {run_id: conclusion for run_id, (_, conclusion) in latest.items()}


def runs_for_pull_request(runs: Iterable[dict], number: int, base_ref: str) -> set[int]:
    """Ids of the Actions runs GitHub ties to this pull request and base branch."""
    bound = set()
    for run in runs:
        for pull in run.get("pull_requests") or []:
            if pull.get("number") == number and ((pull.get("base") or {}).get("ref")) == base_ref:
                bound.add(run.get("id"))
    return bound


def verdict(conclusions: dict[int, str], bound: set[int]) -> Optional[str]:
    """Green only when every run of this pull request that judged the commit passed.

    Runs another pull request made on the same commit (a stacked pull request
    on another base) say nothing, nor do runs GitHub does not tie to a pull
    request (fork runs). A red run anywhere among ours makes the commit red.
    """
    ours = [conclusion for run_id, conclusion in conclusions.items() if run_id in bound]
    if not ours:
        return None
    red = sorted({conclusion for conclusion in ours if conclusion != "success"})
    return red[0] if red else "success"


def github_verdicts(repository: str, token: str, api_url: str, number: int, base_ref: str) -> Verdicts:
    rest_url = os.environ.get("GITHUB_API_URL") or "https://api.github.com"

    def call(url: str, body: Optional[dict] = None) -> dict:
        request = urllib.request.Request(
            url,
            data=json.dumps(body).encode() if body is not None else None,
            headers={"Authorization": f"bearer {token}", "Content-Type": "application/json",
                     "Accept": "application/vnd.github+json"},
        )
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.load(response)

    def lookup(oids: list[str]) -> dict[str, Optional[str]]:
        owner, _, name = repository.partition("/")
        for oid in oids:
            if not SHA.fullmatch(oid):
                raise ValueError(f"not a sha: {oid!r}")
        fields = " ".join(f'c{index}: object(oid: "{oid}") {{ ...Verdict }}' for index, oid in enumerate(oids))
        query = (
            "query($owner: String!, $name: String!) { repository(owner: $owner, name: $name) { "
            + fields + " } } "
            "fragment Verdict on Commit { "
            f"checkSuites(first: 100, filterBy: {{appId: {ACTIONS_APP_ID}}}) {{ nodes {{ "
            "workflowRun { databaseId event file { path } } "
            f'checkRuns(first: 20, filterBy: {{checkName: "{CI_STATUS}", checkType: ALL}}) '
            "{ nodes { conclusion startedAt } } } } }"
        )
        payload = call(api_url, {"query": query, "variables": {"owner": owner, "name": name}})
        if payload.get("errors"):
            raise RuntimeError(f"GraphQL errors: {payload['errors']}")
        repo = payload["data"]["repository"]
        results: dict[str, Optional[str]] = {oid: None for oid in oids}
        for index, oid in enumerate(oids):
            suites = ((repo.get(f"c{index}") or {}).get("checkSuites") or {}).get("nodes") or []
            conclusions = ci_status_runs(suites)
            if not conclusions:
                continue
            # GraphQL does not say which pull request a run served; the runs
            # API does. One call, for the nearest commit CI judged.
            runs = call(f"{rest_url}/repos/{repository}/actions/runs?head_sha={oid}"
                        "&event=pull_request&per_page=100").get("workflow_runs") or []
            results[oid] = verdict(conclusions, runs_for_pull_request(runs, number, base_ref))
            if results[oid] is not None:
                break
        return results

    return lookup


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repository", default=os.environ.get("GITHUB_REPOSITORY", ""))
    parser.add_argument("--merge-sha", required=True, help="the commit this run tests (main merged with the head)")
    parser.add_argument("--head-sha", required=True, help="the pull request head")
    parser.add_argument("--pull-request", type=int, required=True, help="the pull request number")
    parser.add_argument("--base-ref", required=True, help="the pull request's base branch")
    parser.add_argument("--github-output", default=os.environ.get("GITHUB_OUTPUT"))
    parser.add_argument("--summary", default=os.environ.get("GITHUB_STEP_SUMMARY"))
    args = parser.parse_args(argv)

    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN") or ""
    api_url = os.environ.get("GITHUB_GRAPHQL_URL") or "https://api.github.com/graphql"
    try:
        if not token or "/" not in args.repository:
            raise Skip("no token or repository to read CI verdicts with")
        decision = decide(Git(Path.cwd()), args.merge_sha, args.head_sha,
                          github_verdicts(args.repository, token, api_url, args.pull_request, args.base_ref))
    except Skip as skip:
        decision = Decision(None, f"pull request diff: {skip}")
    except Exception as error:  # noqa: BLE001 - any failure routes the usual diff
        detail = getattr(error, "stderr", "") or ""
        decision = Decision(None, f"pull request diff: the delta check failed ({error} {detail.strip()})".strip())

    print(f"CI diff base: {decision.reason}")
    if args.github_output:
        with open(args.github_output, "a", encoding="utf-8") as handle:
            handle.write(f"base_sha={decision.base or ''}\n")
    if args.summary:
        with open(args.summary, "a", encoding="utf-8") as handle:
            handle.write(f"**CI diff base:** {decision.reason}\n\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
