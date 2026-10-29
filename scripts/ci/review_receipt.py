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
  reviewer is not "self" and which names the head: a SHIP by the full 40-character sha, e.g.
  "Review (subagent, correctness first): SHIP at 4b438e85a74f9c2d0e1f3a5b7c9d1e3f5a7b9c1d" (cmux#22762 merged at
  3a97b47e on a receipt naming 0b4c5bf3); a wait verdict by any 7-40 character prefix, since refusing more is safe.

Only people (author __typename User) with OWNER, MEMBER or COLLABORATOR association count. The newest verdict
naming the head decides, so a later BLOCK beats an earlier SHIP. Before that, as next-autoland's review_state()
judges it, the newest review-like word on any head must not say wait: a change request, "Review (codex): BLOCK",
"Verdict: BLOCK", a bare first line "BLOCK at <sha>", "NOT SHIP" or "Do not merge", or a comment starting
"Hold..." refuses even after a SHIP on the head. When the 30-review or 40-comment window comes back full and reaches
back no further than the SHIP, something newer may be cut off, so that refuses too. Comments starting `<!--`
are tools' marked comments, not reviews. Nothing waives a refusal. A base merge (merge-main.sh, update-branch)
makes a new head, which needs its own receipt.

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
# "Review (subagent, correctness first): SHIP", "Self-review", ... One stricter than next-autoland: a first line
# "Verdict: BLOCK" counts too (autoland reads only lines that say "review"; review of cmux#23067).
REVIEW_LINE = re.compile(r"review|\bverdict\b", re.I)
HOLD_LINE = re.compile(r"^\W*hold(?:ing)?\b", re.I)  # "**Holding this PR. ...**"
# A first line that is only a wait verdict, with or without a sha: "BLOCK at <sha>", "**BLOCK at <sha>**", "NOT SHIP",
# "Do not merge". It names no review, so REVIEW_LINE misses it; it still says wait (re-review of cmux#23067).
WAIT_LINE = re.compile(r"^\W*(?:BLOCK|NOT SHIP|HOLD|DO NOT MERGE)\b", re.I)
# The read's windows, next-autoland's: the newest 30 reviews and 40 comments.
REVIEWS_WINDOW, COMMENTS_WINDOW = 30, 40
# A review-like comment counts only with an explicit verdict in a label near its top (next_autoland.py).
LABELLED = r"(?:\breview[^:\n]{0,160}|\bverdict\W{0,4}):\W{0,8}"
SHIPS = re.compile(LABELLED + r"(?:ship|approved?|lgtm|merge|nothing blocking|no (?:defects|findings|blocking issues))\b",
                   re.I)
WAIT = re.compile(LABELLED + r"(?:block(?:ed|ing|s)?|fix|not ship|hold|changes needed)\b|still owed|do not merge|"
                  r"don't merge", re.I)
MARKER = re.compile(r"<!-- autoreview verdict=(SHIP|BLOCK) sha=([0-9a-f]{40}) -->")
SHA_TOKEN = re.compile(r"\b[0-9a-f]{7,40}\b")
RECEIPT = re.compile(r"^\W*(?:independent\s+)?review\s*\(([^)\n]*)\)\s*:\W*(ship|block|fix|not ship|hold)(?![\w-])", re.I)
QUERY = ("query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){pullRequest(number:$number){"
         "headRefOid "
         f"reviews(last:{REVIEWS_WINDOW})"
         "{nodes{state submittedAt body authorAssociation author{__typename login} commit{oid}}} "
         f"comments(last:{COMMENTS_WINDOW})"
         "{nodes{createdAt body authorAssociation author{__typename login}}}}}}")

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


def trusted(item: dict) -> bool:
    return bool(item) and ((item.get("author") or {}).get("__typename") == "User"
                           and item.get("authorAssociation") in TRUSTED)


def review_verdict(body: str) -> str | None:
    """"reviewed", "blocked", or None for a comment with no verdict near its top."""
    marker = MARKER.search(body)
    if marker:
        return "reviewed" if marker.group(1) == "SHIP" else "blocked"
    top = body[:600]
    if WAIT.search(top):
        return "blocked"
    return "reviewed" if SHIPS.search(top) else None


