#!/usr/bin/env python3
"""Pick the open pull requests that PR catch-up merges main into on its own.

pr-catch-up.yml runs this when a push to main passes CI fast guards, so main
just went green at a new commit. A pull request is caught up automatically
when its head is a branch of this repository, it is not a draft, it has no
`no-auto-catch-up` label, and its head has been quiet for 30 minutes (an agent
still pushing is left alone), and either

- conflict: GitHub reports it CONFLICTING. The catch-up merge resolves the
  generated-file conflicts; any other conflict gets the usual comment naming
  the files, or
- red-on-main: its CI fast guards comment from scripts/ci/guard_attribution.py
  (`<!-- cmux-fast-guards-pr -->`, written by the Actions bot) marks a step
  "(red on main too, not this PR)". The pull request is red only because of
  main, and main is green now.

One automatic attempt per head: the workflow's comment carries
`<!-- cmux-auto-catch-up head=<sha> -->`, and a head that already has one is
skipped, so a conflict that needs a person is commented once per head rather
than once per push to main. A pushed catch-up changes the head, and its push
starts the quiet period again.

Every catch-up push re-runs the pull request's CI, so at most `--max` (the
CMUX_AUTO_CATCH_UP_MAX repository variable, default 15) are picked per run,
the most recently pushed first. Heads not pushed for `--max-age-days` are not
touched; `/catch-up` still works on them.

Batched GraphQL reads, never a per-PR call: the open pull requests against
main, newest update first, with the ids and authors of their last 100
comments (paging stops at the first one older than the age limit); the
bodies of the Actions bot's comments on the pull requests that passed the
other rules; and, since GitHub computes mergeability lazily after main moves,
up to three aliased re-reads of the ones still UNKNOWN, 20 seconds apart.
Stdlib only, so the workflow runs it with `python3 -I`.

Usage:
  auto_catch_up_select.py --repo OWNER/NAME [--max 15] [--github-output FILE]
  auto_catch_up_select.py --repo OWNER/NAME --responses replay.json --now 2026-09-25T12:00:00Z
Exit codes: 0 selection printed (possibly empty), 2 GitHub could not answer.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Callable, Iterable

BASE_BRANCH = "main"
OPT_OUT_LABEL = "no-auto-catch-up"
GUARD_PR_MARKER = "<!-- cmux-fast-guards-pr -->"
RED_ON_MAIN = "(red on main too, not this PR)"
ATTEMPT_MARKER = "<!-- cmux-auto-catch-up head={head} -->"
# The GraphQL login of the Actions bot, which writes both markers. A person
# pasting a marker into a comment must not steer the selection.
BOT_LOGINS = frozenset({"github-actions"})
DEFAULT_MAX = 15
MAX_CEILING = 50
DEFAULT_QUIET_MINUTES = 30
DEFAULT_MAX_AGE_DAYS = 14
PAGE_SIZE = 50
BODY_BATCH = 100

PULL_REQUESTS_QUERY = """
query($owner: String!, $name: String!, $base: String!, $first: Int!, $after: String) {
  repository(owner: $owner, name: $name) {
    pullRequests(states: OPEN, baseRefName: $base, first: $first, after: $after,
                 orderBy: {field: UPDATED_AT, direction: DESC}) {
      pageInfo { hasNextPage endCursor }
      nodes {
        number isDraft isCrossRepository updatedAt headRefOid mergeable
        headRepository { nameWithOwner }
        labels(first: 50) { nodes { name } }
        commits(last: 1) {
          nodes { commit { oid committedDate checkSuites(first: 1) { nodes { createdAt } } } }
        }
        comments(last: 100) { nodes { id author { login } } }
      }
    }
  }
}
""".strip()

# One aliased field per pull request whose mergeability GitHub had not
# computed yet; reading it is what makes GitHub compute it.
MERGEABLE_FIELD = "pr{number}: pullRequest(number: {number}) {{ number headRefOid mergeable }}"
MERGEABLE_QUERY = """
query($owner: String!, $name: String!) {{
  repository(owner: $owner, name: $name) {{ {fields} }}
}}
""".strip()
MERGEABLE_BATCH = 50
# GitHub computes mergeability lazily after main moves, so the first read
# after a push to main reports UNKNOWN for most pull requests. Read those
# again a few times, a bounded wait for GitHub's background job.
MERGEABLE_RETRIES = 3
MERGEABLE_RETRY_SECONDS = 20

COMMENT_BODIES_QUERY = """
query($ids: [ID!]!) {
  nodes(ids: $ids) { ... on IssueComment { id body } }
}
""".strip()

# (query, variables) -> the decoded GraphQL response.
GraphQL = Callable[[str, dict], dict]


class SelectionError(Exception):
    """GitHub could not answer; the workflow then catches nothing up."""


@dataclass
class Decision:
    number: int
    head: str
    selected: bool
    reason: str
    last_push: datetime | None = None
    why: str = ""  # conflict or red-on-main, for a selected pull request


def parse_time(value: object) -> datetime | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)


def last_push(pr: dict) -> datetime | None:
    """When the head commit was pushed.

    GraphQL no longer reports push dates (Commit.pushedDate is null), so this
    is the creation of the head commit's first check suite, which GitHub makes
    when the commit arrives, and the committer date when there is no suite.
    """
    nodes = (pr.get("commits") or {}).get("nodes") or [{}]
    commit = (nodes[-1] or {}).get("commit") or {}
    suites = ((commit.get("checkSuites") or {}).get("nodes") or [])
    suite_time = parse_time((suites[0] or {}).get("createdAt")) if suites else None
    return suite_time or parse_time(commit.get("committedDate"))


def labels(pr: dict) -> set[str]:
    return {str(node.get("name")) for node in ((pr.get("labels") or {}).get("nodes") or []) if node}


def bot_comment_ids(pr: dict) -> list[str]:
    ids = []
    for node in ((pr.get("comments") or {}).get("nodes") or []):
        if node and ((node.get("author") or {}).get("login") in BOT_LOGINS) and node.get("id"):
            ids.append(str(node["id"]))
    return ids


def ago(now: datetime, then: datetime | None) -> str:
    if then is None:
        return "unknown"
    minutes = int((now - then).total_seconds() // 60)
    if minutes < 120:
        return f"{minutes}m ago"
    if minutes < 48 * 60:
        return f"{minutes // 60}h ago"
    return f"{minutes // (24 * 60)}d ago"


def prefilter(pr: dict, repo: str, now: datetime, quiet: timedelta, max_age: timedelta) -> str | None:
    """Why this pull request is skipped before its comments matter, or None."""
    if pr.get("isDraft"):
        return "draft"
    head_repo = (pr.get("headRepository") or {}).get("nameWithOwner")
    if pr.get("isCrossRepository") is not False or head_repo != repo:
        return f"head is in {head_repo or 'a deleted repository'}, not {repo}"
    if OPT_OUT_LABEL in labels(pr):
        return f"labeled {OPT_OUT_LABEL}"
    pushed = last_push(pr)
    if pushed is None:
        return "no head push time"
    if now - pushed < quiet:
        return f"head pushed {ago(now, pushed)}, under {int(quiet.total_seconds() // 60)}m"
    if now - pushed > max_age:
        return f"head pushed {ago(now, pushed)}, over {max_age.days}d"
    return None


def classify(pr: dict, bodies: dict[str, str]) -> tuple[str | None, str]:
    """(why to catch up, or None, and the reason line)."""
    head = str(pr.get("headRefOid") or "")
    texts = [bodies[i] for i in bot_comment_ids(pr) if i in bodies]
    mergeable = pr.get("mergeable")
    red_on_main = any(GUARD_PR_MARKER in text and RED_ON_MAIN in text for text in texts)
    why = "conflict" if mergeable == "CONFLICTING" else "red-on-main" if red_on_main else None
    if why is None:
        if mergeable == "UNKNOWN":
            return None, "GitHub has not computed mergeability yet and guards are not red on main"
        return None, "nothing to catch up: no conflict, guards not red on main"
    if any(ATTEMPT_MARKER.format(head=head) in text for text in texts):
        return None, f"automatic catch-up already tried head {head[:12]}"
    return why, "conflicting with main" if why == "conflict" else "CI fast guards red on main only"


def evaluate(prs: Iterable[dict], bodies: dict[str, str], repo: str, now: datetime, cap: int,
             quiet: timedelta = timedelta(minutes=DEFAULT_QUIET_MINUTES),
             max_age: timedelta = timedelta(days=DEFAULT_MAX_AGE_DAYS)) -> list[Decision]:
    """Every pull request's decision; the selected ones first, most recent push first."""
    decisions: list[Decision] = []
    eligible: list[Decision] = []
    for pr in prs:
        number = int(pr.get("number") or 0)
        head = str(pr.get("headRefOid") or "")
        pushed = last_push(pr)
        skip = prefilter(pr, repo, now, quiet, max_age)
        if skip is None and len(head) != 40:
            skip = "head sha is not a full commit id"
        if skip is None:
            why, reason = classify(pr, bodies)
            if why is not None:
                eligible.append(Decision(number, head, True, reason, pushed, why))
                continue
            skip = reason
        decisions.append(Decision(number, head, False, skip, pushed))
    # Most recent head activity first; the number breaks ties so runs agree.
    eligible.sort(key=lambda d: (d.last_push or datetime.min.replace(tzinfo=timezone.utc), d.number), reverse=True)
    for index, decision in enumerate(eligible):
        if index >= cap:
            decision.selected = False
            decision.reason = f"{decision.reason}, but over this run's cap of {cap}"
    return eligible + decisions


