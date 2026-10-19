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
SECTIONS = ("bead", "review", "preview", "attribution", "checks", "guards", "tour", "receipt")
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


def inert(text: str) -> str:
    """Section text that cannot open or close a section, so no line can pose as another."""
    return text.strip().replace("<!-- cmux-pr-status", "<!-- (cmux-pr-status)").replace(
        "<!-- /cmux-pr-status", "<!-- (/cmux-pr-status)")


def render(sections: Mapping[str, str]) -> str:
    known = [k for k in SECTIONS if sections.get(k)]
    extra = sorted(k for k in sections if k not in SECTIONS and sections[k])
    parts = [MARKER, TITLE]
    for key in known + extra:
        parts.append(f"<!-- cmux-pr-status:{key} -->\n{inert(sections[key])}\n<!-- /cmux-pr-status:{key} -->")
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


def list_comments(api: Api, repo: str, pr: int) -> list[dict]:
    found, page = [], 1
    while page <= 30:
        items = api("GET", f"/repos/{repo}/issues/{pr}/comments?per_page=100&page={page}", None) or []
        found += items
        if len(items) < 100:
            break
        page += 1
    return found


def marks(body: str, marker: str) -> bool:
    """Status comments start with MARKER; any other marker matches anywhere in a comment that
    is not a status comment (the merge receipt put its marker last)."""
    if marker == MARKER:
        return body.startswith(MARKER)
    return marker in body and not body.startswith(MARKER)


def bot_comments(comments: list[dict], marker: str) -> list[dict]:
    """This bot's comments marked with marker, oldest first."""
    found = [{"id": c["id"], "body": c.get("body") or ""} for c in comments
             if (c.get("user") or {}).get("login") == BOT and marks(c.get("body") or "", marker)]
    return sorted(found, key=lambda c: int(c["id"]))


def own_text(body: str, key: str) -> str:
    """A section's text when body is a status comment, else body (a comment from before it)."""
    return parse(body).get(key, "") if body.startswith(MARKER) else body


Write = tuple[str, str, "dict | None"]  # (method, path, payload)


def plan(repo: str, pr: int, comments: list[dict], key: str, text: str | None,
         legacy: str | None = None) -> list[Write]:
    """The writes that put `text` in section `key`, given the pull request's comments; [] when
    it is there already. The oldest status comment is kept and any newer one folded into it;
    with no status comment, the oldest legacy comment becomes it (edited, so the timeline gets
    no new entry); every other legacy comment is deleted."""
    text = text.strip() if text else None
    found = bot_comments(comments, MARKER)
    old = bot_comments(comments, legacy) if legacy else []
    writes: list[Write] = []
    if not found:
        if text is not None and old:
            writes.append(("PATCH", f"repos/{repo}/issues/comments/{old[0]['id']}", {"body": render({key: text})}))
            old = old[1:]
        elif text is not None:
            writes.append(("POST", f"repos/{repo}/issues/{pr}/comments", {"body": render({key: text})}))
    else:
        sections: dict[str, str] = {}
        for comment in reversed(found):  # the oldest comment wins a clash
            sections.update(parse(comment["body"]))
        if text is None:
            sections.pop(key, None)
        else:
            sections[key] = text
        body = render(sections)
        if body != found[0]["body"] or len(found) > 1:
            writes.append(("PATCH", f"repos/{repo}/issues/comments/{found[0]['id']}", {"body": body}))
        writes += [("DELETE", f"repos/{repo}/issues/comments/{c['id']}", None) for c in found[1:]]
    writes += [("DELETE", f"repos/{repo}/issues/comments/{c['id']}", None) for c in old]
    return writes


def apply(read: Callable[[], list[dict]], call: Callable[[str, str, "dict | None"], object],
          repo: str, pr: int, key: str, text: str | None, *, legacy: str | None = None,
          sleep: Callable[[float], None] | None = time.sleep) -> str:
    """Read, plan, write; then (unless sleep is None, as in a dry run) wait, read again and
    write again while another writer's stale copy replaced this section."""
    did = "unchanged"
    for _ in range(ATTEMPTS):
        writes = plan(repo, pr, read(), key, text, legacy)
        if not writes:
            return did
        for method, path, payload in writes:
            call(method, path, payload)
        did = "written"
        if sleep is None:
            return did
        # Another writer may have read the comment before this write and write over it.
        sleep(float(os.environ.get("PR_STATUS_SETTLE_SECONDS") or random.uniform(1.5, 3.0)))
    return did + " (unconfirmed: another writer kept replacing the comment)"


def upsert(repo: str, pr: int, key: str, text: str | None, *, legacy: str | None = None,
           api: Api = http_api, sleep: Callable[[float], None] | None = time.sleep) -> str:
    """Set (or with None, remove) one section over the REST API; returns what it did."""
    return apply(lambda: list_comments(api, repo, pr), lambda m, p, b: api(m, "/" + p.lstrip("/"), b),
                 repo, pr, key, text, legacy=legacy, sleep=sleep)


def section(repo: str, pr: int, key: str, *, api: Api = http_api) -> str | None:
    """The section's current text, or None."""
    found = bot_comments(list_comments(api, repo, pr), MARKER)
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
