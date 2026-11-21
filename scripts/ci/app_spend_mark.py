#!/usr/bin/env python3
"""A GitHub App token's hourly spend and budget floor for one workflow job, from GET /rate_limit (free).

    app_spend_mark.py start TAG [--floor F]   after the token is minted; F: pass, landing or a number
    app_spend_mark.py end TAG                 at job end (`if: always()`)

TAG is WORKFLOW/JOB. The token is APP_SPEND_TOKEN (the minted App token); with none (a failed mint) each command says
so and exits 0. Every read and every failure exits 0: this never fails or stops a job on its own.

Leo, 2026-11-18: "Make it count bash gh/curl and the cmux-repo workflows too: each minting workflow prints its spend
from X-RateLimit headers, and they are summed." and "Every App caller checks remaining budget first and degrades
gracefully (keeps the last state, never false conclusions) below a floor."

The cmux-bot installation (12,500 REST an hour) ran dry by mid-hour every hour, and the callers then read refusals
as answers: on 2026-11-18 the overflow watch's pool pass lost the queue janitor's snapshot to a refusal, judged on
the probe alone, and marked every large Linux size dead (runner_pools.py).

Both commands print, for HQ's spend publisher (cmuxterm-hq tools/fleet-reconcilers/app_spend_publish.py):

    app-spend-pool: TAG at=EPOCH limit=L used=U remaining=R reset=S

`end` also prints, when `start` read the same rate-limit window (same reset):

    app-spend: TAG bash rest=N graphql=0 gh=0 gh_paginate=0

where N = used at end - used at start. The pool is the installation's, shared by every job that holds its token at
once, so N is an upper bound on this job's spend (a following `app-spend-note:` line says so).

`start --floor F` (F: `pass` = DEFAULT_FLOOR, or a number, never under DEFAULT_FLOOR): when R < the floor it
writes `low=true` to GITHUB_OUTPUT and a warning; the job's spending steps are gated on
`steps.<id>.outputs.low != 'true'`, so the pass is skipped, the last state is kept and the job ends green. A failed
read is never low. No cmux caller goes under DEFAULT_FLOOR: the hour's last calls (DEFAULT_FLOOR down to the NOW
reserve) belong to HQ's next-autoland and NOW (cmuxterm-hq app_budget.py). On 2026-11-20 the pool was spent within
about 18 minutes of every reset and next-autoland stopped on "the cmux-bot REST pool is spent". `landing` is kept
as an alias of DEFAULT_FLOOR so a pinned checkout that passes it still parses.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
import urllib.request
from collections.abc import Callable, Mapping
from pathlib import Path
from typing import Any

API = os.environ.get("GITHUB_API_URL", "https://api.github.com").rstrip("/")
# The calls left in the cmux-bot hour that only HQ's NOW reconciler (fleet-reconciler-now, which reads this repository
# with the same installation) may spend: no caller here spends below it. Keep in step with NOW_RESERVE in cmuxterm-hq
# tools/fleet-reconcilers/app_budget.py (hq#13472).
APP_BUDGET_NOW_RESERVE = 1500
# Below this many calls left a pass that only watches or rescues keeps its last state; the hour's rest goes to the
# callers that land and post statuses. The same default as cmuxterm-hq's app_budget.py (DEFAULT_FLOOR).
DEFAULT_FLOOR = 2500
# The lowest floor any cmux caller may take. Callers that land, dispatch or post statuses stop here too: the band
# below it (down to the NOW reserve) is next-autoland's (cmuxterm-hq app_budget.py NEXT_AUTOLAND floor, 1,500).
MIN_FLOOR = DEFAULT_FLOOR
LANDING_FLOOR = MIN_FLOOR
POOL_MARK = "app-spend-pool: "
SPEND_MARK = "app-spend: "


def read_pool(token: str, *, opener: Callable[..., Any] = urllib.request.urlopen,
              timeout: float = 10.0) -> dict[str, int] | None:
    """The core pool {limit, used, remaining, reset} for `token`, or None when it cannot be read."""
    if not token:
        return None
    request = urllib.request.Request(f"{API}/rate_limit", headers={
        "Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "cmux-app-spend-mark"})
    try:
        with opener(request, timeout=timeout) as response:
            core = json.load(response)["resources"]["core"]
        return {key: int(core[key]) for key in ("limit", "used", "remaining", "reset")}
    except Exception:  # noqa: BLE001 - an unread pool never stops a job
        return None


def pool_line(tag: str, pool: Mapping[str, int], at: int) -> str:
    return (f"{POOL_MARK}{tag} at={at} limit={pool['limit']} used={pool['used']} "
            f"remaining={pool['remaining']} reset={pool['reset']}")


def spend_lines(tag: str, start: Mapping[str, int] | None, end: Mapping[str, int]) -> list[str]:
    """The `app-spend:` line for the job, when start and end read one rate-limit window."""
    if not start:
        return [f"app-spend-note: {tag} no start reading; spend not measured"]
    if int(start.get("reset", -1)) != end["reset"]:
        return [f"app-spend-note: {tag} the pool reset between start and end; spend not measured"]
    rest = max(0, end["used"] - int(start.get("used", 0)))
    return [f"{SPEND_MARK}{tag} bash rest={rest} graphql=0 gh=0 gh_paginate=0",
            f"app-spend-note: {tag} rest={rest} is an upper bound: every job holding this installation's token "
            "spends the same pool meanwhile"]


FLOORS = {"pass": DEFAULT_FLOOR, "landing": LANDING_FLOOR}


def parse_floor(raw: str) -> int:
    if raw in FLOORS:
        return FLOORS[raw]
    if raw.isdigit():
        # Never under the default floor, whatever a workflow asks for.
        return max(int(raw), MIN_FLOOR)
    raise argparse.ArgumentTypeError(f"--floor takes {', '.join(FLOORS)} or a number, not {raw!r}")


def below_floor(pool: Mapping[str, int] | None, floor: int | None) -> bool:
    return pool is not None and floor is not None and pool["remaining"] < floor


def record_path(tag: str, env: Mapping[str, str]) -> Path:
    base = Path(env.get("RUNNER_TEMP") or env.get("TMPDIR") or "/tmp") / "app-spend-mark"
    return base / (re.sub(r"[^A-Za-z0-9_.-]+", "_", tag) + ".json")


def write_output(env: Mapping[str, str], **values: str) -> None:
    target = env.get("GITHUB_OUTPUT")
    if not target:
        return
    try:
        with open(target, "a", encoding="utf-8") as handle:
            for key, value in values.items():
                handle.write(f"{key}={value}\n")
    except OSError:
        pass


def start(tag: str, floor: int | None, env: Mapping[str, str], *, read: Callable[[str], Any] = read_pool,
          now: Callable[[], float] = time.time, out: Callable[[str], None] = print) -> int:
    token = (env.get("APP_SPEND_TOKEN") or "").strip()
    pool = read(token) if token else None
    if pool is None:
        out(f"app-spend-note: {tag} {'no App token' if not token else 'GET /rate_limit failed'}; not measured")
        write_output(env, low="false", remaining="")
        return 0
    out(pool_line(tag, pool, int(now())))
    try:
        path = record_path(tag, env)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(pool), encoding="utf-8")
    except OSError:
        pass
    low = below_floor(pool, floor)
    write_output(env, low="true" if low else "false", remaining=str(pool["remaining"]))
    if low:
        reset = time.strftime("%H:%MZ", time.gmtime(pool["reset"]))
        out(f"::warning title=App budget::{tag}: {pool['remaining']} of {pool['limit']} calls left, under the floor "
            f"of {floor}, until {reset}; this pass is skipped and keeps its last state")
    return 0


def end(tag: str, env: Mapping[str, str], *, read: Callable[[str], Any] = read_pool,
        now: Callable[[], float] = time.time, out: Callable[[str], None] = print) -> int:
    token = (env.get("APP_SPEND_TOKEN") or "").strip()
    pool = read(token) if token else None
    if pool is None:
        out(f"app-spend-note: {tag} {'no App token' if not token else 'GET /rate_limit failed'}; not measured")
        return 0
    out(pool_line(tag, pool, int(now())))
    try:
        began = json.loads(record_path(tag, env).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        began = None
    for line in spend_lines(tag, began if isinstance(began, dict) else None, pool):
        out(line)
    return 0


def main(argv: list[str] | None = None, env: Mapping[str, str] | None = None) -> int:
    env = os.environ if env is None else env
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("command", choices=("start", "end"))
    parser.add_argument("tag", help="WORKFLOW/JOB")
    parser.add_argument("--floor", type=parse_floor, default=None,
                        help="with start: pass, landing or a number; below it, low=true")
    args = parser.parse_args(argv)
    if args.command == "start":
        return start(args.tag, args.floor, env)
    return end(args.tag, env)


if __name__ == "__main__":
    sys.exit(main())
