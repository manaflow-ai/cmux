#!/usr/bin/env python3
"""Pick the open pull requests that PR catch-up merges main into on its own.

pr-catch-up.yml runs this when a push to main passes CI fast guards, so main
just went green at a new commit (--green-sha). A pull request is caught up
automatically when its head is an unprotected branch of this repository (no
branch protection rule, no ruleset), it is not a draft, it has no
`no-auto-catch-up` label, and its head has a check suite and has been quiet
for 30 minutes (an agent still pushing is left alone), and either

- conflict: GitHub reports it CONFLICTING. The catch-up merge resolves the
  generated-file conflicts; any other conflict gets the usual comment naming
  the files, or
- red-on-main: its CI fast guards comment from scripts/ci/guard_attribution.py
  (`<!-- cmux-fast-guards-pr -->` on the first line, written by the Actions
  bot, about the current head) has a failed step headed "(red on main too",
  and the head does not contain the green commit yet. The pull request is red
  only because of main, and main is green now. A guard comment about an older
  head, or a head that already has the green commit, is left alone.

Each head gets few automatic attempts. A comment the workflow posts (a push,
or a conflict a person must resolve) carries
`<!-- cmux-auto-catch-up head=<sha> -->`, and a head that has one is skipped,
so such a conflict is commented once per head. Outcomes that post nothing (a
branch already up to date, a merge error, a push job that refused the merge)
are counted in a ledger instead of a comment: --ledger-in is the previous
run's, --ledger-out this run's, and a head selected MAX_ATTEMPTS_PER_HEAD
times is skipped, so an outcome that repeats does not take a slot on every
green main. A pushed catch-up changes the head, and its push starts the quiet
period again.

Every catch-up push re-runs the pull request's CI, so at most `--max` (the
CMUX_AUTO_CATCH_UP_MAX repository variable, default 15) are picked per run,
the most recently pushed first. Heads not pushed for `--max-age-days` are not
touched; `/catch-up` still works on them.

Batched GraphQL reads, never a per-PR call for the common case: the open pull
requests against main, newest update first, with the ids and authors of their
first and last 100 comments (paging stops at the first one older than the age
limit); the bodies of the Actions bot's comments on the pull requests that
passed the other rules, plus the middle comments of the rare pull request
with more than 200 whose guard comment was not among them; up to three
aliased re-reads, 20 seconds apart, of mergeability GitHub had not computed
yet; and one aliased comparison of each red-on-main head with the green
commit. Stdlib only, so the workflow runs it with `python3 -I`.

Usage:
  auto_catch_up_select.py --repo OWNER/NAME --green-sha SHA [--max 15] [--github-output FILE]
                          [--ledger-in FILE] [--ledger-out FILE]
  auto_catch_up_select.py --repo OWNER/NAME --green-sha SHA --responses replay.json --now 2026-09-25T12:00:00Z
Exit codes: 0 selection printed (possibly empty), 2 GitHub could not answer.
"""

from __future__ import annotations

import argparse
import json
import re
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
RED_ON_MAIN = "(red on main too"
# guard_attribution.render_pr_comment's second line names the commit it judged.
GUARD_FAILED_ON = re.compile(r"^\*\*`[^`\n]+` failed\*\* on `([0-9a-f]{7,40})`")
ATTEMPT_MARKER = "<!-- cmux-auto-catch-up head={head} -->"
# The GraphQL login of the Actions bot, which writes both markers. A person
# pasting a marker into a comment must not steer the selection.
BOT_LOGINS = frozenset({"github-actions"})
DEFAULT_MAX = 15
MAX_CEILING = 50
DEFAULT_QUIET_MINUTES = 30
DEFAULT_MAX_AGE_DAYS = 14
# Selections of one head, whatever came of them, before it is left alone.
MAX_ATTEMPTS_PER_HEAD = 2
LEDGER_VERSION = 1
PAGE_SIZE = 50
BODY_BATCH = 100
COMMENT_PAGE = 100
# Middle comment pages read for one pull request, at most.
MAX_MIDDLE_PAGES = 10
SHA = re.compile(r"[0-9a-f]{40}")

