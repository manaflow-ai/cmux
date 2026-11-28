#!/usr/bin/env python3
"""Resolve a stuck `cmux/ios-fast` head for ios-fast-verdict-dispatch.yml: the PR's test merge commit at SHA.

The route posts `cmux/ios-fast` pending and pr-router.yml's ios-fast-status answers it. When the run that should
answer dies first (cmux#56949: run 45948051474 failed importing gh_http before the base was repaired), the pending
stays forever, a rerun of that run replays its broken workflow file, and the only other ways out were a new head
or a label cycle. ios-fast-verdict-dispatch.yml is the supported path: dispatched with a PR and its head SHA, it runs
pr-pipeline.yml's ios fast verdict on the PR's merge commit from the current workflow files and posts the real result.

    python3 -I scripts/ci/ios_fast_dispatch.py resolve   (env REPO, PR, SHA, GH_TOKEN, TOKENS)

A read tries GH_TOKEN (the run's github.token), then each TOKENS pool token, as proof_record.py's gate does: the run
token 403s once the repo's shared budget is spent, and a wait for its reset never fits this 5-min job (cmux#62219's
dispatch run 46112802526 slept toward 900 s on `pulls/62219` HTTP 403 and was cancelled at the job's timeout).

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
    if pr.get("mergeable") is False or pr.get("mergeable_state") == "dirty":
        raise Refused("the PR conflicts with its base: no merge commit to test (merge the base first)")
    if not SHA_RE.match(merge):
        raise Refused(f"GitHub has no test merge commit for the PR after {SETTLE_READS} reads "
                      f"(mergeability still computing): dispatch again")
    return merge


# GitHub answers `mergeable: null` while it computes, and a busy base (feat-cmux-next moves every few minutes) keeps
# a PR recomputing, so one read of a conflicting PR said "computing: dispatch again" and every redispatch said it again
# (cmux#39420 at 1a96014d, run 46165116783: GraphQL said CONFLICTING/DIRTY). Re-read until GitHub settles, bounded.
SETTLE_READS = 6
SETTLE_WAIT_S = 5


def read_settled(read, sleep=None) -> dict:
    """The PR once GitHub has decided its mergeability, or its last read after SETTLE_READS."""
    import time
    sleep = time.sleep if sleep is None else sleep
    for i in range(SETTLE_READS):
        pr = read()
        if pr.get("mergeable") is not None or i == SETTLE_READS - 1:
            return pr
        print(f"mergeability still computing (read {i + 1} of {SETTLE_READS}); reading again in {SETTLE_WAIT_S}s",
              file=sys.stderr)
        sleep(SETTLE_WAIT_S)
    return pr


def check_merge(commit: dict, merge: str, sha: str) -> str:
    """The merge commit's first parent (the base it tests against), or Refused when its second parent is not SHA."""
    parents = [p.get("sha") for p in commit.get("parents") or []]
    if len(parents) != 2 or parents[1] != sha:
        raise Refused(f"merge commit {merge} has parents {parents}, not [base, {sha}]: dispatch again")
    return parents[0]


# GitHub refusing this token (spent, or not allowed here), not the read: the next token may get it.
TOKEN_REFUSED = (401, 403, 429)


def read_tokens(env: dict | None = None) -> list[str]:
    """GH_TOKEN first, then the TOKENS pool, each once."""
    env = os.environ if env is None else env
    return list(dict.fromkeys(t for t in [env.get("GH_TOKEN", ""), *env.get("TOKENS", "").split()] if t))


def get(path: str, token: str | list[str]) -> dict:
    tokens = [token] if isinstance(token, str) else list(token)
    for i, one in enumerate(tokens):
        last = i == len(tokens) - 1
        req = urllib.request.Request(f"https://api.github.com/{path}", headers={
            "Accept": "application/vnd.github+json", "Authorization": f"Bearer {one}",
            "X-GitHub-Api-Version": "2022-11-28"})
        # A token with another behind it waits out no rate limit: the next token reads it now.
        status, body, headers = gh_http.request(req, 20, **({} if last else {"rate_budget_s": 0}))
        if status in TOKEN_REFUSED and not last:
            print(f"GET {path}: HTTP {status} with token {i + 1} of {len(tokens)}; trying the next", file=sys.stderr)
            continue
        break
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
    token = read_tokens()
    try:
        if not (repo and pr.isdigit() and token):
            raise Refused("REPO, PR (a number) and GH_TOKEN are needed")
        merge = check_pr(read_settled(lambda: get(f"repos/{repo}/pulls/{pr}", token)), repo, sha)
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
