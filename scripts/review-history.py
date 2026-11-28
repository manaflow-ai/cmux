#!/usr/bin/env python3
"""Mine merged cmux PRs for review comments that led to fix commits.

REVIEW.md is drafted from the output. A review comment "led to a fix" when a
non-merge commit landed on the PR after the comment, and its thread was then
marked outdated (the commented lines changed) or resolved. Review bodies and
plain PR comments are left out: they rarely point at one change.

    scripts/review-history.py collect --since 2026-08-01 --cache review-history.jsonl
    scripts/review-history.py cluster --cache review-history.jsonl > clusters.md

collect reads merged PRs through batched GraphQL (one search page of PRs with
their review threads and commits per request; no REST). It appends one JSON
line per PR to the cache and records the search cursor, so a second run
resumes where the first stopped. It stops before the GraphQL quota drops below
--floor; the quota is shared with every session on the account, so check
`glaeda-gh budget` first and keep the floor high.

cluster is offline. It drops reviewer boilerplate, assigns each addressed
comment to the first topic whose pattern matches (TOPICS below, seeded from
.github/review-bot-rules/), and prints counts, reviewers and a few example
quotes with PR links per topic. Unmatched comments are summarized by their
most common terms so new topics can be added.
"""
from __future__ import annotations

import argparse
import collections
import json
import re
import subprocess
import sys
from datetime import date, timedelta
from pathlib import Path

REPO = "manaflow-ai/cmux"
PAGE = 20

QUERY = """
query($q: String!, $after: String, $page: Int!) {
  rateLimit { cost remaining resetAt }
  search(query: $q, type: ISSUE, first: $page, after: $after) {
    issueCount
    pageInfo { hasNextPage endCursor }
    nodes {
      ... on PullRequest {
        number title mergedAt
        author { login }
        commits(last: 40) { nodes { commit { oid committedDate messageHeadline parents { totalCount } } } }
        reviewThreads(first: 30) {
          nodes {
            isResolved isOutdated path
            comments(first: 1) { nodes { author { login } body createdAt url } }
          }
        }
      }
    }
  }
}
"""


def graphql(query: str, variables: dict) -> dict:
    args = ["gh", "api", "graphql", "-f", f"query={query}"]
    for key, value in variables.items():
        if value is None:
            continue
        args += ["-F" if isinstance(value, int) else "-f", f"{key}={value}"]
    result = subprocess.run(args, capture_output=True, text=True)
    if result.returncode != 0:  # gh exits nonzero on GraphQL errors; the cursor resumes the run
        raise SystemExit(f"GraphQL request failed: {result.stderr.strip()[:500]}")
    return json.loads(result.stdout)["data"]


def addressed_comments(pr: dict) -> list[dict]:
    commits = [
        node["commit"]["committedDate"]
        for node in pr["commits"]["nodes"]
        if node["commit"]["parents"]["totalCount"] < 2
    ]
    author = (pr.get("author") or {}).get("login")
    found = []
    for thread in pr["reviewThreads"]["nodes"]:
        if not (thread["isOutdated"] or thread["isResolved"]):
            continue
        comments = thread["comments"]["nodes"]
        if not comments:
            continue
        first = comments[0]
        reviewer = (first.get("author") or {}).get("login") or "ghost"
        if reviewer == author:
            continue
        if not any(date > first["createdAt"] for date in commits):
            continue
        found.append({
            "pr": pr["number"],
            "title": pr["title"],
            "reviewer": reviewer,
            "path": thread["path"],
            "outdated": thread["isOutdated"],
            "url": first["url"],
            "body": first["body"][:4000],
        })
    return found


