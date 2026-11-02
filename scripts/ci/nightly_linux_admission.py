#!/usr/bin/env python3
"""Admit secret-free nightly controls on reserved fleet Linux before paid overflow.

The controller owns the 180-second lease and dispatches the existing HQ JIT
provisioner. A fleet receipt names an unconsumed runner for each requested job;
the controller gives the fleet 180 seconds before overflow. If admission is
unavailable in legacy mode, use declared hosted-light or measured overflow instead
of an unregistered pool. Opted-in Check Run admission instead fails closed until
the existing controller App publishes a matching terminal receipt. This client
never cancels a job or workflow.
"""
from __future__ import annotations

import datetime as dt
import json
import os
import re
import signal
import sys
import time
from pathlib import Path
from typing import Any, Mapping

import portable_job_placement as portable
from fleet_admission_transport import exchange
import nightly_admission_receipt as published
from nightly_admission_receipt import validate

FLEET_LINUX = "cmux-fleet-linux-x64"
OVERFLOW = {"blacksmith-16vcpu-ubuntu-2404", "blacksmith-32vcpu-ubuntu-2404"}
JOBS = frozenset({"resolve-nightly-cmux-tui-client",
                  "resolve-nightly-ghostty-cli-helper", "build-nightly-inputs",
                  "find-nightly-next-recovery"})
WAIT_SECONDS = 180
CLIENT_DEADLINE = 200


def identity(env: Mapping[str, str]) -> dict[str, Any]:
    jobs = sorted(set(env.get("JOBS", "").split()))
    if not jobs or not set(jobs) <= JOBS:
        raise ValueError("unknown nightly control job")
    if env.get("GITHUB_REPOSITORY") != "manaflow-ai/cmux":
        raise ValueError("fleet admission is only for manaflow-ai/cmux")
    sha = env.get("GITHUB_SHA", "")
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise ValueError("source SHA must be a full commit")
    run_id, attempt = int(env["GITHUB_RUN_ID"]), int(env["GITHUB_RUN_ATTEMPT"])
    if min(run_id, attempt) <= 0:
        raise ValueError("run and attempt must be positive")
    return {"repository": env["GITHUB_REPOSITORY"], "run_id": run_id,
            "run_attempt": attempt, "source_sha": sha, "jobs": jobs}


def timestamp(value: Any) -> dt.datetime:
    if not isinstance(value, str):
        raise ValueError("missing receipt timestamp")
    parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None or parsed.utcoffset() != dt.timedelta(0):
        raise ValueError("receipt timestamps must be UTC")
    return parsed


def admit(env: Mapping[str, str], request: Mapping[str, Any]) -> dict[str, Any]:
    if env.get("CHECK_RECEIPTS") == "1":
        return published.read(request, env.get("SNAPSHOT_TOKEN", ""))
    controller = env.get("CMUX_CI_CONTROLLER", "").rstrip("/")
    if not controller:
        raise ValueError("CMUX_FLEET_CONTROLLER is not configured")
    endpoint = f"{controller}/v1/nightly-linux-admission"
    deadline = time.monotonic() + CLIENT_DEADLINE
    receipt = exchange(endpoint, request)
    lease = receipt.get("lease_id")
    # Each GET waits for a controller state change. This is a bounded long-poll,
    # not repeated GitHub reads; only the controller decides fleet vs overflow.
    while validate(receipt, request) == "pending":
        if time.monotonic() >= deadline:
            raise TimeoutError("nightly fleet admission did not return a terminal receipt")
        receipt = exchange(f"{endpoint}/{lease}?wait=30")
        if receipt.get("lease_id") != lease:
            raise ValueError("admission changed lease identity")
    return receipt


def routes(env: Mapping[str, str], request: Mapping[str, Any], receipt: Mapping[str, Any] | None,
           runners=None, snapshot=None) -> dict[str, str]:
    if env.get("CHECK_RECEIPTS") == "1" and receipt is None:
        raise ValueError("published admission is required before routing")
    status = validate(receipt, request) if receipt is not None else "unknown"
    if env.get("CHECK_RECEIPTS") == "1" and status not in {"fleet", "overflow"}:
        raise ValueError("terminal published admission is required before routing")
    if status == "fleet":
        return dict(receipt["runners"])
    # A configured label is not live runner evidence. Only a verified fleet
    # receipt selects Linux; minis also require a successful capacity read.
    placement_env = {**env, "FLEET_LINUX": "", "LINUX_ONLY": "",
                     "NIGHTLY": "1", "NIGHTLY_WAIT_FOR_FLEET": "",
                     "REQUIRE_LIVE_CAPACITY": "1" if env.get("CHECK_RECEIPTS") == "1" else env.get("REQUIRE_LIVE_CAPACITY", "")}
    placed = portable.decide(placement_env, runners, snapshot, dt.datetime.now(dt.timezone.utc))
    fallback = env.get("OVERFLOW_LINUX", "")
    if fallback not in OVERFLOW:
        raise ValueError("overflow runner is outside the declared set")
    # The central table is the only authority for hosted-light eligibility.
    table = json.loads((Path(__file__).resolve().parents[2] / ".github/runners.json").read_text())
    light = table.get("hosted_light_jobs", {})
    result = {job: "ubuntu-24.04" if env.get("CHECK_RECEIPTS") != "1" and request["run_attempt"] == 1 and f"nightly.yml#{job}" in light else fallback
              for job in request["jobs"]}
    for job in placed.mini_jobs:
        result[job] = placed.mini_runner
    return result


