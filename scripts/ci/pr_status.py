#!/usr/bin/env python3
"""Keep one status comment per pull request, edited in place, with a section per source.

Several workflows and two off-GitHub jobs used to post their own comment on every pull
request: the bead link, the review and build links, red checks, the tour, the merge
receipt. This puts them in one github-actions comment (found by MARKER) so the timeline
gets one entry instead of six, and none posts as a person.

Each writer owns one section (SECTIONS, in display order) and replaces only that one:

    import pr_status
    pr_status.upsert(repo, pr, "checks", "red: web / lint ...")   # set
    pr_status.upsert(repo, pr, "checks", None)                     # remove

A section set to None on a pull request with no status comment writes nothing, so a clean
pull request gets no comment at all. GitHub has no compare-and-swap on comments, so two
writers can race: upsert re-reads the comment after a short wait and writes again when its
section was lost, and folds a duplicate status comment (two writers that both found none)
into the oldest one. `legacy` names the marker of the comment a writer posted before this
existed; that comment is deleted once the section is written, so a pull request in flight
does not show both.

Callers off GitHub (bead-autoclose.py, hq's pr-preview) cannot post as github-actions, so
they dispatch .github/workflows/pr-status.yml, which runs `field` below. `field` builds
the text from validated values only; no caller can put free text on a pull request.

Usage:
  pr_status.py set   --repo R --pr N --section S (--body-file F | --clear) [--legacy MARKER]
  pr_status.py field --repo R --pr N (--bead cx-ID | --preview SHA)
  pr_status.py render --sections-json F        (print the body; tests and previews)
Needs GH_TOKEN or GITHUB_TOKEN with pull-requests: write; GITHUB_API_URL overrides the API.
"""
from __future__ import annotations

import argparse
import json
import random
import re
import os
import sys
import time
import urllib.request
from pathlib import Path
from typing import Callable, Mapping

MARKER = "<!-- cmux-pr-status -->"
BOT = "github-actions[bot]"
SECTIONS = ("bead", "review", "preview", "checks", "tour", "receipt")
TITLE = "**cmux status** <sub>(one comment, edited in place; each line is updated by the job that owns it)</sub>"
SECTION = re.compile(r"<!-- cmux-pr-status:(?P<key>[a-z-]+) -->\n(?P<text>.*?)\n<!-- /cmux-pr-status:(?P=key) -->",
                     re.S)
LIMIT = 65000  # GitHub's comment cap is 65536 characters
BEAD = re.compile(r"cx-[a-z0-9]{2,8}(?:\.[0-9]+)*")
SHA = re.compile(r"[0-9a-f]{40}")
PREVIEW_FEED = "https://github.com/manaflow-ai/cmuxterm-hq/issues/2098"
ATTEMPTS = 4

Api = Callable[[str, str, "dict | None"], object]


def parse(body: str) -> dict[str, str]:
    return {m["key"]: m["text"] for m in SECTION.finditer(body or "")}


def render(sections: Mapping[str, str]) -> str:
    known = [k for k in SECTIONS if sections.get(k)]
    extra = sorted(k for k in sections if k not in SECTIONS and sections[k])
    parts = [MARKER, TITLE]
    for key in known + extra:
        parts.append(f"<!-- cmux-pr-status:{key} -->\n{sections[key].strip()}\n<!-- /cmux-pr-status:{key} -->")
    body = "\n\n".join(parts) + "\n"
    if len(body) > LIMIT:
        # Trim the longest section (the tour's step table, in practice), never the others.
        longest = max(known + extra, key=lambda k: len(sections[k]))
        cut = dict(sections)
        over = len(body) - LIMIT + 200
        cut[longest] = sections[longest][: max(0, len(sections[longest]) - over)].rstrip() + \
            "\n\n(cut to fit GitHub's comment limit; the run that wrote this has the rest)"
        return render(cut)
    return body


def http_api(method: str, path: str, payload: dict | None = None):
    """GitHub REST at GITHUB_API_URL with GH_TOKEN (or GITHUB_TOKEN)."""
    api = os.environ.get("GITHUB_API_URL", "https://api.github.com").rstrip("/")
    token = os.environ.get("GH_TOKEN") or os.environ["GITHUB_TOKEN"]
    request = urllib.request.Request(api + path, method=method,
                                     data=None if payload is None else json.dumps(payload).encode(),
                                     headers={"Authorization": f"Bearer {token}",
                                              "Accept": "application/vnd.github+json",
                                              "X-GitHub-Api-Version": "2022-11-28"})
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.loads(response.read() or b"null")


def bot_comments(api: Api, repo: str, pr: int, marker: str) -> list[dict]:
    """This bot's comments that start with marker, oldest first."""
    found, page = [], 1
    while page <= 30:
        items = api("GET", f"/repos/{repo}/issues/{pr}/comments?per_page=100&page={page}", None) or []
        found += [{"id": c["id"], "body": c.get("body") or ""} for c in items
                  if (c.get("user") or {}).get("login") == BOT and (c.get("body") or "").startswith(marker)]
        if len(items) < 100:
            break
        page += 1
    return sorted(found, key=lambda c: int(c["id"]))