def collect(args: argparse.Namespace) -> int:
    cache = Path(args.cache)
    cursor_file = cache.with_suffix(cache.suffix + ".cursor")
    state = cursor_file.read_text().split() if cursor_file.exists() and not args.restart else []
    if state and state[0] != args.since:
        print(f"resuming the saved cursor at {state[0]}, not --since {args.since}; pass --restart to start over", file=sys.stderr)
    if args.restart:
        cache.write_text("")
    start = date.fromisoformat(state[0]) if state else date.fromisoformat(args.since)
    after = state[1] if len(state) > 1 else None
    until = date.fromisoformat(args.until) if args.until else date.today()
    pages = 0
    with cache.open("a") as out:
        while pages < args.max_pages:
            if start > until:
                print("done: every window read", file=sys.stderr)
                cursor_file.unlink(missing_ok=True)
                return 0
            end = min(start + timedelta(days=args.window_days - 1), until)
            q = f"repo:{args.repo} is:pr is:merged merged:{start}..{end}"
            data = graphql(QUERY, {"q": q, "after": after, "page": args.page})
            rate = data["rateLimit"]
            search = data["search"]
            for pr in search["nodes"]:
                if not pr:
                    continue
                out.write(json.dumps({"number": pr["number"], "mergedAt": pr["mergedAt"], "comments": addressed_comments(pr)}) + "\n")
            out.flush()
            pages += 1
            print(f"{start}..{end} page {pages}: {len(search['nodes'])} PRs of {search['issueCount']}, cost {rate['cost']}, {rate['remaining']} GraphQL left", file=sys.stderr)
            if search["issueCount"] > 1000 and after is None:
                print(f"warning: {search['issueCount']} PRs in {start}..{end}; search returns 1000, so lower --window-days", file=sys.stderr)
            if search["pageInfo"]["hasNextPage"]:
                after = search["pageInfo"]["endCursor"]
            else:
                start, after = end + timedelta(days=1), None
            cursor_file.write_text(f"{start} {after or ''}".strip())
            if rate["remaining"] - rate["cost"] < args.floor:
                print(f"stopping: GraphQL quota near the floor ({rate['remaining']} left, resets {rate['resetAt']}); rerun to resume", file=sys.stderr)
                return 0
    return 0


TEST_TOPIC = "Tests that don't test the change"
TEST_PATH = re.compile(r"(^|/)(tests?|tests_v2|\w*Tests)/|\.test\.|_test\.|Tests?\.swift$")
TEST_TEXT = re.compile(r"\bassert|vacuous|fixture|never (verifies|exercises)|does not exercise|regression (guard|test)", re.IGNORECASE)

# Topic patterns, first match wins; a comment on a test file, or about
# assertions, is a test finding first. Seeded from .github/review-bot-rules/ and
# tuned on the collected comments; extend when "unmatched" shows a new theme.
TOPICS: list[tuple[str, str]] = [
    ("Localization and user-facing text", r"locali[sz]|xcstrings|translat|locale|string\(localized|hard-?coded (string|text)|\b(arabic|japanese|zh-hans|zh-hant|spanish|italian|nb)\b"),
    ("Security: authorization, secrets and untrusted input", r"\bcwe-|injection|untrusted|sanitiz|secret|credential|authoriz|authenticat|allowlist|keychain|entitlement|path traversal|symlink|\$\{\{|privilege|fail(s)? open"),
    ("Fixed sleeps, timeouts and polling", r"sleep|polling|\bpoll|fixed (wait|delay|timeout|retry)|timeout|busy[- ]wait|yields|readiness"),
    ("Cancellation, stale results and races", r"cancel|stale|race|superseded|in-flight|in flight|out of order|generation|fence|outlive|reentran|concurrent|serializ"),
    ("Main thread and actor isolation", r"main ?thread|mainactor|@mainactor|\bactor\b|isolation|sendable|assumeisolated|dispatchqueue|thread[- ]safe|\block\b|mutex|deadlock"),
    ("Cleanup, leaks and lifetimes", r"leak|retain cycle|\[weak|\bweak\b|deinit|clean ?up|teardown|orphan|temp(orary)? (file|dir)|never (cleared|removed)|dangling"),
    ("Errors swallowed or reported as success", r"silent|swallow|ignor(e|es|ed) (the )?(error|failure)|reports? success|exit (code|status)|non-?zero|fail(s)? closed|try\?|unhandled|returns? (nil|success) (on|when)"),
    ("Edge cases: empty, nil, invalid and bounds", r"empty|\bnil\b|\bnull\b|missing|invalid|malformed|whitespace|out of (range|bounds)|off[- ]by[- ]one|overflow|unbounded|\blimit\b|duplicate"),
    ("CI, workflows and scripts", r"workflow|github actions|\bci\b|runner|actionlint|\byaml\b|pull_request|set -e|pipefail|\bjq\b|quot(e|ing)|xcode pin|lockfile|derived ?data"),
    ("State ownership and source of truth", r"source of truth|owner|single source|derived|cache[ds]? (state|value)|out of sync|authoritative|binding|@state|@observable"),
    ("Performance and hot paths", r"performance|hot path|allocat|o\(n|quadratic|expensive|every (frame|keystroke|tick|row|refresh)|rescan|redundant (work|call)|i/o on"),
    ("Docs and comments out of date", r"comment|docstring|doc says|documentation|readme|misleading|prose|still (says|lists)"),
    ("Naming, dead code and simplification", r"unused|dead|naming|rename|simplif|redundant|unnecessary|extract|all-static|namespace"),
]