def fetch_pull_requests(graphql: GraphQL, repo: str, now: datetime, max_age: timedelta) -> list[dict]:
    """Open pull requests against main updated within the age limit, newest update first."""
    owner, name = repo.split("/", 1)
    cutoff = now - max_age
    found: list[dict] = []
    after = None
    while True:
        response = graphql(PULL_REQUESTS_QUERY, {"owner": owner, "name": name, "base": BASE_BRANCH,
                                                 "first": PAGE_SIZE, "after": after})
        try:
            connection = response["data"]["repository"]["pullRequests"]
            nodes = connection["nodes"]
            page = connection["pageInfo"]
        except (KeyError, TypeError) as error:
            raise SelectionError(f"unreadable pull request page ({error.__class__.__name__})") from error
        for node in nodes:
            if not node:
                continue
            updated = parse_time(node.get("updatedAt"))
            # A push updates the pull request, so nothing after this one was
            # pushed within the age limit.
            if updated is not None and updated < cutoff:
                return found
            found.append(node)
        if not page.get("hasNextPage"):
            return found
        after = page.get("endCursor")


def fetch_bodies(graphql: GraphQL, ids: list[str]) -> dict[str, str]:
    bodies: dict[str, str] = {}
    for start in range(0, len(ids), BODY_BATCH):
        response = graphql(COMMENT_BODIES_QUERY, {"ids": ids[start:start + BODY_BATCH]})
        try:
            nodes = response["data"]["nodes"]
        except (KeyError, TypeError) as error:
            raise SelectionError(f"unreadable comment bodies ({error.__class__.__name__})") from error
        for node in nodes:
            if node and node.get("id"):
                bodies[str(node["id"])] = str(node.get("body") or "")
    return bodies


