#!/usr/bin/env python3
"""The repository GITHUB_TOKEN's floor for a recurring job, from GET /rate_limit (free).

    JOB_TOKEN=${{ github.token }} job_token_floor.py TAG [--floor F]

TAG is WORKFLOW/JOB. Every workflow in the repository draws on one GITHUB_TOKEN hour (1,000 REST calls on this
repository). The App mints and App callers stop at their floors (app_spend_mark.py --floor pass), but a recurring
job that is held there, or refused there, moved its calls onto github.token, which had no floor, and the hour ran
out: on 2026-11-25 every cmux-next-post-merge-dispatch tick from 03:19Z to 06:27Z failed "API rate limit exceeded
for installation", and the post-merge batch stopped. The binding rule (cmuxterm-hq docs/handbook/
unfloored-spender-drains-installation.md): "Every recurring spender on a shared installation stops at a floor, as
the mints do."

When the job token's core remaining is under the floor, this writes `held=true` to GITHUB_OUTPUT and the job's
github.token uses are gated on `steps.<id>.outputs.held != 'true'` (a step's `if:`, or a fallback token that is
empty while held), so the pass keeps its last state, ends green and the next tick looks again after the reset. The
calls under the floor belong to the paths that publish, land and dispatch (the nightly's notarization, the
post-merge batch), which take no floor.

F is a number of calls or a share of the limit (`0.3`); never under MIN_SHARE of the limit. Default: DEFAULT_SHARE.
A failed read is never held (an unread pool never stops a job), and every outcome exits 0.

Each run prints one line for readers (NOW, ci-health-report) to sum, and one more when it holds:

    job-token-pool: TAG at=EPOCH limit=L used=U remaining=R reset=S floor=F
    job-token-floor: TAG held remaining=R floor=F until=ISO

plus a `::notice` naming the reset, so a held tick says why in the run's annotations. No token is printed.
"""

from __future__ import annotations

import argparse
import os
import sys
import time
from collections.abc import Callable, Mapping
from datetime import datetime, timezone
from typing import Any

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from app_spend_mark import read_pool, write_output  # noqa: E402

DEFAULT_SHARE = 0.3
MIN_SHARE = 0.2
POOL_MARK = "job-token-pool: "
HELD_MARK = "job-token-floor: "


def floor_calls(raw: str | None, limit: int) -> int:
    """The floor in calls for a pool of `limit`: F as calls or a share, never under MIN_SHARE of the limit."""
    least = int(MIN_SHARE * limit)
    if raw in (None, ""):
        return max(int(DEFAULT_SHARE * limit), least)
    value = float(raw)
    calls = int(value * limit) if value < 1 else int(value)
    return max(calls, least)


def check(tag: str, raw_floor: str | None, env: Mapping[str, str], *, read: Callable[[str], Any] = read_pool,
          now: Callable[[], float] = time.time, out: Callable[[str], None] = print) -> int:
    token = (env.get("JOB_TOKEN") or "").strip()
    pool = read(token) if token else None
    if pool is None:
        out(f"job-token-note: {tag} {'no JOB_TOKEN' if not token else 'GET /rate_limit failed'}; not held")
        write_output(env, held="false", remaining="")
        return 0
    floor = floor_calls(raw_floor, pool["limit"])
    out(f"{POOL_MARK}{tag} at={int(now())} limit={pool['limit']} used={pool['used']} "
        f"remaining={pool['remaining']} reset={pool['reset']} floor={floor}")
    held = pool["remaining"] < floor
    write_output(env, held="true" if held else "false", remaining=str(pool["remaining"]))
    if held:
        until = datetime.fromtimestamp(pool["reset"], timezone.utc).strftime("%Y-%m-%dT%H:%MZ")
        out(f"{HELD_MARK}{tag} held remaining={pool['remaining']} floor={floor} until={until}")
        out(f"::notice title=GITHUB_TOKEN floor::{tag} sends nothing on github.token this pass: "
            f"{pool['remaining']} of {pool['limit']} left, under its floor of {floor}; the next pass after "
            f"{until} looks again. The rest of the hour is for publish, land and dispatch paths.")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("tag")
    parser.add_argument("--floor", default=None, help="calls, or a share of the limit (0.3)")
    args = parser.parse_args(argv)
    try:
        if args.floor not in (None, ""):
            float(args.floor)
    except ValueError:
        print(f"job-token-note: {args.tag} --floor {args.floor!r} is not a number; using the default")
        args.floor = None
    return check(args.tag, args.floor, os.environ)


if __name__ == "__main__":
    sys.exit(main())
