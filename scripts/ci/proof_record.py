#!/usr/bin/env python3
"""Proof records: what a pre-PR verify loop ran on a pull request's exact head, posted on the PR as one comment.

The format is shared by every flow suite: iOS (`cmux ios verify`, scripts/ci/ios_verify.py, suite `ios-flows`) and
the Mac, web and GUI suites that reuse the FlowSuite schema (cmux-next-ios/FlowSuite/README.md). ci/proof-record/
README.md describes it and ci/proof-record/schema.json is its JSON Schema; this module is the one reader and writer.

A record is a JSON object (version 1):

  kind "cmux-proof-record", version 1, suite (ios-flows | mac-flows | web-flows | gui-flows), repo, pr, head_sha
  (the commit the runs built, the PR's head when it was posted), base_ref, base_sha (the base commit under the head),
  selection (the suite's selector output: flows and the tests behind them), runs ([{name, step, worker, args,
  result, seconds}]), captures ([{name, sha256, verdict, diff_ratio}] against baseline), baseline ({source, sha,
  pr, step} or null), video, verdict ("pass" | "fail"), timing ({pushed_at, proof_at, push_to_proof_s}), tool.

On the PR it is one comment whose first line is the marker `<!-- cmux-proof-record SUITE HEAD_SHA -->` and whose body
holds the record in a ```json fence. A gate reads the PR's comments (`find`), takes the newest record of its suite
whose head_sha is the PR's current head, and trusts it only when the comment's author may write to the repository
(author_association OWNER, MEMBER or COLLABORATOR, or a bot this repository runs).

    python3 -I scripts/ci/proof_record.py gate --suite ios-flows   (env REPO, PR, SHA, GH_TOKEN: prints the state)
    python3 -I scripts/ci/proof_record.py validate FILE
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import os
import re
import sys
import urllib.request
from typing import Iterable

KIND = "cmux-proof-record"
VERSION = 1
SUITES = ("ios-flows", "mac-flows", "web-flows", "gui-flows")
VERDICTS = ("pass", "fail")
RUN_RESULTS = ("pass", "fail", "error", "skipped")
CAPTURE_VERDICTS = ("same", "changed", "new", "missing", "unbaselined")
TRUSTED_ASSOCIATIONS = frozenset({"OWNER", "MEMBER", "COLLABORATOR"})
MARKER = re.compile(r"<!-- cmux-proof-record (?P<suite>[a-z-]+) (?P<sha>[0-9a-f]{40}) -->")
FENCE = re.compile(r"```json\n(?P<body>\{.*?\})\n```", re.S)
REQUIRED = ("kind", "version", "suite", "repo", "pr", "head_sha", "selection", "runs", "verdict", "timing", "tool")


def problems(record: object) -> list[str]:
    """What makes RECORD not a valid version-1 record (empty when it is one)."""
    if not isinstance(record, dict):
        return ["not a JSON object"]
    out = [f"missing {k}" for k in REQUIRED if k not in record]
    if record.get("kind") != KIND:
        out.append(f"kind is not {KIND}")
    if record.get("version") != VERSION:
        out.append(f"version is not {VERSION}")
    if record.get("suite") not in SUITES:
        out.append(f"suite is not one of {', '.join(SUITES)}")
    if not re.fullmatch(r"[0-9a-f]{40}", str(record.get("head_sha", ""))):
        out.append("head_sha is not a full commit id")
    if record.get("verdict") not in VERDICTS:
        out.append("verdict is not pass or fail")
    runs = record.get("runs")
    if not isinstance(runs, list):
        out.append("runs is not a list")
    else:
        for i, r in enumerate(runs):
            if not isinstance(r, dict) or r.get("result") not in RUN_RESULTS or not r.get("name"):
                out.append(f"runs[{i}] needs a name and a result ({', '.join(RUN_RESULTS)})")
        if record.get("verdict") == "pass" and any(isinstance(r, dict) and r.get("result") in ("fail", "error")
                                                   for r in runs):
            out.append("verdict is pass but a run failed")
        if record.get("verdict") == "pass" and not runs:
            out.append("verdict is pass with no run")
    for i, c in enumerate(record.get("captures") or []):
        if not isinstance(c, dict) or c.get("verdict") not in CAPTURE_VERDICTS:
            out.append(f"captures[{i}] verdict is not one of {', '.join(CAPTURE_VERDICTS)}")
    return out


def render(record: dict, summary_md: str = "") -> str:
    """The PR comment for RECORD: the marker, a short human summary, and the record itself."""
    bad = problems(record)
    if bad:
        raise ValueError("not a proof record: " + "; ".join(bad))
    head = f"<!-- {KIND} {record['suite']} {record['head_sha']} -->"
    body = json.dumps(record, indent=1, sort_keys=True)
    return f"{head}\n{summary_md.strip()}\n\n<details><summary>Proof record</summary>\n\n```json\n{body}\n```\n</details>\n"


def parse(comment_body: str) -> dict | None:
    """The record in one comment body, or None when it holds none (or a malformed one)."""
    m = MARKER.search(comment_body or "")
    f = FENCE.search(comment_body or "")
    if not (m and f):
        return None
    try:
        record = json.loads(f.group("body"))
    except ValueError:
        return None
    if problems(record) or record["suite"] != m.group("suite") or record["head_sha"] != m.group("sha"):
        return None
    return record


DEFAULT_BOTS = "quota-goblin-*[[]bot[]],cmux-bot[[]bot[]]"


def trusted(comment: dict, bots: Iterable[str] = ()) -> bool:
    """A collaborator's comment, or one by a GitHub App this repository installed (BOTS: fnmatch patterns; a
    fleet agent's `gh pr comment` goes through the broker and posts as its pool app, quota-goblin-N[bot])."""
    user = comment.get("user") or {}
    return (comment.get("author_association") in TRUSTED_ASSOCIATIONS
            or (user.get("type") == "Bot" and any(fnmatch.fnmatchcase(user.get("login") or "", b) for b in bots)))