BOILERPLATE = [
    re.compile(r"<!--.*?-->", re.DOTALL),
    re.compile(r"<details>.*?</details>", re.DOTALL),
    re.compile(r"```.*?```", re.DOTALL),
    re.compile(r"\[!\[.*?\]\(.*?\)\]\(.*?\)"),
    re.compile(r"<a [^>]*>\s*<img [^>]*>\s*</a>"),
    re.compile(r"<sub>.*?</sub>", re.DOTALL),
    re.compile(r"<img [^>]*>"),
    re.compile(r"_?(⚠️|🛠️|💡|🧹|🔒) [^\n]*_?"),
]
STOP = set("""the a an and or of to in is it that this for on be with as are by not if when from at was can
should would will we you your its into but so than then there their them they which what also only one all any
use used using have has had do does done there's it's don't doesn't i me my our here now just more most same
other each some no yes may might could been being make makes made like get gets see e.g i.e via while because""".split())


RABBIT_HEADER = re.compile(r"^\s*[_*]{1,2}([^_*\n]+?)[_*]{1,2}\s*\|\s*[_*]{1,2}([^_*\n]+?)[_*]{1,2}[^\n]*\n")
CURSOR_TITLE = re.compile(r"^\s*(?:###\s*)?(.{0,120}?)\s*(High|Medium|Low) Severity\b")
PRIORITY = re.compile(r"^\s*(P[0-3])\b:?")
BOLD_TITLE = re.compile(r"\*\*([^*\n]{10,}?)\*\*")


def summarize(body: str) -> tuple[str, str, str]:
    """Return (reviewer category, severity, text) for a review comment.

    The reviewers write in their own shapes: CodeRabbit opens with
    `**category** | **severity** | ...` (or the italic form), collapsed
    analysis, then a bold one-line finding; Cursor Bugbot writes
    `### Title  High Severity  explanation`; Greptile and cubic lead with a
    P0-P3 badge or prefix. The finding line plus a little context is the text
    clustered and quoted.
    """
    category = severity = ""
    match = RABBIT_HEADER.match(body)
    if match:
        category = re.sub(r"^[^\w]+", "", match.group(1)).strip()
        severity = re.sub(r"^[^\w]+", "", match.group(2)).strip()
        body = body[match.end():]
    text = clean(body)
    cursor = CURSOR_TITLE.match(text)
    if cursor:
        severity = severity or cursor.group(2)
        title = cursor.group(1).strip()
        rest = text[cursor.end():].strip()
        text = (title + ". " if title else "") + rest[:400]
    priority = PRIORITY.match(text)
    if priority:
        severity = severity or priority.group(1)
        text = text[priority.end():].strip()
    title = BOLD_TITLE.search(text)
    if title and title.start() < 40:
        rest = text[title.end():].strip()
        text = title.group(1).strip() + " " + rest[:400]
    return category, severity, text


def clean(body: str) -> str:
    previous = None
    while previous != body:  # <details> nest; strip innermost first
        previous = body
        body = re.sub(r"<details>(?:(?!<details>).)*?</details>", " ", body, flags=re.DOTALL)
    for pattern in BOILERPLATE:
        body = pattern.sub(" ", body)
    return re.sub(r"\s+", " ", body).strip()


def first_sentence(text: str, limit: int = 220) -> str:
    text = re.sub(r"^\*\*|\*\*", "", text)
    match = re.match(r"(.{20,}?[.!?])(\s|$)", text)
    sentence = match.group(1) if match else text
    return sentence if len(sentence) <= limit else sentence[: limit - 1] + "…"


