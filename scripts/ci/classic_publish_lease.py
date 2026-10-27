#!/usr/bin/env python3
"""Newest-wins publication for one classic channel (nightly or rc).

Main and rc push runs build in parallel, so their continuations
(auto-resume-nightly-notarization.yml) reach publication in any order. A
concurrency group would replace a pending publisher, so the writers instead
share an R2 lease, and the newest build wins:

  - A claim record (CLAIM_KEY) names the highest build that has started to
    publish. A publisher raises it to its own build before it waits. One
    older than the claim steps aside without taking the lease, so the newest
    build never waits behind older contenders, only behind the one holder
    that took the lease before it claimed.
  - That holder yields: before each write it runs `check`, which answers
    `yield` once a newer build has claimed, and the job skips its remaining
    writes. The newest build rewrites every feed, tag and note after it.
  - The lease is short (LEASE_TTL on R2's clock) and a heartbeat renews it
    while its job lives, so a holder keeps it through any rate-limit wait,
    and a holder that dies frees it within LEASE_TTL. `check` fails the job
    when it no longer holds the lease, so it never writes without it.

    classic_publish_lease.py acquire --build N --skip-env NAME [--no-claim]
        Prints `proceed` (the lease is held and the heartbeat runs) or
        `yield` (a newer build has claimed; nothing is held, and NAME=true is
        written to GITHUB_ENV so the job's write steps skip). --no-claim:
        compare with the claim without raising it (the delta republish,
        which follows its own build's publication).
    classic_publish_lease.py check --build N --skip-env NAME
        Prints `proceed` or `yield` (and writes NAME=true); exits 1 when the
        lease was lost.
    classic_publish_lease.py release
        Stops the heartbeat and releases the lease.

Reads LEASE_KEY, CLAIM_KEY, LEASE_OWNER and RUNNER_TEMP, and r2_cas.py's
R2 variables, from the environment. LEASE_WAIT (seconds) bounds the wait.
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

LEASE_TTL = 600  # seconds on R2's clock
RENEW_EVERY = 60
CLAIM_TRIES = 20


def _pid_file() -> Path:
    return Path(os.environ["RUNNER_TEMP"]) / "classic-publish-lease.pid"


def claimed(key: str) -> tuple[str | None, int]:
    etag, body = r2_cas.get(key)
    try:
        build = int(json.loads(body or b"{}").get("build", 0))
    except (ValueError, AttributeError, TypeError):
        build = 0
    return etag, build


def claim(key: str, build: int, owner: str) -> bool:
    """Raises the claim to build. False when a newer build already holds it."""
    for _ in range(CLAIM_TRIES):
        etag, current = claimed(key)
        if current > build:
            return False
        if current == build:
            return True
        body = json.dumps({"build": build, "run": owner}).encode()
        if r2_cas.put(key, body, etag=etag, cache_control="no-store", content_type="application/json"):
            return True
    raise RuntimeError(f"the claim at {key} kept changing; giving up after {CLAIM_TRIES} tries")


def start_heartbeat(key: str, owner: str) -> None:
    process = subprocess.Popen(
        [sys.executable, __file__, "heartbeat", "--key", key, "--owner", owner],
        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    _pid_file().write_text(str(process.pid))


def stop_heartbeat() -> None:
    try:
        pid = int(_pid_file().read_text())
    except (OSError, ValueError):
        return
    try:
        os.kill(pid, signal.SIGTERM)  # the heartbeat this job started
    except ProcessLookupError:
        pass
    _pid_file().unlink(missing_ok=True)


def keep(key: str, owner: str) -> bool:
    """Renews the lease; True while this owner holds it. The heartbeat and
    `check` both renew, so one may lose the conditional write to the other
    (412) while the lease is still this owner's."""
    return r2_cas.renew(key, owner) or r2_cas.holds(key, owner)


def heartbeat(key: str, owner: str, sleep=time.sleep) -> None:
    # Stops when the lease is released or lost, or when the job ends (the
    # runner ends the job's processes).
    while True:
        sleep(RENEW_EVERY)
        try:
            if not keep(key, owner):
                return
        except Exception:  # a transient error; the next beat retries well inside the TTL
            continue


def acquire(build: int, *, raise_claim: bool, env=os.environ) -> str:
    lease, claim_key, owner = env["LEASE_KEY"], env["CLAIM_KEY"], env["LEASE_OWNER"]
    if raise_claim:
        if not claim(claim_key, build, owner):
            return "yield"
    elif claimed(claim_key)[1] > build:
        return "yield"
    if not r2_cas.lock(lease, owner, LEASE_TTL, int(env.get("LEASE_WAIT", "9000"))):
        raise RuntimeError("the lease stayed held for the whole wait")
    if claimed(claim_key)[1] > build:  # a newer build claimed while this one waited
        r2_cas.unlock(lease, owner)
        return "yield"
    start_heartbeat(lease, owner)
    return "proceed"


def check(build: int, env=os.environ) -> str:
    lease, claim_key, owner = env["LEASE_KEY"], env["CLAIM_KEY"], env["LEASE_OWNER"]
    # Renewing proves the lease is still this job's and restarts its age, so
    # the write that follows starts with a full TTL even if a beat was missed.
    if not keep(lease, owner):
        raise RuntimeError("this job no longer holds the publication lease; refusing to write")
    return "yield" if claimed(claim_key)[1] > build else "proceed"


def release(env=os.environ) -> None:
    stop_heartbeat()
    r2_cas.unlock(env["LEASE_KEY"], env["LEASE_OWNER"])


def _skip(name: str, verdict: str) -> str:
    if verdict == "yield":
        with open(os.environ["GITHUB_ENV"], "a", encoding="utf-8") as env:
            env.write(f"{name}=true\n")
        print("A newer build has claimed this channel's publication; this job skips its writes", file=sys.stderr)
    return verdict


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    a = sub.add_parser("acquire")
    a.add_argument("--build", type=int, required=True)
    a.add_argument("--no-claim", action="store_true")
    a.add_argument("--skip-env", required=True)
    c = sub.add_parser("check")
    c.add_argument("--build", type=int, required=True)
    c.add_argument("--skip-env", required=True)
    sub.add_parser("release")
    h = sub.add_parser("heartbeat")
    h.add_argument("--key", required=True)
    h.add_argument("--owner", required=True)
    args = parser.parse_args(argv)
    try:
        if args.command == "acquire":
            print(_skip(args.skip_env, acquire(args.build, raise_claim=not args.no_claim)))
        elif args.command == "check":
            print(_skip(args.skip_env, check(args.build)))
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
