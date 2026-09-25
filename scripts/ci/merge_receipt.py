#!/usr/bin/env python3
"""Leave a short receipt on each merged pull request: what CI verified at merge.

main moves fast and pull requests often merge before every check on their head
finishes. That is allowed; this never blocks a merge. It records, once per
pull request, which checks on the head commit had passed when it merged and
which had not, so whoever fixes main later knows where to look.

Each check's state is read as of the merge time: a run that finished before
the merge counts with its conclusion, one that started but had not finished is
"in progress", and one that started after the merge is "not reported". A check
name that ran several times (a re-run, a superseded run) counts its latest
start before the merge.

Checks are grouped for reading: reusable-workflow jobs lose their caller
prefix, every guards job folds into "guards", and every app-host shard into
"app-host unit tests". Bots, CLA and other bookkeeping checks are left out
unless they failed.

A pull request whose judging checks (compile admission, app-host unit tests,
ci-status and required checks) were not all green at merge gets the
`merged-unverified` label, which main_regression_attribution.py uses to break
ties between suspects. The comment is idempotent through a hidden marker and
is edited in place on a re-run.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from collections.abc import Iterable, Mapping
from dataclasses import dataclass, field

MARKER = "<!-- cmux:merge-receipt -->"
LABEL = "merged-unverified"
# Checks that are expected on every pull request even when they never reported.
EXPECTED = ("ci-status",)
# Checks that judge the change itself. Required checks judge it too.
JUDGING_RE = re.compile(r"macOS compile admission|app-host unit tests|^ci-status$")
# Bookkeeping checks from GitHub Actions that say nothing about the change.
NOISE_RE = re.compile(
    r"^CLA |^CLA$|CLA Assistant|CLA policy guard|^welcome$|Watch owned pool jobs|\(report only\)|^changes$"
)
ACTIONS_APP = "github-actions"
MAX_LISTED = 12

# States, worst first. A group reports its worst member.
FAILURE, CANCELLED, IN_PROGRESS, PENDING, NOT_REPORTED, SUCCESS, SKIPPED = (
    "failure", "cancelled", "in progress", "pending", "not reported", "success", "skipped",
)
ORDER = (FAILURE, CANCELLED, IN_PROGRESS, PENDING, NOT_REPORTED, SUCCESS, SKIPPED)
GREEN = frozenset({SUCCESS, SKIPPED})
CONCLUSIONS = {
    "SUCCESS": SUCCESS, "NEUTRAL": SUCCESS, "SKIPPED": SKIPPED,
    "FAILURE": FAILURE, "TIMED_OUT": FAILURE, "STARTUP_FAILURE": FAILURE, "ACTION_REQUIRED": FAILURE,
    "CANCELLED": CANCELLED, "STALE": CANCELLED,
}
STATUS_STATES = {"SUCCESS": SUCCESS, "PENDING": IN_PROGRESS, "EXPECTED": PENDING, "FAILURE": FAILURE, "ERROR": FAILURE}


@dataclass
class Check:
    name: str
    state: str
    required: bool = False
    noise: bool = False


@dataclass
class Group:
    name: str
    checks: list[Check] = field(default_factory=list)

    @property
    def state(self) -> str:
        states = {check.state for check in self.checks}
        bad = [state for state in ORDER if state in states and state not in GREEN]
        if bad:
            return bad[0]
        return SUCCESS if SUCCESS in states else SKIPPED

    @property
    def judging(self) -> bool:
        return bool(JUDGING_RE.search(self.name)) or any(check.required for check in self.checks)

    def label(self) -> str:
        return f"{self.name} ({len(self.checks)})" if len(self.checks) > 1 else self.name


def state_at(context: Mapping[str, object], merged_at: str) -> tuple[str, str]:
    """(state as of the merge, start time) for one check run or status context.

    Timestamps are ISO-8601 UTC strings from GitHub, so they compare as text.
    """
    if context.get("__typename") == "StatusContext":
        created = str(context.get("createdAt") or "")
        if not created or created > merged_at:
            return NOT_REPORTED, created
        return STATUS_STATES.get(str(context.get("state") or ""), PENDING), created
    started = str(context.get("startedAt") or "")
    if not started:
        return PENDING, ""
    if started > merged_at:
        return NOT_REPORTED, started
    completed = str(context.get("completedAt") or "")
    if completed and completed <= merged_at:
        return CONCLUSIONS.get(str(context.get("conclusion") or ""), FAILURE), started
    return IN_PROGRESS, started


def context_name(context: Mapping[str, object]) -> str:
    return str(context.get("name") or context.get("context") or "")


def is_noise(context: Mapping[str, object]) -> bool:
    if context.get("__typename") == "StatusContext":
        return True
    app = ((context.get("checkSuite") or {}).get("app") or {}).get("slug")
    return app != ACTIONS_APP or bool(NOISE_RE.search(context_name(context)))


def checks_at_merge(contexts: Iterable[Mapping[str, object]], merged_at: str) -> list[Check]:
    """One check per name: its latest run started before the merge, else its earliest later one."""
    best: dict[str, tuple[bool, str, Check]] = {}
    for context in contexts:
        name = context_name(context)
        state, started = state_at(context, merged_at)
        check = Check(name, state, bool(context.get("isRequired")), is_noise(context))
        before = state != NOT_REPORTED
        current = best.get(name)
        if current is None:
            best[name] = (before, started, check)
            continue
        was_before, was_started, _ = current
        if before != was_before:
            newer = before
        else:
            newer = started > was_started if before else started < was_started
        if newer:
            best[name] = (before, started, check)
    # A job that had not started at the merge did not exist yet for whoever
    # merged; only required and expected checks are worth naming as missing.
    checks = [
        check for _, _, check in best.values()
        if check.state != NOT_REPORTED or check.required or check.name in EXPECTED
    ]
    seen = {check.name for check in checks}
    checks += [Check(name, NOT_REPORTED, True) for name in EXPECTED if name not in seen]
    return checks


def group_name(name: str) -> str:
    if "app-host unit tests" in name:
        return "app-host unit tests"
    if name.startswith("guards / "):
        return "guards"
    return name.split(" / ", 1)[1] if " / " in name else name


def groups(checks: Iterable[Check]) -> list[Group]:
    found: dict[str, Group] = {}
    for check in checks:
        key = group_name(check.name)
        found.setdefault(key, Group(key)).checks.append(check)
    return sorted(found.values(), key=lambda group: group.name.lower())


@dataclass
class Receipt:
    body: str
    unverified: bool


def listed(items: list[str]) -> str:
    if len(items) <= MAX_LISTED:
        return ", ".join(items)
    return ", ".join(items[:MAX_LISTED]) + f", and {len(items) - MAX_LISTED} more"


def receipt(snapshot: Mapping[str, object]) -> Receipt:
    """The comment body and whether the pull request merged unverified."""
    merged_at = str(snapshot["mergedAt"])
    sha = str(snapshot["headRefOid"])[:10]
    checks = checks_at_merge(snapshot.get("contexts") or [], merged_at)
    real = groups(check for check in checks if not check.noise)
    noisy = groups(check for check in checks if check.noise)
    # Judging groups first so the eye lands on them.
    real.sort(key=lambda group: not group.judging)
    verified = [group.label() for group in real if group.state == SUCCESS]
    skipped = [group.label() for group in real if group.state == SKIPPED]
    missing = [f"{group.label()} ({group.state})" for group in real if group.state not in GREEN]
    missing += [f"{group.label()} ({group.state})" for group in noisy if group.state in (FAILURE, CANCELLED)]
    unverified = any(group.judging and group.state not in GREEN for group in real)

    head = f"**Merge receipt** for `{sha}`"
    if not missing:
        tail = f"; {len(skipped)} skipped by policy" if skipped else ""
        lines = [f"{head}: every check was green at merge ({len(verified)} verified{tail}). "
                 "Full suite runs on main after merge."]
    else:
        lines = [f"{head}, merged {merged_at.replace('T', ' ').rstrip('Z')} UTC"]
        lines.append(f"- Not verified at merge: {listed(missing)}")
        if verified:
            lines.append(f"- Verified: {listed(verified)}")
        if skipped:
            lines.append(f"- Skipped by policy: {listed(skipped)}")
        lines.append("- Full suite: runs on main after merge.")
        if unverified:
            lines.append(f"\nLabeled `{LABEL}`: if main breaks near this merge, look here first.")
    lines.append(MARKER)
    return Receipt("\n".join(lines), unverified)


# --- GitHub ---------------------------------------------------------------

PR_QUERY = """
query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      number merged mergedAt headRefOid
      labels(first: 50) { nodes { name } }
      comments(last: 100) { nodes { databaseId body } }
    }
  }
}
"""

CONTEXTS_QUERY = """
query($owner: String!, $name: String!, $oid: GitObjectID!, $number: Int!, $after: String) {
  repository(owner: $owner, name: $name) {
    object(oid: $oid) {
      ... on Commit {
        statusCheckRollup {
          contexts(first: 100, after: $after) {
            pageInfo { hasNextPage endCursor }
            nodes {
              __typename
              ... on CheckRun {
                name status conclusion startedAt completedAt
                isRequired(pullRequestNumber: $number)
                checkSuite { app { slug } }
              }
              ... on StatusContext { context state createdAt isRequired(pullRequestNumber: $number) }
            }
          }
        }
      }
    }
  }
}
"""


def gh(args: list[str]) -> str:
    return subprocess.run(["gh", *args], check=True, capture_output=True, text=True).stdout


def graphql(query: str, **variables: object) -> dict:
    args = ["api", "graphql", "-f", f"query={query}"]
    for key, value in variables.items():
        if value is None:
            continue
        args += ["-F" if isinstance(value, int) else "-f", f"{key}={value}"]
    return json.loads(gh(args))["data"]


def fetch(repo: str, number: int) -> dict:
    """The pull request's merge time, head, labels, receipt comment and head check contexts."""
    owner, name = repo.split("/", 1)
    pr = graphql(PR_QUERY, owner=owner, name=name, number=number)["repository"]["pullRequest"]
    contexts: list[dict] = []
    after = None
    while True:
        commit = graphql(
            CONTEXTS_QUERY, owner=owner, name=name, oid=pr["headRefOid"], number=number, after=after,
        )["repository"]["object"] or {}
        page = ((commit.get("statusCheckRollup") or {}).get("contexts")) or {}
        contexts += page.get("nodes") or []
        info = page.get("pageInfo") or {}
        if not info.get("hasNextPage"):
            break
        after = info["endCursor"]
    return {
        "number": pr["number"], "merged": pr["merged"], "mergedAt": pr["mergedAt"],
        "headRefOid": pr["headRefOid"],
        "labels": [node["name"] for node in (pr.get("labels") or {}).get("nodes") or []],
        "comments": (pr.get("comments") or {}).get("nodes") or [],
        "contexts": contexts,
    }


