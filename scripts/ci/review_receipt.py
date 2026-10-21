#!/usr/bin/env python3
"""The review receipt gh-merge-green requires before it merges a pull request into feat-cmux-next.

    review_receipt.py OWNER/REPO NUMBER SHA [--pr-file FILE]

A head merges only when an independent review passed that exact commit. next-autoland applies the same rule
(leo-workspace tools/next_autoland.py, e2a34f6): it paused 2026-10-21 after cmux#22899 merged before its re-review,
which then found cmux#22988. A receipt, for the exact head, is one of:

- an APPROVED review of that commit (CHANGES_REQUESTED on it is a BLOCK);
- the autoreview marker `<!-- autoreview verdict=SHIP|BLOCK sha=<sha> -->` anywhere in a comment or review body
  (the marker decides its comment);
- otherwise the body's first non-empty line, "Review (<reviewer>): SHIP|BLOCK|FIX|NOT SHIP|HOLD ...", whose
  reviewer is not "self" and which names the head by a 7-40 character prefix, e.g.
  "Review (subagent, correctness first): SHIP at 4b438e85a74f".

Only people (author __typename User) with OWNER, MEMBER or COLLABORATOR association count. The newest verdict
naming the head decides, so a later BLOCK beats an earlier SHIP. Nothing waives a missing receipt.

One GraphQL read. --pr-file reads a recorded response instead (tests). Prints `receipt=<who passed it>`.
Exit 0: receipt; 1: refused (the reason on stderr); 3: GitHub rate-limited the read.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Callable

TRUSTED = {"OWNER", "MEMBER", "COLLABORATOR"}
MARKER = re.compile(r"<!-- autoreview verdict=(SHIP|BLOCK) sha=([0-9a-f]{40}) -->")
SHA_TOKEN = re.compile(r"\b[0-9a-f]{7,40}\b")
RECEIPT = re.compile(r"^\W*(?:independent\s+)?review\s*\(([^)\n]*)\)\s*:\W*(ship|block|fix|not ship|hold)(?![\w-])", re.I)
QUERY = ("query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){pullRequest(number:$number){"
         "headRefOid "
         "reviews(last:100){nodes{state submittedAt body authorAssociation author{__typename login} commit{oid}}} "
         "comments(last:100){nodes{createdAt body authorAssociation author{__typename login}}}}}}")

Runner = Callable[[list[str]], tuple[int, str, str]]


class Refused(Exception):
    pass


class RateLimited(Refused):
    pass


def _load_rate_limit():
    spec = importlib.util.spec_from_file_location("_review_receipt_rate_limit", Path(__file__).with_name("gh_rate_limit.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def names_head(line: str, head: str) -> bool:
    """The line names the head by a 7-40 character prefix near its top."""
    return any(head.startswith(token) for token in SHA_TOKEN.findall(line[:600].lower()))


def head_verdicts(pr: dict, head: str) -> list[tuple[str, str, str]]:
    """(at, "ship" or "block", detail) for every trusted verdict that names the head."""
    found = []

    def body_verdict(item: dict, at: str, login: str) -> None:
        body = (item.get("body") or "").strip()
        marker = MARKER.search(body)
        if marker:  # the marker decides its comment, wherever it sits
            if marker.group(2) == head:
                found.append((at, "ship" if marker.group(1) == "SHIP" else "block", f"autoreview {marker.group(1)} by {login}"))
            return
        first = next((line for line in body.splitlines() if line.strip()), "")
        line = RECEIPT.match(first)
        if line and "self" not in line.group(1).lower() and names_head(first, head):
            found.append((at, "ship" if line.group(2).lower() == "ship" else "block", f"{login}: {first.strip()[:60]}"))

    def trusted(item: dict) -> bool:
        return bool(item) and ((item.get("author") or {}).get("__typename") == "User"
                               and item.get("authorAssociation") in TRUSTED)

    for item in (pr.get("reviews") or {}).get("nodes") or []:
        if not trusted(item):
            continue
        at, login = item.get("submittedAt") or "", item["author"].get("login") or ""
        if ((item.get("commit") or {}).get("oid") or "") == head and item.get("state") in ("APPROVED", "CHANGES_REQUESTED"):
            found.append((at, "ship" if item["state"] == "APPROVED" else "block", f"{item['state'].lower()} by {login}"))
        body_verdict(item, at, login)
    for item in (pr.get("comments") or {}).get("nodes") or []:
        if trusted(item):
            body_verdict(item, item.get("createdAt") or "", item["author"].get("login") or "")
    return found


def receipt(pr: dict, head: str) -> str:
    """Who passed the head, or "": the newest verdict naming it must be a SHIP."""
    found = head_verdicts(pr, head)
    if not found:
        return ""
    _, kind, detail = max(found, key=lambda f: f[0])
    return detail if kind == "ship" else ""


def _gh(args: list[str]) -> tuple[int, str, str]:
    try:
        out = subprocess.run(["gh", *args], capture_output=True, text=True, timeout=60)
    except subprocess.TimeoutExpired:
        return 1, "", "reading the reviews took over 60s"
    return out.returncode, out.stdout, out.stderr


def read_pr(repo: str, number: str, run: Runner = _gh) -> dict:
    owner, _, name = repo.partition("/")
    status, out, err = run(["api", "graphql", "-f", f"query={QUERY}", "-f", f"owner={owner}", "-f", f"name={name}",
                            "-F", f"number={number}"])
    if status != 0:
        if _load_rate_limit().is_rate_limited(err):
            raise RateLimited(f"GitHub rate-limited the review read ({err.strip()[:200]})")
        raise Refused(f"cannot read the reviews of #{number} ({err.strip()[:200]})")
    return unwrap(json.loads(out))


def unwrap(payload: dict) -> dict:
    if payload.get("errors"):
        raise Refused(f"the review read returned errors: {json.dumps(payload['errors'])[:200]}")
    if "data" in payload:
        payload = ((payload.get("data") or {}).get("repository") or {}).get("pullRequest") or {}
    if not payload:
        raise Refused("the review read returned no pull request")
    return payload


def main(argv: list[str] | None = None, run: Runner = _gh) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("repo")
    parser.add_argument("number")
    parser.add_argument("sha")
    parser.add_argument("--pr-file", help="a recorded GraphQL response for the pull request (tests)")
    args = parser.parse_args(argv)
    try:
        if args.pr_file:
            pr = unwrap(json.loads(Path(args.pr_file).read_text()))
        else:
            pr = read_pr(args.repo, args.number, run)
        head = pr.get("headRefOid") or ""
        if head != args.sha:
            raise Refused(f"the head is {head or 'unknown'}, not {args.sha}; review and merge the current head")
        who = receipt(pr, args.sha)
        if not who:
            raise Refused(f"no SHIP review receipt on {args.sha}: after an independent review of this head, comment "
                          f"'Review (subagent, correctness first): SHIP at {args.sha[:12]}' (a newer BLOCK, FIX or "
                          "change request on the head wins over a SHIP)")
    except RateLimited as error:
        print(f"rate-limited: {error}", file=sys.stderr)
        return 3
    except (Refused, ValueError, OSError) as error:
        print(error, file=sys.stderr)
        return 1
    print(f"receipt={who}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
