#!/usr/bin/env python3
"""Which commits of feat-cmux-next the direct-push quarantine holds, for the NEXT nightly (request-nightly-next.sh).

feat-cmux-next takes direct pushes, and a direct push meets no PR check. Leo, 2026-11-12, asked whether to require pull
requests: "ugh we can just warn/pre-whatever/quarantine stuff idk", and "like run [something] right after a direct
push/some direct pushes potentially". cmux adds no CI for it (CLAUDE.md: "Never add CI gates ... CI jobs or steps"):
cmuxterm-hq's base-red-watch reads feat-cmux-next's own push runs, and when a confirmed red's every suspect is a direct
push it posts CONTEXT `failure` on that commit, then `success` on the tip once it is fixed or reverted. Nothing is
reverted. This reads those statuses only: walking TIP's first-parent history (the commits request-nightly-next.sh
promotes from) from the oldest commit read, a red CONTEXT opens the quarantine and a green one closes it; pending,
errored and absent statuses change nothing. A commit off the first-parent line is not read, so a side branch's
status can neither open nor lift it.

Only the publisher's statuses count: CONTEXT from any creator but CREATOR (the cmux-bot app that cmuxterm-hq's trusted
publisher posts as) is ignored, with one line on stderr. Anyone with write access can post a status with that
context; a forged success must not lift a quarantine, nor a forged failure set one.

    quarantined --repo R --tip SHA
        Prints one line per quarantined commit of TIP's recent history: "<sha> <culprit> <pusher>". Exit 1 when the
        history cannot be read. With GH_TICK_CACHE set (nightly-next-tick), the answer is kept there for TIP.

Descriptions (posted by cmuxterm-hq's tools/fleet-reconcilers/direct_push_publish.py): "red: base <sha40> since
<sha12> by <login>", "cleared: base <sha40> since <sha12>".
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys

CONTEXT = "cmux-next/direct-push-gates"
DEPTH = 100  # first-parent commits read: request-nightly-next.sh promotes from the tip's newest 99
CREATOR = "cmux-bot[bot]"  # the trusted publisher's app, as REST names it: only its CONTEXT statuses are read
# GraphQL names the same app `cmux-bot` with __typename Bot (REST adds "[bot]"); a user may register the bare login, so a
# creator counts only as a Bot with one of these logins (cmux#42343 review F1).
CREATOR_LOGINS = frozenset({"cmux-bot", "cmux-bot[bot]"})
SHA_RE = re.compile(r"^[0-9a-f]{40}$")
BASE_RE = re.compile(r"\bbase ([0-9a-f]{40})\b")
SINCE_RE = re.compile(r"\bsince ([0-9a-f]{7,40})\b")
BY_RE = re.compile(r"\bby @?([A-Za-z0-9][A-Za-z0-9-]*(?:\[bot\])?)")
COMMIT_FIELDS = (f'... on Commit{{oid author{{user{{login}} name}} '
                 f'status{{context(name:"{CONTEXT}"){{state description creator{{__typename login}}}}}}}}')


def query(shas: list[str]) -> str:
    """One GraphQL read of exactly these commits (GraphQL's history follows every parent, not the first one)."""
    lookups = " ".join(f'c{i}:object(oid:"{sha}"){{{COMMIT_FIELDS}}}' for i, sha in enumerate(shas))
    return f"query($o:String!,$n:String!){{repository(owner:$o,name:$n){{{lookups}}}}}"


def gh(*args: str) -> str:
    return subprocess.run(["gh", *args], check=True, capture_output=True, text=True, timeout=120).stdout


def quarantine_walk(nodes: list) -> tuple[dict | None, list[tuple[str, dict]]]:
    """(the open quarantine after the newest node, [(sha, quarantine)] for each node it holds), from GraphQL history
    nodes, newest first. A red CONTEXT opens it, a green one closes it; anything else changes nothing. CONTEXT from a
    creator other than CREATOR is ignored."""
    found, held = None, []
    for node in reversed([n for n in nodes or [] if isinstance(n, dict) and isinstance(n.get("oid"), str)]):
        ctx = (node.get("status") or {}).get("context") if isinstance(node.get("status"), dict) else None
        ctx = ctx if isinstance(ctx, dict) else {}
        who = ctx.get("creator") if isinstance(ctx.get("creator"), dict) else {}
        creator = str(who.get("login") or "")
        if ctx and not trusted(who):
            print(f"direct-push quarantine: ignored a {CONTEXT} status ({ctx.get('state')}) on {node['oid'][:12]} "
                  f"from {creator or 'an unknown creator'}; only {CREATOR} posts it", file=sys.stderr)
            ctx = {}
        state = ctx.get("state")
        if state == "SUCCESS":
            found = None
        elif state == "FAILURE" and found is None:
            desc = str(ctx.get("description") or "")
            base, since, by = BASE_RE.search(desc), SINCE_RE.search(desc), BY_RE.search(desc)
            author = node.get("author") or {}
            found = {"culprit": since.group(1) if since else node["oid"][:12], "base": base.group(1) if base else "",
                     "pusher": by.group(1) if by else ((author.get("user") or {}).get("login") or "unknown")}
        if found is not None:
            held.append((node["oid"], found))
    return found, held


def first_parents(tip: str) -> list[str]:
    """TIP's newest DEPTH first-parent commits, newest first: the line request-nightly-next.sh promotes from."""
    out = subprocess.run(["git", "rev-list", "--first-parent", "-n", str(DEPTH), tip], check=True,
                         capture_output=True, text=True, timeout=60).stdout.split()
    shas = [sha for sha in out if SHA_RE.match(sha)]
    if not shas:
        raise ValueError(f"{tip}'s first-parent history unreadable")
    return shas


STATUS_PAGES = 10  # REST lists at most 100 statuses a page; GitHub keeps at most 1000 per commit and context


def trusted(who) -> bool:
    """A status creator is the publisher: a Bot (GraphQL __typename, REST type) with one of CREATOR_LOGINS."""
    who = who if isinstance(who, dict) else {}
    return (who.get("__typename") or who.get("type")) == "Bot" and who.get("login") in CREATOR_LOGINS


def newest_trusted(repo: str, sha: str) -> dict:
    """The publisher's newest CONTEXT status on SHA, as GraphQL's context reads ({} for none), from REST's full status
    list (newest first). GraphQL's status.context(name:) is only the latest status of that context, so a status posted
    over the publisher's FAILURE by anyone else would hide it (Codex BLOCK on #42343 at 28980e76): read only when the
    latest is not the publisher's. A list past STATUS_PAGES raises (unreadable), never reads as no verdict."""
    for page in range(1, STATUS_PAGES + 1):
        got = json.loads(gh("api", f"repos/{repo}/commits/{sha}/statuses?per_page=100&page={page}") or "[]")
        if not isinstance(got, list):
            raise ValueError(f"{sha[:12]}'s statuses unreadable")
        for item in got:
            if isinstance(item, dict) and item.get("context") == CONTEXT and trusted(item.get("creator")):
                return {"state": str(item.get("state") or "").upper(), "description": item.get("description") or "",
                        "creator": {"__typename": "Bot", "login": item["creator"]["login"]}}
        if len(got) < 100:
            return {}
    raise ValueError(f"{sha[:12]} has more than {STATUS_PAGES * 100} statuses; the publisher's may be past them")


def history(repo: str, oid: str) -> list:
    """GraphQL nodes for OID's first-parent commits, newest first; a commit GitHub does not return reads as one with no
    status (an open quarantine still holds it)."""
    shas = first_parents(oid)
    owner, name = repo.split("/", 1)
    out = json.loads(gh("api", "graphql", "-f", f"query={query(shas)}", "-f", f"o={owner}", "-f", f"n={name}"))
    if out.get("errors"):
        raise ValueError(f"graphql errors: {str(out['errors'])[:200]}")
    found = (out.get("data") or {}).get("repository")
    if not isinstance(found, dict):
        raise ValueError(f"{oid}'s history unreadable")
    by_oid = {n["oid"]: n for n in found.values() if isinstance(n, dict) and isinstance(n.get("oid"), str)}
    nodes = [by_oid.get(sha) or {"oid": sha} for sha in shas]
    for node in nodes:
        ctx = (node.get("status") or {}).get("context") if isinstance(node.get("status"), dict) else None
        if isinstance(ctx, dict) and ctx and not trusted(ctx.get("creator")):
            # someone else's status is the latest: the publisher's verdict, if any, is under it
            who = (ctx.get("creator") or {}).get("login") if isinstance(ctx.get("creator"), dict) else None
            print(f"direct-push quarantine: ignored a {CONTEXT} status ({ctx.get('state')}) on {node['oid'][:12]} "
                  f"from {who or 'an unknown creator'}; only {CREATOR} posts it, so its newest status under that "
                  "one is read", file=sys.stderr)
            node["status"] = {"context": newest_trusted(repo, node["oid"])}
    return nodes


def quarantined(args: argparse.Namespace) -> int:
    cache = Path(os.environ["GH_TICK_CACHE"]) / f"quarantine-{args.tip}" if os.environ.get("GH_TICK_CACHE") else None
    if cache is not None and cache.is_file():
        print(cache.read_text(), end="")
        return 0
    try:
        _, held = quarantine_walk(history(args.repo, args.tip))
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired, ValueError, KeyError) as error:
        print(f"direct-push quarantine unreadable: {str(getattr(error, 'stderr', '') or error)[-200:]}",
              file=sys.stderr)
        return 1
    text = "".join(f"{sha} {q['culprit'][:12]} {q['pusher']}\n" for sha, q in held)
    if cache is not None:
        cache.parent.mkdir(parents=True, exist_ok=True)
        cache.write_text(text)
    print(text, end="")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    q = sub.add_parser("quarantined")
    q.add_argument("--repo", required=True)
    q.add_argument("--tip", required=True)
    args = parser.parse_args(argv)
    return quarantined(args)


if __name__ == "__main__":
    sys.exit(main())
