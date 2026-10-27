#!/usr/bin/env python3
"""Hand an unpublished cmux-tui tree key to one run that deferred to this one.

A cmux-tui artifacts run that took a tree key and ended without publishing it
(notify-unpublished-tree) re-runs one run that deferred the key to it: that
run left a cmux-tui-tree-deferred-<key> artifact. The re-run wins the claim and
builds the key.

Two limits keep the hand-off from spending the installation's API and
attestation quota in a loop (2026-10-27: tree runs reached attempts 15 to 17,
each re-running the next after its own hand-off, while the attestation quota
blocked every publish):
- a deferred run is re-run at most twice (attempt 3 is its last), because a
  re-run that defers again leaves a fresh marker; and
- an owner whose every failed job failed only on GitHub's quota (an
  attestation step, or a log that names a rate limit) hands nothing off: a
  re-run spends the same quota and fails the same way. The tree is published
  by the next push of the key, or by cmux-tui-tree-request.yml once the quota
  resets. One failed job that is not quota-only makes the run a real failure,
  and the hand-off goes ahead.

usage: cmux_tui_tree_handoff.py --repo OWNER/NAME --run-id ID --key KEY
Needs GH_TOKEN with actions: write (job logs are read with actions access).
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from typing import Any, Callable, Iterable, Mapping, Sequence

# A deferred run's last attempt the hand-off may start: two re-runs at most.
MAX_ATTEMPT = 3
# publish to R2's actions/attest-build-provenance steps: "Attest raw binary subjects",
# its "(try 2)" / "(try 3)" / "(last try)" retries, and "Retry the attestation of ...".
ATTEST_STEP = re.compile(r"^(?:Attest raw binary subjects(?: \((?:try \d+|last try)\))?|Retry the attestation\b.*)$")
RATE_LIMIT_TEXT = re.compile(
    r"rate limit exceeded|secondary rate limit|too many requests|\bHTTP 429\b|status(?: code)?:? 429", re.IGNORECASE)
# Jobs that only follow a failure: they never make an owner's failure their own.
REPORTING_JOBS = frozenset({"report an unpublished cmux-tui tree to cmux-next"})


def failed_jobs(jobs: Sequence[Mapping[str, Any]]) -> list[Mapping[str, Any]]:
    return [job for job in jobs if job.get("conclusion") == "failure" and job.get("name") not in REPORTING_JOBS]


def job_quota_only(job: Mapping[str, Any], log_text: str | None) -> bool:
    """A failed job failed only on GitHub's quota: each failed step is an attestation step, or its log names a
    rate limit. An unreadable log (None) is no evidence of a quota failure."""
    steps = [step.get("name") or "" for step in job.get("steps") or [] if step.get("conclusion") == "failure"]
    if steps and all(ATTEST_STEP.match(name) for name in steps):
        return True
    return log_text is not None and bool(RATE_LIMIT_TEXT.search(log_text))


def quota_only_failure(jobs: Sequence[Mapping[str, Any]], log_of: Callable[[Mapping[str, Any]], str | None]) -> bool:
    """True when the run has failed jobs and every one of them failed only on GitHub's quota."""
    failed = failed_jobs(jobs)
    return bool(failed) and all(job_quota_only(job, log_of(job)) for job in failed)


def order_candidates(artifacts: Iterable[Mapping[str, Any]], self_run: int) -> list[tuple[int, int, str]]:
    """(artifact id, run id, branch) of unexpired deferred markers left by other runs, feat-cmux-next
    pushes first, newest run first within each branch class."""
    rows = []
    for artifact in artifacts:
        run = artifact.get("workflow_run") or {}
        if artifact.get("expired") or not run.get("id") or int(run["id"]) == self_run:
            continue
        rows.append((int(artifact["id"]), int(run["id"]), str(run.get("head_branch") or "")))
    return sorted(rows, key=lambda row: (row[2] != "feat-cmux-next", -row[1]))


