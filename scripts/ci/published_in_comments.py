#!/usr/bin/env python3
"""Tell each PR which published build it shipped in.

After a build is published, the release workflows run this over the build's
commit span (`--since` the previous published commit, `--head` the published
one). Every non-merge commit whose subject ends in "(#1234)" names a PR, the
same rule `scripts/cmux-next/release-notes.py prs` uses for the release body.

Each PR gets one comment, marked `<!-- cmux-published-in -->`, holding one
line per build: the first build creates it, later ones (a nightly, then a
stable release) edit it in place. A rerun of the same build changes nothing.
Existing comments are read in batched GraphQL, then each write is one REST
call, paced for GitHub's content-creation limit. A failure on one PR is
reported and the rest continue; the script exits 0 so
a publication is never failed by a comment.

    published_in_comments.py --repo manaflow-ai/cmux --since OLD --head NEW \\
        --name "nightly-next 2026101901" --url https://github.com/.../releases/tag/nightly-next
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import time

MARKER = "<!-- cmux-published-in -->"
PR_SUFFIX = re.compile(r"\(#(\d+)\)\s*$")
BOT = "github-actions[bot]"


def pr_numbers(subjects: list[str]) -> list[int]:
    """PR numbers in the order given (newest first), each once."""
    seen: list[int] = []
    for subject in subjects:
        match = PR_SUFFIX.search(subject)
        if match and int(match.group(1)) not in seen:
            seen.append(int(match.group(1)))
    return seen


def build_line(name: str, url: str, sha: str) -> str:
    return f"- [{name}]({url}) (`{sha[:10]}`)"


def updated_body(existing: str | None, line: str) -> str | None:
    """The comment body with this build's line, or None when it is already there."""
    if existing is None:
        return f"{MARKER}\nShipped in:\n{line}\n"
    if line in existing.splitlines():
        return None
    return existing.rstrip("\n") + "\n" + line + "\n"


def git_subjects(since: str, head: str) -> list[str]:
    out = subprocess.run(
        ["git", "log", "--no-merges", "--format=%s", f"{since}..{head}"],
        check=True, capture_output=True, text=True,
    ).stdout
    return [line for line in out.splitlines() if line.strip()]


def gh(*args: str, payload: dict | None = None) -> object:
    result = subprocess.run(
        ["gh", "api", *args, *(["--input", "-"] if payload is not None else [])],
        input=json.dumps(payload) if payload is not None else None,
        check=True, capture_output=True, text=True,
    )
    return json.loads(result.stdout) if result.stdout.strip() else None


def existing_comments(repo: str, numbers: list[int], batch: int = 25) -> dict[int, dict]:
    """The marker comment on each PR, read 25 PRs per GraphQL query from each PR's last 100 comments.

    A stable release spans hundreds of PRs, more than one REST call per PR
    fits in the job token's hourly quota. A marker comment older than the last
    100 comments is missed, and that PR gets a second one.
    """
    owner, name = repo.split("/", 1)
    found: dict[int, dict] = {}
    for start in range(0, len(numbers), batch):
        chunk = numbers[start:start + batch]
        fields = " ".join(
            f"p{n}: issueOrPullRequest(number: {n}) {{ ... on PullRequest {{ comments(last: 100) "
            "{ nodes { databaseId body author { login } } } } }"
            for n in chunk
        )
        query = f'query {{ repository(owner: "{owner}", name: "{name}") {{ {fields} }} }}'
        data = gh("graphql", "-f", f"query={query}")["data"]["repository"]
        for n in chunk:
            for comment in reversed(((data.get(f"p{n}") or {}).get("comments") or {}).get("nodes") or []):
                login = (comment.get("author") or {}).get("login")
                if login in {BOT, "github-actions"} and MARKER in (comment.get("body") or ""):
                    found[n] = {"id": comment["databaseId"], "body": comment["body"]}
                    break
    return found


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--since", required=True, help="the previously published commit")
    parser.add_argument("--head", required=True, help="the commit this build published")
    parser.add_argument("--name", required=True, help="build name shown in the comment, e.g. 'v0.66.0'")
    parser.add_argument("--url", required=True, help="release page for the build")
    parser.add_argument("--max", type=int, default=1000, help="comment on no PR when the span has more than this many")
    parser.add_argument("--pause", type=float, default=1.0, help="seconds between comment writes")
    parser.add_argument("--dry-run", action="store_true", help="print what would be posted")
    args = parser.parse_args()

    try:
        numbers = pr_numbers(git_subjects(args.since, args.head))
    except subprocess.CalledProcessError as error:
        print(f"published-in: cannot read {args.since}..{args.head}: {error.stderr.strip()}", file=sys.stderr)
        return 0
    if len(numbers) > args.max:
        print(f"published-in: {len(numbers)} PRs in the span, over --max {args.max}; commenting on none", file=sys.stderr)
        return 0
    line = build_line(args.name, args.url, args.head)
    try:
        existing = {} if args.dry_run else existing_comments(args.repo, numbers)
    except (subprocess.CalledProcessError, KeyError, TypeError) as error:
        print(f"published-in: cannot read existing comments: {getattr(error, 'stderr', error)}", file=sys.stderr)
        return 0
    posted = skipped = failed = 0
    for number in numbers:
        try:
            comment = existing.get(number)
            body = updated_body(comment["body"] if comment else None, line)
            if body is None:
                skipped += 1
            elif args.dry_run:
                print(f"#{number}: {line}")
                posted += 1
            elif comment:
                gh("-X", "PATCH", f"repos/{args.repo}/issues/comments/{comment['id']}", payload={"body": body})
                posted += 1
            else:
                gh("-X", "POST", f"repos/{args.repo}/issues/{number}/comments", payload={"body": body})
                posted += 1
            if not args.dry_run:
                time.sleep(args.pause)  # GitHub's secondary limit on content writes
        except subprocess.CalledProcessError as error:
            failed += 1
            print(f"published-in: #{number}: {error.stderr.strip()[:300]}", file=sys.stderr)
    print(f"published-in: {args.name}: {len(numbers)} PRs, {posted} written, {skipped} already noted, {failed} failed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
