#!/usr/bin/env python3
"""How often a react-apps-check shard could reuse a pass keyed by its inputs, not the whole tree.

    webviews-shard-receipt-hits.py --since 2026-11-19T00:00Z --until 2026-11-21T00:00Z [--max-pairs N] [--json]

A pull request's react-apps-check shards test its merge commit: the head merged onto the base as it was at the push.
A pass receipt keyed by a set of paths answers a later head only when that head's merge commit holds the same blobs
at every one of those paths. This replays that on local git data, no GitHub reads:

  - heads: consecutive commits on the origin branches (one push is about one commit on agent lanes), with their
    committer times inside the window, that are not on the base;
  - the merge commit of each head: `git merge-tree --write-tree` of it onto the newest first-parent base commit no
    newer than it (a head that conflicts is skipped);
  - a later head counts only when its merge commit routes the webview suite (its diff from the base touches the
    webviews inputs; else no shard runs);
  - a hit: its key equals the earlier head's, for each key below.

Keys (the paths whose blobs the key holds):
  narrow   webviews_test_history.py `inputs`: web_subareas.py's react lists and the web bundle's routed inputs;
  safe     narrow plus what the shard is seen to read beyond it: the CmuxNext Swift sources and cmux-tui (webview
           tests and the protocol codegen check read them), schemas, plans, scripts, tests, .github, clients and the
           root configs the shard-1 hooks tests read.

Also prints how many first-parent base commits in the window touch each key: a pair of heads with k base commits
between them keeps its key only if none of them does.
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from bisect import bisect_right
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import web_subareas as ws  # noqa: E402

SAFE_EXTRA = ("Packages/macOS/CmuxNext/Sources", "cmux-tui", "schemas", "plans", "scripts", "tests", ".github",
              "clients", "web/data", ".claude/settings.json", ".codex/hooks.json", "package.json", ".gitattributes")


def git(*args: str, check: bool = True) -> str:
    return subprocess.run(["git", "-C", str(ROOT), *args], capture_output=True, text=True, check=check).stdout


def narrow_paths() -> list[str]:
    routed = subprocess.run([sys.executable, str(ROOT / "scripts/cmux-next/web-bundle-key.py"), str(ROOT), "--routed"],
                            capture_output=True, text=True, check=True).stdout.split()
    return sorted({p.rstrip("/") for p in (*ws.REACT_PREFIXES, *ws.REACT_EXACT, *ws.ALL_SUBAREA_INPUTS,
                                           "scripts/ci/pin-browser-test-font.sh", *routed)})


def matcher(paths: list[str]):
    rx = [re.compile(re.escape(p[7:]).replace(r"\*", "[^/]*") + "$") if p.startswith(":(glob)")
          else re.compile(re.escape(p) + "(/|$)") for p in paths]
    return lambda f: any(x.match(f) for x in rx)


def key(tree: str, paths: list[str]) -> str:
    return git("ls-tree", "-r", tree, "--", *[p for p in paths if not p.startswith(":(")]) + \
        git("ls-tree", "-r", "--full-tree", tree, "--", "release-notes/next/highlights")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--since", required=True)
    ap.add_argument("--until", required=True)
    ap.add_argument("--base", default="origin/feat-cmux-next")
    ap.add_argument("--max-pairs", type=int, default=600)
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args(argv)

    narrow = narrow_paths()
    safe = sorted(set(narrow) | set(SAFE_EXTRA))
    touches = {"narrow": matcher(narrow), "safe": matcher(safe)}

    base = [line.split() for line in git("log", "--first-parent", f"--since={args.since}", f"--until={args.until}",
                                         "--format=%ct %H", args.base).splitlines() if line]
    base.sort()
    times = [int(t) for t, _ in base]
    base_touch = {name: 0 for name in touches}
    for _, sha in base:
        files = git("diff", "--name-only", "--no-renames", f"{sha}^1", sha).split()
        for name, hit in touches.items():
            base_touch[name] += any(hit(f) for f in files)

    since = int(git("log", "-1", "--format=%ct", f"--until={args.since}", args.base).strip() or 0)
    until = times[-1] if times else 0
    refs = [line.split() for line in git("for-each-ref", "--format=%(committerdate:unix) %(refname)",
                                         "refs/remotes/origin").splitlines()]
    refs = [r for t, r in refs if since <= int(t) <= until + 86400 and not r.endswith("/HEAD")]
    pairs, merge_cache = [], {}

    def merged(commit: str, when: int) -> str | None:
        if commit in merge_cache:
            return merge_cache[commit]
        i = bisect_right(times, when) - 1
        out = None
        if i >= 0:
            run = subprocess.run(["git", "-C", str(ROOT), "merge-tree", "--write-tree", base[i][1], commit],
                                 capture_output=True, text=True)
            if run.returncode == 0:
                out = f"{base[i][1]} {run.stdout.split()[0]}"
        merge_cache[commit] = out
        return out

    for ref in refs:
        commits = [line.split() for line in git("log", "--reverse", "--format=%ct %H", f"{args.base}..{ref}",
                                                check=False).splitlines() if line]
        commits = [(int(t), c) for t, c in commits if times and times[0] <= int(t) <= until]
        for (t1, c1), (t2, c2) in zip(commits, commits[1:]):
            pairs.append((t1, c1, t2, c2))
        if len(pairs) >= args.max_pairs:
            break
    pairs = pairs[:args.max_pairs]

    counted = {"pairs": 0, "routed": 0, "narrow": 0, "safe": 0, "same_merge_tree": 0}
    for t1, c1, t2, c2 in pairs:
        counted["pairs"] += 1
        m1, m2 = merged(c1, t1), merged(c2, t2)
        if not m1 or not m2:
            continue
        b2, tree2 = m2.split()
        if not any(touches["narrow"](f) for f in git("diff", "--name-only", "--no-renames", b2, tree2).split()):
            continue
        counted["routed"] += 1
        tree1 = m1.split()[1]
        counted["same_merge_tree"] += tree1 == tree2
        for name, paths in (("narrow", narrow), ("safe", safe)):
            counted[name] += key(tree1, paths) == key(tree2, paths)
    report = {"base_commits": len(base), "base_commits_touching": base_touch, "heads": counted}
    if args.json:
        print(json.dumps(report, indent=1))
    else:
        print(f"base: {len(base)} first-parent commits; touching narrow {base_touch['narrow']}, safe {base_touch['safe']}")
        r = counted["routed"] or 1
        print(f"head pairs: {counted['pairs']}, later head routes the webview suite: {counted['routed']}")
        for name in ("same_merge_tree", "narrow", "safe"):
            print(f"  {name}: {counted[name]} hits ({100 * counted[name] / r:.1f}% of routed later heads)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
