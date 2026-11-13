#!/usr/bin/env python3
"""receipt_read: every receipt on a pull request, read back past the newest few items. The one shared reader.

    receipt_read.py OWNER/REPO NUMBER [--head SHA] [--since ISO]   the receipts at the head, one JSON line each

A tool asking "is there a receipt on this PR" (a "Review (<reviewer>): SHIP at <sha>" first line, the autoreview
marker, an approval of the commit, a next-review receipt or request note, a tool's own marked comment) read the PR's
`reviews(last: N)` / `comments(last: N)` and searched only that window. On a busy PR (many agents post as one
account) newer chatter pushed the receipt out of the window and the tool answered "none" without knowing it had read
part of the thread (cmuxterm-hq docs/handbook/newest-n-read-as-any.md; cmuxterm-hq#9369 fixed NOW's next-review line
this way first). This reads a PR's reviews and comments as one timeline, newest first:
`timelineItems(itemTypes: [PULL_REQUEST_REVIEW, ISSUE_COMMENT], since: <since>, last: PAGE)` with `headRefOid`, for
any number of PRs in one query, then pages back with `before:` only for a PR whose items so far are not `enough`, at
most MORE_PAGES more pages, one query per page for every PR still looking. A PR left with older items unread says so
(`complete` False): an unread page is "unknown", never "none".

GraphQL only (REST is often the spent pool). `graphql(query, variables) -> data` is the caller's own transport;
gh_graphql() wraps `gh api graphql`. Every read raises ReadError when GitHub's answer is not a full one.

Canonical copy: manaflow-ai/cmux scripts/ci/receipt_read.py. Byte-identical copies, each pinned by the
receipt_read.source beside it (repository, path, commit, SHA-256) and checked by a test there:
manaflow-ai/cmuxterm-hq tools/agent-guards/receipt_read.py and teamleaderleo/leo-workspace tools/receipt_read.py.
Change it in cmux first, then copy it and update both pins.

The detector, lint() below, is shared too: each repo's test runs it over its tools and refuses a newest-N window of
reviews or comments (`reviews(last:`, `comments(last:`, a `timelineItems(...last:` of reviews or comments) in a file
that looks for a receipt, verdict or marker, unless the repo's allowlist names that file and why its read is whole
(it pages back, or reads totalCount and refuses past it, or decides nothing from a missing item).
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from typing import Callable, Iterable

PAGE = 50  # timeline items per PR per page, newest first
MORE_PAGES = 3  # pages read back after the first, only for PRs whose items are not yet enough
TYPES = ("PULL_REQUEST_REVIEW", "ISSUE_COMMENT")
REVIEW_FIELDS = ("id databaseId url state submittedAt lastEditedAt body viewerDidAuthor authorAssociation "
                 "author { __typename login } commit { oid }")
COMMENT_FIELDS = ("id databaseId url createdAt lastEditedAt body viewerDidAuthor authorAssociation "
                  "author { __typename login }")
ITEMS = ("pageInfo { hasPreviousPage startCursor } nodes { __typename "
         f"... on PullRequestReview {{ {REVIEW_FIELDS} }} ... on IssueComment {{ {COMMENT_FIELDS} }} }}")
# The receipt forms every gate reads (cmux scripts/ci/review_receipt.py RECEIPT and MARKER): a first line
# "Review (<reviewer>): SHIP|BLOCK|FIX|NOT SHIP|HOLD ..." and the autoreview marker anywhere in the body.
RECEIPT = re.compile(r"^\W*(?:independent\s+)?review\s*\(([^)\n]*)\)\s*:\W*(ship|block|fix|not ship|hold)(?![\w-])",
                     re.I)
MARKER = re.compile(r"<!-- autoreview verdict=(SHIP|BLOCK) sha=([0-9a-f]{40}) -->")
SHA = re.compile(r"\b[0-9a-f]{7,40}\b")
HEAD_WINDOW = 600  # a receipt names its head near its top (review_receipt.names_head)

GraphQL = Callable[[str, dict], dict]
Enough = Callable[[list, str], bool]


class ReadError(Exception):
    """GitHub's answer was not a full one: no repository, an error, not JSON. Never read as "no receipt"."""


def at(item: dict) -> str:
    """When ITEM was posted: a review's submittedAt, a comment's createdAt ("" for a pending review)."""
    return (item.get("submittedAt") or item.get("createdAt") or "") if isinstance(item, dict) else ""


def first_line(item: dict) -> str:
    body = item.get("body") if isinstance(item, dict) else ""
    return next((line for line in (body or "").splitlines() if line.strip()), "")