def existing_comment(comments: Iterable[Mapping[str, object]]) -> int | None:
    for comment in comments:
        if MARKER in str(comment.get("body") or ""):
            return int(comment["databaseId"])
    return None


def command_post(args: argparse.Namespace) -> int:
    snapshot = fetch(args.repo, args.pr)
    if args.snapshot_output:
        with open(args.snapshot_output, "w", encoding="utf-8") as handle:
            json.dump({key: snapshot[key] for key in ("number", "mergedAt", "headRefOid", "contexts")}, handle, indent=1)
    if not snapshot["merged"]:
        print(f"#{args.pr} is not merged; nothing to record.")
        return 0
    result = receipt(snapshot)
    print(result.body)
    print(f"unverified={str(result.unverified).lower()}")
    if args.dry_run:
        return 0
    comment_id = existing_comment(snapshot["comments"])
    if comment_id is None:
        gh(["api", f"repos/{args.repo}/issues/{args.pr}/comments", "-f", f"body={result.body}"])
    else:
        gh(["api", "-X", "PATCH", f"repos/{args.repo}/issues/comments/{comment_id}", "-f", f"body={result.body}"])
    has_label = LABEL in snapshot["labels"]
    if result.unverified and not has_label:
        gh(["api", f"repos/{args.repo}/issues/{args.pr}/labels", "-f", f"labels[]={LABEL}"])
    elif not result.unverified and has_label:
        gh(["api", "-X", "DELETE", f"repos/{args.repo}/issues/{args.pr}/labels/{LABEL}"])
    return 0


def command_render(args: argparse.Namespace) -> int:
    with open(args.snapshot, encoding="utf-8") as handle:
        result = receipt(json.load(handle))
    print(result.body)
    print(f"unverified={str(result.unverified).lower()}")
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    post = sub.add_parser("post", help="comment on and label one merged pull request")
    post.add_argument("--repo", required=True)
    post.add_argument("--pr", type=int, required=True)
    post.add_argument("--dry-run", action="store_true", help="print the receipt without writing")
    post.add_argument("--snapshot-output", help="also save the fetched checks as a fixture")
    post.set_defaults(func=command_post)
    render = sub.add_parser("render", help="print the receipt for a saved snapshot")
    render.add_argument("snapshot")
    render.set_defaults(func=command_render)
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