def review_state(pr: dict) -> tuple[str, str]:
    """(state, detail) from the newest review-like word by someone with write access, on any head: "reviewed",
    "blocked" (changes requested, a BLOCK verdict, a review still owed), "held" (a comment starting "Hold..."),
    or "none". A port of next_autoland.py's review_state(), with REVIEW_LINE also matching "Verdict:"."""
    found = []
    for item in (pr.get("reviews") or {}).get("nodes") or []:
        if not trusted(item):
            continue
        login = item["author"].get("login")
        body, at = item.get("body") or "", item.get("submittedAt") or ""
        first = next((line for line in body.splitlines() if line.strip()), "")
        if item.get("state") == "APPROVED":
            found.append((at, "reviewed", f"approved by {login}"))
        elif item.get("state") == "CHANGES_REQUESTED":
            found.append((at, "blocked", f"changes requested by {login}"))
        elif WAIT_LINE.search(first):
            found.append((at, "blocked", first.strip()[:80]))
        elif REVIEW_LINE.search(first) and review_verdict(body):
            found.append((at, review_verdict(body), first.strip()[:80]))
    for item in (pr.get("comments") or {}).get("nodes") or []:
        if not trusted(item):
            continue
        body = (item.get("body") or "").strip()
        first = next((line for line in body.splitlines() if line.strip()), "")
        if body.startswith("<!--"):
            continue  # a tool's marked comment (base-red-watch, previews), not a person's review
        if HOLD_LINE.search(first):
            found.append((item.get("createdAt") or "", "held", first.strip()[:80]))
        elif WAIT_LINE.search(first):
            found.append((item.get("createdAt") or "", "blocked", first.strip()[:80]))
        elif REVIEW_LINE.search(first) and review_verdict(body):
            found.append((item.get("createdAt") or "", review_verdict(body), first.strip()[:80]))
    if not found:
        return "none", ""
    _, state, detail = max(found, key=lambda f: f[0])
    return state, detail


def names_head(line: str, head: str, full: bool = True) -> bool:
    """The line names the head near its top: by its full 40-character sha, or by a 7-40 character prefix when not
    full (a wait verdict)."""
    return any(token == head if full else head.startswith(token) for token in SHA_TOKEN.findall(line[:600].lower()))


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
        if line and "self" not in line.group(1).lower() and names_head(first, head, full=line.group(2).lower() == "ship"):
            found.append((at, "ship" if line.group(2).lower() == "ship" else "block", f"{login}: {first.strip()[:60]}"))

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


def newest_verdict(pr: dict, head: str) -> tuple[str, str, str] | None:
    found = head_verdicts(pr, head)
    return max(found, key=lambda f: f[0]) if found else None


def receipt(pr: dict, head: str) -> str:
    """Who passed the head, or "": the newest verdict naming it must be a SHIP."""
    newest = newest_verdict(pr, head)
    return newest[2] if newest and newest[1] == "ship" else ""


def window_cut_off(pr: dict, since: str) -> str:
    """The list ("reviews" or "comments") that came back full and reaches back no further than `since`, so items
    newer than `since` may have been cut off from it; "" when both lists reach past it."""
    for key, cap, stamp in (("reviews", REVIEWS_WINDOW, "submittedAt"), ("comments", COMMENTS_WINDOW, "createdAt")):
        nodes = [node for node in (pr.get(key) or {}).get("nodes") or [] if node]
        # A pending review has no timestamp; it says nothing about how far back the window reaches.
        stamps = [node[stamp] for node in nodes if node.get(stamp)]
        if len(nodes) >= cap and min(stamps, default=since) >= since:
            return key
    return ""


def decide(pr: dict, head: str) -> tuple[str, str]:
    """(who passed the head, "") or ("", why it may not merge), in next-autoland's order."""
    state, detail = review_state(pr)
    if state in ("blocked", "held"):
        return "", f"no SHIP review receipt on {head} can merge while the newest review says wait: {detail}"
    newest = newest_verdict(pr, head)
    if not newest or newest[1] != "ship":
        return "", f"no SHIP review receipt on {head}"
    cut = window_cut_off(pr, newest[0])
    if cut:
        size = REVIEWS_WINDOW if cut == "reviews" else COMMENTS_WINDOW
        return "", (f"no SHIP review receipt on {head} can be confirmed: {cut} window full (the newest {size} reach "
                    "back only to the SHIP), so the gate can't confirm nothing newer says wait; post the receipt again")
    return newest[2], ""


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
        who, why = decide(pr, args.sha)
        if not who:
            raise Refused(f"{why}: after an independent review of this head, comment "
                          f"'Review (subagent, correctness first): SHIP at {args.sha}'. A newer BLOCK, FIX, hold "
                          "or change request wins over a SHIP, and a base merge (merge-main.sh or update-branch) "
                          "makes a new head that needs its own receipt")
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
