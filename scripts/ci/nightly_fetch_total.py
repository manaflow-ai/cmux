#!/usr/bin/env python3
"""github.com git fetches per job of one nightly run, and the run's total.

    python3 scripts/ci/nightly_fetch_total.py RUN_ID [--repo manaflow-ai/cmux]
    python3 scripts/ci/nightly_fetch_total.py --logs DIR      (saved job logs, one <name>.log each)

Leo's checkout-429 order: a nightly makes 0 github.com git fetches. A job's count is the larger of
the git "From https://github.com/..." lines in its log (one per fetch that brought objects: checkout,
submodules, shim fallbacks) and the largest "github.com git fetches this job: N" a fleet shim or
scripts/ci/nightly-source.sh printed. The last line is the one grep:

    github.com git fetches this run: N
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import glaeda_log  # noqa: E402

FROM_GITHUB = re.compile(r"^\S*\s*From https://github\.com/", re.M)
STATED = re.compile(r"github\.com git fetches this job: (\d+)")


def count(log: str) -> int:
    stated = [int(n) for n in STATED.findall(log)]
    return max([len(FROM_GITHUB.findall(log)), *stated])


def gh(*args: str) -> str:
    return subprocess.run(["gh", *args], check=True, capture_output=True, text=True).stdout


def run_logs(repo: str, run: str):
    pages = gh("api", "--paginate", f"repos/{repo}/actions/runs/{run}/jobs?filter=latest&per_page=100",
               "--jq", ".jobs[] | {id, name, conclusion}")
    for line in pages.splitlines():
        job = json.loads(line)
        if job.get("conclusion") in (None, "skipped"):
            continue
        # this host's glaeda-gh keeps job logs: no API read for one its daemon saw
        log = glaeda_log.cached_job_log(repo, job["id"])
        if log is None:
            try:
                log = gh("api", f"repos/{repo}/actions/jobs/{job['id']}/logs")
            except subprocess.CalledProcessError:
                yield job["name"], None
                continue
        yield job["name"], log


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("run", nargs="?")
    parser.add_argument("--repo", default="manaflow-ai/cmux")
    parser.add_argument("--logs", type=Path)
    args = parser.parse_args(argv)
    if args.logs:
        jobs = ((p.stem, p.read_text(errors="replace")) for p in sorted(args.logs.glob("*.log")))
    elif args.run:
        jobs = run_logs(args.repo, args.run)
    else:
        parser.error("give a RUN_ID or --logs DIR")
    total = unread = 0
    for name, log in jobs:
        if log is None:
            unread += 1
            print(f"{'?':>3}  {name} (log unreadable)")
            continue
        n = count(log)
        total += n
        print(f"{n:>3}  {name}")
    suffix = f" ({unread} job logs unreadable)" if unread else ""
    print(f"github.com git fetches this run: {total}{suffix}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
