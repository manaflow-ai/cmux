#!/usr/bin/env python3
"""One writer at a time for a classic channel (nightly or rc), newest first.

Main and rc push runs build in parallel, so their continuations
(auto-resume-nightly-notarization.yml) reach publication in any order. A
concurrency group would replace a pending publisher, so the writers instead
share an R2 lease, and waiting writers queue by build:

  - A claim record (CLAIM_KEY) names the newest waiting build. A waiter
    renews it while it waits (it goes stale CLAIM_TTL after its waiter stops),
    and only the newest live claimant tries for the lease. So the newest
    build waits only for the writer that already holds the lease, never for
    older contenders, and a claimant that fails or dies frees the queue: the
    next build claims and takes its turn. An older build that gets the lease
    after a newer one published is refused by the publish job's own guards.
  - A holder never yields part way: it finishes its publication, so the
    feeds, tag and release notes always describe one build.
  - A heartbeat renews the lease (LEASE_TTL on R2's clock) while its job
    lives, so a holder keeps it through any rate-limit wait. Each renewal
    writes new bytes, so the lease's ETag changes and a waiter that read it
    expired cannot then take it. `check` runs before each write and fails the
    job when the lease is gone.
  - A lease that expired without a release is taken over only once the
    holder's job has completed (its owner names the run, attempt and job;
    GitHub's API says), so a holder that lost its renewals but still writes
    is never overlapped, and a later job of the same run can recover a lease
    its publish job failed to release. An unreadable answer counts as still
    running.

    classic_publish_lease.py acquire --build N
        Waits for its turn (LEASE_WAIT seconds at most), takes the lease and
        starts the heartbeat. Exits 1 when the wait runs out.
    classic_publish_lease.py check
        Renews the lease; exits 1 when this job no longer holds it.
    classic_publish_lease.py release
        Stops the heartbeat, releases the lease and withdraws the claim.

Reads LEASE_KEY, CLAIM_KEY, LEASE_OWNER (RUN_ID-ATTEMPT-JOB), RUNNER_TEMP,
GITHUB_REPOSITORY and GH_TOKEN, and r2_cas.py's R2 variables, from the
environment.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

_spec = importlib.util.spec_from_file_location("r2_cas", Path(__file__).with_name("r2_cas.py"))
r2_cas = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(r2_cas)

LEASE_TTL = 1800  # seconds on R2's clock
RENEW_EVERY = 20
CLAIM_TTL = 120  # a waiter renews its claim every POLL seconds
POLL = 10


def _pid_file(env=os.environ) -> Path:
    return Path(env["RUNNER_TEMP"]) / "classic-publish-lease.pid"


def _json(body: bytes) -> dict:
    try:
        value = json.loads(body or b"{}")
    except ValueError:
        return {}
    return value if isinstance(value, dict) else {}


def _put(key: str, value: dict, etag: str | None) -> bool:
    # A fresh nonce in every write: R2's ETag follows the bytes.
    body = json.dumps({**value, "nonce": time.time_ns()}).encode()
    return r2_cas.put(key, body, etag=etag, cache_control="no-store", content_type="application/json")


def live_claim(key: str) -> tuple[str | None, dict]:
    """The claim's ETag and value; the value is {} when no waiter holds it."""
    etag, body, age = r2_cas.read(key)
    claim = _json(body)
    if etag is None or claim.get("withdrawn") or age > CLAIM_TTL:
        return etag, {}
    return etag, claim


def withdraw(key: str, owner: str) -> None:
    etag, claim = live_claim(key)
    if claim.get("owner") == owner:
        _put(key, {"withdrawn": True}, etag)  # a lost race means another waiter claimed


def job_finished(owner: str, env=os.environ) -> bool:
    """Whether the job that owner (RUN_ID-ATTEMPT-JOB) names has completed.

    The publishing jobs set no `name:`, so GitHub names each by its job id."""
    parts = owner.split("-", 2)
    if len(parts) != 3 or not (parts[0].isdigit() and parts[1].isdigit()) or not parts[2]:
        return False
    result = subprocess.run(
        ["gh", "api", "--paginate", f"repos/{env['GITHUB_REPOSITORY']}/actions/runs/{parts[0]}/attempts/{parts[1]}/jobs?per_page=100",
         "--jq", ".jobs[] | [.name, .status] | @tsv"],
        capture_output=True, text=True, check=False, env=env,
    )
    if result.returncode != 0:
        return False
    statuses = [line.split("\t", 1)[1] for line in result.stdout.splitlines() if line.split("\t", 1)[0] == parts[2]]
    return bool(statuses) and all(status == "completed" for status in statuses)


