#!/usr/bin/env python3
"""Direct pushes to feat-cmux-next: run the merge gate on each one, and quarantine the branch while one is red.

feat-cmux-next takes direct pushes (no ruleset requires a pull request), and a direct push meets no PR check: in the
week to 2026-11-12, 16 of the branch's base-red fixes repaired a direct push. Leo, asked whether to require pull
requests: "ugh we can just warn/pre-whatever/quarantine stuff idk", and "like run [something] right after a direct
push/some direct pushes potentially". So .github/workflows/cmux-next-direct-push-gates.yml runs the fast gates
(scripts/ci/cmux_next_fast_gates.py, the same gates every pull request meets) on each push that holds a direct commit,
posts CONTEXT on the push's head, and on red warns the pusher in a commit comment. Nothing is ever reverted.

The quarantine is read from those statuses alone. Walking feat-cmux-next's history from the oldest commit read, a red
CONTEXT opens it and a green one closes it; pending, errored and absent statuses change nothing. While it is open the
workflow gates every later push (a PR merge too) against the same last green base, so the first push that fixes or
reverts the red posts green and lifts it. Readers:
- the NEXT nightly (scripts/cmux-next/request-nightly-next.sh) promotes no quarantined commit, so it skips forward
  from the last green base once the red is fixed;
- cmuxterm-hq's base-red-watch pages the base-reds owner once per quarantine, and next-autoland makes no base merge
  onto a quarantined tip.

A direct commit: one that no merged pull request made (GitHub's commits/SHA/pulls names no PR whose merge commit it is)
and whose author is not a bot (a `[bot]` login or name: the base autofix, docs/lessons/fix_causes.py's rule).

    resolve --repo R --before SHA --after SHA [--forced true|false] [--output FILE]
        Writes run=, base=, since=, direct= and reason= (direct, quarantine or none) for the workflow. GH_TOKEN reads.
    prepare --base SHA [--head HEAD] [--output FILE]
        Fetches BASE into this shallow checkout, deepened until it meets HEAD (cmux_next_fast_gates.deepen), and
        writes web= (whether web lint has anything to lint).
    quarantined --repo R --tip SHA
        Prints one line per commit of TIP's recent history that is quarantined: "<sha> <culprit> <pusher>". Exit 1 when
        the history cannot be read. With GH_TICK_CACHE set (nightly-next-tick), the answer is kept there for TIP.

Descriptions (cmuxterm-hq's base_red_watch.quarantine_of parses them): "red: base <sha40> since <sha12> by <login>",
"green: base <sha40>", "cleared: base <sha40> since <sha12>".
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
BRANCH = "feat-cmux-next"
DEPTH = 100  # commits read for the quarantine: the workflow re-posts it on every push while it is open
PULL_READS = 40  # commits whose pull requests are read a push; the rest of a longer push count as direct
SHA = re.compile(r"^[0-9a-f]{40}$")
ZERO = "0" * 40
BASE_RE = re.compile(r"\bbase ([0-9a-f]{40})\b")
SINCE_RE = re.compile(r"\bsince ([0-9a-f]{7,40})\b")
BY_RE = re.compile(r"\bby @?([A-Za-z0-9][A-Za-z0-9-]*(?:\[bot\])?)")
QUERY = ("query($o:String!,$n:String!,$oid:GitObjectID!){repository(owner:$o,name:$n){object(oid:$oid){"
         f"... on Commit{{history(first:{DEPTH}){{nodes{{oid author{{user{{login}} name}} "
         f'status{{context(name:"{CONTEXT}"){{state description}}}}}}}}}}}}}}}}')


def gh(*args: str) -> str:
    return subprocess.run(["gh", *args], check=True, capture_output=True, text=True, timeout=120).stdout


def gh_json(path: str):
    return json.loads(gh("api", path))


def is_bot(author: dict | None, commit_author: dict | None) -> bool:
    login = str((author or {}).get("login") or "")
    name = str((commit_author or {}).get("name") or "")
    return login.endswith("[bot]") or name.endswith("[bot]")


def from_pull_request(sha: str, pulls: list) -> bool:
    return any(isinstance(p, dict) and p.get("merged_at") and p.get("merge_commit_sha") == sha for p in pulls or [])


def direct_commits(commits: list[dict], pulls_of) -> list[str]:
    """The direct commits of a push (compare API commits, oldest first): not a bot's, and not a merged PR's merge
    commit. Past PULL_READS, a non-bot commit counts as direct unread (gating it costs a run; missing it costs a red)."""
    out, reads = [], 0
    for c in commits:
        sha = c.get("sha")
        if not isinstance(sha, str) or is_bot(c.get("author"), (c.get("commit") or {}).get("author")):
            continue
        if reads < PULL_READS:
            reads += 1
            if from_pull_request(sha, pulls_of(sha)):
                continue
        out.append(sha)
    return out


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


def write(path: str | None, values: dict[str, str]) -> None:
    text = "".join(f"{k}={v}\n" for k, v in values.items())
    if path:
        with open(path, "a", encoding="utf-8") as stream:
            stream.write(text)
    print(text, end="")


def decide(before: str, after: str, forced: bool, compare, pulls_of, nodes_at) -> dict[str, str]:
    """The workflow's resolve: whether to gate, against which base, and why."""
    none = {"run": "false", "base": "", "since": "", "direct": "", "reason": "none"}
    if not SHA.match(after) or not SHA.match(before) or before == ZERO:
        return none  # a new or deleted branch: nothing to compare
    data = compare(before, after)
    commits = data.get("commits") or []
    base = before
    if forced or data.get("status") not in ("ahead", "identical"):
        base = ((data.get("merge_base_commit") or {}).get("sha")) or before
    direct = direct_commits(commits, pulls_of)
    try:
        open_q, _ = quarantine_walk(nodes_at(before))
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, ValueError, KeyError):
        open_q = None  # unread: a direct push is still gated against its own base below
    if open_q is not None and SHA.match(open_q.get("base") or ""):
        return {"run": "true", "base": open_q["base"], "since": open_q["culprit"][:12], "direct": " ".join(direct),
                "reason": "quarantine"}
    if direct:
        return {"run": "true", "base": base, "since": direct[0][:12], "direct": " ".join(direct), "reason": "direct"}
    return none