def output_key(job: str) -> str:
    # A job's routing output is not a runner label. Keep the public output
    # free of the legacy guard's bare product-name label token.
    return job.replace("cmux-", "").replace("-", "_")


def write(env: Mapping[str, str], selected: Mapping[str, str], receipt: Mapping[str, Any] | None,
          error: str = "", client_observation: Mapping[str, Any] | None = None) -> None:
    if env.get("GITHUB_OUTPUT"):
        with open(env["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
            output.write(f"admission_ready={str(receipt is not None).lower()}\n")
            for job, label in selected.items():
                output.write(f"{output_key(job)}_runner={label}\n")
    record = {"identity": identity(env), "receipt": receipt, "runners": selected, "error": error,
              "client_observation": client_observation}
    if env.get("ADMISSION_RECEIPT_PATH"):
        Path(env["ADMISSION_RECEIPT_PATH"]).write_text(json.dumps(record, sort_keys=True) + "\n")
    if env.get("GITHUB_STEP_SUMMARY"):
        with open(env["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as summary:
            summary.write("### Early nightly fleet admission\n\n```json\n" + json.dumps(record, indent=2) + "\n```\n")
    print(json.dumps(record, sort_keys=True))


def read_minis(env: Mapping[str, str]):
    """Capacity reads cannot extend the placement step beyond its five-minute budget."""
    previous = signal.getsignal(signal.SIGALRM)

    def timeout(_signum, _frame):
        raise portable.Deadline("owned-mini capacity read deadline")

    try:
        signal.signal(signal.SIGALRM, timeout)
        signal.setitimer(signal.ITIMER_REAL, 30)
        return portable.read(env, dt.datetime.now(dt.timezone.utc))
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous)


def main(env: Mapping[str, str] = os.environ) -> int:
    request = identity(env)
    if env.get("CHECK_RECEIPTS") == "1":
        try:
            receipt = admit(env, request)
            runners = snapshot = None
            if receipt["status"] == "overflow":
                try:
                    runners, snapshot = read_minis(env)
                except (Exception, portable.Deadline):
                    pass  # The verified controller receipt still authorizes paid overflow.
            selected = routes(env, request, receipt, runners, snapshot)
        except (Exception, portable.Deadline) as failure:
            write(env, {}, None, f"published fleet admission unavailable: {type(failure).__name__}")
            return 1
        write(env, selected, receipt)
        return 0
    started = time.monotonic()
    started_at = dt.datetime.now(dt.timezone.utc).isoformat()
    observation = None
    receipt = None
    error = ""
    runners = snapshot = None
    try:
        receipt = admit(env, request)
        if receipt["status"] == "overflow":
            runners, snapshot = read_minis(env)
        selected = routes(env, request, receipt, runners, snapshot)
    except (Exception, portable.Deadline) as failure:
        # The pool may not be enrolled at all. Never strand a job on its label
        # when the controller cannot prove a registered runner is ready.
        error = f"fleet admission unavailable: {type(failure).__name__}"
        receipt = None
        # An unread controller is not proof of zero registered runners. Give
        # admission its original three-minute window, including time already
        # spent in the controller deadline. Never fabricate a receipt.
        remaining = WAIT_SECONDS - (time.monotonic() - started)
        if remaining > 0:
            time.sleep(remaining)
        observation = {"source": "client", "status": "admission-unavailable",
                       "started_at": started_at,
                       "ended_at": dt.datetime.now(dt.timezone.utc).isoformat(),
                       "no_start_seconds": time.monotonic() - started,
                       "scope": "no admitted runner received; not a controller capacity receipt"}
        # Read immediately before placing; a pre-wait idle snapshot is stale.
        try:
            runners, snapshot = read_minis(env)
        except (Exception, portable.Deadline):
            runners = snapshot = None
        selected = routes(env, request, None, runners, snapshot)
    write(env, selected, receipt, error, observation)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
