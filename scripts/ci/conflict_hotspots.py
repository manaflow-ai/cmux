#!/usr/bin/env python3
"""Merge-conflict hotspots: which files make concurrent cmux PRs collide.

Two steps, so the GitHub half runs where `gh` is and the git half where the clone is:

  fetch  --repo manaflow-ai/cmux --git-dir DIR --ref REF --days 14 --out prs.json
         One batched GraphQL query per 50 PRs: createdAt and every commit headline (to find
         "Merge feat-cmux-next into ..." / "Merge branch ..." syncs). PR numbers come from the
         squash subjects "(#N)" on REF's first-parent history, so pass --git-dir of any clone.
  analyze --git-dir DIR --ref REF --prs prs.json --days 14 [--jobs 8] [--out report.json]
         Pure git. Per file: PRs that touched it, PR pairs open at the same time that both
         touched it, sync-merge commits whose window it was in on both sides, and a replay:
         `git merge-tree` of each squash against the base as it was when the PR opened (what
         an author who never synced would have hit), listing the files that conflict.

  split --git-dir DIR --ref REF --prs prs.json --file PATH [--file PATH ...]
         For each PR whose replay conflicts on PATH: did it only add lines there (numstat, nothing
         removed)? Those are the entries a one-file-per-entry directory turns into new files, which
         cannot conflict; the rest edited existing lines and conflict in either layout.

Same harness before and after a fix: rerun `analyze` and compare the file's rows. First used for
scripts/ci/entry_logs.py (2026-11-25): run on a Linux host against a cmux mirror, about 25 min of
GraphQL (148 queries, cost 1 each) and 3 min of `git merge-tree` for 14 days.
"""
from __future__ import annotations

import argparse
import bisect
import collections
import concurrent.futures
import datetime as dt
import json
import re
import subprocess
import sys

PR_RE = re.compile(r"\(#(\d+)\)\s*$")
SYNC_RE = re.compile(
    r"^Merge (branch '[^']+'|remote-tracking branch '[^']+'|(origin/)?(feat-cmux-next|main)\b|.* into )"
)


def git(git_dir: str, *args: str, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["git", f"--git-dir={git_dir}", *args], text=True, capture_output=True, check=check
    )


def parse_time(s: str) -> float:
    return dt.datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()


def first_parent_log(git_dir: str, ref: str, since: str) -> list[dict]:
    """Squash commits on REF: sha, parent, time, pr, files."""
    out = git(
        git_dir, "log", "--first-parent", f"--since={since}", "--no-merges", "--name-only",
        "--format=%x00%H %P%x01%ct%x01%s", ref,
    ).stdout
    commits = []
    for block in out.split("\0")[1:]:
        head, _, files = block.partition("\n")
        shas, ct, subject = head.split("\x01", 2)
        sha, *parents = shas.split()
        m = PR_RE.search(subject)
        commits.append({
            "sha": sha, "parent": parents[0] if parents else None, "time": int(ct),
            "subject": subject, "pr": int(m.group(1)) if m else None,
            "files": [f for f in files.split("\n") if f],
        })
    commits.reverse()  # oldest first
    return commits


def cmd_fetch(a: argparse.Namespace) -> None:
    commits = first_parent_log(a.git_dir, a.ref, f"{a.days} days ago")
    numbers = sorted({c["pr"] for c in commits if c["pr"]})
    have = {}
    try:
        have = {int(k): v for k, v in json.load(open(a.out)).items()}
    except (OSError, ValueError):
        pass
    todo = [n for n in numbers if n not in have]
    owner, name = a.repo.split("/")
    print(f"{len(numbers)} PRs, {len(todo)} to fetch", file=sys.stderr)
    for i in range(0, len(todo), a.batch):
        chunk = todo[i:i + a.batch]
        fields = " ".join(
            f"p{n}: pullRequest(number: {n}) {{ number createdAt mergedAt baseRefName "
            f"commits(first: 100) {{ totalCount nodes {{ commit {{ messageHeadline committedDate }} }} }} }}"
            for n in chunk
        )
        q = f'query {{ repository(owner: "{owner}", name: "{name}") {{ {fields} }} rateLimit {{ cost remaining }} }}'
        r = subprocess.run(["gh", "api", "graphql", "-f", f"query={q}"], text=True, capture_output=True)
        if r.returncode != 0 and not r.stdout:
            sys.exit(f"graphql failed: {r.stderr[:500]}")
        data = json.loads(r.stdout).get("data") or {}
        repo = data.get("repository") or {}
        for n in chunk:
            pr = repo.get(f"p{n}")
            if not pr:
                continue
            have[n] = {
                "createdAt": pr["createdAt"], "mergedAt": pr["mergedAt"], "base": pr["baseRefName"],
                "commitCount": pr["commits"]["totalCount"],
                "commits": [[c["commit"]["messageHeadline"], c["commit"]["committedDate"]]
                            for c in pr["commits"]["nodes"]],
            }
        rl = data.get("rateLimit") or {}
        print(f"  {i + len(chunk)}/{len(todo)} cost={rl.get('cost')} remaining={rl.get('remaining')}",
              file=sys.stderr)
        json.dump(have, open(a.out, "w"))
    json.dump(have, open(a.out, "w"))


