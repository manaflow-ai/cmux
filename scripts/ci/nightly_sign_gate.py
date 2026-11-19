#!/usr/bin/env python3
"""nightly.yml resolve-nightly-cmux-tui-client: "Leave the sign to a newer nightly-next build".

Leo, 2026-11-19: "if i wait for the nightly then i might as well just update to the thing".

Latest wins: a nightly-next build a newer one passed publishes nothing. The recorder (scripts/ci/nightly_speed.py,
hq#10221) kept 40 such runs from 2026-11-16 13:59Z to 11-18 12:41Z, every one "success, no feed upload", 819 min
open in all. The checks that found them run on the signing Mac: nightly-next-one's leave step and its feed recheck
(after the whole-Mac claim), and build-sign-notarize-nightly's yield (nightly_sign_yield.py, once the job has its
runner). This makes the same calls in resolve, on the nightly-only pool, before either sign job exists, so a run
that can only be superseded never takes the signing Mac. resolve's `superseded` output already skips every build
and sign job and the loop's retry (cmux#45997 is the same pattern for cmux-tui artifacts).

A run leaves when:
1. the NEXT feed already serves a build above this run's (<run id><attempt>): the feed's compare-and-swap
   (nightly_version.py check-build, publish-recheck-recovered.sh) refuses this build whatever happens, so this is
   certain; or
2. nightly_sign_yield.decide yields for this run's sign job: a newer nightly-next push run's sign job is queued,
   pending or running, and Leo's 30-minute rule does not pin this run. For nightly-next-one (the one job), a newer
   run's finished job does not count: it can end green having left its slot, so only (1) reads a finished one.

A newer push alone never counts (#28961, sign-pick-overtaken.sh): only a published build or a sign job that exists.
Anything unreadable is doubt, and doubt builds and signs, as before. The checks on the Mac stay behind this one.

Env: GITHUB_REPOSITORY, GITHUB_RUN_ID, GITHUB_RUN_ATTEMPT, GITHUB_EVENT_NAME, GITHUB_REF_NAME, TRACK, SIGN_JOB
(nightly-next-one or build-sign-notarize-nightly), GH_TOKEN (actions: read), GITHUB_OUTPUT; NIGHTLY_NEXT_SIGN_GATE
(0 turns it off), NIGHTLY_NEXT_SIGN_YIELD, GITHUB_API_URL optional. Writes superseded=true|false; always exits 0.
"""
from __future__ import annotations

import datetime as dt
import importlib.util
import os
import sys
from collections.abc import Callable
from pathlib import Path

sy = sys.modules.get("nightly_sign_yield")
if sy is None:
    _spec = importlib.util.spec_from_file_location("nightly_sign_yield", Path(__file__).resolve().parent / "nightly_sign_yield.py")
    sy = importlib.util.module_from_spec(_spec)
    sys.modules["nightly_sign_yield"] = sy
    _spec.loader.exec_module(sy)

ONE_JOB = "nightly-next-one"
SIGN_JOBS = (ONE_JOB, sy.SIGN_JOB)


def own_build(env: dict[str, str]) -> int | None:
    run_id, attempt = env.get("GITHUB_RUN_ID", ""), env.get("GITHUB_RUN_ATTEMPT", "1")
    if not (run_id.isdigit() and attempt.isdigit() and 0 < int(attempt) < 100):
        return None
    return int(run_id) * 100 + int(attempt)


def highest_build(feed: bytes) -> int | None:
    """The NEXT feed's highest build number, None for an empty feed; Unreadable for anything else."""
    run = sy.last_published_run(feed)
    if run is None:
        return None
    return max(int(b) for b in sy.BUILD.findall(feed.decode("utf-8", "replace")))


def decide(env: dict[str, str], get: sy.Get, feed: Callable[[], bytes] = sy.read_feed,
           now: Callable[[], dt.datetime] | None = None, log: Callable[[str], None] = print) -> tuple[bool, str]:
    """(superseded, why)."""
    if env.get("NIGHTLY_NEXT_SIGN_GATE", "1") == "0":
        return False, "NIGHTLY_NEXT_SIGN_GATE is 0"
    if env.get("TRACK") != "nightly-next" or env.get("GITHUB_REF_NAME") != "nightly-next":
        return False, "not a nightly-next build"
    sign_job = env.get("SIGN_JOB", "")
    if sign_job not in SIGN_JOBS:
        return False, f"no sign job named ({sign_job!r})"
    build = own_build(env)
    if build is None:
        return False, "no run id or attempt"
    try:
        body = feed()
        highest = highest_build(body)
    except sy.Unreadable as why:
        log(f"::warning title=Sign gate::could not read the NEXT feed ({why}); building and signing as usual")
        return False, "unreadable feed"
    if highest is not None and highest > build:
        return True, f"the NEXT feed already serves build {highest}, above this run's {build}"
    yielded, why = sy.decide(env, get, log=log, feed=lambda: body, now=now, sign_job=sign_job,
                             signed_counts=sign_job != ONE_JOB)
    if yielded:
        return True, why
    return False, f"the feed's highest build is {highest or 'none'}, this run's {build}; {why}"


def main() -> int:
    env = dict(os.environ)
    get = sy.http_get(env.get("GITHUB_API_URL", "https://api.github.com"), env.get("GH_TOKEN", ""))
    superseded, why = decide(env, get)
    output = env.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a", encoding="utf-8") as handle:
            handle.write(f"superseded={'true' if superseded else 'false'}\n")
    if superseded:
        print(f"::notice title=Superseded before signing::{why}; this run takes no signing Mac")
    else:
        print(f"building and signing: {why}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