def names_head(item: dict, head: str) -> bool:
    """ITEM is a receipt for HEAD: an approval or change request of that commit, the autoreview marker naming it, or
    a "Review (...): <verdict>" first line naming it by its full sha or a 7+ character prefix. Who wrote it, and what
    it decides, is the caller's call."""
    if not isinstance(item, dict) or not head:
        return False
    head = head.lower()
    body = item.get("body") if isinstance(item.get("body"), str) else ""
    if item.get("state") in ("APPROVED", "CHANGES_REQUESTED") and ((item.get("commit") or {}).get("oid") or "") == head:
        return True
    marker = MARKER.search(body)
    if marker:  # the marker decides its item, wherever it sits
        return marker.group(2) == head
    first = first_line(item)
    return bool(RECEIPT.match(first)) and any(head.startswith(sha) for sha in SHA.findall(first[:HEAD_WINDOW].lower()))


def _wanted(prs, since: str | None) -> dict[int, str | None]:
    if isinstance(prs, dict):
        return {int(n): (s or None) for n, s in prs.items()}
    return {int(n): since for n in prs}


def read(graphql: GraphQL, repo: str, prs: Iterable[int] | dict, enough: Enough | None = None, *,
         since: str | None = None, types: Iterable[str] = TYPES, page: int = PAGE, more_pages: int = MORE_PAGES,
         extra: str = "") -> dict[int, dict]:
    """{number: {"number", "head", "items", "complete", "pr"}} for each PR in PRS (numbers, or {number: since}).

    "items" are the PR's reviews and comments (TYPES) posted since its `since` (all of them when None), oldest
    first; "head" its headRefOid; "pr" the fields EXTRA asked for (read with the first page); "complete" whether
    no older item is left unread. The first page of every PR is one query; a PR whose items are not ENOUGH
    (enough(items, head) -> bool; None: never enough, so read to the start or the bound) and has older items is read
    back, one query per page for all such PRs, at most MORE_PAGES pages."""
    wanted = _wanted(prs, since)
    owner, _, name = repo.partition("/")
    if not owner or not name:
        raise ReadError(f"{repo!r} is not OWNER/REPO")
    kinds = ", ".join(types)
    out = {n: {"number": n, "head": "", "items": [], "complete": False, "pr": {}} for n in wanted}
    cursors: dict[int, str] = {}
    pending = sorted(wanted)
    for page_no in range(1 + max(0, more_pages)):
        if not pending:
            break
        variables: dict = {"owner": owner, "name": name}
        params, fields = ["$owner: String!", "$name: String!"], []
        for n in pending:
            args = [f"itemTypes: [{kinds}]", f"last: {int(page)}"]
            if wanted[n]:
                params.append(f"$s{n}: DateTime!")
                variables[f"s{n}"] = wanted[n]
                args.append(f"since: $s{n}")
            if page_no:
                params.append(f"$c{n}: String!")
                variables[f"c{n}"] = cursors[n]
                args.append(f"before: $c{n}")
            first = f"headRefOid {extra} " if page_no == 0 else ""
            fields.append(f"p{n}: pullRequest(number: {n}) {{ {first}timelineItems({', '.join(args)}) {{ {ITEMS} }} }}")
        data = graphql(f"query({', '.join(params)}) {{ repository(owner: $owner, name: $name) {{ {' '.join(fields)} }} }}",
                       variables)
        repo_data = data.get("repository") if isinstance(data, dict) else None
        if not isinstance(repo_data, dict):
            raise ReadError(f"{repo}: no repository in the answer")
        more = []
        for n in pending:
            pr = repo_data.get(f"p{n}")
            if not isinstance(pr, dict):
                raise ReadError(f"{repo}#{n}: no pull request in the answer")
            found = out[n]
            if page_no == 0:
                found["head"] = pr.get("headRefOid") if isinstance(pr.get("headRefOid"), str) else ""
                found["pr"] = {k: v for k, v in pr.items() if k not in ("headRefOid", "timelineItems")}
            items = pr.get("timelineItems")
            if not isinstance(items, dict):
                raise ReadError(f"{repo}#{n}: no timeline in the answer")
            found["items"] = [i for i in (items.get("nodes") or []) if isinstance(i, dict)] + found["items"]
            info = items.get("pageInfo") if isinstance(items.get("pageInfo"), dict) else {}
            older = info.get("hasPreviousPage") is True and isinstance(info.get("startCursor"), str)
            found["complete"] = not older
            if older and not (enough and enough(found["items"], found["head"])):
                cursors[n] = info["startCursor"]
                more.append(n)
        pending = more
    return out


def receipts(graphql: GraphQL, repo: str, number: int, head: str | None = None, since: str | None = None,
             **kwargs) -> tuple[list[dict], bool]:
    """(every receipt at HEAD on the PR posted since SINCE, oldest first; whether the read was complete). HEAD None:
    the PR's current head. Reads back only until one is found (read's bound)."""
    def enough(items, current):
        return any(names_head(i, head or current) for i in items)
    found = read(graphql, repo, [number], enough, since=since, **kwargs)[int(number)]
    return [i for i in found["items"] if names_head(i, head or found["head"])], found["complete"]


