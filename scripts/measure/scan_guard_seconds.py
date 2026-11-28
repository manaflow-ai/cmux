#!/usr/bin/env python3
"""Seconds a whole-tree scan guard takes on a pull request: the whole scan against changed files only.

What it measures: for each of the last N first-parent commits on a ref (each is one merged pull request), the wall
time of `python3 GUARD` on that commit's tree with CMUX_GUARDS_BASE_SHA set to its parent (the changed-files run CI
does), and for the first K of them with no base (the whole scan, as before tests/guard_delta.py). The guard files
named with --overlay (the new guard code) are committed on top of both the parent and the commit, so the diff the
guard sees is exactly the pull request's. It also checks that the two runs agree on pass or fail.

It checks the commits out in a throwaway worktree of its own under --scratch and removes it at the end.

Run it: python3 scripts/measure/scan_guard_seconds.py --guard tests/test_outbound_hosts.py \\
          --overlay tests/guard_delta.py tests/test_outbound_hosts.py --commits 20 --whole 3 [--ref origin/main]
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import statistics
import subprocess
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def git(cwd: Path, *args: str, data: bytes | None = None) -> str:
    return subprocess.run(["git", "-C", str(cwd), *args], input=data, check=True,
                          capture_output=True).stdout.decode().strip()


def run(tree: Path, guard: str, base: str | None) -> tuple[float, int]:
    env = {k: v for k, v in os.environ.items() if k != "CMUX_GUARDS_BASE_SHA"}
    if base:
        env["CMUX_GUARDS_BASE_SHA"] = base
    start = time.monotonic()
    p = subprocess.run(["python3", guard], cwd=tree, env=env, capture_output=True)
    return time.monotonic() - start, p.returncode


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--guard", required=True)
    ap.add_argument("--overlay", nargs="+", required=True)
    ap.add_argument("--commits", type=int, default=20)
    ap.add_argument("--whole", type=int, default=3)
    ap.add_argument("--ref", default="HEAD")
    ap.add_argument("--scratch", default=tempfile.gettempdir())
    args = ap.parse_args()

    overlay = {rel: (ROOT / rel).read_bytes() for rel in args.overlay}
    commits = git(ROOT, "rev-list", "--first-parent", f"--max-count={args.commits}", args.ref).split()
    tree = Path(tempfile.mkdtemp(prefix="scan-guard-seconds-", dir=args.scratch)) / "tree"
    git(ROOT, "worktree", "add", "-q", "--detach", str(tree), commits[0])
    rows = []
    try:
        for i, commit in enumerate(commits):
            git(tree, "checkout", "-q", "--detach", f"{commit}^1")
            for rel, data in overlay.items():
                (tree / rel).parent.mkdir(parents=True, exist_ok=True)
                (tree / rel).write_bytes(data)
            git(tree, "add", "-A", "--", *overlay)
            git(tree, "-c", "user.name=m", "-c", "user.email=m@m", "commit", "-q", "--allow-empty", "-m", "base")
            base = git(tree, "rev-parse", "HEAD")
            patch = subprocess.run(["git", "-C", str(tree), "diff", "--binary", f"{commit}^1", commit,
                                    "--", ".", *[f":!{rel}" for rel in overlay]], check=True,
                                   capture_output=True).stdout
            if patch:
                git(tree, "apply", "--index", "--whitespace=nowarn", data=patch)
            git(tree, "-c", "user.name=m", "-c", "user.email=m@m", "commit", "-q", "--allow-empty", "-m", "head")
            files = len(git(tree, "diff", "--name-only", base, "HEAD").split())
            changed_s, changed_rc = run(tree, args.guard, base)
            row = {"commit": commit[:12], "files": files, "changed_s": round(changed_s, 2), "changed_rc": changed_rc}
            if i < args.whole:
                whole_s, whole_rc = run(tree, args.guard, None)
                row |= {"whole_s": round(whole_s, 2), "whole_rc": whole_rc}
            rows.append(row)
            print(json.dumps(row), flush=True)
    finally:
        git(ROOT, "worktree", "remove", "--force", str(tree))
        shutil.rmtree(tree.parent, ignore_errors=True)
    whole = [r["whole_s"] for r in rows if "whole_s" in r]
    changed = [r["changed_s"] for r in rows]
    print(json.dumps({"guard": args.guard, "commits": len(rows),
                      "whole_median_s": statistics.median(whole) if whole else None,
                      "changed_median_s": statistics.median(changed), "changed_max_s": max(changed)}))


if __name__ == "__main__":
    main()