def cluster(args: argparse.Namespace) -> int:
    # The last line per PR wins: a rerun without --restart, or a crash between
    # a page's write and its cursor, appends PRs that are already cached.
    rows: dict[int, dict] = {}
    with open(args.cache) as handle:
        for line in handle:
            if line.strip():
                row = json.loads(line)
                rows[row["number"]] = row
    prs = len(rows)
    comments = [comment for row in rows.values() for comment in row["comments"]]
    compiled = [(name, re.compile(pattern, re.IGNORECASE)) for name, pattern in TOPICS]
    buckets: dict[str, list[dict]] = collections.defaultdict(list)
    for comment in comments:
        category, severity, text = summarize(comment["body"])
        if len(text) < 20:
            continue
        comment.update(text=text, category=category, severity=severity)
        if TEST_PATH.search(comment.get("path") or "") or TEST_TEXT.search(text):
            topic = TEST_TOPIC
        else:
            topic = next((name for name, pattern in compiled if pattern.search(text)), "Unmatched")
        buckets[topic].append(comment)
    addressed_prs = len({c["pr"] for c in comments})
    reviewers = collections.Counter(c["reviewer"] for c in comments).most_common(8)
    print(f"# Review comments that led to fix commits\n")
    print(f"{prs} merged PRs read; {len(comments)} addressed review comments on {addressed_prs} of them.\n")
    print("By reviewer: " + ", ".join(f"{who} {n}" for who, n in reviewers) + "\n")
    order = sorted(buckets, key=lambda name: (name == "Unmatched", -len(buckets[name])))
    for name in order:
        items = buckets[name]
        reviewers = collections.Counter(c["reviewer"] for c in items).most_common(4)
        paths = collections.Counter(c["path"].split("/")[0] for c in items if c.get("path")).most_common(4)
        print(f"## {name} ({len(items)})\n")
        print("Reviewers: " + ", ".join(f"{who} {n}" for who, n in reviewers))
        print("Top dirs: " + ", ".join(f"`{d}` {n}" for d, n in paths))
        severities = collections.Counter(c["severity"] for c in items if c["severity"]).most_common()
        if severities:
            print("Severity as the reviewer labelled it: " + ", ".join(f"{s} {n}" for s, n in severities))
        print()
        if name == "Unmatched":
            words = collections.Counter(
                word for c in items for word in re.findall(r"[a-z][a-z_]{3,}", c["text"].lower()) if word not in STOP
            ).most_common(30)
            print("Common terms: " + ", ".join(f"{w} {n}" for w, n in words) + "\n")
        seen = set()
        for comment in items:
            if len(seen) >= args.examples:
                break
            if comment["pr"] in seen:
                continue
            seen.add(comment["pr"])
            print(f"- [#{comment['pr']}]({comment['url']}) ({comment['reviewer']}, `{comment['path']}`): {first_sentence(comment['text'])}")
        print()
        categories = collections.Counter(c["category"] for c in items if c["category"]).most_common(5)
        if categories:
            print("CodeRabbit categories here: " + ", ".join(f"{s} {n}" for s, n in categories))
        print()
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    c = sub.add_parser("collect", help="read merged PRs into the cache through batched GraphQL")
    c.add_argument("--repo", default=REPO)
    c.add_argument("--since", required=True, help="merged on or after this date (YYYY-MM-DD)")
    c.add_argument("--until", help="merged on or before this date (default: today)")
    c.add_argument("--window-days", type=int, default=2, help="days per search; GitHub search stops at 1000 results")
    c.add_argument("--cache", required=True)
    c.add_argument("--page", type=int, default=PAGE, help="PRs per GraphQL request")
    c.add_argument("--max-pages", type=int, default=50)
    c.add_argument("--floor", type=int, default=1500, help="stop before GraphQL quota drops below this")
    c.add_argument("--restart", action="store_true", help="empty the cache and ignore the saved cursor")
    k = sub.add_parser("cluster", help="group cached comments by topic, as Markdown")
    k.add_argument("--cache", required=True)
    k.add_argument("--examples", type=int, default=6)
    args = parser.parse_args()
    return collect(args) if args.command == "collect" else cluster(args)


if __name__ == "__main__":
    sys.exit(main())
