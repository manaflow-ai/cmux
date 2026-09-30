#!/usr/bin/env python3
"""Read the independent CI fast-guards check without duplicating its tests."""

from __future__ import annotations

import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Mapping, Sequence

CHECK_NAME = "CI fast guards"
POLL_COUNT = 12
POLL_SECONDS = 15


def completed_state(check_runs: Sequence[Mapping[str, Any]]) -> str | None:
    """Return success/failure once every matching check has settled.

    A queued check has null timestamps. If an older successful check exists for
    the same SHA, it must not hide that pending run; returning None makes the
    caller keep polling and eventually fall back to the duplicate tests.
    """
    matches = [check for check in check_runs if check.get("name") == CHECK_NAME]
    if not matches or any(check.get("status") != "completed" for check in matches):
        return None
    latest = max(
        matches,
        key=lambda check: check.get("completed_at") or check.get("started_at") or "",
    )
    return "success" if latest.get("conclusion") == "success" else "failure"


def check_runs() -> list[Mapping[str, Any]]:
    url = "https://api.github.com/repos/%s/commits/%s/check-runs?per_page=100" % (
        urllib.parse.quote(os.environ["REPOSITORY"], safe="/"), os.environ["HEAD_SHA"]
    )
    request = urllib.request.Request(
        url,
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": "Bearer " + os.environ["GH_TOKEN"],
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    with urllib.request.urlopen(request, timeout=10) as response:
        payload = json.load(response)
    return payload.get("check_runs", [])


def main() -> int:
    skip = "false"
    for attempt in range(POLL_COUNT):
        try:
            state = completed_state(check_runs())
        except (OSError, ValueError, urllib.error.HTTPError):
            state = None
        if state is not None:
            skip = "true" if state == "success" else "false"
            break
        if attempt < POLL_COUNT - 1:
            time.sleep(POLL_SECONDS)
    with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
        output.write("skip=%s\n" % skip)
    print(
        "CI fast guards: %s"
        % ("success; duplicate ci group skipped" if skip == "true" else "unavailable or failed; running ci group")
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
