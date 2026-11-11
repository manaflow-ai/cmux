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

Only people (author __typename User) with OWNER, MEMBER or COLLABORATOR association count. The newest independent
verdict decides, not the newest SHIP: the newest verdict naming the head must be a SHIP, and no independent verdict
on any head of the pull request (a receipt line, the marker or a change request) may be a newer BLOCK, so a later
BLOCK beats an earlier SHIP wherever it sits. A first line that says it carries (CARRIED: the word in the reviewer
label, "Review (codex; carried): SHIP at <new head>", or "carried from"/"carried over" on the line) is a lane's claim
that an older head's SHIP carries across a base merge, not a verdict: it counts as the head's receipt only when no
independent verdict names the head and the newest independent verdict on the pull request is a SHIP (next-autoland's ship_receipt, cmuxterm-hq#4975). cmux#27189 landed 2026-10-29 on
"Review (Astra; carried): SHIP at 127a023e" while the box review of its pre-merge head had returned BLOCK.
Carried receipts also require both history windows to be below their limits: a full window could hide a verdict naming
the target head, which a carry cannot replace. A risk:high pull request never merges on a carried receipt: it needs an
independent verdict of its own on the exact head (cmux-ad, 2026-10-30, decision 788, as docs/ci/risk-tiers.md says;
a base merge can change what a risk:high patch does even with no conflict). next-autoland applies the same rule
(cmuxterm-hq#5420, exact_receipt).

Before that, as next-autoland's review_state() judges it, the newest review-like word on any head must not say wait:
a change request, "Review (codex): BLOCK", "Verdict: BLOCK", a bare first line "BLOCK at <sha>", "NOT SHIP" or "Do
not merge", or a comment starting "Hold..." refuses even after a SHIP on the head; a carried SHIP is not a review
there either, so it never overtakes one. When the 30-review or 40-comment window comes back full and reaches
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
# Only these exact first-line forms release a prior human hold. A retained automatic receipt on a line that starts
# with Hold remains a hold, rather than being mistaken for an automatic SHIP.
_LIFT = (r"(?:(?:is|was|has been)\s+(?:lifted|released|removed|cleared|withdrawn|over)|lifted|released|removed|"
         r"cleared|withdrawn)")
_LANDING = (r"(?:reviewed and\s+)?(?:landing|merging)(?:\s+now)?(?:\s+under the normal path)?"
            r"(?:\s*\(SHIP at [0-9a-f]{7,40}(?:,\s*compile \d+)?\))?")
HOLD_LIFTED = re.compile(
    r"^\W*hold\s+(?:"
    + _LIFT + r"[*_`]*\s*[.!]?"
    + r"|(?:" + _LIFT + r"|had no (?:stated )?reason)[*_`]*\s*[.!;,\u2014]\s*" + _LANDING + r"\s*[.!]?"
    + r")[*_`]*\s*$", re.I)


def hold_lifted(first: str) -> bool:
    """Whether a Hold first line explicitly releases a prior hold."""
    return bool(HOLD_LIFTED.match(first.strip()))


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
# next-review receipts carry the time their automatic review began. This identifies those receipts without treating
# an ordinary human SHIP that happens to mention next-review as automatic.
AUTO_SINCE = re.compile(r"<!-- next-review since=(\S+) run=([0-9a-f]+) -->")
SHA_TOKEN = re.compile(r"\b[0-9a-f]{7,40}\b")
RECEIPT = re.compile(r"^\W*(?:independent\s+)?review\s*\(([^)\n]*)\)\s*:\W*(ship|block|fix|not ship|hold)(?![\w-])", re.I)
# A carried receipt: a lane's claim that an older head's SHIP carries to a new head, not a review (cmux#27189). It is
# written "Review (<reviewer>; carried): SHIP at <head>" (skills/cmux-review/SKILL.md): the word in the reviewer label.
# "carried from" or "carried over" anywhere on the first line is a carry claim too. Any other "carries" in the verdict's
# own text is not: cmux#27632's "Review (independent review subagent): SHIP at feae7301... the warning carries the
# whole finding" was read as carried and refused (2026-10-29). cmuxterm-hq next_autoland.CARRIED has the same rule (#5214).
CARRIED = re.compile(r"^\W*(?:independent\s+)?review\s*\([^)\n]*\bcarr(?:y|ies|ied|ying)\b[^)\n]*\)\s*:"
                     r"|\bcarried\s+(?:from|over)\b", re.I)
QUERY = ("query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){pullRequest(number:$number){"
         "headRefOid labels(first:100){nodes{name}} "
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


def carried(first: str) -> bool:
    """The first line is a carried SHIP receipt: a lane's claim, not a review (CARRIED)."""
    line = RECEIPT.match(first)
    return bool(line and line.group(2).lower() == "ship" and CARRIED.search(first))


def review_state(pr: dict) -> tuple[str, str]:
    """(state, detail) from the newest review-like word by someone with write access, on any head: "reviewed",
    "blocked" (changes requested, a BLOCK verdict, a review still owed), "held" (a comment starting "Hold..."),
    or "none". A port of next_autoland.py's review_state(), with REVIEW_LINE also matching "Verdict:". A carried
    SHIP is not a review, so it never overtakes a hold or a BLOCK here."""
    # Keep the source body with each entry so an automatic next-review SHIP can be removed when an explicit human
    # hold is the latest non-automatic decision. The body is not part of the returned detail.
    found = []
    for item in (pr.get("reviews") or {}).get("nodes") or []:
        if not trusted(item):
            continue
        login = item["author"].get("login")
        body, at = item.get("body") or "", item.get("submittedAt") or ""
        first = next((line for line in body.splitlines() if line.strip()), "")
        if item.get("state") == "APPROVED":
            found.append((at, "reviewed", f"approved by {login}", body, False))
        elif item.get("state") == "CHANGES_REQUESTED":
            found.append((at, "blocked", f"changes requested by {login}", body, False))
        elif carried(first):
            continue
        elif WAIT_LINE.search(first):
            found.append((at, "blocked", first.strip()[:80], body, False))
        elif REVIEW_LINE.search(first) and review_verdict(body):
            found.append((at, review_verdict(body), first.strip()[:80], body, False))
    for item in (pr.get("comments") or {}).get("nodes") or []:
        if not trusted(item):
            continue
        body = (item.get("body") or "").strip()
        first = next((line for line in body.splitlines() if line.strip()), "")
        if body.startswith("<!--") or carried(first):
            continue  # a tool's marked comment (base-red-watch, previews) or a carried SHIP, not a person's review
        if HOLD_LINE.search(first):
            if not hold_lifted(first):
                found.append((item.get("createdAt") or "", "held", first.strip()[:80], body, True))
            continue
        if WAIT_LINE.search(first):
            found.append((item.get("createdAt") or "", "blocked", first.strip()[:80], body, True))
        elif REVIEW_LINE.search(first) and review_verdict(body):
            found.append((item.get("createdAt") or "", review_verdict(body), first.strip()[:80], body, True))

    # next-review's automatic receipt is intentionally a review for a normal PR, but it must not clear an explicit
    # human hold. A retained automatic marker on a first-line Hold is excluded here and remains an active hold.
    auto_candidates = [
        ((item.get("createdAt") or ""), body) for item in (pr.get("comments") or {}).get("nodes") or []
        if trusted(item)
        and AUTO_SINCE.search(body := (item.get("body") or "").strip())
        and not HOLD_LINE.search(next((line for line in body.splitlines() if line.strip()), ""))
        and review_verdict(body) == "reviewed"
    ]
    # The API has no authored-by-tool bit. For identical automatic-looking comments, retain only the earliest as the
    # automatic receipt; a later human comment quoting that receipt is a distinct decision and remains authoritative.
    automatic = {(min((at for at, candidate in auto_candidates if candidate == body), default=""), body)
                 for _, body in auto_candidates}
    # Only comments can be automatic receipts; a human review may quote the same body and must retain its own
    # decision and provenance.
    decisions = [entry for entry in found if not (entry[4] and (entry[0], entry[3]) in automatic)]
    if decisions:
        held_at, state, _, _, _ = max(decisions, key=lambda f: f[0])
        lifted = any(
            trusted(item)
            and (item.get("createdAt") or "") > held_at
            and hold_lifted(next((line for line in (item.get("body") or "").splitlines() if line.strip()), ""))
            for item in (pr.get("comments") or {}).get("nodes") or []
        )
        if state == "held" and not lifted:
            found = decisions
        elif state == "held":
            # The explicit lift clears the active hold entry before the prior receipt is reconsidered. A later Hold
            # would be the newest non-automatic decision and would make `lifted` false, so filtering all held entries
            # here cannot clear a newly placed hold.
            found = [entry for entry in found if entry[1] != "held"]
    if not found:
        return "none", ""
    _, state, detail, _, _ = max(found, key=lambda f: f[0])
    return state, detail


def names_head(line: str, head: str, full: bool = True) -> bool:
    """The line names the head near its top: by its full 40-character sha, or by a 7-40 character prefix when not
    full (a wait verdict)."""
    return any(token == head if full else head.startswith(token) for token in SHA_TOKEN.findall(line[:600].lower()))


def head_verdicts(pr: dict, head: str | None) -> list[tuple[str, str, str]]:
    """(at, "ship", "block" or "carried", detail) for every trusted verdict that names the head (None: every verdict,
    whatever head it names or none). A SHIP receipt line that says it carries (CARRIED) is "carried"."""
    found = []

    def body_verdict(item: dict, at: str, login: str) -> None:
        body = (item.get("body") or "").strip()
        marker = MARKER.search(body)
        if marker:  # the marker decides its comment, wherever it sits
            if head is None or marker.group(2) == head:
                found.append((at, "ship" if marker.group(1) == "SHIP" else "block", f"autoreview {marker.group(1)} by {login}"))
            return
        first = next((line for line in body.splitlines() if line.strip()), "")
        line = RECEIPT.match(first)
        if line and "self" not in line.group(1).lower() and (
                head is None or names_head(first, head, full=line.group(2).lower() == "ship")):
            kind = "block" if line.group(2).lower() != "ship" else "carried" if CARRIED.search(first) else "ship"
            found.append((at, kind, f"{login}: {first.strip()[:60]}"))

    for item in (pr.get("reviews") or {}).get("nodes") or []:
        if not trusted(item):
            continue
        at, login = item.get("submittedAt") or "", item["author"].get("login") or ""
        if (head is None or ((item.get("commit") or {}).get("oid") or "") == head) \
                and item.get("state") in ("APPROVED", "CHANGES_REQUESTED"):
            found.append((at, "ship" if item["state"] == "APPROVED" else "block", f"{item['state'].lower()} by {login}"))
        body_verdict(item, at, login)
    for item in (pr.get("comments") or {}).get("nodes") or []:
        if trusted(item):
            body_verdict(item, item.get("createdAt") or "", item["author"].get("login") or "")
    return found


def newest_independent(pr: dict) -> tuple[str, str, str] | None:
    """The newest independent verdict on the pull request, on any head (head_verdicts, carried receipts left out)."""
    found = [f for f in head_verdicts(pr, None) if f[1] != "carried"]
    return max(found, key=lambda f: f[0]) if found else None


def high_risk(pr: dict) -> bool:
    """The pull request carries the risk:high tier label (any case)."""
    return any(((node or {}).get("name") or "").lower() == "risk:high"
               for node in (pr.get("labels") or {}).get("nodes") or [])


def ship_receipt(pr: dict, head: str, exact: bool = False) -> tuple[str, str] | None:
    """(since, who) for the head's SHIP, else None. The newest independent verdict naming the head must be a SHIP
    that no independent BLOCK on any head is newer than; with none naming the head, a carried SHIP naming it stands
    only while the newest independent verdict on the pull request is a SHIP. `since` is when the independent SHIP
    that stands behind the receipt was given, so window_cut_off checks nothing newer than it was cut off."""
    found = head_verdicts(pr, head)
    own = [f for f in found if f[1] != "carried"]
    latest = newest_independent(pr)
    if own:
        at, kind, detail = max(own, key=lambda f: f[0])
        blocks = [f for f in head_verdicts(pr, None) if f[1] == "block"]
        if kind != "ship" or any(block[0] > at for block in blocks):
            return None
        return at, detail
    carry = [f for f in found if f[1] == "carried"]
    if exact or not carry or not latest or latest[1] != "ship" or window_cut_off(pr, None):
        return None  # `exact`: a carried SHIP is no receipt at all (risk:high, decision 788)
    return latest[0], max(carry, key=lambda f: f[0])[2]


def receipt(pr: dict, head: str) -> str:
    """Who passed the head, or "" (ship_receipt)."""
    found = ship_receipt(pr, head)
    return found[1] if found else ""


def window_cut_off(pr: dict, since: str | None) -> str:
    """The list ("reviews" or "comments") that came back full and reaches back no further than `since`, so items
    newer than `since` may have been cut off from it; "" when both lists reach past it. With None, any full
    window is ambiguous: a carried receipt needs complete history to prove no verdict names its head."""
    for key, cap, stamp in (("reviews", REVIEWS_WINDOW, "submittedAt"), ("comments", COMMENTS_WINDOW, "createdAt")):
        nodes = [node for node in (pr.get(key) or {}).get("nodes") or [] if node]
        # A pending review has no timestamp; it says nothing about how far back the window reaches.
        stamps = [node[stamp] for node in nodes if node.get(stamp)]
        if len(nodes) >= cap and (since is None or min(stamps, default=since) >= since):
            return key
    return ""


def decide(pr: dict, head: str) -> tuple[str, str]:
    """(who passed the head, "") or ("", why it may not merge), in next-autoland's order."""
    state, detail = review_state(pr)
    if state in ("blocked", "held"):
        return "", f"no SHIP review receipt on {head} can merge while the newest review says wait: {detail}"
    high = high_risk(pr)
    found = ship_receipt(pr, head, exact=high)
    if not found:
        latest = newest_independent(pr)
        newer = (f"; the newest independent verdict is a BLOCK ({latest[2]}), so no older or carried SHIP stands"
                 if latest and latest[1] == "block" else "")
        exact = "; risk:high needs an independent review of this exact head, and no carried SHIP counts" if high else ""
        return "", f"no SHIP review receipt on {head}{newer}{exact}"
    cut = window_cut_off(pr, found[0])
    if cut:
        size = REVIEWS_WINDOW if cut == "reviews" else COMMENTS_WINDOW
        return "", (f"no SHIP review receipt on {head} can be confirmed: {cut} window full (the newest {size} reach "
                    "back only to the SHIP), so the gate can't confirm nothing newer says wait; post the receipt again")
    return found[1], ""


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
                          "or change request on any head wins over an older SHIP, and a base merge (merge-main.sh or "
                          "update-branch) makes a new head that needs its own receipt; a carried SHIP counts only "
                          "while the newest independent verdict is a SHIP")
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
