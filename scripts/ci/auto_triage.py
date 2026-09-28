#!/usr/bin/env python3
"""Put severity and area labels on cmux issues, and say why.

Two modes:

    python3 scripts/ci/auto_triage.py --issue 12345
        One issue, the way the auto-triage workflow calls it. Applies the
        labels the rules propose and leaves one comment naming the rule.

    python3 scripts/ci/auto_triage.py --backfill --limit 200 --receipt out.jsonl
        Walk open issues and label the untriaged ones. No comments: a backfill
        that comments is 1700 notifications. The receipt records every label
        added so the pass can be reverted with --revert.

Both modes skip any issue that already carries a severity, `area:` or
`needs-triage` label. Whoever labeled it first wins, which is how a human
overrides the rules: change the labels and the bot stays out.

`scripts/ci/triage_rules.py` holds the rules. `docs/triage.md` explains them.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Iterator

sys.path.insert(0, str(Path(__file__).resolve().parent))

from triage_rules import (  # noqa: E402
    NEEDS_TRIAGE,
    Classification,
    classify,
    existing_triage_labels,
)


API = "https://api.github.com"
COMMENT_MARKER = "<!-- auto-triage:v1 -->"
DOCS = "https://github.com/manaflow-ai/cmux/blob/main/docs/triage.md"


def request(method: str, url: str, token: str, payload: dict[str, Any] | None = None) -> Any:
    body = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=body, method=method)
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("X-GitHub-Api-Version", "2022-11-28")
    if body is not None:
        req.add_header("Content-Type", "application/json")
    for attempt in range(4):
        try:
            with urllib.request.urlopen(req, timeout=30) as response:
                text = response.read().decode()
                return json.loads(text) if text else None
        except urllib.error.HTTPError as error:
            # Secondary rate limits answer 403 with a Retry-After. Everything
            # else is a real failure and should stop the pass, not retry into it.
            retry_after = error.headers.get("Retry-After") if error.headers else None
            if error.code in (403, 429) and attempt < 3:
                delay = int(retry_after) if retry_after and retry_after.isdigit() else 30 * (attempt + 1)
                print(f"  rate limited, sleeping {delay}s", flush=True)
                time.sleep(delay)
                continue
            detail = error.read().decode(errors="replace")
            raise SystemExit(f"{method} {url} failed: {error.code} {detail}") from error
        except urllib.error.URLError as error:
            if attempt < 3:
                time.sleep(5 * (attempt + 1))
                continue
            raise SystemExit(f"{method} {url} failed: {error}") from error
    raise SystemExit(f"{method} {url} failed after retries")


def token_from_env() -> str:
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN") or ""
    if not token:
        raise SystemExit("set GH_TOKEN")
    return token


def iter_open_issues(repo: str, token: str) -> Iterator[dict[str, Any]]:
    """Open issues, newest first. Pull requests are filtered out."""
    page = 1
    while True:
        batch = request(
            "GET",
            f"{API}/repos/{repo}/issues?state=open&per_page=100&page={page}&sort=created&direction=desc",
            token,
        )
        if not batch:
            return
        for item in batch:
            if "pull_request" in item:
                continue
            yield item
        if len(batch) < 100:
            return
        page += 1


def render_comment(result: Classification) -> str:
    lines = [COMMENT_MARKER, "Triaged by rule:", ""]
    if result.severity:
        lines.append(f"- **{result.severity}** — {result.severity_reason}.")
    else:
        lines.append("- **No severity** — this reads as a feature request or RFC, not something broken.")
    if result.areas:
        pretty = ", ".join(f"`{area}`" for area in result.areas)
        lines.append(f"- **Area:** {pretty}, from words in the title.")
    else:
        lines.append(
            f"- **`{NEEDS_TRIAGE}`** — the title did not point at one area more than the others."
        )
    lines.append("")
    lines.append(
        f"Wrong? Change the labels and they will stay changed; this runs once per issue. "
        f"The rules are in [docs/triage.md]({DOCS})."
    )
    return "\n".join(lines)


def apply_to_issue(
    repo: str,
    token: str,
    item: dict[str, Any],
    *,
    comment: bool,
    dry_run: bool,
) -> list[str] | None:
    """Label one issue. Returns the labels added, or None if it was skipped."""
    number = int(item["number"])
    already = existing_triage_labels(item.get("labels") or [])
    if already:
        return None

    result = classify(item.get("title") or "", item.get("body") or "", item.get("labels") or [])
    additions = result.labels_to_add()
    if not additions:
        return None

    summary = ",".join(additions)
    print(f"#{number} {summary}  {str(item.get('title') or '')[:70]}", flush=True)
    if dry_run:
        return additions

    request(
        "POST",
        f"{API}/repos/{repo}/issues/{number}/labels",
        token,
        {"labels": additions},
    )
    if comment:
        request(
            "POST",
            f"{API}/repos/{repo}/issues/{number}/comments",
            token,
            {"body": render_comment(result)},
        )
    return additions


def write_receipt(path: Path, rows: list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, sort_keys=True) + "\n")


def revert(repo: str, token: str, receipt: Path, *, dry_run: bool) -> int:
    """Remove exactly the labels a recorded pass added, and nothing else."""
    if not receipt.exists():
        raise SystemExit(f"{receipt}: no such receipt")
    removed = 0
    for line in receipt.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        row = json.loads(line)
        number = int(row["number"])
        for label in row.get("added") or []:
            print(f"#{number} remove {label}", flush=True)
            removed += 1
            if dry_run:
                continue
            quoted = urllib.parse.quote(label)
            try:
                request("DELETE", f"{API}/repos/{repo}/issues/{number}/labels/{quoted}", token)
            except SystemExit as error:
                # A label a human already removed answers 404. That is the
                # outcome we wanted anyway.
                if "failed: 404" not in str(error):
                    raise
    print(f"{removed} label removals {'planned' if dry_run else 'applied'}")
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default=os.environ.get("GH_REPO", "manaflow-ai/cmux"))
    parser.add_argument("--issue", type=int, help="triage one issue and comment on it")
    parser.add_argument("--backfill", action="store_true", help="walk open issues, no comments")
    parser.add_argument("--revert", type=Path, help="undo the labels recorded in a receipt")
    parser.add_argument("--limit", type=int, default=0, help="stop after this many issues changed")
    parser.add_argument("--receipt", type=Path, help="append a JSONL record of every label added")
    parser.add_argument("--no-comment", action="store_true", help="with --issue, skip the comment")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)

    if sum(bool(value) for value in (args.issue, args.backfill, args.revert)) != 1:
        parser.error("pick exactly one of --issue, --backfill, --revert")

    token = token_from_env()
    now = dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")

    if args.revert:
        return revert(args.repo, token, args.revert, dry_run=args.dry_run)

    if args.issue:
        item = request("GET", f"{API}/repos/{args.repo}/issues/{args.issue}", token)
        if "pull_request" in item:
            print(f"#{args.issue} is a pull request; auto-triage only labels issues")
            return 0
        if str(item.get("state")) != "open":
            print(f"#{args.issue} is {item.get('state')}; leaving it alone")
            return 0
        added = apply_to_issue(
            args.repo,
            token,
            item,
            comment=not args.no_comment,
            dry_run=args.dry_run,
        )
        if added is None:
            print(f"#{args.issue} already has triage labels; leaving it alone")
        elif args.receipt:
            write_receipt(args.receipt, [{"number": args.issue, "added": added, "at": now}])
        return 0

    changed: list[dict[str, Any]] = []
    scanned = 0
    for item in iter_open_issues(args.repo, token):
        scanned += 1
        added = apply_to_issue(args.repo, token, item, comment=False, dry_run=args.dry_run)
        if added:
            changed.append({"number": int(item["number"]), "added": added, "at": now})
            if args.receipt and not args.dry_run and len(changed) % 25 == 0:
                write_receipt(args.receipt, changed[-25:])
            if args.limit and len(changed) >= args.limit:
                break
    if args.receipt and not args.dry_run:
        tail = len(changed) % 25
        if tail:
            write_receipt(args.receipt, changed[-tail:])
    elif args.receipt and args.dry_run:
        write_receipt(args.receipt, changed)
    print(f"scanned {scanned} open issues, labeled {len(changed)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
