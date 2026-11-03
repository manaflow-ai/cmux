#!/usr/bin/env python3
"""Tell each PR which published build it shipped in.

After a build is published, the release workflows run this over the build's
commit span (`--since` the previous published commit, `--head` the published
one). Every first-parent, non-merge commit whose subject ends in "(#1234)"
names a PR. First-parent keeps out history merged in from elsewhere: a
merged-in repository's own "(#5)" subjects, or main's PRs arriving on
feat-cmux-next through a sync merge.

Publication lines live in the shared PR status comment, in its `published`
section. Legacy standalone `<!-- cmux-published-in -->` comments are folded
into that section without losing their release links. A rerun of the same
build changes nothing. Existing comments are read in batched GraphQL, and
status writes preserve other sections and settle concurrent writers. Writes
are paced under GitHub's secondary limit on content writes (about 500 an
hour). The first rate-limit refusal stops the run and says how many PRs are
left; a rerun skips the ones already noted. Any other failure on one PR is
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
from pathlib import Path

# This script is also loaded by path in tests.
sys.path.insert(0, str(Path(__file__).resolve().parent))
import pr_status  # noqa: E402

MARKER = "<!-- cmux-published-in -->"
PR_SUFFIX = re.compile(r"\(#(\d+)\)\s*$")
SECTION = "published"


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
    """Legacy standalone-comment update, retained as the lossless overflow fallback."""
    if existing is None:
        return f"{MARKER}\nShipped in:\n{line}\n"
    if line in existing.splitlines():
        return None
    return existing.rstrip("\n") + "\n" + line + "\n"


def publication_text(comments: list[dict], line: str, previous: str = "") -> str:
    """Keep every published build, including old standalone comments, once."""
    bodies = [previous] + [pr_status.parse(c["body"]).get(SECTION, "")
              for c in pr_status.bot_comments(comments, pr_status.MARKER)]
    bodies += [c["body"] for c in pr_status.bot_comments(comments, MARKER)]
    lines = list(dict.fromkeys(item for body in bodies for item in body.splitlines()
                              if item.startswith("- ")))
    if line not in lines:
        lines.append(line)
    return "Shipped in:\n" + "\n".join(lines)


def has_publication_line(comments: list[dict], line: str) -> bool:
    """Whether a publication line survived in status or a legacy comment."""
    sections = [pr_status.parse(c["body"]).get(SECTION, "")
                for c in pr_status.bot_comments(comments, pr_status.MARKER)]
    sections += [c["body"] for c in pr_status.bot_comments(comments, MARKER)]
    return any(line in body.splitlines() for body in sections)


def status_api(method: str, path: str, payload: dict | None = None) -> object:
    return gh("-X", method, path.lstrip("/"), payload=payload)


def publish(repo: str, number: int, line: str, comments: list[dict], pause: float) -> str:
    """Write the shared section, retaining a standalone comment if it cannot fit losslessly."""
    # The initial GraphQL batch avoids one discovery request per PR, but it
    # may be stale by the time this PR is written. Re-read immediately before
    # the first plan so another status writer's section is never overwritten.
    snapshot = pr_status.list_comments(status_api, repo, number)
    did = "unchanged"
    text = ""
    for attempt in range(pr_status.ATTEMPTS):
        if attempt:
            snapshot = pr_status.list_comments(status_api, repo, number)
        text = publication_text(snapshot, line, text)
        writes = pr_status.plan(repo, number, snapshot, SECTION, text, legacy=MARKER)
        if writes:
            # pr_status.render trims the longest section when a comment exceeds
            # GitHub's cap. Never delete a legacy comment if that would drop a
            # publication line; update that comment separately below instead.
            publication_lines = [item for item in text.splitlines() if item.startswith("- ")]
            content_writes = [(method, payload) for method, _, payload in writes
                              if method in {"POST", "PATCH"} and payload]
            if content_writes:
                rendered = content_writes[0][1].get("body", "")
                old_status = pr_status.bot_comments(snapshot, pr_status.MARKER)
                old_sections: dict[str, str] = {}
                for status_comment in reversed(old_status):
                    old_sections.update(pr_status.parse(status_comment["body"]))
                rendered_sections = pr_status.parse(rendered)
                publication_lost = any(item not in rendered for item in publication_lines)
                other_section_lost = any(rendered_sections.get(key) != value
                                         for key, value in old_sections.items()
                                         if key != SECTION)
                if publication_lost or other_section_lost:
                    fallback = legacy_publish(repo, number, line, snapshot, pause, text)
                    return did if fallback == "unchanged" else fallback
            # plan() puts the shared edit before legacy deletions. Finish the
            # migration in this run; a future release would need another edit
            # and could otherwise leave the old comment behind indefinitely.
            # Pace each deletion too, so cleanup stays under the write limit.
            for method, path, payload in writes:
                if method == "DELETE":
                    # A different publisher may append to a legacy comment
                    # during the paced pause. Merge its history before cleanup,
                    # or keep the legacy fallback if the new history cannot fit.
                    fresh = pr_status.list_comments(status_api, repo, number)
                    latest = publication_text(fresh, line, text)
                    pending = pr_status.plan(repo, number, fresh, SECTION, latest, legacy=MARKER)
                    # Consolidating duplicate status comments plans a PATCH
                    # even when the merged body is already present. Only a
                    # changed body must be persisted before deleting a copy.
                    bodies = {str(c["id"]): c.get("body", "") for c in fresh}
                    changed = any(m != "DELETE" and (b or {}).get("body") != bodies.get(p.rsplit("/", 1)[-1])
                                  for m, p, b in pending)
                    if latest != text or changed:
                        text = latest
                        break
                    if not any(m == "DELETE" and p == path for m, p, _ in pending):
                        continue
                status_api(method, path, payload)
                time.sleep(pause)
                did = "written"
        else:
            # A status comment can already be at GitHub's size cap. In that
            # case render() may trim the newly appended line and produce the
            # exact body that is already present, so plan() quite correctly
            # reports no write even though this publication was lost. Keep a
            # standalone legacy comment as the lossless overflow path.
            if not has_publication_line(snapshot, line):
                fallback = legacy_publish(repo, number, line, snapshot, pause, text)
                return did if fallback == "unchanged" else fallback
            return did
    return did + " (unconfirmed: another writer kept replacing the comment)"


def legacy_publish(repo: str, number: int, line: str, comments: list[dict], pause: float,
                   history: str = "") -> str:
    """Lossless fallback when the shared status comment has no room for all builds."""
    # The caller's snapshot may be stale while another publication writer is
    # editing the legacy comment. Re-read immediately before merging so this
    # patch includes any release links that landed since the status plan.
    comments = pr_status.list_comments(status_api, repo, number)
    lines = [item for item in history.splitlines() if item.startswith("- ")]
    if line not in lines:
        lines.append(line)
    old = pr_status.bot_comments(comments, MARKER)
    remaining = list(dict.fromkeys(lines))
    wrote = False
    for comment in old:
        body = comment["body"]
        changed = False
        for item in remaining[:]:
            updated = updated_body(body, item)
            if updated is None:
                remaining.remove(item)
            elif len(updated) <= pr_status.LIMIT:
                body = updated
                remaining.remove(item)
                changed = True
            else:
                break
        if changed:
            status_api("PATCH", f"repos/{repo}/issues/comments/{comment['id']}", {"body": body})
            time.sleep(pause)
            wrote = True

    # A legacy comment can be full, or several old comments can collectively
    # hold more history than one GitHub comment permits. Split only the missing
    # lines into bounded new comments rather than merging existing comments.
    while remaining:
        body = f"{MARKER}\nShipped in:\n"
        added = []
        for item in remaining:
            candidate = body + item + "\n"
            if len(candidate) > pr_status.LIMIT and added:
                break
            body = candidate
            added.append(item)
        if not added:  # publication lines are short, but avoid a stuck loop.
            added.append(remaining.pop(0))
            body += added[0] + "\n"
        else:
            del remaining[:len(added)]
        status_api("POST", f"repos/{repo}/issues/{number}/comments", {"body": body})
        time.sleep(pause)
        wrote = True
    return "written" if wrote else "unchanged"


def git_subjects(since: str, head: str) -> list[str]:
    out = subprocess.run(
        ["git", "log", "--first-parent", "--no-merges", "--format=%s", f"{since}..{head}"],
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


def comments_query(owner: str, name: str, numbers: list[int]) -> str:
    fields = " ".join(
        f"p{n}: issueOrPullRequest(number: {n}) {{ ... on PullRequest {{ comments(last: 100) "
        "{ pageInfo { hasPreviousPage } nodes { databaseId body author { login } } } } }"
        for n in numbers
    )
    return f'query {{ repository(owner: "{owner}", name: "{name}") {{ {fields} }} }}'


def normalize_comments(node: dict | None) -> list[dict]:
    """Match REST's comment shape and bot logins for the shared status writer."""
    result = []
    for comment in ((node or {}).get("comments") or {}).get("nodes") or []:
        login = (comment.get("author") or {}).get("login") or ""
        if login in {"github-actions", "cmux-bot"}:
            login += "[bot]"
        result.append({"id": comment["databaseId"], "body": comment.get("body") or "",
                       "user": {"login": login}})
    return result


