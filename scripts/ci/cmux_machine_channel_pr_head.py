#!/usr/bin/env python3
"""Find the merged PR head's machine channel build for a feat-cmux-next push (PR_HEAD_FAST_LANE).

`find SHA` prints the pr-router run id whose machine-channel-* artifacts are this merge's code, or
nothing. It holds when SHA is the squash merge of a same-repository PR into feat-cmux-next whose head has
SHA's v2 tree key (an up-to-date head squashes to its own tree), and that head's pr-router run built
both thin Linux targets. A head behind the base squashes to another tree (every one of 18 merges on
2026-11-26 11:00-13:00Z), so a merge the train landed takes the train's combined tip instead: the
lane/merge-train head whose git tree is SHA's (its last member's squash is the tip's tree). A run
still building is waited for up to --wait seconds; any miss prints nothing and the push run builds
as before (.github/workflows/cmux-machine-channel.yml).
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Callable

ROOT = Path(__file__).resolve().parents[2]
TARGETS = ("x86_64-unknown-linux-musl", "aarch64-unknown-linux-musl")
BASE = "feat-cmux-next"
ROUTER = "pr-router.yml"
# The merge train's combined tip (cmuxterm-hq tools/fleet-reconcilers/merge_train.py; standing PR #55855).
TRAIN_TIP = "lane/merge-train"
# The callee's job names in a pr-router run ("<caller> / <job>"): plan and the two builds.
JOB_MARKS = ("does the machine channel need this commit", "build-machine-channel")

Api = Callable[[str], object]


def log(msg: str) -> None:
    print(f"pr-head: {msg}", file=sys.stderr)


def github_api(repo: str, token: str) -> Api:
    def get(path: str) -> object:
        req = urllib.request.Request(
            f"https://api.github.com/repos/{repo}/{path}",
            headers={"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json"},
        )
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                return json.load(r)
        except urllib.error.HTTPError as exc:
            # The refusal's own words: a spent quota and a missing permission are both a 403.
            body = exc.read(300).decode("utf-8", "replace").replace("\n", " ")
            raise RuntimeError(f"{path}: HTTP {exc.code}: {body}") from exc

    return get


def tree_key(rev: str) -> str:
    subprocess.run(
        ["git", "-C", str(ROOT), "fetch", "--no-tags", "--depth=1", "origin", rev],
        check=False, capture_output=True, timeout=120,
    )
    out = subprocess.run(
        [sys.executable, str(ROOT / "scripts/ci/cmux_tui_tree_key.py"), "--version", "v2", rev],
        check=False, capture_output=True, text=True, timeout=120,
    )
    return out.stdout.strip() if out.returncode == 0 else ""


def git_tree(rev: str) -> str:
    out = subprocess.run(
        ["git", "-C", str(ROOT), "rev-parse", f"{rev}^{{tree}}"],
        check=False, capture_output=True, text=True, timeout=60,
    )
    return out.stdout.strip() if out.returncode == 0 else ""


def train_tip(api: Api, tree: str) -> str:
    """The newest merge train tip whose tree is TREE, or ''."""
    if not tree:
        return ""
    branch = urllib.parse.quote(TRAIN_TIP, safe="")
    runs = (api(f"actions/workflows/{ROUTER}/runs?branch={branch}&event=pull_request&per_page=30") or {}).get(
        "workflow_runs", []
    )
    for run in sorted(runs, key=lambda r: r.get("id", 0), reverse=True):
        if (run.get("head_commit") or {}).get("tree_id") == tree:
            return run.get("head_sha") or ""
    return ""


def merged_head(api: Api, repo: str, sha: str) -> str:
    for pr in api(f"commits/{sha}/pulls") or []:
        head = pr.get("head") or {}
        if (
            pr.get("merge_commit_sha") == sha
            and (pr.get("base") or {}).get("ref") == BASE
            and ((head.get("repo") or {}).get("full_name") == repo)
        ):
            return head.get("sha") or ""
    return ""


def artifacts_ready(api: Api, run_id: int, prefix: str) -> bool:
    names = {
        a["name"]
        for a in (api(f"actions/runs/{run_id}/artifacts?per_page=100") or {}).get("artifacts", [])
        if not a.get("expired")
    }
    return all(f"{prefix}cmux-tui-{t}" in names for t in TARGETS)


def still_building(api: Api, run: dict) -> bool:
    """Whether this run may yet upload the artifacts: its machine channel jobs are not all done."""
    if run.get("status") == "completed":
        return False
    jobs = (api(f"actions/runs/{run['id']}/jobs?per_page=100") or {}).get("jobs", [])
    mine = [j for j in jobs if any(m in j.get("name", "") for m in JOB_MARKS)]
    if not mine:
        return True  # the router has not started its callees yet
    return any(j.get("status") != "completed" for j in mine)


def find(api: Api, repo: str, sha: str, prefix: str, wait_s: float,
         key: Callable[[str], str] = tree_key, sleep: Callable[[float], None] = time.sleep,
         now: Callable[[], float] = time.monotonic, tree: Callable[[str], str] = git_tree) -> int | None:
    head = merged_head(api, repo, sha)
    if not head:
        log(f"{sha} is not a same-repository squash merge into {BASE}")
        return None
    mine, theirs = key(sha), key(head)
    if not mine or mine != theirs:
        tip = train_tip(api, tree(sha))
        if not tip:
            log(f"head {head} tree key {theirs or 'none'} != merge {mine or 'none'}, no train tip has its tree: build here")
            return None
        log(f"head {head} tree key {theirs or 'none'} != merge {mine or 'none'}; train tip {tip} has its tree")
        head = tip
    deadline = now() + wait_s
    while True:
        runs = (api(f"actions/workflows/{ROUTER}/runs?head_sha={head}&event=pull_request&per_page=20") or {}).get(
            "workflow_runs", []
        )
        waiting = False
        for run in sorted(runs, key=lambda r: r.get("id", 0), reverse=True):
            if artifacts_ready(api, run["id"], prefix):
                log(f"run {run['id']} built {head} (tree key {mine})")
                return int(run["id"])
            waiting = waiting or still_building(api, run)
        if not waiting or now() >= deadline:
            log(f"no finished machine channel build of {head}{' in time' if waiting else ''}")
            return None
        sleep(30)


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)
    f = sub.add_parser("find")
    f.add_argument("sha")
    f.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", "manaflow-ai/cmux"))
    f.add_argument("--wait", type=float, default=1500)
    f.add_argument("--prefix", default="")
    args = ap.parse_args(argv)
    token = os.environ.get("GH_TOKEN", "")
    if not token:
        log("no GH_TOKEN")
        return 0
    prefix = args.prefix or json.loads(
        (ROOT / "scripts/cmux-next/cmux-tui-build-profiles.json").read_text()
    )["machine_channel"]["artifact_prefix"]
    try:
        run = find(github_api(args.repo, token), args.repo, args.sha, prefix, args.wait)
    except Exception as exc:  # a miss falls back to the canonical build
        log(f"lookup failed: {exc}")
        run = None
    if run:
        print(run)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
