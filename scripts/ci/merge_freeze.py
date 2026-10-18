#!/usr/bin/env python3
"""Merge freezes as GitHub issues: visible, owned and expiring, readable from any host.

A freeze is an open issue in the repository with the `merge-freeze` label. The title is the
reason. The body names what it covers and until when, one field per line:

    paths: cmux-tui/crates/acpmux/ cmux-tui/spec/
    expires: 2026-10-20T18:00Z
    owner: @someone          (optional; defaults to the issue's author)
    branch: feat-cmux-next   (optional; default: every branch)

A freeze lasts at most MAX_HOURS from when its issue was opened, whatever `expires` says.
One whose `paths` or `expires` don't parse blocks nothing and is reported as malformed, so
a typo never freezes the repository. `expire` closes lapsed freezes with a comment, so the
open ones are the live ones.

A pull request that touches a frozen path merges only after the freeze's owner adds the
`freeze-ok` label to it. The label's actor comes from the issue timeline, so anyone can see
who let a pull request through.

Usage:
  merge_freeze.py check --repo OWNER/REPO --pr N [--base BRANCH] [--files FILE]
                        [--issues-file FILE --events-file FILE]
  merge_freeze.py list --repo OWNER/REPO
  merge_freeze.py expire --repo OWNER/REPO [--dry-run]

`check` exits 0 when nothing blocks the merge, 1 when a freeze does (it prints which), and
2 when GitHub can't be read: an unknown freeze state never reads as clear.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone

LABEL = "merge-freeze"
OK_LABEL = "freeze-ok"
MAX_HOURS = 72


@dataclass
class Freeze:
    number: int
    title: str
    owner: str
    created: datetime
    paths: list[str] = field(default_factory=list)
    expires: datetime | None = None
    branch: str | None = None
    problems: list[str] = field(default_factory=list)

    @property
    def deadline(self) -> datetime | None:
        if self.expires is None:
            return None
        return min(self.expires, self.created + timedelta(hours=MAX_HOURS))

    def active(self, now: datetime) -> bool:
        return not self.problems and self.deadline is not None and now < self.deadline

    def covers(self, path: str) -> str | None:
        for prefix in self.paths:
            bare = prefix.rstrip("/")
            if path == bare or path.startswith(bare + "/"):
                return prefix
        return None


def parse_time(value: str) -> datetime:
    value = value.strip()
    if value.endswith("Z"):
        value = value[:-1] + "+00:00"
    parsed = datetime.fromisoformat(value)
    if parsed.tzinfo is None:
        raise ValueError("needs a timezone, for example 2026-10-20T18:00Z")
    return parsed.astimezone(timezone.utc)


def parse_issue(issue: dict) -> Freeze:
    freeze = Freeze(
        number=issue["number"],
        title=issue.get("title") or "",
        owner=(issue.get("user") or {}).get("login", ""),
        created=parse_time(issue["created_at"]),
    )
    body = re.sub(r"<!--.*?-->", "", issue.get("body") or "", flags=re.S)
    fields: dict[str, str] = {}
    for line in body.splitlines():
        match = re.match(r"^\s*[-*]?\s*\**(paths|expires|owner|branch)\**\s*:\s*(.*?)\s*$", line, re.I)
        if match and match.group(1).lower() not in fields:
            fields[match.group(1).lower()] = match.group(2)
    freeze.paths = [p.strip("`") for p in fields.get("paths", "").split() if p.strip("`")]
    if not freeze.paths:
        freeze.problems.append("no `paths:` line")
    elif any(p.strip("/") in ("", "*", ".") for p in freeze.paths):
        freeze.problems.append("`paths:` names the whole repository; name the directories instead")
    if "expires" not in fields:
        freeze.problems.append("no `expires:` line")
    else:
        try:
            freeze.expires = parse_time(fields["expires"])
        except ValueError as error:
            freeze.problems.append(f"`expires:` doesn't parse ({error})")
    if fields.get("owner"):
        freeze.owner = fields["owner"].split()[0].lstrip("@")
    if fields.get("branch"):
        freeze.branch = fields["branch"].split()[0]
    return freeze


def gh(*args: str) -> str:
    return subprocess.run(["gh", *args], check=True, capture_output=True, text=True).stdout


def gh_items(endpoint: str) -> list[dict]:
    """Every item of a paginated list endpoint (one JSON object per line: older gh has no --slurp)."""
    out = gh("api", "--paginate", endpoint, "--jq", ".[] | @json")
    return [json.loads(line) for line in out.splitlines() if line.strip()]


def read_json_list(path: str) -> list[dict]:
    """A recorded API response (tests, or a caller that already fetched it). Empty means none."""
    with open(path) as handle:
        text = handle.read()
    return json.loads(text) if text.strip() else []


def open_freezes(repo: str, issues_file: str | None = None) -> list[Freeze]:
    if issues_file is not None:
        issues = [i for i in read_json_list(issues_file)
                  if i.get("state", "open") == "open"
                  and LABEL in {label.get("name") for label in i.get("labels", [])}]
    else:
        issues = gh_items(f"repos/{repo}/issues?state=open&labels={LABEL}&per_page=100")
    return [parse_issue(issue) for issue in issues if "pull_request" not in issue]


def ok_labeler(events: list[dict]) -> str | None:
    """Who added freeze-ok, if it is still on: the last add, cleared by a later removal."""
    adder = None
    for event in events:
        if (event.get("label") or {}).get("name") != OK_LABEL:
            continue
        if event.get("event") == "labeled":
            adder = (event.get("actor") or {}).get("login")
        elif event.get("event") == "unlabeled":
            adder = None
    return adder


def blocking(freezes: list[Freeze], files: list[str], base: str | None, labeler: str | None,
             now: datetime) -> list[str]:
    out = []
    for freeze in freezes:
        if not freeze.active(now) or (freeze.branch and base and freeze.branch != base):
            continue
        hits = [(path, prefix) for path in files if (prefix := freeze.covers(path))]
        if not hits or (labeler and labeler.lower() == freeze.owner.lower()):
            continue
        shown = ", ".join(f"{path} ({prefix})" for path, prefix in hits[:5])
        more = f" and {len(hits) - 5} more" if len(hits) > 5 else ""
        out.append(f"#{freeze.number} \"{freeze.title}\" by @{freeze.owner} until "
                   f"{freeze.deadline:%Y-%m-%d %H:%MZ}: {shown}{more}")
    return out


def describe(freeze: Freeze, now: datetime) -> str:
    if freeze.problems:
        state = "malformed: " + "; ".join(freeze.problems)
    elif freeze.active(now):
        state = f"active until {freeze.deadline:%Y-%m-%d %H:%MZ}"
    else:
        state = f"lapsed at {freeze.deadline:%Y-%m-%d %H:%MZ}"
    scope = f" on {freeze.branch}" if freeze.branch else ""
    return f"#{freeze.number} @{freeze.owner}{scope} {state}: {' '.join(freeze.paths) or '-'} ({freeze.title})"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="mode", required=True)
    check = sub.add_parser("check")
    check.add_argument("--repo", required=True)
    check.add_argument("--pr", required=True)
    check.add_argument("--base")
    check.add_argument("--files", help="changed paths, one per line (default: read from GitHub)")
    check.add_argument("--issues-file", help="the open issues as JSON, instead of reading GitHub")
    check.add_argument("--events-file", help="the pull request's issue events as JSON, instead of reading GitHub")
    for name in ("list", "expire"):
        p = sub.add_parser(name)
        p.add_argument("--repo", required=True)
        if name == "expire":
            p.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)
    now = datetime.now(timezone.utc)

    try:
        freezes = open_freezes(args.repo, getattr(args, "issues_file", None))
        if args.mode == "list":
            for freeze in freezes:
                print(describe(freeze, now))
            return 0
        if args.mode == "expire":
            for freeze in freezes:
                if freeze.problems or freeze.active(now):
                    continue
                print(f"closing #{freeze.number}: lapsed at {freeze.deadline:%Y-%m-%d %H:%MZ}")
                if not args.dry_run:
                    gh("issue", "close", str(freeze.number), "--repo", args.repo, "--comment",
                       f"This freeze lapsed at {freeze.deadline:%Y-%m-%d %H:%MZ} and no longer blocks merges. "
                       f"Open a new `{LABEL}` issue to freeze again (docs/ci/merge-freeze.md).")
            return 0
        if args.files:
            with open(args.files) as handle:
                files = [line.strip() for line in handle if line.strip()]
        else:
            files = gh("api", "--paginate", f"repos/{args.repo}/pulls/{args.pr}/files?per_page=100",
                       "--jq", ".[].filename").split()
        labeler = None
        if any(f.active(now) for f in freezes):
            events = (read_json_list(args.events_file) if args.events_file is not None
                      else gh_items(f"repos/{args.repo}/issues/{args.pr}/events?per_page=100"))
            labeler = ok_labeler(events)
    except (subprocess.CalledProcessError, OSError, KeyError, ValueError) as error:
        detail = getattr(error, "stderr", "") or error
        print(f"cannot read merge freezes for {args.repo}#{args.pr}: {detail}".strip(), file=sys.stderr)
        return 2
    for freeze in freezes:
        if freeze.problems:
            print(f"warning: ignoring {describe(freeze, now)}", file=sys.stderr)
    blocked = blocking(freezes, files, args.base, labeler, now)
    for line in blocked:
        print(line)
    return 1 if blocked else 0


if __name__ == "__main__":
    sys.exit(main())
