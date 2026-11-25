#!/usr/bin/env python3
"""Which api-workerd shards of this run died without a test verdict (cmux#56511).

backend.yml runs the API Worker suite in 12 matrix shards, and the `test` job (the check that deploys and
prod-promote read) fails when any shard is not green. Most reds on feat-cmux-next were not the tests': a pool
runner that went away mid-job (the job fails with no step finished and no log), a setup step that stalled past
its bound (setup-node, the Bun cache restore, bun install), or the 45 min job limit on a slow host, which GitHub
reports as cancelled. None of those ran the tests to an answer, so none of them is a test verdict.

This reads the run's jobs (GitHub REST, filter=latest) and sorts every shard into one of three:

  pass    the shard job succeeded (or was skipped on purpose, see --allow-skipped)
  fail    the shard's test step itself ended `failure`: the tests ran and failed, already after the shard's own
          rerun of its failed files, so that is the code's answer and nothing reruns it again
  infra   anything else: the test step was cancelled, skipped, never started, or the job is missing

It prints `infra=<shards space separated>` and `fail=<...>` lines for $GITHUB_OUTPUT. The `test` job reruns the
infra shards itself; a fail shard fails the gate as before.

Usage:
  api_workerd_infra_shards.py --jobs-json FILE        # classify a saved jobs listing (tests)
  api_workerd_infra_shards.py --repo O/R --run-id N   # fetch the run's jobs with $GITHUB_TOKEN
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

SHARDS = 12
JOB_NAME = re.compile(r"^api-workerd \((\d+)/(\d+)\)$")
TEST_STEP_PREFIX = "API Worker tests (workerd), shard "


def classify(jobs: list[dict], shards: int = SHARDS) -> dict[int, str]:
    """Map each shard 1..shards to pass, fail or infra from the run's job listing."""
    seen: dict[int, dict] = {}
    for job in jobs:
        m = JOB_NAME.match(job.get("name") or "")
        if not m or int(m.group(2)) != shards:
            continue
        shard = int(m.group(1))
        # filter=latest already keeps the latest attempt; if two still show, the later id wins.
        if shard not in seen or (job.get("id") or 0) > (seen[shard].get("id") or 0):
            seen[shard] = job
    verdicts: dict[int, str] = {}
    for shard in range(1, shards + 1):
        job = seen.get(shard)
        if job is None:
            verdicts[shard] = "infra"
            continue
        if job.get("conclusion") == "success":
            verdicts[shard] = "pass"
            continue
        step = next(
            (s for s in job.get("steps") or [] if (s.get("name") or "").startswith(TEST_STEP_PREFIX)),
            None,
        )
        verdicts[shard] = "fail" if step is not None and step.get("conclusion") == "failure" else "infra"
    return verdicts


def fetch_jobs(repo: str, run_id: str, token: str, attempts: int = 4) -> list[dict]:
    jobs: list[dict] = []
    page = 1
    while True:
        url = f"https://api.github.com/repos/{repo}/actions/runs/{run_id}/jobs?filter=latest&per_page=100&page={page}"
        req = urllib.request.Request(
            url,
            headers={
                "Authorization": f"Bearer {token}",
                "Accept": "application/vnd.github+json",
                "X-GitHub-Api-Version": "2022-11-28",
                "User-Agent": "cmux-ci-api-workerd-gate",
            },
        )
        for attempt in range(attempts):
            try:
                with urllib.request.urlopen(req, timeout=30) as resp:
                    body = json.load(resp)
                break
            except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as error:
                if attempt == attempts - 1:
                    raise SystemExit(f"api_workerd_infra_shards: could not read the run's jobs: {error}")
                # A bounded backoff between API attempts, not runtime synchronization.
                time.sleep(2 * (attempt + 1))
        batch = body.get("jobs") or []
        jobs.extend(batch)
        if len(batch) < 100:
            return jobs
        page += 1


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--jobs-json")
    parser.add_argument("--repo")
    parser.add_argument("--run-id")
    parser.add_argument("--shards", type=int, default=SHARDS)
    args = parser.parse_args(argv)

    if args.jobs_json:
        with open(args.jobs_json, encoding="utf-8") as f:
            data = json.load(f)
        jobs = data.get("jobs", data) if isinstance(data, dict) else data
    else:
        token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
        if not (args.repo and args.run_id and token):
            parser.error("--repo, --run-id and $GITHUB_TOKEN are needed without --jobs-json")
        jobs = fetch_jobs(args.repo, args.run_id, token)

    verdicts = classify(jobs, args.shards)
    for shard, verdict in verdicts.items():
        print(f"api-workerd shard {shard}/{args.shards}: {verdict}", file=sys.stderr)
    print("infra=" + " ".join(str(s) for s, v in verdicts.items() if v == "infra"))
    print("fail=" + " ".join(str(s) for s, v in verdicts.items() if v == "fail"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