def may_rerun(run: Mapping[str, Any]) -> tuple[bool, str]:
    """Whether a deferred run may be re-run now: completed (GitHub refuses a live one) and under the cap."""
    attempt = int(run.get("run_attempt") or 1)
    if run.get("status") != "completed":
        return False, f"run is {run.get('status')}"
    if attempt >= MAX_ATTEMPT:
        return False, f"attempt {attempt} reached the cap of {MAX_ATTEMPT} (two re-runs)"
    return True, f"attempt {attempt}"


def _gh(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(["gh", *args], capture_output=True, text=True)


def _list(path: str, key: str) -> list[dict]:
    """Every item of a paginated list endpoint (gh --paginate, one JSON item per line)."""
    result = _gh("api", "--paginate", path, "--jq", f".{key}[]")
    if result.returncode != 0:
        raise RuntimeError(f"gh api {path} failed: {result.stderr.strip()}")
    return [json.loads(line) for line in result.stdout.splitlines() if line.strip()]


def handoff(repo: str, run_id: int, key: str) -> None:
    jobs = _list(f"repos/{repo}/actions/runs/{run_id}/jobs?filter=latest&per_page=100", "jobs")

    def log_of(job: Mapping[str, Any]) -> str | None:
        result = _gh("api", f"repos/{repo}/actions/jobs/{job['id']}/logs")
        if result.returncode != 0:
            print(f"::warning::could not read the log of job {job['id']} ({job.get('name')}): {result.stderr.strip()}")
            return None
        return result.stdout

    if quota_only_failure(jobs, log_of):
        print(f"::warning title=tree hand-off skipped::run {run_id} failed only on GitHub's rate limit or "
              f"attestation; a re-run would spend the same quota. Tree {key} is left for the next push of the key.")
        return
    artifacts = _list(f"repos/{repo}/actions/artifacts?name=cmux-tui-tree-deferred-{key}&per_page=100", "artifacts")
    candidates = order_candidates(artifacts, run_id)
    if not candidates:
        print(f"No run of tree {key} deferred to this one.")
        return
    for artifact, deferred, branch in candidates:
        result = _gh("api", f"repos/{repo}/actions/runs/{deferred}")
        if result.returncode != 0 or not result.stdout.strip():
            print(f"::warning::could not read run {deferred} ({branch}): {result.stderr.strip()}")
            continue
        allowed, why = may_rerun(json.loads(result.stdout))
        if not allowed:
            print(f"Not re-running run {deferred} ({branch}): {why}.")
            continue
        rerun = _gh("run", "rerun", str(deferred), "--repo", repo)
        if rerun.returncode != 0:
            print(f"::warning::could not re-run run {deferred} ({branch}): {rerun.stderr.strip()}")
            continue
        print(f"Re-ran run {deferred} ({branch}, {why}), which deferred to this one, to build tree {key}.")
        # The marker is used once. If it cannot be deleted, a later owner may re-run this run again, but only
        # up to MAX_ATTEMPT: the cap is read from the run itself, not from the marker.
        deleted = _gh("api", "-X", "DELETE", f"repos/{repo}/actions/artifacts/{artifact}")
        if deleted.returncode != 0:
            print(f"::warning::could not delete deferred marker {artifact} of run {deferred}: {deleted.stderr.strip()}")
            raise SystemExit(1)
        return
    print(f"::warning::no run that deferred tree {key} to this one could be re-run")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--run-id", required=True, type=int)
    parser.add_argument("--key", required=True)
    args = parser.parse_args(argv)
    if not os.environ.get("GH_TOKEN"):
        print("::warning::tree hand-off needs GH_TOKEN; nothing was handed off", file=sys.stderr)
        return 2
    try:
        handoff(args.repo, args.run_id, args.key)
    except Exception as error:  # the step is continue-on-error: say why nothing was handed off
        print(f"::warning::tree {args.key} was not handed off: {error}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
