#!/usr/bin/env python3
"""Merge freezes as GitHub issues: visible, owned and expiring, readable from any host.

A freeze is an open issue in the repository with the `merge-freeze` label. The title is the
reason. The body names what it covers and until when, one field per line:

    paths: cmux-tui/crates/acpmux/ cmux-tui/spec/
    expires: 2026-10-20T18:00Z
    owner: @someone          (optional; defaults to the issue's author)
    branch: feat-cmux-next   (optional; default: every branch)

Only an admin or maintainer turns a freeze on, by adding the label; a label from anyone else,
or a body edited after the label went on, leaves the issue inactive until a maintainer adds the
label again. A freeze lasts at most MAX_HOURS from when its issue was opened, whatever
`expires` says.
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
# Lists are read one page per `gh api` call. 30 pages of 100 is 3000 items: the most changed files
# GitHub's files API lists, and more open freezes or label events than a repository has.
PER_PAGE = 100
MAX_PAGES = 30


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
    # Prefixes are repository paths: `./x/`, `/x/` and `x/,` all mean `x/`.
    raw = [p.strip("`,") for p in fields.get("paths", "").replace(",", " ").split()]
    freeze.paths = [re.sub(r"^\.?/+", "", p) for p in raw if p.strip("`,")]
    if not freeze.paths:
        freeze.problems.append("no `paths:` line")
    elif any(p.strip("/") in ("", "*", ".") for p in freeze.paths):
        freeze.problems.append("`paths:` names the whole repository; name the directories instead")
    elif any(re.search(r"[*?\[]", p) for p in freeze.paths):
        freeze.problems.append("`paths:` takes path prefixes, not globs (`cmux-tui/`, not `cmux-tui/*`)")
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


def gh_items(endpoint: str, max_pages: int = MAX_PAGES) -> list[dict]:
    """Every item of a paginated list endpoint, one page per `gh api` call. Not `gh api --paginate`:
    that is one invocation making any number of requests, which the gh quota shim can't charge and
    refuses, and a refused read left every merge with an unknown freeze state. A list longer than
    max_pages pages raises (status 2): a list cut short never reads as "no freeze"."""
    sep = "&" if "?" in endpoint else "?"
    items: list[dict] = []
    for page in range(1, max_pages + 1):
        batch = json.loads(gh("api", f"{endpoint}{sep}per_page={PER_PAGE}&page={page}"))
        if not isinstance(batch, list):
            raise TypeError(f"{endpoint} page {page} is not a list")
        items.extend(batch)
        if len(batch) < PER_PAGE:
            return items
    raise ValueError(f"{endpoint} has more than {max_pages} pages of {PER_PAGE}; "
                     "refusing to read a list cut short as complete")


def read_json_list(path: str) -> list[dict]:
    """A recorded API response (tests, or a caller that already fetched it). Empty means none."""
    with open(path) as handle:
        text = handle.read()
    return json.loads(text) if text.strip() else []


def last_labeler(events: list[dict], name: str) -> tuple[str | None, str | None]:
    """Who added the label and when, if it is still on: the last add, cleared by a later removal."""
    adder, at = None, None
    for event in events:
        if (event.get("label") or {}).get("name") != name:
            continue
        if event.get("event") == "labeled":
            adder, at = (event.get("actor") or {}).get("login"), event.get("created_at")
        elif event.get("event") == "unlabeled":
            adder, at = None, None
    return adder, at


def ok_labeler(events: list[dict]) -> str | None:
    """Who added freeze-ok, if it is still on."""
    return last_labeler(events, OK_LABEL)[0]


def repo_role(repo: str, login: str) -> str | None:
    """The person's role on the repository (admin, maintain, write, triage, read), or None for a
    non-collaborator."""
    try:
        return json.loads(gh("api", f"repos/{repo}/collaborators/{login}/permission")).get("role_name")
    except subprocess.CalledProcessError as error:
        if "404" in (error.stderr or ""):
            return None
        raise


def last_edited(repo: str, number: int) -> str | None:
    owner, name = repo.split("/", 1)
    query = "query($o:String!,$n:String!,$i:Int!){repository(owner:$o,name:$n){issue(number:$i){lastEditedAt}}}"
    out = gh("api", "graphql", "-f", f"query={query}", "-f", f"o={owner}", "-f", f"n={name}", "-F", f"i={number}")
    return json.loads(out)["data"]["repository"]["issue"]["lastEditedAt"]


def check_authority(freeze: Freeze, labeler: str | None, role: str | None, labeled_at: str | None,
                    edited_at: str | None) -> None:
    """A freeze stops merges for everyone, so only a maintainer turns one on: the merge-freeze
    label must come from an admin or maintainer, after the body's last edit. An edit after the
    label (widening `paths:`, say) leaves the freeze inactive until a maintainer adds it again."""
    if not labeler or role not in ("admin", "maintain"):
        who = f"@{labeler} ({role or 'not a collaborator'})" if labeler else "nobody"
        freeze.problems.append(f"the `{LABEL}` label was added by {who}, not an admin or maintainer")
    elif edited_at and labeled_at and parse_time(edited_at) > parse_time(labeled_at):
        freeze.problems.append(f"edited after @{labeler} added `{LABEL}`; a maintainer must add it again")


def open_freezes(repo: str, issues_file: str | None = None) -> list[Freeze]:
    if issues_file is not None:
        # Recorded issues carry what the API calls below would return: labeled_by,
        # labeler_role, labeled_at and last_edited_at.
        issues = [i for i in read_json_list(issues_file)
                  if i.get("state", "open") == "open"
                  and LABEL in {label.get("name") for label in i.get("labels", [])}]
    else:
        issues = gh_items(f"repos/{repo}/issues?state=open&labels={LABEL}")
    freezes = []
    for issue in issues:
        if "pull_request" in issue:
            continue
        freeze = parse_issue(issue)
        if issues_file is not None:
            labeler, role = issue.get("labeled_by"), issue.get("labeler_role")
            labeled_at, edited_at = issue.get("labeled_at"), issue.get("last_edited_at")
        else:
            labeler, labeled_at = last_labeler(
                gh_items(f"repos/{repo}/issues/{freeze.number}/events"), LABEL)
            role = repo_role(repo, labeler) if labeler else None
            edited_at = last_edited(repo, freeze.number)
        check_authority(freeze, labeler, role, labeled_at, edited_at)
        freezes.append(freeze)
    return freezes


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


def lapsed_at(freeze: Freeze, now: datetime) -> datetime | None:
    """When an open freeze issue stopped mattering, if it has: an active one at its deadline; a
    malformed or unauthorised one (never active) once MAX_HOURS have passed since it opened, so it
    doesn't stay open forever."""
    if freeze.problems:
        cap = freeze.created + timedelta(hours=MAX_HOURS)
        return cap if now >= cap else None
    if freeze.active(now):
        return None
    return freeze.deadline


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
                lapsed = lapsed_at(freeze, now)
                if lapsed is None:
                    continue
                state = "lapsed" if not freeze.problems else "isn't active (" + "; ".join(freeze.problems) + ") and is past"
                print(f"closing #{freeze.number}: {state} {lapsed:%Y-%m-%d %H:%MZ}")
                if not args.dry_run:
                    gh("issue", "close", str(freeze.number), "--repo", args.repo, "--comment",
                       f"This freeze {state} {lapsed:%Y-%m-%d %H:%MZ} and no longer blocks merges. "
                       f"Open a new `{LABEL}` issue to freeze again (docs/ci/merge-freeze.md).")
            return 0
        if args.files:
            with open(args.files) as handle:
                files = [line.strip() for line in handle if line.strip()]
        else:
            # Both ends of a rename: moving a file out of a frozen directory touches it too.
            entries = gh_items(f"repos/{args.repo}/pulls/{args.pr}/files")
            files = [e["filename"] for e in entries] + [e["previous_filename"] for e in entries
                                                        if e.get("previous_filename")]
            # The files API stops at 3000 files; an incomplete list can't clear a freeze.
            expected = json.loads(gh("api", f"repos/{args.repo}/pulls/{args.pr}")).get("changed_files")
            if expected is not None and len(entries) < expected:
                raise ValueError(f"GitHub listed {len(entries)} of {expected} changed files")
        labeler = None
        if any(f.active(now) for f in freezes):
            events = (read_json_list(args.events_file) if args.events_file is not None
                      else gh_items(f"repos/{args.repo}/issues/{args.pr}/events"))
            labeler = ok_labeler(events)
    # TypeError, AttributeError: GitHub answered with an unexpected shape (a null issue or a missing
    # timestamp, say). Still unknown, not frozen.
    except (subprocess.CalledProcessError, OSError, KeyError, ValueError, TypeError, AttributeError) as error:
        detail = getattr(error, "stderr", "") or error
        target = f"{args.repo}#{args.pr}" if args.mode == "check" else args.repo
        print(f"cannot read merge freezes for {target}: {detail}".strip(), file=sys.stderr)
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
