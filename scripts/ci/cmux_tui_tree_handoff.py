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
- an owner whose only failures are a GitHub rate limit or the attestation
  steps hands nothing off: a re-run spends the same quota and fails the same
  way. The tree is published by the next push of the key, or by
  cmux-tui-tree-request.yml once the quota resets.

usage: cmux_tui_tree_handoff.py --repo OWNER/NAME --run-id ID --key KEY
Needs GH_TOKEN with actions: write.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from typing import Any, Iterable, Mapping, Sequence

# A deferred run's last attempt the hand-off may start: two re-runs at most.
MAX_ATTEMPT = 3
# Steps whose failure is GitHub's quota, not the build: actions/attest-build-provenance
# and its retries ("Attest raw binary subjects (try 2)", "Retry the attestation ...").
QUOTA_STEP = re.compile(r"\battest", re.IGNORECASE)
RATE_LIMIT_TEXT = re.compile(r"rate limit exceeded", re.IGNORECASE)
# Jobs that only follow a failure: they never make an owner's failure their own.
REPORTING_JOBS = frozenset({"report an unpublished cmux-tui tree to cmux-next"})


def quota_only_failure(jobs: Sequence[Mapping[str, Any]], failure_text: str = "") -> bool:
    """True when every failed step of this run is an attestation step, or the failure text names a
    GitHub rate limit; a run with no failed step is not a quota failure."""
    failed_steps = [
        step.get("name") or ""
        for job in jobs
        if job.get("conclusion") == "failure" and job.get("name") not in REPORTING_JOBS
        for step in job.get("steps") or []
        if step.get("conclusion") == "failure"
    ]
    if RATE_LIMIT_TEXT.search(failure_text or ""):
        return True
    return bool(failed_steps) and all(QUOTA_STEP.search(name) for name in failed_steps)


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


def _gh(*args: str, check: bool = True) -> str:
    result = subprocess.run(["gh", *args], capture_output=True, text=True)
    if check and result.returncode != 0:
        raise RuntimeError(f"gh {' '.join(args[:2])} failed: {result.stderr.strip()}")
    return result.stdout if result.returncode == 0 else ""


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--run-id", required=True, type=int)
    parser.add_argument("--key", required=True)
    parser.add_argument("--failure-text", default="", help="text of this run's failure annotations, if any")
    args = parser.parse_args(argv)
    if not os.environ.get("GH_TOKEN"):
        print("GH_TOKEN is required", file=sys.stderr)
        return 2
    jobs = json.loads(_gh("api", f"repos/{args.repo}/actions/runs/{args.run_id}/jobs?filter=latest&per_page=100")).get("jobs", [])
    # A failed job's annotations carry the action's error ("API rate limit exceeded for installation").
    notes = [args.failure_text]
    for job in jobs:
        if job.get("conclusion") == "failure" and job.get("name") not in REPORTING_JOBS:
            body = _gh("api", f"repos/{args.repo}/check-runs/{job['id']}/annotations?per_page=50", check=False)
            notes += [str(note.get("message") or "") for note in (json.loads(body) if body else [])]
    if quota_only_failure(jobs, "\n".join(notes)):
        print(f"::warning title=tree hand-off skipped::run {args.run_id} failed only on GitHub's rate limit or "
              f"attestation; a re-run would spend the same quota. Tree {args.key} is left for the next push of the key.")
        return 0
    artifacts = json.loads(_gh("api", f"repos/{args.repo}/actions/artifacts?name=cmux-tui-tree-deferred-{args.key}&per_page=100"))
    candidates = order_candidates(artifacts.get("artifacts", []), args.run_id)
    if not candidates:
        print(f"No run of tree {args.key} deferred to this one.")
        return 0
    for artifact, run_id, branch in candidates:
        run = json.loads(_gh("api", f"repos/{args.repo}/actions/runs/{run_id}", check=False) or "{}")
        allowed, why = may_rerun(run)
        if not allowed:
            print(f"Not re-running run {run_id} ({branch}): {why}.")
            continue
        if subprocess.run(["gh", "run", "rerun", str(run_id), "--repo", args.repo]).returncode != 0:
            continue
        _gh("api", "-X", "DELETE", f"repos/{args.repo}/actions/artifacts/{artifact}", check=False)
        print(f"Re-ran run {run_id} ({branch}, {why}), which deferred to this one, to build tree {args.key}.")
        return 0
    print(f"::warning::no run that deferred tree {args.key} to this one could be re-run")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
