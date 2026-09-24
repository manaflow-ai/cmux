#!/usr/bin/env python3
"""Put a pull request run's post-admission test jobs on free owned Macs first.

macos-compile-admission calls this as its last step. The jobs that run its
product next (the app-host shards and cli-product-tests) each get a runner
label: an owned pool while it has a free machine, and the caller's fallback
(pr_retry_runner or the admission's own pool) only for the jobs that do not
fit. Blacksmith is overflow, never the first choice while a mini is idle.

"Free" is read live, not from the janitor's snapshot: every queued or running
job on an owned label across the repository's in-flight runs takes one of
that label's CI_OWNED_POOL_SLOTS machines. This job's own machine counts as
free, since it is released before any consumer is created. Owned pools take
jobs in the lane's order (std, then light).

Only attempt 1 of a same-repository pull request run with owned pools on is
placed, and only when the product's Xcode is the one the owned labels pin
(the consumers load the product only under the Xcode that linked it). Any
error places nothing, which keeps every consumer on its fallback: today's
route. A consumer placed on a machine that another run takes first queues
there, and ci-owned-pool-rescue.yml moves the run to Blacksmith.

Writes `placement=<JSON {"<shard>": "<label>", "cli": "<label>"}>` to
GITHUB_OUTPUT.
"""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path
from typing import Any, Mapping, Sequence

sys.path.insert(0, str(Path(__file__).resolve().parent))

import pr_runner_pool as pool  # noqa: E402

# Keys of the consumers, in the order they are placed. Shards first: they are
# the fan-out, and cli-product-tests is the shortest job.
CLI_KEY = "cli"
MAX_RUN_PAGES = 3


def busy_by_label(runs_jobs: Sequence[Sequence[Mapping[str, Any]]], labels: Sequence[str], *,
                  own_runner: str) -> dict[str, int]:
    """Queued or running jobs on each owned label, leaving out this job's own machine."""
    busy = {label: 0 for label in labels}
    for jobs in runs_jobs:
        for job in jobs:
            if not isinstance(job, Mapping) or job.get("status") not in ("queued", "in_progress", "waiting"):
                continue
            if own_runner and job.get("runner_name") == own_runner:
                continue
            for label in job.get("labels") or []:
                if label in busy:
                    busy[label] += 1
                    break
    return busy


def place(keys: Sequence[str], free: Mapping[str, int], labels: Sequence[str]) -> dict[str, str]:
    """Each key gets the first label in order with a free machine left; the rest get none."""
    left = {label: max(0, int(free.get(label) or 0)) for label in labels}
    placement: dict[str, str] = {}
    for key in keys:
        for label in labels:
            if left[label] > 0:
                left[label] -= 1
                placement[key] = label
                break
    return placement


def consumer_keys(shards: str, cli: bool) -> list[str]:
    keys = [str(int(shard)) for shard in json.loads(shards or "[]")]
    return keys + ([CLI_KEY] if cli else [])


def eligible(env: Mapping[str, str]) -> str | None:
    """Why nothing may be placed, or None when the run may use owned pools."""
    if (env.get("EVENT_NAME") or "") != "pull_request":
        return "not a pull request"
    if (env.get("HEAD_REPO") or "") != (env.get("GITHUB_REPOSITORY") or "") or not env.get("HEAD_REPO"):
        return "fork head"
    if (env.get("GITHUB_RUN_ATTEMPT") or "1").strip() != "1":
        return "a retry attempt"
    if (env.get("POOL_OWNED") or "").strip() != "1":
        return "owned pools are off"
    return None


def in_flight_jobs(client: pool.GitHub) -> list[list[Mapping[str, Any]]]:
    runs: list[Mapping[str, Any]] = []
    for status in ("in_progress", "queued"):
        for page in range(1, MAX_RUN_PAGES + 1):
            batch = client.get(f"/actions/runs?status={status}&per_page={pool.PAGE_SIZE}&page={page}"
                               ).get("workflow_runs") or []
            runs.extend(run for run in batch if isinstance(run, Mapping))
            if len(batch) < pool.PAGE_SIZE:
                break
    seen: set[Any] = set()
    jobs: list[list[Mapping[str, Any]]] = []
    for run in runs:
        if run.get("id") in seen:
            continue
        seen.add(run.get("id"))
        listed = client.get(f"/actions/runs/{run['id']}/jobs?filter=latest&per_page={pool.PAGE_SIZE}"
                            ).get("jobs") or []
        jobs.append([job for job in listed if isinstance(job, Mapping)])
    return jobs


def main(env: Mapping[str, str] | None = None) -> int:
    env = os.environ if env is None else env
    placement: dict[str, str] = {}
    labels = [label for label in pool.owned_pools(env.get("XCODE_APP"))
              if pool.slots(env.get("OWNED_SLOTS")).get(label)]
    why = eligible(env) or (None if labels else "no owned pool with slots on the product's Xcode")
    keys = consumer_keys(env.get("SHARDS") or "[]", (env.get("CLI") or "") == "true")
    if why is None and keys:
        try:
            client = pool.GitHub(env.get("GH_TOKEN") or env.get("GITHUB_TOKEN") or "", env["GITHUB_REPOSITORY"])
            busy = busy_by_label(in_flight_jobs(client), labels, own_runner=env.get("RUNNER_NAME") or "")
            capacity = pool.slots(env.get("OWNED_SLOTS"))
            free = {label: capacity[label] - busy[label] for label in labels}
            placement = place(keys, free, labels)
            why = "free owned machines: " + ", ".join(f"{label} {free[label]}" for label in labels)
        except Exception as error:  # noqa: BLE001 - every failure keeps the fallback route
            placement, why = {}, f"could not read the owned pools' load ({error})"
    fallback = len(keys) - len(placement)
    text = (f"Consumer placement: {len(placement)} on owned Macs, {fallback} on the fallback pool "
            f"({why or 'nothing to place'})")
    print(text)
    for key in keys:
        print(f"  {key}: {placement.get(key, 'fallback')}")
    if env.get("GITHUB_STEP_SUMMARY"):
        with open(env["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as handle:
            handle.write(text + "\n")
    if env.get("GITHUB_OUTPUT"):
        with open(env["GITHUB_OUTPUT"], "a", encoding="utf-8") as handle:
            handle.write(f"placement={json.dumps(placement, separators=(',', ':'))}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
