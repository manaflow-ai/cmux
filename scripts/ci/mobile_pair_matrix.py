#!/usr/bin/env python3
"""Exercise each distinct source in the supported shipped window in both roles."""
import argparse
import json
import os
from pathlib import Path
import re
import resource
import subprocess
import tempfile
import time


def pairs(window, head, trees):
    rows = window["include"]
    if not rows or {row["role"] for row in rows} != {"host", "dial"}:
        raise ValueError("the shipped window must contain both host and dial sources")
    for row in rows:
        if not re.fullmatch(r"[0-9a-f]{40}", row["sha"]) or not row["release_ids"]:
            raise ValueError("source and publication IDs are required")
        shipped = trees[row["sha"]]
        yield row, (shipped, head) if row["role"] == "host" else (head, shipped)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("window", type=Path)
    parser.add_argument("--head", type=Path, default=Path.cwd())
    args = parser.parse_args()
    head = args.head.resolve()
    window = json.loads(args.window.read_text())
    logs = Path(os.environ["SKEW_LOG_DIR"]).resolve()
    logs.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="phone-pair-sources-") as directory:
        trees = {row["sha"]: Path(directory) / row["sha"] for row in window["include"]}
        plan = list(pairs(window, head, trees))
        added = []
        try:
            for sha, tree in trees.items():
                subprocess.run(["git", "-C", str(head), "fetch", "--no-tags", "--depth=1", "origin", sha],
                               check=True, timeout=120)
                subprocess.run(["git", "-C", str(head), "worktree", "add", "--detach", str(tree), sha],
                               check=True, timeout=120)
                added.append(tree)
            for row, (host, dial) in plan:
                label = row["role"] + "-" + row["sha"][:12]
                env = dict(os.environ, SKEW_LOG_DIR=str(logs / label))
                start = time.monotonic()
                cpu = resource.getrusage(resource.RUSAGE_CHILDREN)
                result = subprocess.run(["bash", str(head / "scripts/ci/mobile-pair-skew.sh"),
                                         str(host), str(dial)], env=env, timeout=1800)
                after = resource.getrusage(resource.RUSAGE_CHILDREN)
                receipt = dict(row, pr_sha=subprocess.check_output(
                    ["git", "-C", str(head), "rev-parse", "HEAD"], text=True).strip(),
                    wall_seconds=time.monotonic() - start,
                    cpu_seconds=(after.ru_utime + after.ru_stime - cpu.ru_utime - cpu.ru_stime),
                    exit_code=result.returncode)
                (logs / (label + ".json")).write_text(json.dumps(receipt, indent=2) + "\n")
                print(json.dumps(receipt), flush=True)
                result.check_returncode()
        finally:
            for tree in reversed(added):
                subprocess.run(["git", "-C", str(head), "worktree", "remove", str(tree)], check=True)


if __name__ == "__main__":
    main()