def resolve(args: argparse.Namespace) -> int:
    def compare(before, after):
        return gh_json(f"repos/{args.repo}/compare/{before}...{after}?per_page=100")

    def pulls_of(sha):
        return gh_json(f"repos/{args.repo}/commits/{sha}/pulls")

    write(args.output, decide(args.before, args.after, args.forced == "true", compare, pulls_of,
                              lambda oid: history(args.repo, oid)))
    return 0


def prepare(args: argparse.Namespace) -> int:
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import cmux_next_fast_gates as gates  # noqa: PLC0415  (the fast gates' own deepen and web plan)

    repo = Path.cwd()
    if not SHA.match(args.base):
        print(f"direct-push gates: --base must be a full sha, not {args.base!r}", file=sys.stderr)
        return 2
    head = gates.rev(repo, args.head)
    if gates.git(repo, "rev-parse", "--is-shallow-repository").stdout.strip() == "true":
        gates.git(repo, "fetch", "--no-tags", "--quiet", f"--depth={gates.FETCH_DEPTH}", "origin", args.base)
    gates.deepen(repo, "origin", [args.base, head], head, args.base)
    if gates.git(repo, "merge-base", "--is-ancestor", args.base, head, check=False).returncode:
        print(f"direct-push gates: {args.base} is not an ancestor of {head}", file=sys.stderr)
        return 1
    write(args.output, {"web": "true" if gates.web_needed(repo, args.base, head) else "false"})
    return 0


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
    r = sub.add_parser("resolve")
    r.add_argument("--repo", required=True)
    r.add_argument("--before", required=True)
    r.add_argument("--after", required=True)
    r.add_argument("--forced", choices=("true", "false"), default="false")
    r.add_argument("--output")
    p = sub.add_parser("prepare")
    p.add_argument("--base", required=True)
    p.add_argument("--head", default="HEAD")
    p.add_argument("--output")
    q = sub.add_parser("quarantined")
    q.add_argument("--repo", required=True)
    q.add_argument("--tip", required=True)
    args = parser.parse_args(argv)
    return {"resolve": resolve, "prepare": prepare, "quarantined": quarantined}[args.command](args)


if __name__ == "__main__":
    sys.exit(main())
