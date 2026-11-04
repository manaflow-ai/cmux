#!/usr/bin/env python3
"""Select promotion only from a durable exclusive admission or no-start receipt."""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import re
import time
from datetime import datetime

from fleet_admission_transport import exchange

JOB = "promote-nightly-next"
PATH = "/v1/nightly-promotion-admission"
MAX_CLOCK_SKEW_SECONDS = 30


def timestamp(value):
    return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()


def identity(env):
    if (env.get("GITHUB_REPOSITORY") != "manaflow-ai/cmux"
            or env.get("GITHUB_REF") != "refs/heads/main"
            or env.get("GITHUB_EVENT_NAME") != "workflow_dispatch"):
        raise ValueError("promotion admission is only for the main dispatch workflow")
    request = dict(repository=env["GITHUB_REPOSITORY"], run_id=int(env["GITHUB_RUN_ID"]),
                   run_attempt=int(env["GITHUB_RUN_ATTEMPT"]), source_sha=env["GITHUB_SHA"], jobs=[JOB])
    if request["run_id"] <= 0 or request["run_attempt"] <= 0 or not re.fullmatch(r"[0-9a-f]{40}", request["source_sha"]):
        raise ValueError("invalid promotion identity")
    return request


def lease_id(request):
    return hashlib.sha256(b"nightly-promotion:" + json.dumps(request, separators=(",", ":")).encode()).hexdigest()[:24]


def select(request, lease, overflow, now=None):
    now = time.time() if now is None else now
    if any(lease.get(key) != value for key, value in request.items()) or lease.get("lease_id") != lease_id(request):
        raise ValueError("promotion admission identity mismatch")
    created, expires = timestamp(lease["created_at"]), timestamp(lease["expires_at"])
    if expires - created != 180 or created > now + MAX_CLOCK_SKEW_SECONDS:
        raise ValueError("promotion admission window is not 180 seconds")
    if lease.get("status") == "pending":
        return None
    decided = timestamp(lease["decided_at"])
    # A decision is readiness evidence, so it must already be in the past;
    # allowing future-dated no-start receipts would bypass the 180-second wait.
    if decided > now:
        raise ValueError("promotion decision is dated in the future")
    if lease.get("status") == "fleet":
        expected = "cmux-promotion-" + lease_id(request) + "-" + JOB
        if not created <= decided < expires or lease.get("runners") != {JOB: expected}:
            raise ValueError("promotion has no timely reserved runner")
        return expected
    if (lease.get("status") == "overflow" and decided >= expires
            and type(lease.get("no_start_seconds")) is int and lease["no_start_seconds"] >= 180
            and abs((decided - created) - lease["no_start_seconds"]) < 1
            and not lease.get("runners")):
        return overflow
    raise ValueError("promotion has no valid fleet or no-start decision")


def place(request, call, overflow):
    lease = call("POST", PATH, request)
    first = {key: lease.get(key) for key in ("lease_id", "created_at", "expires_at")}
    # Bounded controller long-polls, not GitHub queue polling. API failure never
    # silently authorizes paid overflow or resets the durable admission clock.
    for _ in range(10):
        runner = select(request, lease, overflow)
        if runner:
            return runner, lease
        lease = call("GET", PATH + "/" + lease_id(request) + "?wait=30", None)
        if any(lease.get(key) != value for key, value in first.items()):
            raise ValueError("controller changed promotion lease deadline")
    runner = select(request, lease, overflow)
    if runner:
        return runner, lease
    raise TimeoutError("promotion admission did not reach a terminal decision")


def main(env=os.environ):
    request = identity(env)
    controller = env.get("CMUX_CI_CONTROLLER", "").rstrip("/")
    if not controller:
        raise ValueError("existing CMUX_FLEET_CONTROLLER repository variable is required")
    declared = json.loads(Path(".github/runners.json").read_text())["pools"]["promotion"]["members"]
    candidate = json.loads(env.get("RUNNER_POOLS") or "{}").get("promotion")
    if candidate not in declared:
        raise ValueError("RUNNER_POOLS.promotion must name a declared live overflow runner")
    overflow = candidate

    def call(method, path, body):
        return exchange(controller + path, body)

    runner, lease = place(request, call, overflow)
    with open(env["GITHUB_OUTPUT"], "a") as output:
        output.write("runner=" + runner + "\n")
    # The durable clock and terminal state are public audit evidence, not an
    # idle-runner snapshot. Never include the provider's signed receipt URL.
    evidence = {key: lease.get(key) for key in ("lease_id", "run_id", "run_attempt", "source_sha", "created_at", "expires_at", "decided_at", "status", "reason", "no_start_seconds")}
    with open(env["GITHUB_STEP_SUMMARY"], "a") as summary:
        summary.write("### Promotion runner admission\n\n```json\n" + json.dumps(evidence, indent=2) + "\n```\n")


if __name__ == "__main__":
    main()
