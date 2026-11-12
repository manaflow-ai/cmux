#!/usr/bin/env python3
"""CMUX_NOW_EPOCH: the one clock override for scripts that judge dates against now.

Whole seconds since 1970-01-01 UTC, digits only, from 0 to 253402300799 (9999-12-31T23:59:59Z, the
last second a datetime holds). Unset means the real clock. Any other value, the empty string
included, stops the script with exit 2 and one line:

    error: CMUX_NOW_EPOCH='abc' is not an epoch: ...

never a ValueError or OverflowError traceback, and never a quiet fall back to the real clock. An
empty value is refused because a workflow `env:` filled from a missing variable sets it empty, and
falling back would turn the 2101 time-bomb row (cmux-next-guards tooling-tests) into a run that
judges nothing.

Callers: scripts/ci/asc_developer_id_app.py and scripts/lint-feature-flags.py load this by path.
scripts/cmux-next/continue-nightly-next.sh keeps the same rule in bash, because main and
feat-cmux-next keep identical copies of it and main has no copy of this file;
tests/test_cmux_now_epoch.py runs both on one table of values so the two cannot drift.

Load it by path (importlib), never `import cmux_now_epoch`: scripts run as `python3 -I` have no
script directory on sys.path. Run directly, it prints the epoch it would use.
"""
from __future__ import annotations

import datetime as dt
import os
import re
import sys
from typing import Mapping

NAME = "CMUX_NOW_EPOCH"
MAX_EPOCH = 253402300799
_DIGITS = re.compile(r"[0-9]{1,12}")


class NotAnEpoch(ValueError):
    pass


def parse(value: str) -> dt.datetime:
    """The UTC time VALUE names, or NotAnEpoch with the line the caller prints."""
    if not _DIGITS.fullmatch(value) or int(value) > MAX_EPOCH:
        raise NotAnEpoch(
            f"{NAME}={value!r} is not an epoch: whole seconds since 1970 UTC, 0 to {MAX_EPOCH} "
            f"(4133980800 is 2101-01-01); unset it for the real clock")
    return dt.datetime.fromtimestamp(int(value), dt.timezone.utc)


def utc_now(environ: Mapping[str, str] | None = None) -> dt.datetime:
    """CMUX_NOW_EPOCH when set, else the real clock; a malformed value exits 2 with one line."""
    value = (os.environ if environ is None else environ).get(NAME)
    if value is None:
        return dt.datetime.now(dt.timezone.utc)
    try:
        return parse(value)
    except NotAnEpoch as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2) from None


if __name__ == "__main__":
    print(int(utc_now().timestamp()))
