#!/usr/bin/env python3
"""A feat-cmux-next push whose build an earlier push already makes (TWIN_BUILD, cmux-machine-channel.yml).

`find SHA` prints the run id of the newest earlier cmux-machine-channel.yml push run that builds SHA's code, or
nothing: SHA's first-parent ancestors with SHA's v2 tree key (a merge that moved no build input has its
parent's key), newest first, whose push run's x86_64 build is queued, running or passed. Of the 60
feat-cmux-next merges 00:30-01:05Z on 2026-11-28, 42 had their parent's key (18 runs of equal keys, one 13
long), and each of the 42 queued its own 14-minute thin build of bytes another run was already building:
three build lanes for a merge every 35 s. A run that took another run's build (a PR head's, or its own twin)
built nothing and is passed over.

`wait RUN --target T ...` prints RUN once its machine-channel artifacts for every T are there, waiting up to
--wait seconds; nothing when the run's build for a target ended without one (the push is then carried by
the next point, which is forward-only: the same inputs would have failed this push's own build too).

Every lookup that fails prints nothing, and the push builds as before.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import subprocess
import sys
import time
import urllib.parse
from pathlib import Path
from typing import Callable

ROOT = Path(__file__).resolve().parents[2]
BASE = "feat-cmux-next"
WORKFLOW = "cmux-machine-channel.yml"
# How far back the same key is followed (first parents), and how many runs' jobs are read for it.
MAX_DEPTH = 30
MAX_JOB_READS = 6
LIVE = {"queued", "in_progress", "waiting", "pending", "requested"}

Api = Callable[[str], object]


def log(msg: str) -> None:
    print(f"twin: {msg}", file=sys.stderr)


def _load(name: str, file: str):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts/ci" / file)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


def build_job(target: str) -> re.Pattern[str]:
    # "build-machine-channel x86_64 lane N / build TARGET" (FREE_LANE) or "build-machine-channel / build TARGET".
    return re.compile(rf"^build-machine-channel( [a-z0-9_]+ lane \d+)? / build {re.escape(target)}$")


X86 = "x86_64-unknown-linux-musl"


def first_parents(sha: str, depth: int = MAX_DEPTH) -> list[str]:
    out = subprocess.run(
        ["git", "-C", str(ROOT), "rev-list", "--first-parent", f"--max-count={depth + 1}", sha],
        check=False, capture_output=True, text=True, timeout=60,
    )
    return out.stdout.split()[1:] if out.returncode == 0 else []


def same_key_ancestors(sha: str, key: Callable[[str], str], parents: Callable[[str], list[str]] = first_parents
                       ) -> list[str]:
    """SHA's first-parent ancestors, newest first, up to the first one with another v2 tree key."""
    mine = key(sha)
    if not mine:
        return []
    found = []
    for rev in parents(sha):
        if key(rev) != mine:
            break
        found.append(rev)
    return found


def find(api: Api, sha: str, key: Callable[[str], str], parents: Callable[[str], list[str]] = first_parents
         ) -> int | None:
    twins = same_key_ancestors(sha, key, parents)
    if not twins:
        log(f"{sha[:12]}'s parent has another tree key: build here")
        return None
    branch = urllib.parse.quote(BASE, safe="")
    runs = (api(f"actions/workflows/{WORKFLOW}/runs?branch={branch}&event=push&per_page=100") or {}).get(
        "workflow_runs", []
    )
    by_sha: dict[str, list[dict]] = {}
    for run in sorted(runs, key=lambda r: r.get("id", 0), reverse=True):
        by_sha.setdefault(run.get("head_sha") or "", []).append(run)
    pattern, reads = build_job(X86), 0
    for rev in twins:
        for run in by_sha.get(rev, []):
            if reads >= MAX_JOB_READS:
                log(f"read {reads} runs' jobs for {len(twins)} same-key ancestors, none builds: build here")
                return None
            reads += 1
            jobs = (api(f"actions/runs/{run['id']}/jobs?per_page=100") or {}).get("jobs", [])
            for job in jobs:
                if not pattern.match(job.get("name", "")):
                    continue
                if job.get("status") in LIVE or job.get("conclusion") == "success":
                    log(f"run {run['id']} of {rev[:12]} builds this tree key ({job.get('status')}): take it")
                    return int(run["id"])
    log(f"{len(twins)} same-key ancestors, none with a live or passed x86_64 build: build here")
    return None


def wait(api: Api, run_id: int, targets: list[str], prefix: str, wait_s: float,
         sleep: Callable[[float], None] = time.sleep, now: Callable[[], float] = time.monotonic) -> int | None:
    want = {f"{prefix}cmux-tui-{t}" for t in targets}
    deadline = now() + wait_s
    while True:
        have = {
            a["name"]
            for a in (api(f"actions/runs/{run_id}/artifacts?per_page=100") or {}).get("artifacts", [])
            if not a.get("expired")
        }
        if want <= have:
            log(f"run {run_id} has {', '.join(sorted(want))}")
            return run_id
        jobs = (api(f"actions/runs/{run_id}/jobs?per_page=100") or {}).get("jobs", [])
        for t in targets:
            if f"{prefix}cmux-tui-{t}" in have:
                continue
            mine = [j for j in jobs if build_job(t).match(j.get("name", ""))]
            if mine and all(j.get("status") == "completed" for j in mine):
                # Its last artifact upload can trail the job's end by a moment: one more read.
                again = {
                    a["name"] for a in (api(f"actions/runs/{run_id}/artifacts?per_page=100") or {}).get("artifacts", [])
                    if not a.get("expired")
                }
                if want <= again:
                    return run_id
                log(f"run {run_id}'s {t} build ended ({mine[0].get('conclusion')}) with no artifact")
                return None
        if now() >= deadline:
            log(f"run {run_id} has no {', '.join(sorted(want - have))} in {wait_s:.0f} s")
            return None
        sleep(60)


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)
    f = sub.add_parser("find")
    f.add_argument("sha")
    w = sub.add_parser("wait")
    w.add_argument("run", type=int)
    w.add_argument("--target", action="append", required=True)
    w.add_argument("--wait", type=float, default=1500)
    w.add_argument("--prefix", default="")
    for p in (f, w):
        p.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", "manaflow-ai/cmux"))
    args = ap.parse_args(argv)
    token = os.environ.get("GH_TOKEN", "")
    if not token:
        log("no GH_TOKEN")
        return 0
    api = _load("pr_head", "cmux_machine_channel_pr_head.py").github_api(args.repo, token)
    try:
        if args.cmd == "find":
            tk = _load("cmux_tui_tree_key", "cmux_tui_tree_key.py")

            def key(rev: str) -> str:
                try:
                    return tk.tree_key(rev, "v2")
                except Exception:  # an unreadable revision ends the walk
                    return ""

            run = find(api, args.sha, key)
        else:
            prefix = args.prefix or json.loads(
                (ROOT / "scripts/cmux-next/cmux-tui-build-profiles.json").read_text()
            )["machine_channel"]["artifact_prefix"]
            run = wait(api, args.run, args.target, prefix, args.wait)
    except Exception as exc:  # a miss falls back: find builds here, wait points nothing
        log(f"lookup failed: {exc}")
        run = None
    if run:
        print(run)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