def find(comments: list[dict], suite: str, head_sha: str, bots: Iterable[str] = ()) -> dict | None:
    """The newest trusted record of SUITE at HEAD_SHA among a PR's issue comments (GitHub's REST shape)."""
    best = None
    for c in comments:
        if not trusted(c, bots):
            continue
        record = parse(c.get("body") or "")
        if record and record["suite"] == suite and record["head_sha"] == head_sha:
            if best is None or (c.get("created_at") or "") >= best[0]:
                best = (c.get("created_at") or "", {**record, "_comment": c.get("html_url", "")})
    return best[1] if best else None


def gate(record: dict | None, suite: str) -> tuple[str, str]:
    """The commit-status state and description a gate posts for the record it found."""
    if record is None:
        return "pending", f"Waiting for the {suite} proof at this head: run `cmux ios verify`"
    if record["verdict"] != "pass":
        failed = [r["name"] for r in record["runs"] if r.get("result") in ("fail", "error")]
        return "failure", f"{suite} proof at this head failed: {', '.join(failed) or 'see the record'}"
    took = (record.get("timing") or {}).get("push_to_proof_s")
    flows = (record.get("selection") or {}).get("flows") or []
    return "success", f"{suite} proof at this head: {len(flows)} flows passed" + (f" in {took}s" if took else "")


def pr_comments(repo: str, pr: int | str, token: str, pages: int = 10) -> list[dict]:
    out: list[dict] = []
    for page in range(1, pages + 1):
        req = urllib.request.Request(
            f"https://api.github.com/repos/{repo}/issues/{pr}/comments?per_page=100&page={page}",
            headers={"Accept": "application/vnd.github+json", "Authorization": f"Bearer {token}",
                     "X-GitHub-Api-Version": "2022-11-28"})
        with urllib.request.urlopen(req, timeout=20) as resp:
            got = json.loads(resp.read())
        out += got
        if len(got) < 100:
            break
    return out


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    g = sub.add_parser("gate", help="print STATE<TAB>DESCRIPTION for the PR's current head (env REPO, PR, SHA, GH_TOKEN)")
    g.add_argument("--suite", required=True, choices=SUITES)
    g.add_argument("--bots", default=os.environ.get("PROOF_RECORD_BOTS", DEFAULT_BOTS))
    v = sub.add_parser("validate")
    v.add_argument("file")
    a = ap.parse_args(argv)
    if a.cmd == "validate":
        text = open(a.file, encoding="utf-8").read()
        record = parse(text) if MARKER.search(text) else json.loads(text)
        bad = ["no record in the comment"] if record is None else problems(record)
        for p in bad:
            print(p, file=sys.stderr)
        return 1 if bad else 0
    repo, pr, sha = os.environ.get("REPO", ""), os.environ.get("PR", ""), os.environ.get("SHA", "")
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN") or ""
    if not (repo and pr and sha and token):
        print("error\tproof record not read: REPO, PR, SHA and GH_TOKEN are needed")
        return 0
    try:
        record = find(pr_comments(repo, pr, token), a.suite, sha, [b for b in a.bots.split(",") if b])
    except Exception as e:  # noqa: BLE001 - an unread record is an error state, never a pass
        print(f"error\tproof record not read ({type(e).__name__}): rerun this job")
        return 0
    state, desc = gate(record, a.suite)
    print(f"{state}\t{desc}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
