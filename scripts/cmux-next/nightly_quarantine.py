#!/usr/bin/env python3
"""Which commits of feat-cmux-next the direct-push quarantine holds, for the NEXT nightly (request-nightly-next.sh).

feat-cmux-next takes direct pushes, and a direct push meets no PR check. Leo, 2026-11-12, asked whether to require pull
requests: "ugh we can just warn/pre-whatever/quarantine stuff idk", and "like run [something] right after a direct
push/some direct pushes potentially". cmux adds no CI for it (CLAUDE.md: "Never add CI gates ... CI jobs or steps"):
cmuxterm-hq's base-red-watch reads feat-cmux-next's own push runs, and when a confirmed red's every suspect is a direct
push it posts CONTEXT `failure` on that commit, then `success` on the tip once it is fixed or reverted. Nothing is
reverted. This reads those statuses only: walking the branch's history from the oldest commit read, a red CONTEXT
opens the quarantine and a green one closes it; pending, errored and absent statuses change nothing.

    quarantined --repo R --tip SHA
        Prints one line per quarantined commit of TIP's recent history: "<sha> <culprit> <pusher>". Exit 1 when the
        history cannot be read. With GH_TICK_CACHE set (nightly-next-tick), the answer is kept there for TIP.

Descriptions (posted by cmuxterm-hq's base_red_watch.direct_push_verdicts): "red: base <sha40> since <sha12> by
<login>", "cleared: base <sha40> since <sha12>".
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
DEPTH = 100  # commits read: the nightly promotes from the tip's recent history
BASE_RE = re.compile(r"\bbase ([0-9a-f]{40})\b")
SINCE_RE = re.compile(r"\bsince ([0-9a-f]{7,40})\b")
BY_RE = re.compile(r"\bby @?([A-Za-z0-9][A-Za-z0-9-]*(?:\[bot\])?)")
QUERY = ("query($o:String!,$n:String!,$oid:GitObjectID!){repository(owner:$o,name:$n){object(oid:$oid){"
         f"... on Commit{{history(first:{DEPTH}){{nodes{{oid author{{user{{login}} name}} "
         f'status{{context(name:"{CONTEXT}"){{state description}}}}}}}}}}}}}}}}')


def gh(*args: str) -> str:
    return subprocess.run(["gh", *args], check=True, capture_output=True, text=True, timeout=120).stdout


def quarantine_walk(nodes: list) -> tuple[dict | None, list[tuple[str, dict]]]:
    """(the open quarantine after the newest node, [(sha, quarantine)] for each node it holds), from GraphQL history
    nodes, newest first. A red CONTEXT opens it, a green one closes it; anything else changes nothing."""
    found, held = None, []
    for node in reversed([n for n in nodes or [] if isinstance(n, dict) and isinstance(n.get("oid"), str)]):
        ctx = (node.get("status") or {}).get("context") if isinstance(node.get("status"), dict) else None
        state = (ctx or {}).get("state")
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


def history(repo: str, oid: str) -> list:
    owner, name = repo.split("/", 1)
    out = json.loads(gh("api", "graphql", "-f", f"query={QUERY}", "-f", f"o={owner}", "-f", f"n={name}",
                        "-f", f"oid={oid}"))
    if out.get("errors"):
        raise ValueError(f"graphql errors: {str(out['errors'])[:200]}")
    nodes = ((((out.get("data") or {}).get("repository") or {}).get("object") or {}).get("history") or {}).get("nodes")
    if not isinstance(nodes, list):
        raise ValueError(f"{oid}'s history unreadable")
    return nodes


def quarantined(args: argparse.Namespace) -> int:
    cache = Path(os.environ["GH_TICK_CACHE"]) / f"quarantine-{args.tip}" if os.environ.get("GH_TICK_CACHE") else None
    if cache is not None and cache.is_file():
        print(cache.read_text(), end="")
        return 0
    try:
        _, held = quarantine_walk(history(args.repo, args.tip))
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, ValueError, KeyError) as error:
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