def refresh_mergeable(graphql: GraphQL, repo: str, prs: list[dict],
                      sleep: Callable[[float], None] = time.sleep) -> None:
    """Re-read UNKNOWN mergeability in place until GitHub answers or the retries run out.

    A head that moved since the first read keeps UNKNOWN: its other fields
    were judged for the old head.
    """
    owner, name = repo.split("/", 1)
    for attempt in range(MERGEABLE_RETRIES):
        pending = {int(pr["number"]): pr for pr in prs if pr.get("mergeable") == "UNKNOWN"}
        if not pending:
            return
        if attempt:
            sleep(MERGEABLE_RETRY_SECONDS)
        numbers = sorted(pending)
        for start in range(0, len(numbers), MERGEABLE_BATCH):
            fields = " ".join(MERGEABLE_FIELD.format(number=n) for n in numbers[start:start + MERGEABLE_BATCH])
            response = graphql(MERGEABLE_QUERY.format(fields=fields), {"owner": owner, "name": name})
            try:
                answers = (response["data"]["repository"] or {}).values()
            except (KeyError, TypeError, AttributeError) as error:
                raise SelectionError(f"unreadable mergeability ({error.__class__.__name__})") from error
            for answer in answers:
                if not answer:
                    continue
                pr = pending.get(int(answer.get("number") or 0))
                if pr is not None and answer.get("headRefOid") == pr.get("headRefOid"):
                    pr["mergeable"] = answer.get("mergeable") or "UNKNOWN"


def select(graphql: GraphQL, repo: str, now: datetime, cap: int,
           quiet: timedelta = timedelta(minutes=DEFAULT_QUIET_MINUTES),
           max_age: timedelta = timedelta(days=DEFAULT_MAX_AGE_DAYS),
           sleep: Callable[[float], None] = time.sleep) -> tuple[list[Decision], int]:
    """(decisions, number of pull requests read)."""
    prs = fetch_pull_requests(graphql, repo, now, max_age)
    passed = [pr for pr in prs if prefilter(pr, repo, now, quiet, max_age) is None
              and len(str(pr.get("headRefOid") or "")) == 40]
    ids = [i for pr in passed for i in bot_comment_ids(pr)]
    bodies = fetch_bodies(graphql, ids) if ids else {}
    # Only pull requests that nothing but mergeability decides.
    undecided = [pr for pr in passed if pr.get("mergeable") == "UNKNOWN" and classify(pr, bodies)[0] is None]
    refresh_mergeable(graphql, repo, undecided, sleep)
    return evaluate(prs, bodies, repo, now, cap, quiet, max_age), len(prs)