def existing_comments(repo: str, numbers: list[int], batch: int = 25) -> tuple[dict[int, list[dict]], set[int]]:
    """Comments on each PR, and the numbers that could not be read.

    Reads 25 PRs per GraphQL query from each PR's last 100 comments: a stable
    release spans hundreds of PRs, more than one REST call per PR fits in the
    job token's hourly quota. A longer timeline uses a paginated REST read
    so an older status comment is never missed. A batch that fails (a
    number that was deleted or transferred) is retried one PR at a time, and
    the PRs that still fail are skipped.
    """
    owner, name = repo.split("/", 1)
    found: dict[int, list[dict]] = {}
    unreadable: set[int] = set()
    for start in range(0, len(numbers), batch):
        chunk = numbers[start:start + batch]
        try:
            data = gh("graphql", "-f", f"query={comments_query(owner, name, chunk)}")["data"]["repository"]
        except (subprocess.CalledProcessError, KeyError, TypeError) as error:
            if isinstance(error, subprocess.CalledProcessError) and rate_limited(error):
                raise
            data = {}
            for n in chunk:
                try:
                    data.update(gh("graphql", "-f", f"query={comments_query(owner, name, [n])}")["data"]["repository"])
                except (subprocess.CalledProcessError, KeyError, TypeError) as retry_error:
                    if isinstance(retry_error, subprocess.CalledProcessError) and rate_limited(retry_error):
                        raise
                    unreadable.add(n)
        for n in chunk:
            node = data.get(f"p{n}")
            if n in unreadable:
                continue
            try:
                if ((node or {}).get("comments") or {}).get("pageInfo", {}).get("hasPreviousPage"):
                    found[n] = pr_status.list_comments(status_api, repo, n)
                else:
                    found[n] = normalize_comments(node)
            except subprocess.CalledProcessError as error:
                if rate_limited(error):
                    raise
                unreadable.add(n)
    return found, unreadable