def write(api: Api, repo: str, pr: int, comment_id: int | None, body: str) -> None:
    if comment_id is None:
        api("POST", f"/repos/{repo}/issues/{pr}/comments", {"body": body})
    else:
        api("PATCH", f"/repos/{repo}/issues/comments/{comment_id}", {"body": body})


def delete(api: Api, repo: str, comment_id: int) -> None:
    api("DELETE", f"/repos/{repo}/issues/comments/{comment_id}", None)


def upsert(repo: str, pr: int, key: str, text: str | None, *, legacy: str | None = None,
           api: Api = http_api, sleep: Callable[[float], None] = time.sleep) -> str:
    """Set (or with None, remove) one section; returns what it did."""
    text = text.strip() if text else None
    did = "unchanged"
    for _ in range(ATTEMPTS):
        found = bot_comments(api, repo, pr, MARKER)
        if not found:
            if text is None:
                did = "none"
                break
            write(api, repo, pr, None, render({key: text}))
            did = "created"
        else:
            primary, extras = found[0], found[1:]
            sections: dict[str, str] = {}
            for comment in reversed(found):  # the oldest comment wins a clash
                sections.update(parse(comment["body"]))
            if text is None:
                sections.pop(key, None)
            else:
                sections[key] = text
            body = render(sections)
            if body != primary["body"] or extras:
                write(api, repo, pr, int(primary["id"]), body)
                did = "updated" if did == "unchanged" else did
            for extra in extras:
                delete(api, repo, int(extra["id"]))
            if body == primary["body"] and not extras:
                break
        # Another writer may have read the comment before this write and will write over it:
        # wait, re-read, and repeat when this section did not survive.
        sleep(float(os.environ.get("PR_STATUS_SETTLE_SECONDS") or random.uniform(1.5, 3.0)))
        again = bot_comments(api, repo, pr, MARKER)
        if len(again) <= 1 and (parse(again[0]["body"]).get(key) if again else None) == text:
            break
    else:
        did += " (unconfirmed: another writer kept replacing the comment)"
    if legacy:
        for old in bot_comments(api, repo, pr, legacy):
            delete(api, repo, int(old["id"]))
    return did


def section(repo: str, pr: int, key: str, *, api: Api = http_api) -> str | None:
    """The section's current text, or None."""
    found = bot_comments(api, repo, pr, MARKER)
    return parse(found[0]["body"]).get(key) if found else None


def field_text(bead: str | None, preview: str | None) -> tuple[str, str]:
    """(section, text) for a dispatched field; raises ValueError on anything but a valid value."""
    if bead is not None:
        if not BEAD.fullmatch(bead):
            raise ValueError(f"not a bead id: {bead!r}")
        return "bead", f"Bead: `{bead}`"
    if preview is not None:
        if not SHA.fullmatch(preview):
            raise ValueError(f"not a commit SHA: {preview!r}")
        return "preview", f"Visual preview of `{preview[:7]}`: in the [maintainers' private review feed]({PREVIEW_FEED})."
    raise ValueError("give --bead or --preview")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    sub = parser.add_subparsers(dest="command", required=True)
    s = sub.add_parser("set", help="set or clear one section")
    s.add_argument("--repo", required=True)
    s.add_argument("--pr", type=int, required=True)
    s.add_argument("--section", required=True, choices=SECTIONS)
    group = s.add_mutually_exclusive_group(required=True)
    group.add_argument("--body-file", type=Path)
    group.add_argument("--clear", action="store_true")
    s.add_argument("--legacy", help="marker of the comment this section replaces; deleted after the write")
    f = sub.add_parser("field", help="set the bead or preview line from a validated value")
    f.add_argument("--repo", required=True)
    f.add_argument("--pr", type=int, required=True)
    f.add_argument("--bead")
    f.add_argument("--preview")
    r = sub.add_parser("render", help="print the comment for a JSON object of sections")
    r.add_argument("--sections-json", type=Path, required=True)
    args = parser.parse_args(argv)

    if args.command == "render":
        sys.stdout.write(render(json.loads(args.sections_json.read_text())))
        return 0
    if args.command == "field":
        try:
            key, text = field_text(args.bead or None, args.preview or None)
        except ValueError as error:
            print(f"pr-status: {error}", file=sys.stderr)
            return 2
        legacy = None  # the old bead and preview comments were a person's; they stay
    else:
        key = args.section
        text = None if args.clear else args.body_file.read_text()
        legacy = args.legacy
    did = upsert(args.repo, args.pr, key, text, legacy=legacy)
    print(f"pr-status: #{args.pr} {key}: {did}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