def try_lock(key: str, owner: str, env=os.environ, finished=job_finished) -> bool:
    """One attempt at the lease: free when absent or released, or expired with
    its holder's job completed."""
    etag, body, age = r2_cas.read(key)
    current = _json(body)
    if etag is not None and not current.get("released"):
        if age <= LEASE_TTL or not finished(str(current.get("owner", "")), env):
            return False
    return _put(key, {"owner": owner}, etag)


def acquire(build: int, env=os.environ, clock=time.monotonic, sleep=time.sleep, heartbeat=None,
            finished=job_finished) -> None:
    lease, claim_key, owner = env["LEASE_KEY"], env["CLAIM_KEY"], env["LEASE_OWNER"]
    deadline = clock() + int(env.get("LEASE_WAIT", "18000"))
    while True:
        etag, claim = live_claim(claim_key)
        claimed = int(claim.get("build", 0) or 0)
        if claim.get("owner") == owner or claimed < build:
            # This build is the newest waiter: claim (or renew the claim).
            if not _put(claim_key, {"build": build, "owner": owner}, etag):
                sleep(1)  # another waiter wrote first; read again
                continue
            turn = True
        else:
            turn = claimed == build  # the same build (a rerun) may contend too
        if turn and try_lock(lease, owner, env, finished):
            _, newest = live_claim(claim_key)
            if newest.get("owner") not in (None, owner) and int(newest.get("build", 0) or 0) > build:
                r2_cas.unlock(lease, owner)  # a newer build claimed meanwhile: its turn first
            else:
                withdraw(claim_key, owner)
                (heartbeat or start_heartbeat)(lease, owner)
                return
        if clock() >= deadline:
            withdraw(claim_key, owner)
            raise RuntimeError(f"no turn at the {lease} lease within the wait")
        sleep(POLL)


def renew(key: str, owner: str) -> bool:
    """Renews the lease; True while this owner holds it. The heartbeat and
    `check` both renew, so one may lose the conditional write to the other
    while the lease is still this owner's."""
    etag, body, _ = r2_cas.read(key)
    lease = _json(body)
    if etag is None or lease.get("owner") != owner or lease.get("released"):
        return False
    return _put(key, {"owner": owner}, etag) or r2_cas.holds(key, owner)


def start_heartbeat(key: str, owner: str) -> None:
    process = subprocess.Popen(
        [sys.executable, __file__, "heartbeat", "--key", key, "--owner", owner],
        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    _pid_file().write_text(str(process.pid))


def stop_heartbeat(env=os.environ) -> None:
    try:
        pid = int(_pid_file(env).read_text())
    except (OSError, ValueError):
        return
    try:
        os.kill(pid, signal.SIGTERM)  # the heartbeat this job started
    except ProcessLookupError:
        pass
    _pid_file(env).unlink(missing_ok=True)


def heartbeat(key: str, owner: str, sleep=time.sleep) -> None:
    # Stops when the lease is released or taken, or when the job ends (the
    # runner ends the job's processes). A failed renewal is retried on the
    # next beat, well inside LEASE_TTL.
    while True:
        sleep(RENEW_EVERY)
        try:
            if not renew(key, owner):
                return
        except Exception:
            continue


def check(env=os.environ) -> None:
    if not renew(env["LEASE_KEY"], env["LEASE_OWNER"]):
        raise RuntimeError("this job no longer holds the publication lease; refusing to write")


def release(env=os.environ) -> None:
    stop_heartbeat(env)
    r2_cas.unlock(env["LEASE_KEY"], env["LEASE_OWNER"])
    withdraw(env["CLAIM_KEY"], env["LEASE_OWNER"])


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    a = sub.add_parser("acquire")
    a.add_argument("--build", type=int, required=True)
    sub.add_parser("check")
    sub.add_parser("release")
    h = sub.add_parser("heartbeat")
    h.add_argument("--key", required=True)
    h.add_argument("--owner", required=True)
    args = parser.parse_args(argv)
    try:
        if args.command == "acquire":
            acquire(args.build)
        elif args.command == "check":
            check()
        elif args.command == "release":
            release()
        else:
            heartbeat(args.key, args.owner)
    except RuntimeError as error:
        print(f"::error::{error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