def gh_graphql(query: str, variables: dict) -> dict:
    body = json.dumps({"query": query, "variables": variables})
    completed = subprocess.run(["gh", "api", "graphql", "--input", "-"], input=body,
                               capture_output=True, text=True)
    if completed.returncode != 0:
        lines = (completed.stderr.strip() or completed.stdout.strip()).splitlines()
        raise SelectionError(f"gh api graphql failed: {lines[0] if lines else 'no output'}")
    try:
        response = json.loads(completed.stdout)
    except ValueError as error:
        raise SelectionError("gh api graphql returned no JSON") from error
    if response.get("errors"):
        raise SelectionError(f"GraphQL error: {str(response['errors'][0].get('message'))[:200]}")
    return response


def replay(path: Path) -> GraphQL:
    """Answer each query with the next recorded response (tests, dry runs)."""
    responses = list(json.loads(path.read_text(encoding="utf-8")))

    def answer(query: str, variables: dict) -> dict:
        if not responses:
            raise SelectionError("the replay file has no response left")
        return responses.pop(0)

    return answer


def parse_cap(raw: str | None) -> tuple[int, str | None]:
    """The per-run cap from the repository variable; a bad value keeps the default."""
    if raw is None or not raw.strip():
        return DEFAULT_MAX, None
    try:
        value = int(raw.strip())
    except ValueError:
        return DEFAULT_MAX, f"CMUX_AUTO_CATCH_UP_MAX={raw!r} is not a number; using {DEFAULT_MAX}"
    if value < 0:
        return DEFAULT_MAX, f"CMUX_AUTO_CATCH_UP_MAX={raw!r} is negative; using {DEFAULT_MAX}"
    if value > MAX_CEILING:
        return MAX_CEILING, f"CMUX_AUTO_CATCH_UP_MAX={raw!r} is over {MAX_CEILING}; using {MAX_CEILING}"
    return value, None


def matrix(decisions: list[Decision]) -> dict:
    return {"include": [{"pr": d.number, "pin": d.head, "why": d.why} for d in decisions if d.selected]}


def report(decisions: list[Decision], read: int, now: datetime) -> list[str]:
    chosen = [d for d in decisions if d.selected]
    lines = [f"auto catch-up: {len(chosen)} of {read} open pull request(s) against {BASE_BRANCH} selected"]
    for d in decisions:
        verb = "select" if d.selected else "skip  "
        lines.append(f"  {verb} #{d.number} {d.head[:12]} pushed {ago(now, d.last_push)}: {d.reason}")
    return lines


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", required=True, help="OWNER/NAME")
    parser.add_argument("--max", default=None, help=f"per-run cap (default {DEFAULT_MAX})")
    parser.add_argument("--quiet-minutes", type=int, default=DEFAULT_QUIET_MINUTES)
    parser.add_argument("--max-age-days", type=int, default=DEFAULT_MAX_AGE_DAYS)
    parser.add_argument("--now", default=None, help="ISO time to judge against (default: now)")
    parser.add_argument("--responses", default=None, help="replay recorded GraphQL responses instead of gh")
    parser.add_argument("--github-output", default=None, help="append matrix= and count= to this file")
    args = parser.parse_args(argv)
    if args.repo.count("/") != 1:
        parser.error("--repo must be OWNER/NAME")
    now = parse_time(args.now) if args.now else datetime.now(timezone.utc)
    if now is None:
        parser.error("--now must be an ISO time")
    cap, warning = parse_cap(args.max)
    if warning:
        print(f"::warning::{warning}")
    graphql = replay(Path(args.responses)) if args.responses else gh_graphql
    try:
        decisions, read = select(graphql, args.repo, now, cap, timedelta(minutes=args.quiet_minutes),
                                 timedelta(days=args.max_age_days))
    except SelectionError as error:
        print(f"::error::auto catch-up selection failed: {error}")
        return 2
    print("\n".join(report(decisions, read, now)))
    chosen = matrix(decisions)
    if args.github_output:
        with open(args.github_output, "a", encoding="utf-8") as out:
            out.write(f"matrix={json.dumps(chosen, separators=(',', ':'))}\n")
            out.write(f"count={len(chosen['include'])}\n")
    else:
        print(json.dumps(chosen))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