def split(found: dict) -> dict:
    """One read() result as the shape a `reviews { nodes } comments { nodes }` query gave: {"headRefOid", <extra>,
    "reviews": {"nodes", "complete"}, "comments": {"nodes", "complete"}}, oldest first."""
    reviews = [i for i in found["items"] if i.get("__typename") == "PullRequestReview"]
    comments = [i for i in found["items"] if i.get("__typename") == "IssueComment"]
    return {**found["pr"], "headRefOid": found["head"],
            "reviews": {"nodes": reviews, "complete": found["complete"]},
            "comments": {"nodes": comments, "complete": found["complete"]}}


def gh_graphql(run: Callable[[list], tuple[int, str, str]] | None = None, timeout: int = 60) -> GraphQL:
    """A graphql(query, variables) over `gh api graphql`. RUN(argv) -> (status, stdout, stderr) replaces the
    subprocess (a caller's own runner or a test's)."""
    def default(argv: list) -> tuple[int, str, str]:
        try:
            done = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
        except subprocess.TimeoutExpired:
            return 1, "", f"gh api graphql took over {timeout}s"
        return done.returncode, done.stdout, done.stderr

    def graphql(query: str, variables: dict) -> dict:
        argv = ["gh", "api", "graphql", "-f", f"query={query}"]
        for key, value in variables.items():
            argv += ["-F" if isinstance(value, int) and not isinstance(value, bool) else "-f", f"{key}={value}"]
        status, out, err = (run or default)(argv)
        if status != 0:
            raise ReadError((err or out or f"gh exited {status}").strip()[:300])
        try:
            payload = json.loads(out)
        except ValueError:
            raise ReadError(f"gh api graphql answered something other than JSON: {out.strip()[:80]}") from None
        if not isinstance(payload, dict) or payload.get("errors"):
            raise ReadError(f"GraphQL errors: {json.dumps((payload or {}).get('errors'))[:300]}")
        return payload.get("data") or {}
    return graphql


# A newest-N window of a PR's reviews or comments, the shape this reader replaces.
WINDOW = re.compile(r"\b(?:reviews|comments)\s*\(\s*last\s*:"
                    r"|\btimelineItems\s*\((?=[^)]*\b(?:ISSUE_COMMENT|PULL_REQUEST_REVIEW)\b)[^)]*\blast\s*:")
# What a receipt, verdict or marker search says somewhere in its file.
LOOKS = re.compile(r"SHIP at|receipt|verdict|<!--", re.I)
SCANNED = (".py", ".sh", ".mjs", ".js", ".ts", ".go")


def windowed_reads(text: str) -> list[int]:
    """The line numbers of TEXT's newest-N review or comment windows, when TEXT looks for a receipt (LOOKS)."""
    if not LOOKS.search(text):
        return []
    return [text.count("\n", 0, m.start()) + 1 for m in WINDOW.finditer(text)]


def lint(root: str, dirs: Iterable[str], allowed: dict[str, str]) -> list[str]:
    """Problems, one line each: a file under ROOT/DIRS (tests and this reader left out) with a newest-N receipt read
    that ALLOWED ({path: why its read is whole}) does not name, and an ALLOWED path that has none any more."""
    found: dict[str, list[int]] = {}
    for top in dirs:
        for folder, subdirs, files in os.walk(os.path.join(root, top)):
            subdirs[:] = sorted(d for d in subdirs if d not in ("node_modules", ".git", "fixtures", "testdata"))
            for name in sorted(files):
                path = os.path.relpath(os.path.join(folder, name), root).replace(os.sep, "/")
                if (not name.endswith(SCANNED) or name.startswith("test_") or name.endswith(("_test.py", "_test.go"))
                        or name == "receipt_read.py"):
                    continue
                try:
                    with open(os.path.join(folder, name), encoding="utf-8") as handle:
                        lines = windowed_reads(handle.read())
                except (OSError, UnicodeDecodeError):
                    continue
                if lines:
                    found[path] = lines
    problems = [f"{path}:{lines[0]}: a newest-N read of reviews or comments in a file that looks for a receipt; "
                "read them through receipt_read.read (it pages back), or add the file to the allowlist with why its "
                "read is whole" for path, lines in sorted(found.items()) if path not in allowed]
    problems += [f"{path}: allowlisted, but has no newest-N receipt read any more; drop it from the allowlist"
                 for path in sorted(allowed) if path not in found]
    return problems


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="receipt_read.py", description=__doc__.split("\n")[0])
    parser.add_argument("repo")
    parser.add_argument("number", type=int)
    parser.add_argument("--head", help="the head to read receipts for (default: the PR's current head)")
    parser.add_argument("--since", help="only items posted since this ISO time")
    args = parser.parse_args(argv)
    try:
        found, complete = receipts(gh_graphql(), args.repo, args.number, args.head, args.since)
    except ReadError as error:
        print(f"receipt_read: {error}", file=sys.stderr)
        return 2
    for item in found:
        print(json.dumps({"at": at(item), "type": item.get("__typename"), "url": item.get("url"),
                          "author": (item.get("author") or {}).get("login"), "first": first_line(item)[:200]}))
    if not found and not complete:
        print(f"receipt_read: no receipt in the newest {PAGE * (1 + MORE_PAGES)} items; older ones unread",
              file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