def rate_limited(error: subprocess.CalledProcessError) -> bool:
    return bool(re.search(r"rate limit|HTTP 429|abuse", error.stderr or "", re.IGNORECASE))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--since", required=True, help="the previously published commit")
    parser.add_argument("--head", required=True, help="the commit this build published")
    parser.add_argument("--name", required=True, help="build name shown in the comment, e.g. 'v0.66.0'")
    parser.add_argument("--url", required=True, help="release page for the build")
    parser.add_argument("--max", type=int, default=1000, help="comment on no PR when the span has more than this many")
    parser.add_argument("--pause", type=float, default=7.5, help="seconds between comment writes (500 an hour)")
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
    if args.dry_run:
        existing, unreadable = {}, set()
    else:
        try:
            existing, unreadable = existing_comments(args.repo, numbers)
        except subprocess.CalledProcessError as error:
            if rate_limited(error):
                print(f"published-in: rate limited while reading comments; {len(numbers)} PRs left, rerun to finish", file=sys.stderr)
                return 0
            raise
    numbers = [n for n in numbers if n not in unreadable]
    posted = skipped = failed = 0
    for index, number in enumerate(numbers):
        try:
            if args.dry_run:
                print(f"#{number}: {line}")
                posted += 1
            elif publish(args.repo, number, line, existing.get(number, []), args.pause) == "unchanged":
                skipped += 1
            else:
                posted += 1
        except subprocess.CalledProcessError as error:
            if rate_limited(error):
                print(f"published-in: rate limited at #{number}; {len(numbers) - index} PRs left, rerun to finish", file=sys.stderr)
                break
            failed += 1
            print(f"published-in: #{number}: {error.stderr.strip()[:300]}", file=sys.stderr)
    print(f"published-in: {args.name}: {len(numbers)} PRs, {posted} written, {skipped} already noted, "
          f"{failed} failed, {len(unreadable)} unreadable")
    return 0


if __name__ == "__main__":
    sys.exit(main())
