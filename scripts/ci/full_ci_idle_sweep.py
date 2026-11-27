#!/usr/bin/env python3
"""Take a stale `full-ci` off idle lane pull requests into feat-cmux-next.

`full-ci` makes every later head of a pull request run the full suite (scripts/ci/head_tier.py), base merges
included, and nothing takes it off: land no longer adds it, and an agent lane that added it to get past a stuck
land tier moves on. 2026-11-26 13:15-16:28Z: 141 open pull requests carried it, 89 of them lane pull requests with
no commit of their own and no label add for 6 h; a sample of 40 labelled pull requests spent 6,446 runner-min in
the window, about 24% of all 78,454 (the per-merged-PR goal ci-usage-per-pr-10x). leo-workspace
tools/land_tier_sweep.py --label full-ci does the same clear, but a lane VM's broker refuses a label edit on
another lane's branch, so only a token here can run it on every lane's pull requests.

A pull request is cleared only when all hold:
  - it is open, into feat-cmux-next, from this repository, on a `lane/` branch (an agent lane's): a person's own
    `full-ci` is their opt-in and stays;
  - it does not carry `ready-to-land` (its land may be live; the land tier runs either way then);
  - and either: its newest commit that is not a base merge, and its newest `full-ci` add, are both IDLE_HOURS
    (default 6) old (a base merge is not activity: update-branch heads land every few hours on an open pull request);
    or its newest `full-ci` add is older than its newest commit, base merges included (stale head): the add ran the
    full tier at the head it was added on, and every later head inherits it. That is what a lane's add means since
    the broker and tools/gh_full_ci_pulse.py make it a pulse (off, on, off; no later head inherits it); a label from
    before the pulse stayed on busy lanes the idle rule never reaches. 2026-11-26 21:50Z: 52 open pull requests
    carried full-ci, 30 of them lane pull requests updated in the last 6 h. When no add of the label was read, only
    the idle rule applies.

Removing a label with the workflow token starts no workflow, and the routers skip `unlabeled` events anyway.
Dry run unless --apply. Capped by --max a run (default 100), --pace seconds apart.

    python3 scripts/ci/full_ci_idle_sweep.py [--repo OWNER/NAME] [--idle-hours 6] [--max 100] [--pace 1] [--apply]
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import subprocess
import sys
import time
from typing import Callable, Dict, List, Optional

LABEL = "full-ci"
LAND = "ready-to-land"
BASE = "feat-cmux-next"

SEARCH = """query($q: String!, $after: String) { search(query: $q, type: ISSUE, first: 50, after: $after) {
  pageInfo { hasNextPage endCursor }
  nodes { ... on PullRequest { number baseRefName headRefName isCrossRepository labels(first: 30) { nodes { name } }
    commits(last: 30) { nodes { commit { committedDate messageHeadline parents(first: 2) { totalCount } } } }
    timelineItems(last: 20, itemTypes: [LABELED_EVENT]) { nodes { ... on LabeledEvent { createdAt label { name } } } }
  } } } }"""


def parse_time(value: str) -> float:
    return dt.datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()


def is_base_merge(commit: Dict, base: str) -> bool:
    """A two-parent commit whose headline merges BASE in (`Merge branch 'feat-cmux-next' into x`,
    `Merge remote-tracking branch 'origin/feat-cmux-next'`, `Merge origin/feat-cmux-next into lane/x`)."""
    head = str(commit.get("messageHeadline") or "")
    if int((commit.get("parents") or {}).get("totalCount") or 0) != 2 or not base:
        return False
    return head.lower().startswith("merge") and re.search(
        r"(?<![\w/-])(origin/)?" + re.escape(base) + r"(?![\w/-])", head) is not None


def last_activity(pr: Dict) -> Optional[float]:
    """The newest of: a commit that is not a base merge, an add of LABEL. None when no commit was read."""
    commits = pr.get("commits") or []
    if not commits:
        return None
    base = str(pr.get("baseRefName") or "")
    times = [parse_time(str(c["committedDate"])) for c in commits
             if c.get("committedDate") and not is_base_merge(c, base)]
    times += [parse_time(str(e["createdAt"])) for e in pr.get("labelAdds") or []
              if e.get("createdAt") and e.get("label") == LABEL]
    # Every read commit a base merge, no add read: the pull request's own change is older still.
    return max(times, default=0.0)


def stale_head(pr: Dict) -> bool:
    """The newest read add of LABEL is older than the newest read commit (base merges count: each runs the tier)."""
    adds = [parse_time(str(e["createdAt"])) for e in pr.get("labelAdds") or []
            if e.get("createdAt") and e.get("label") == LABEL]
    commits = [parse_time(str(c["committedDate"])) for c in pr.get("commits") or [] if c.get("committedDate")]
    return bool(adds) and bool(commits) and max(commits) > max(adds)


def select(prs: List[Dict], now: float, idle_hours: float) -> List[Dict]:
    keep = []
    for pr in prs:
        labels = set(pr.get("labels") or [])
        if LABEL not in labels or LAND in labels:
            continue
        if pr.get("baseRefName") != BASE or pr.get("isCrossRepository"):
            continue
        if not str(pr.get("headRefName") or "").startswith("lane/"):
            continue
        last = last_activity(pr)
        idle = last is not None and now - last >= idle_hours * 3600
        if not idle and not stale_head(pr):
            continue
        keep.append(pr)
    return keep


def shape(node: Dict) -> Dict:
    return {"number": node["number"], "baseRefName": node.get("baseRefName"), "headRefName": node.get("headRefName"),
            "isCrossRepository": bool(node.get("isCrossRepository")),
            "labels": [lb.get("name") for lb in (node.get("labels") or {}).get("nodes") or [] if lb],
            "commits": [c["commit"] for c in (node.get("commits") or {}).get("nodes") or [] if c and c.get("commit")],
            "labelAdds": [{"createdAt": e.get("createdAt"), "label": (e.get("label") or {}).get("name")}
                          for e in (node.get("timelineItems") or {}).get("nodes") or [] if e]}


def gh(argv: List[str]) -> subprocess.CompletedProcess:
    return subprocess.run(["gh"] + argv, capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=120,
                          check=False)


def read_prs(repo: str, run: Callable = gh) -> List[Dict]:
    out, after = [], None
    for _ in range(20):
        argv = ["api", "graphql", "-f", "query=" + SEARCH,
                "-f", "q=repo:%s is:pr is:open base:%s label:%s" % (repo, BASE, LABEL)]
        if after:
            argv += ["-f", "after=" + after]
        done = run(argv)
        if done.returncode != 0:
            raise SystemExit("full_ci_idle_sweep: could not list %s's %s pull requests: %s"
                             % (repo, LABEL, (done.stderr or "").strip()[:300]))
        page = json.loads(done.stdout or "{}")["data"]["search"]
        out += [shape(n) for n in page["nodes"] if n and n.get("number")]
        if not page["pageInfo"]["hasNextPage"]:
            break
        after = page["pageInfo"]["endCursor"]
    return out


def remove(repo: str, number: int, run: Callable = gh) -> str:
    done = run(["api", "-X", "DELETE", "repos/%s/issues/%d/labels/%s" % (repo, number, LABEL)])
    said = (done.stderr or done.stdout or "").strip()
    if done.returncode != 0 and "HTTP 404" not in said and "not found" not in said.lower():
        return said[:300] or "exit %d" % done.returncode
    return ""


def main(argv: Optional[List[str]] = None, run: Callable = gh, now: Optional[float] = None,
         sleep: Callable = time.sleep) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--repo", default=os.environ.get("GH_REPO") or "manaflow-ai/cmux")
    ap.add_argument("--idle-hours", type=float, default=6.0)
    ap.add_argument("--max", type=int, default=100)
    ap.add_argument("--pace", type=float, default=1.0)
    ap.add_argument("--apply", action="store_true")
    a = ap.parse_args(argv)
    prs = read_prs(a.repo, run)
    picked = select(prs, time.time() if now is None else now, a.idle_hours)
    print("full_ci_idle_sweep: %s: %d open pull requests into %s carry %s; %d are lane pull requests without %s, "
          "idle >= %g h by their last non-base-merge commit or label add, or with a commit after the label add%s"
          % (a.repo, len(prs), BASE, LABEL, len(picked), LAND, a.idle_hours, "" if a.apply else " (dry run)"))
    for pr in picked:
        print("  #%d %s" % (pr["number"], pr["headRefName"]))
    if not a.apply:
        return 0
    removed = 0
    for pr in picked[:a.max]:
        if removed:
            sleep(a.pace)
        err = remove(a.repo, int(pr["number"]), run)
        if err:
            print("full_ci_idle_sweep: stopped at #%d after %d removed: %s" % (pr["number"], removed, err),
                  file=sys.stderr)
            return 1
        removed += 1
    print("full_ci_idle_sweep: removed %s from %d pull requests" % (LABEL, removed))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
