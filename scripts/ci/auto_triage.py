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


MAX_SLEEP = 900


class ApiError(RuntimeError):
    """A GitHub response the caller may want to inspect rather than die on."""

    def __init__(self, method: str, url: str, code: int, body: str) -> None:
        super().__init__(f"{method} {url} failed: {code} {body}")
        self.code = code
        self.body = body


def rate_limit_delay(headers: Any, attempt: int) -> int | None:
    """How long to wait, or None when this is not a rate limit.

    403 covers both "you are going too fast" and "you may not do this at all".
    Retrying a permission failure four times wastes the job's whole timeout, so
    a delay is only returned when the response actually says rate limit.
    """
    get = headers.get if headers else (lambda _name: None)
    retry_after = get("Retry-After")
    if retry_after and str(retry_after).strip().isdigit():
        # Secondary limits send this, and it is the number to trust.
        return min(int(str(retry_after).strip()), MAX_SLEEP)
    if str(get("X-RateLimit-Remaining") or "").strip() == "0":
        # A primary limit sends no Retry-After, only the reset timestamp.
        reset = str(get("X-RateLimit-Reset") or "").strip()
        if reset.isdigit():
            wait = int(reset) - int(time.time()) + 1
            return min(max(wait, 1), MAX_SLEEP)
        return min(30 * (attempt + 1), MAX_SLEEP)
    return None


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
            detail = error.read().decode(errors="replace")
            delay = rate_limit_delay(error.headers, attempt) if error.code in (403, 429) else None
            if delay is not None and attempt < 3:
                print(f"  rate limited, sleeping {delay}s", flush=True)
                time.sleep(delay)
                continue
            raise ApiError(method, url, error.code, detail) from error
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
        lines.append(
            "- **No severity** — this reads as a request or a design discussion rather than "
            "a report of something broken. If it is a bug, add the severity that fits."
        )
    if result.areas:
        pretty = ", ".join(f"`{area}`" for area in result.areas)
        if any(note.startswith("area from the issue form:") for note in result.notes):
            lines.append(f"- **Area:** {pretty}, selected in the issue form.")
        else:
            lines.append(f"- **Area:** {pretty}, from words in the title.")
    else:
        lines.append(
            f"- **`{NEEDS_TRIAGE}`** — the title did not point at one area more than the others."
        )
    lines.append("")
    lines.append(
        f"Wrong? Change the labels and they will stay changed: this only labels an issue that "
        f"has no triage label yet. The rules are in [docs/triage.md]({DOCS})."
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
    # Always at least one label: with no area, `needs-triage` is the answer.
    additions = result.labels_to_add()
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


class Receipt:
    """Append-only JSONL record of labels added, one line per issue.

    Written as the pass goes, not at the end. A pass over the whole backlog can
    stop on a 5xx, a rate limit or the job timeout, and a label with no receipt
    line is a label nothing can undo.

    A dry run writes rows too, because seeing them is the point, but every row
    carries `dry_run` and `--revert` refuses a file containing one. Otherwise
    the artifact from a preview pass reads as a record of labels that were
    never applied, and reverting it would strip labels a human put there.
    """

    def __init__(self, path: Path, repo: str, *, dry_run: bool) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        self.repo = repo
        self.dry_run = dry_run
        self.handle = path.open("a", encoding="utf-8")

    def add(self, number: int, added: list[str]) -> None:
        row: dict[str, Any] = {
            "repo": self.repo,
            "number": number,
            "added": added,
            "at": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
        }
        if self.dry_run:
            row["dry_run"] = True
        self.handle.write(json.dumps(row, sort_keys=True) + "\n")
        self.handle.flush()

    def close(self) -> None:
        self.handle.close()

    def __enter__(self) -> "Receipt":
        return self

    def __exit__(self, *_exc: object) -> None:
        self.close()


def load_receipt(receipt: Path, repo: str) -> list[dict[str, Any]]:
    """Rows to revert, refusing anything that does not describe this repo."""
    if not receipt.exists():
        raise SystemExit(f"{receipt}: no such receipt")
    rows: list[dict[str, Any]] = []
    for number, line in enumerate(receipt.read_text().splitlines(), start=1):
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except json.JSONDecodeError as error:
            raise SystemExit(f"{receipt}:{number}: not JSON: {error}") from error
        if row.get("dry_run"):
            raise SystemExit(
                f"{receipt}:{number} came from a dry run, so it records labels that were "
                f"never applied. Reverting it would remove labels this tool did not add."
            )
        row_repo = row.get("repo")
        if row_repo and row_repo != repo:
            raise SystemExit(
                f"{receipt}:{number} is for {row_repo}, not {repo}. Issue numbers do not "
                f"mean the same thing in two repositories; pass --repo {row_repo}."
            )
        if not row_repo:
            raise SystemExit(
                f"{receipt}:{number} has no repo field, so it predates this check and "
                f"cannot be verified. Remove the labels by hand."
            )
        rows.append(row)
    return rows


def revert(repo: str, token: str, receipt: Path, *, dry_run: bool) -> int:
    """Remove exactly the labels a recorded pass added, and nothing else."""
    rows = load_receipt(receipt, repo)
    if not dry_run:
        # Fail loudly on a repo this token cannot see. GitHub answers 404 for
        # that, which the loop below would otherwise read as "already removed"
        # and report as a clean run that did nothing.
        request("GET", f"{API}/repos/{repo}", token)
    removed = 0
    missing = 0
    for row in rows:
        number = int(row["number"])
        for label in row.get("added") or []:
            if dry_run:
                print(f"#{number} would remove {label}", flush=True)
                removed += 1
                continue
            quoted = urllib.parse.quote(label)
            try:
                request("DELETE", f"{API}/repos/{repo}/issues/{number}/labels/{quoted}", token)
            except ApiError as error:
                # "Label does not exist" means a human removed it already, and
                # that is the outcome we wanted. Any other 404 is a wrong
                # target: a deleted, transferred or nonexistent issue.
                if error.code == 404 and "label does not exist" in error.body.lower():
                    missing += 1
                    continue
                raise
            print(f"#{number} removed {label}", flush=True)
            removed += 1
    verb = "planned" if dry_run else "applied"
    extra = f", {missing} already gone" if missing else ""
    print(f"{removed} label removals {verb}{extra}")
    return 0


def positive(value: str) -> int:
    """A limit of 0 used to mean "no limit", which is a bad thing to typo."""
    try:
        number = int(value)
    except ValueError:
        raise argparse.ArgumentTypeError(f"{value!r} is not a number") from None
    if number < 1:
        raise argparse.ArgumentTypeError(
            f"--limit must be 1 or more (got {value!r}); omit it to walk every open issue"
        )
    return number


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default=os.environ.get("GH_REPO", "manaflow-ai/cmux"))
    parser.add_argument("--issue", type=int, help="triage one issue and comment on it")
    parser.add_argument("--backfill", action="store_true", help="walk open issues, no comments")
    parser.add_argument("--revert", type=Path, help="undo the labels recorded in a receipt")
    parser.add_argument("--limit", type=positive, help="stop after this many issues changed")
    parser.add_argument("--receipt", type=Path, help="append a JSONL record of every label added")
    parser.add_argument("--no-comment", action="store_true", help="with --issue, skip the comment")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)

    if sum(bool(value) for value in (args.issue, args.backfill, args.revert)) != 1:
        parser.error("pick exactly one of --issue, --backfill, --revert")

    token = token_from_env()

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
            with Receipt(args.receipt, args.repo, dry_run=args.dry_run) as receipt:
                receipt.add(args.issue, added)
        return 0

    receipt = Receipt(args.receipt, args.repo, dry_run=args.dry_run) if args.receipt else None
    changed = 0
    scanned = 0
    try:
        for item in iter_open_issues(args.repo, token):
            scanned += 1
            added = apply_to_issue(args.repo, token, item, comment=False, dry_run=args.dry_run)
            if not added:
                continue
            changed += 1
            if receipt:
                receipt.add(int(item["number"]), added)
            if args.limit and changed >= args.limit:
                break
    finally:
        if receipt:
            receipt.close()
        print(f"scanned {scanned} open issues, labeled {changed}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except ApiError as error:
        raise SystemExit(str(error)) from error
