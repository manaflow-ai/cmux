#!/usr/bin/env python3
"""A green result reused for the same input tree: the content-addressed half of affected-only CI.

    tree_result.py mark --dir D --job ID --key K    # write this run's green record (the job's last step)
    tree_result.py said --dir D --job ID --key K    # check a restored record and say whose it is; exit 1 if not ours

scripts/ci/affected_jobs.py gives each routed job a key (`<job>_tree` output): a hash of the object id of every
input of the job at the tested commit, its workflow file and the router's own files (result_key). Two commits with
the same key build and test the same files, so the job's verdict on one is its verdict on the other.

.github/actions/tree-result stores one record per (job, key) in the GitHub cache, only after every tested step of
the job passed, and looks it up as the job's first step. A hit skips the tested steps and the job still reports
green, with the run that earned it named in its summary. Nothing is skipped without a verdict: the verdict is the
earlier run's, for the same input tree.

- A record is saved only by a run whose tested steps all passed (the save step runs on success()).
- The key covers the job's inputs only. What is not an input (the runner image, a service the test reads at run
  time) is the same as for affected_jobs.py routing: a push to feat-cmux-next runs every job with no reuse.
- GitHub scopes the cache: a pull request reads the records its base branch saved and its own, never another pull
  request's.

Test: tests/test_ci_tree_result.py.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path

RECORD = "record.json"


def mark(directory: Path, job: str, key: str, env: dict[str, str]) -> dict:
    record = {
        "job": job, "key": key, "conclusion": "success",
        "commit": env.get("GITHUB_SHA", ""), "event": env.get("GITHUB_EVENT_NAME", ""),
        "ref": env.get("GITHUB_REF", ""),
        "run": f"{env.get('GITHUB_SERVER_URL', 'https://github.com')}/{env.get('GITHUB_REPOSITORY', '')}"
               f"/actions/runs/{env.get('GITHUB_RUN_ID', '')}/attempts/{env.get('GITHUB_RUN_ATTEMPT', '1')}",
        "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    directory.mkdir(parents=True, exist_ok=True)
    (directory / RECORD).write_text(json.dumps(record, sort_keys=True) + "\n", encoding="utf-8")
    return record


def said(directory: Path, job: str, key: str) -> tuple[bool, str]:
    """(whether the restored record is a green result of JOB for KEY, the line that says so)."""
    try:
        record = json.loads((directory / RECORD).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return False, "no readable record: the job runs"
    if not isinstance(record, dict) or record.get("job") != job or record.get("key") != key \
            or record.get("conclusion") != "success":
        return False, f"the record is not a green result of {job} for this input tree: the job runs"
    return True, (f"Same input tree as {record.get('commit', '')[:12] or 'an earlier commit'} "
                  f"({record.get('event') or 'a run'} on {record.get('ref') or '?'}, {record.get('at', '')}), "
                  f"green in {record.get('run', '')}: {job} reuses that result for input tree {key[:16]}.")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("command", choices=("mark", "said"))
    parser.add_argument("--dir", type=Path, required=True)
    parser.add_argument("--job", required=True)
    parser.add_argument("--key", required=True)
    args = parser.parse_args(argv)
    if args.command == "mark":
        mark(args.dir, args.job, args.key, dict(os.environ))
        return 0
    ok, line = said(args.dir, args.job, args.key)
    print(line)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as out:
            out.write(f"### Result reused for the same input tree\n\n{line}\n")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