def replay(git_dir: str, parent: str, squash: str, base_then: str) -> list[str]:
    """Files that conflict when the PR's change meets the base it would have opened against."""
    if parent == base_then:
        return []
    r = git(git_dir, "merge-tree", "--write-tree", "--name-only", "--no-messages",
            f"--merge-base={parent}", squash, base_then, check=False)
    if r.returncode == 0:
        return []
    lines = r.stdout.splitlines()
    return sorted(set(lines[1:]))


def cmd_analyze(a: argparse.Namespace) -> None:
    prs = {int(k): v for k, v in json.load(open(a.prs)).items()}
    # Base history for windows reaches back past the 14 days: PRs opened before it.
    history = first_parent_log(a.git_dir, a.ref, f"{a.days + a.lookback} days ago")
    cutoff = dt.datetime.now(dt.timezone.utc).timestamp() - a.days * 86400
    times = [c["time"] for c in history]
    merged = [c for c in history if c["time"] >= cutoff and c["pr"] in prs
              and prs[c["pr"]]["base"] == a.base]

    def base_at(t: float) -> int:
        return max(0, bisect.bisect_right(times, t) - 1)

    def base_files_between(t0: float, t1: float) -> set[str]:
        i0, i1 = bisect.bisect_right(times, t0), bisect.bisect_right(times, t1)
        out: set[str] = set()
        for c in history[i0:i1]:
            out.update(c["files"])
        return out

    touch = collections.defaultdict(list)  # file -> [(start, end, pr)]
    sync_files = collections.Counter()
    sync_prs = collections.defaultdict(set)
    syncs_total = 0
    prs_with_sync = 0
    jobs = []
    for c in merged:
        p = prs[c["pr"]]
        start, end = parse_time(p["createdAt"]), c["time"]
        files = set(c["files"])
        for f in files:
            touch[f].append((start, end, c["pr"]))
        sync_times = sorted(parse_time(t) for h, t in p["commits"] if SYNC_RE.match(h))
        if sync_times:
            prs_with_sync += 1
        prev = start
        for st in sync_times:
            syncs_total += 1
            for f in files & base_files_between(prev, st):
                sync_files[f] += 1
                sync_prs[f].add(c["pr"])
            prev = max(prev, st)
        bi = base_at(start)
        if history[bi]["time"] <= start and c["parent"]:
            jobs.append((c["pr"], c["parent"], c["sha"], history[bi]["sha"]))

    replay_files = collections.Counter()
    replay_conflicted = 0
    with concurrent.futures.ThreadPoolExecutor(a.jobs) as pool:
        futs = {pool.submit(replay, a.git_dir, par, sq, b0): pr for pr, par, sq, b0 in jobs}
        for fut in concurrent.futures.as_completed(futs):
            files = fut.result()
            if files:
                replay_conflicted += 1
            replay_files.update(files)

    rows = []
    for f, iv in touch.items():
        iv.sort()
        pairs = 0
        concurrent_prs: set[int] = set()
        ends: list[tuple[float, int]] = []  # active (end, pr)
        for s, e, pr in iv:
            ends = [(e2, p2) for e2, p2 in ends if e2 > s]
            if ends:
                pairs += len(ends)
                concurrent_prs.add(pr)
                concurrent_prs.update(p2 for _, p2 in ends)
            ends.append((e, pr))
        rows.append({
            "file": f, "prs": len(iv), "concurrent_prs": len(concurrent_prs), "pairs": pairs,
            "sync_merges": sync_files.get(f, 0), "sync_prs": len(sync_prs.get(f, ())),
            "replay_conflicts": replay_files.get(f, 0),
        })
    rows.sort(key=lambda r: (r["replay_conflicts"], r["sync_merges"], r["pairs"]), reverse=True)
    report = {
        "ref": a.ref, "head": git(a.git_dir, "rev-parse", a.ref).stdout.strip(), "days": a.days,
        "merged_prs": len(merged), "prs_with_sync_merge": prs_with_sync, "sync_merges": syncs_total,
        "replayed": len(jobs), "replay_conflicted_prs": replay_conflicted, "files": rows,
    }
    if a.out:
        json.dump(report, open(a.out, "w"), indent=1)
    print(f"{report['merged_prs']} merged PRs; {prs_with_sync} carry {syncs_total} sync merges; "
          f"replay: {replay_conflicted} of {len(jobs)} conflict against the base they opened on")
    print(f"{'replay':>6} {'syncs':>5} {'syncPR':>6} {'pairs':>6} {'concPR':>6} {'PRs':>4}  file")
    for r in rows[: a.top]:
        print(f"{r['replay_conflicts']:>6} {r['sync_merges']:>5} {r['sync_prs']:>6} {r['pairs']:>6} "
              f"{r['concurrent_prs']:>6} {r['prs']:>4}  {r['file']}")


