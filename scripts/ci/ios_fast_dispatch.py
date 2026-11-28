#!/usr/bin/env python3
"""Resolve a stuck `cmux/ios-fast` head for ios-fast-verdict-dispatch.yml: the PR's test merge commit at SHA.

The route posts `cmux/ios-fast` pending and pr-router.yml's ios-fast-status answers it. When the run that should
answer dies first (cmux#56949: run 45948051474 failed importing gh_http before the base was repaired), the pending
stays forever, a rerun of that run replays its broken workflow file, and the only other ways out were a new head
or a label cycle. ios-fast-verdict-dispatch.yml is the supported path: dispatched with a PR and its head SHA, it runs
pr-pipeline.yml's ios fast verdict on the PR's merge commit from the current workflow files and posts the real result.

    python3 -I scripts/ci/ios_fast_dispatch.py resolve   (env REPO, PR, SHA, GH_TOKEN)

prints the merge commit and writes `merge` and `base` to $GITHUB_OUTPUT, or fails naming why: the PR is closed, its
head moved past SHA, it is a fork, or GitHub has no merge commit with SHA as its second parent yet.
"""

from __future__ import annotations

import json
import os
import re
import sys
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gh_http  # noqa: E402

SHA_RE = re.compile(r"^[0-9a-f]{40}$")
BASE = "feat-cmux-next"


class Refused(Exception):
    pass


def check_pr(pr: dict, repo: str, sha: str) -> str:
    """The merge commit to test for PR at head SHA, or Refused naming why the dispatch cannot judge it."""
    if not SHA_RE.match(sha):
        raise Refused(f"sha must be a full 40-character commit id, not {sha!r}")
    if pr.get("state") != "open":
        raise Refused(f"the PR is {pr.get('state')}: nothing waits on its cmux/ios-fast")
    head = pr.get("head") or {}
    if (head.get("repo") or {}).get("full_name") != repo:
        raise Refused("a fork's head: pr-router.yml posts no cmux/ios-fast there")
    if (pr.get("base") or {}).get("ref") != BASE:
        raise Refused(f"the PR's base is {(pr.get('base') or {}).get('ref')!r}, not {BASE}")
    if head.get("sha") != sha:
        raise Refused(f"the PR's head is {head.get('sha')}, not {sha}: its own pr router run answers that head")
    merge = pr.get("merge_commit_sha") or ""
    if pr.get("mergeable") is False:
        raise Refused("the PR conflicts with its base: no merge commit to test (merge the base first)")
    if not SHA_RE.match(merge):
        raise Refused("GitHub has no test merge commit for the PR yet (mergeability is computing): dispatch again")
    return merge


def check_merge(commit: dict, merge: str, sha: str) -> str:
    """The merge commit's first parent (the base it tests against), or Refused when its second parent is not SHA."""
    parents = [p.get("sha") for p in commit.get("parents") or []]
    if len(parents) != 2 or parents[1] != sha:
        raise Refused(f"merge commit {merge} has parents {parents}, not [base, {sha}]: dispatch again")
    return parents[0]


def get(path: str, token: str) -> dict:
    req = urllib.request.Request(f"https://api.github.com/{path}", headers={
        "Accept": "application/vnd.github+json", "Authorization": f"Bearer {token}",
        "X-GitHub-Api-Version": "2022-11-28"})
    status, body, headers = gh_http.request(req, 20)
    if status != 200:
        until = gh_http.limited_until(headers) if status in (403, 429) else None
        if until:
            raise Refused(f"GET {path}: rate-limited until {until} (HTTP {status}); dispatch again after it")
        raise Refused(f"GET {path}: HTTP {status} {body[:200]!r}")
    return json.loads(body)


def main(argv: list[str] | None = None) -> int:
    args = sys.argv[1:] if argv is None else argv
    if args != ["resolve"]:
        print(__doc__, file=sys.stderr)
        return 2
    repo, pr, sha = os.environ.get("REPO", ""), os.environ.get("PR", "").strip().lstrip("#"), os.environ.get("SHA", "").strip()
    token = os.environ.get("GH_TOKEN", "")
    try:
        if not (repo and pr.isdigit() and token):
            raise Refused("REPO, PR (a number) and GH_TOKEN are needed")
        merge = check_pr(get(f"repos/{repo}/pulls/{pr}", token), repo, sha)
        base = check_merge(get(f"repos/{repo}/commits/{merge}", token), merge, sha)
    except Refused as e:
        print(f"::error title=ios fast verdict dispatch::{e}")
        return 1
    print(f"#{pr} head {sha}: testing merge commit {merge} (base {base})")
    out = os.environ.get("GITHUB_OUTPUT")
    if out:
        with open(out, "a", encoding="utf-8") as f:
            f.write(f"merge={merge}\nbase={base}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