PULL_REQUESTS_QUERY = """
query($owner: String!, $name: String!, $base: String!, $first: Int!, $after: String) {
  repository(owner: $owner, name: $name) {
    pullRequests(states: OPEN, baseRefName: $base, first: $first, after: $after,
                 orderBy: {field: UPDATED_AT, direction: DESC}) {
      pageInfo { hasNextPage endCursor }
      nodes {
        number isDraft isCrossRepository updatedAt headRefName headRefOid mergeable
        headRepository { nameWithOwner }
        headRef { branchProtectionRule { id } rules(first: 1) { totalCount } }
        labels(first: 50) { nodes { name } }
        commits(last: 1) { nodes { commit { oid checkSuites(first: 1) { nodes { createdAt } } } } }
        comments(first: 100) { totalCount pageInfo { hasNextPage endCursor } nodes { id author { login } } }
        lastComments: comments(last: 100) { nodes { id author { login } } }
      }
    }
  }
}
""".strip()

# The comments between the first and the last 100, for the rare pull request
# with more than 200 whose guard comment (created once, edited in place) was
# not among them.
MIDDLE_COMMENTS_QUERY = """
query($owner: String!, $name: String!, $number: Int!, $after: String) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      comments(first: 100, after: $after) { pageInfo { hasNextPage endCursor } nodes { id author { login } } }
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

# Whether a red-on-main head already has the green commit: comparing the head
# (as base) with it, aheadBy counts the green commit's history missing from
# the head. mergeStateStatus is no help: GitHub reports BEHIND only when the
# base requires up-to-date branches, and a red head reads UNSTABLE first.
COMPARE_FIELD = ("pr{number}: pullRequest(number: {number}) {{ number headRefOid"
                 " headRef {{ compare(headRef: $green) {{ aheadBy }} }} }}")
COMPARE_QUERY = """
query($owner: String!, $name: String!, $green: String!) {{
  repository(owner: $owner, name: $name) {{ {fields} }}
}}
""".strip()

COMMENT_BODIES_QUERY = """
query($ids: [ID!]!) {
  nodes(ids: $ids) { ... on IssueComment { id body } }
}
""".strip()

# (query, variables) -> the decoded GraphQL response.
GraphQL = Callable[[str, dict], dict]
# pull request number -> (head sha, automatic selections of that head).
Ledger = dict[int, tuple[str, int]]


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
    """When the head commit was pushed, or None when it has no check suite yet.

    GraphQL no longer reports push dates (Commit.pushedDate is null), so this
    is the creation of the head commit's first check suite, which GitHub makes
    when the commit arrives. The committer date is not a stand-in: a rebase or
    a cherry-pick pushes an old date, which would read as a quiet head.
    """
    nodes = (pr.get("commits") or {}).get("nodes") or [{}]
    commit = (nodes[-1] or {}).get("commit") or {}
    suites = ((commit.get("checkSuites") or {}).get("nodes") or [])
    return parse_time((suites[0] or {}).get("createdAt")) if suites else None


def labels(pr: dict) -> set[str]:
    return {str(node.get("name")) for node in ((pr.get("labels") or {}).get("nodes") or []) if node}


def comment_nodes(pr: dict) -> list[dict]:
    """The comments read for this pull request, first ones first, each once."""
    seen: set[str] = set()
    nodes = []
    for group in (((pr.get("comments") or {}).get("nodes") or []), pr.get("_middleComments") or [],
                  ((pr.get("lastComments") or {}).get("nodes") or [])):
        for node in group:
            if node and node.get("id") and str(node["id"]) not in seen:
                seen.add(str(node["id"]))
                nodes.append(node)
    return nodes


def bot_comment_ids(pr: dict) -> list[str]:
    return [str(node["id"]) for node in comment_nodes(pr)
            if ((node.get("author") or {}).get("login") in BOT_LOGINS)]


def bot_texts(pr: dict, bodies: dict[str, str]) -> list[str]:
    return [bodies[i] for i in bot_comment_ids(pr) if i in bodies]


def guard_red_on_main(text: str, head: str) -> bool:
    """Whether this is a CI fast guards comment about `head` with a step red on main.

    The marker must be the comment's first line, the failed-on commit its
    second line's (so a comment left over from an older head does not count),
    and the red-on-main note part of a step heading.
    """
    lines = text.splitlines()
    if len(lines) < 2 or lines[0].strip() != GUARD_PR_MARKER:
        return False
    failed_on = GUARD_FAILED_ON.match(lines[1])
    if not failed_on or not head.startswith(failed_on.group(1)):
        return False
    return any(line.startswith("### `") and RED_ON_MAIN in line for line in lines[2:])


def has_guard_comment(pr: dict, bodies: dict[str, str]) -> bool:
    return any(text.splitlines()[:1] == [GUARD_PR_MARKER] for text in bot_texts(pr, bodies))


def red_on_main(pr: dict, bodies: dict[str, str]) -> bool:
    head = str(pr.get("headRefOid") or "")
    return any(guard_red_on_main(text, head) for text in bot_texts(pr, bodies))


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
    if not SHA.fullmatch(str(pr.get("headRefOid") or "")):
        return "head sha is not a full commit id"
    head_ref = pr.get("headRef")
    if not isinstance(head_ref, dict):
        return "head branch is gone"
    # The merge job refuses a protected head without a comment, so selecting
    # one would take a slot on every green main.
    if head_ref.get("branchProtectionRule") or ((head_ref.get("rules") or {}).get("totalCount") or 0) != 0:
        return "head branch is protected by a rule or ruleset"
    if OPT_OUT_LABEL in labels(pr):
        return f"labeled {OPT_OUT_LABEL}"
    pushed = last_push(pr)
    if pushed is None:
        return "no check suite on the head yet"
    if now - pushed < quiet:
        return f"head pushed {ago(now, pushed)}, under {int(quiet.total_seconds() // 60)}m"
    if now - pushed > max_age:
        return f"head pushed {ago(now, pushed)}, over {max_age.days}d"
    return None


def classify(pr: dict, bodies: dict[str, str], green: str, ledger: Ledger) -> tuple[str | None, str]:
    """(why to catch up, or None, and the reason line)."""
    head = str(pr.get("headRefOid") or "")
    mergeable = pr.get("mergeable")
    if mergeable == "CONFLICTING":
        why = "conflict"
    elif red_on_main(pr, bodies):
        behind = pr.get("_behindGreen")
        if behind is False:
            return None, f"guards red on main, but the head already has {BASE_BRANCH} at {green[:12]}"
        if behind is None:
            return None, f"guards red on main, but GitHub could not compare the head with {green[:12]}"
        why = "red-on-main"
    elif mergeable == "UNKNOWN":
        return None, "GitHub has not computed mergeability yet and guards are not red on main"
    else:
        return None, "nothing to catch up: no conflict, guards not red on main for this head"
    if any(ATTEMPT_MARKER.format(head=head) in text for text in bot_texts(pr, bodies)):
        return None, f"automatic catch-up already tried head {head[:12]}"
    tried_head, count = ledger.get(int(pr.get("number") or 0), ("", 0))
    if tried_head == head and count >= MAX_ATTEMPTS_PER_HEAD:
        return None, f"automatic catch-up already selected head {head[:12]} {count} times"
    return why, "conflicting with main" if why == "conflict" else "CI fast guards red on main only"


def evaluate(prs: Iterable[dict], bodies: dict[str, str], repo: str, now: datetime, cap: int,
             green: str, ledger: Ledger | None = None,
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
        if skip is None:
            why, reason = classify(pr, bodies, green, ledger or {})
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


def fetch_middle_comments(graphql: GraphQL, repo: str, prs: list[dict], bodies: dict[str, str]) -> None:
    """Page the middle comments of pull requests whose guard comment is not in their first or last 100.

    Stops for each at the guard comment, at the last 100, or after
    MAX_MIDDLE_PAGES pages. Adds the comments to the pull request and their
    bot bodies to `bodies`.
    """
    owner, name = repo.split("/", 1)
    for pr in prs:
        first = pr.get("comments") or {}
        page = first.get("pageInfo") or {}
        last_ids = {str(n.get("id")) for n in ((pr.get("lastComments") or {}).get("nodes") or []) if n}
        middle: list[dict] = []
        after = page.get("endCursor")
        more = bool(page.get("hasNextPage")) and int(first.get("totalCount") or 0) > 2 * COMMENT_PAGE
        for _ in range(MAX_MIDDLE_PAGES):
            if not more or has_guard_comment(pr, bodies):
                break
            response = graphql(MIDDLE_COMMENTS_QUERY, {"owner": owner, "name": name,
                                                       "number": int(pr["number"]), "after": after})
            try:
                connection = response["data"]["repository"]["pullRequest"]["comments"]
                nodes = [n for n in connection["nodes"] if n]
                info = connection["pageInfo"]
            except (KeyError, TypeError) as error:
                raise SelectionError(f"unreadable comments ({error.__class__.__name__})") from error
            fresh = [n for n in nodes if str(n.get("id")) not in last_ids]
            middle += fresh
            pr["_middleComments"] = middle
            ids = [str(n["id"]) for n in fresh if n.get("id") and (n.get("author") or {}).get("login") in BOT_LOGINS]
            if ids:
                bodies.update(fetch_bodies(graphql, ids))
            more = bool(info.get("hasNextPage")) and len(fresh) == len(nodes)
            after = info.get("endCursor")


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


def compare_with_green(graphql: GraphQL, repo: str, prs: list[dict], green: str) -> None:
    """Set `_behindGreen` on each pull request: True when its head lacks the green commit.

    It stays unset (None) when GitHub gave no answer for the head that was judged.
    """
    owner, name = repo.split("/", 1)
    by_number = {int(pr["number"]): pr for pr in prs}
    numbers = sorted(by_number)
    for start in range(0, len(numbers), MERGEABLE_BATCH):
        fields = " ".join(COMPARE_FIELD.format(number=n) for n in numbers[start:start + MERGEABLE_BATCH])
        response = graphql(COMPARE_QUERY.format(fields=fields), {"owner": owner, "name": name, "green": green})
        try:
            answers = (response["data"]["repository"] or {}).values()
        except (KeyError, TypeError, AttributeError) as error:
            raise SelectionError(f"unreadable comparison ({error.__class__.__name__})") from error
        for answer in answers:
            if not answer:
                continue
            pr = by_number.get(int(answer.get("number") or 0))
            ahead = ((answer.get("headRef") or {}).get("compare") or {}).get("aheadBy")
            if pr is not None and answer.get("headRefOid") == pr.get("headRefOid") and isinstance(ahead, int):
                pr["_behindGreen"] = ahead > 0


def select(graphql: GraphQL, repo: str, now: datetime, cap: int, green: str, ledger: Ledger | None = None,
           quiet: timedelta = timedelta(minutes=DEFAULT_QUIET_MINUTES),
           max_age: timedelta = timedelta(days=DEFAULT_MAX_AGE_DAYS),
           sleep: Callable[[float], None] = time.sleep) -> tuple[list[Decision], list[dict]]:
    """(decisions, the pull requests read)."""
    if not SHA.fullmatch(green or ""):
        raise SelectionError("the green commit is not a full commit id")
    prs = fetch_pull_requests(graphql, repo, now, max_age)
    passed = [pr for pr in prs if prefilter(pr, repo, now, quiet, max_age) is None]
    ids = [i for pr in passed for i in bot_comment_ids(pr)]
    bodies = fetch_bodies(graphql, ids) if ids else {}
    # A conflict needs no guard comment.
    fetch_middle_comments(graphql, repo, [pr for pr in passed if pr.get("mergeable") != "CONFLICTING"], bodies)
    # Only pull requests that nothing but mergeability decides.
    undecided = [pr for pr in passed if pr.get("mergeable") == "UNKNOWN" and not red_on_main(pr, bodies)]
    refresh_mergeable(graphql, repo, undecided, sleep)
    red = [pr for pr in passed if pr.get("mergeable") != "CONFLICTING" and red_on_main(pr, bodies)]
    if red:
        compare_with_green(graphql, repo, red, green)
    return evaluate(prs, bodies, repo, now, cap, green, ledger, quiet, max_age), prs


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


def load_ledger(path: Path | None) -> tuple[Ledger, str | None]:
    """The previous run's ledger; a missing or malformed one is empty (every head gets its attempts again)."""
    if path is None or not path.is_file():
        return {}, None
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        if data.get("version") != LEDGER_VERSION:
            return {}, "the ledger has another version; starting a new one"
        ledger: Ledger = {}
        for key, entry in data["attempts"].items():
            head, count = entry["head"], entry["count"]
            if (str(key).isdigit() and isinstance(head, str) and SHA.fullmatch(head)
                    and isinstance(count, int) and 0 < count <= 100):
                ledger[int(key)] = (head, count)
        return ledger, None
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        return {}, "the ledger is unreadable; starting a new one"