def cmd_split(a: argparse.Namespace) -> None:
    prs = {int(k): v for k, v in json.load(open(a.prs)).items()}
    history = first_parent_log(a.git_dir, a.ref, f"{a.days + a.lookback} days ago")
    cutoff = dt.datetime.now(dt.timezone.utc).timestamp() - a.days * 86400
    times = [c["time"] for c in history]
    for path in a.file:
        touched = conflicted = pure = 0
        for c in history:
            if c["time"] < cutoff or c["pr"] not in prs or path not in c["files"] or not c["parent"]:
                continue
            touched += 1
            start = parse_time(prs[c["pr"]]["createdAt"])
            b0 = history[max(0, bisect.bisect_right(times, start) - 1)]["sha"]
            if path not in replay(a.git_dir, c["parent"], c["sha"], b0):
                continue
            conflicted += 1
            stat = git(a.git_dir, "diff", "--numstat", "--no-renames", c["parent"], c["sha"], "--", path).stdout.split()
            if stat and stat[1] == "0":
                pure += 1
        print(f"{path}: {touched} PRs, {conflicted} conflict in replay; {pure} of those only added lines "
              f"(0 conflicts as entry files), {conflicted - pure} edited existing lines")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    f = sub.add_parser("fetch")
    f.add_argument("--repo", default="manaflow-ai/cmux")
    f.add_argument("--git-dir", required=True)
    f.add_argument("--ref", default="origin/feat-cmux-next")
    f.add_argument("--days", type=int, default=14)
    f.add_argument("--batch", type=int, default=50)
    f.add_argument("--out", required=True)
    f.set_defaults(fn=cmd_fetch)
    an = sub.add_parser("analyze")
    an.add_argument("--git-dir", required=True)
    an.add_argument("--ref", default="origin/feat-cmux-next")
    an.add_argument("--base", default="feat-cmux-next")
    an.add_argument("--prs", required=True)
    an.add_argument("--days", type=int, default=14)
    an.add_argument("--lookback", type=int, default=14, help="extra days of base history for old PRs")
    an.add_argument("--jobs", type=int, default=8)
    an.add_argument("--top", type=int, default=40)
    an.add_argument("--out")
    an.set_defaults(fn=cmd_analyze)
    sp = sub.add_parser("split")
    sp.add_argument("--git-dir", required=True)
    sp.add_argument("--ref", default="origin/feat-cmux-next")
    sp.add_argument("--prs", required=True)
    sp.add_argument("--file", action="append", required=True)
    sp.add_argument("--days", type=int, default=14)
    sp.add_argument("--lookback", type=int, default=14)
    sp.set_defaults(fn=cmd_split)
    a = ap.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