def next_ledger(prs: list[dict], decisions: list[Decision], old: Ledger) -> Ledger:
    """This run's ledger: the entries whose head is still a pull request's head, plus this run's selections."""
    current = {int(pr.get("number") or 0): str(pr.get("headRefOid") or "") for pr in prs}
    ledger = {number: (head, count) for number, (head, count) in old.items() if current.get(number) == head}
    for decision in decisions:
        if decision.selected:
            head, count = ledger.get(decision.number, (decision.head, 0))
            ledger[decision.number] = (decision.head, (count if head == decision.head else 0) + 1)
    return ledger


def dump_ledger(ledger: Ledger) -> str:
    attempts = {str(number): {"head": head, "count": count} for number, (head, count) in sorted(ledger.items())}
    return json.dumps({"version": LEDGER_VERSION, "attempts": attempts}, indent=1, sort_keys=True) + "\n"


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
    parser.add_argument("--green-sha", required=True, help="the main commit whose CI fast guards passed")
    parser.add_argument("--max", default=None, help=f"per-run cap (default {DEFAULT_MAX})")
    parser.add_argument("--quiet-minutes", type=int, default=DEFAULT_QUIET_MINUTES)
    parser.add_argument("--max-age-days", type=int, default=DEFAULT_MAX_AGE_DAYS)
    parser.add_argument("--now", default=None, help="ISO time to judge against (default: now)")
    parser.add_argument("--responses", default=None, help="replay recorded GraphQL responses instead of gh")
    parser.add_argument("--ledger-in", default=None, help="the previous run's ledger (missing: empty)")
    parser.add_argument("--ledger-out", default=None, help="write this run's ledger here")
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
    ledger, warning = load_ledger(Path(args.ledger_in) if args.ledger_in else None)
    if warning:
        print(f"::warning::{warning}")
    graphql = replay(Path(args.responses)) if args.responses else gh_graphql
    try:
        decisions, prs = select(graphql, args.repo, now, cap, args.green_sha, ledger,
                                timedelta(minutes=args.quiet_minutes), timedelta(days=args.max_age_days))
    except SelectionError as error:
        print(f"::error::auto catch-up selection failed: {error}")
        return 2
    print("\n".join(report(decisions, len(prs), now)))
    chosen = matrix(decisions)
    if args.ledger_out:
        Path(args.ledger_out).write_text(dump_ledger(next_ledger(prs, decisions, ledger)), encoding="utf-8")
    if args.github_output:
        with open(args.github_output, "a", encoding="utf-8") as out:
            out.write(f"matrix={json.dumps(chosen, separators=(',', ':'))}\n")
            out.write(f"count={len(chosen['include'])}\n")
    else:
        print(json.dumps(chosen))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
