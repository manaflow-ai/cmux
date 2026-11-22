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


class PermanentAPIError(Exception):
    """The token or REST budget cannot recover during this job."""


def completed_state(check_runs: Sequence[Mapping[str, Any]]) -> str | None:
    """Return success/failure once every matching check has settled.

    A queued check has null timestamps. If an older successful check exists for
    the same SHA, it must not hide that pending run; returning None makes the
    caller keep polling and eventually fall back to the duplicate tests.
    """
    matches = [check for check in check_runs if check.get("name") == CHECK_NAME]
    if not matches or any(check.get("status") != "completed" for check in matches):
        return None
    def newest_key(check: Mapping[str, Any]) -> tuple[int, Any]:
        raw_id = check.get("id")
        if raw_id not in (None, ""):
            try:
                return (1, int(raw_id))
            except (TypeError, ValueError):
                pass
        return (0, check.get("completed_at") or check.get("started_at") or "")

    # Check-run IDs are creation ordered; completion order is not. This keeps
    # an older run that finished late from overriding the newest verdict.
    latest = max(matches, key=newest_key)
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
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            payload = json.load(response)
    except urllib.error.HTTPError as error:
        if error.code in (401, 403, 429):
            raise PermanentAPIError("GitHub API authorization or rate limit") from error
        raise
    return payload.get("check_runs", [])


def main() -> int:
    skip = "false"
    verdict = "unavailable"
    for attempt in range(POLL_COUNT):
        try:
            state = completed_state(check_runs())
        except PermanentAPIError as error:
            print(f"CI fast guards lookup unavailable: {error}")
            break
        except (OSError, ValueError, urllib.error.HTTPError):
            state = None
        if state is not None:
            # The independent workflow is authoritative once it has settled.
            # A failed check must be propagated by the caller rather than
            # rerunning the same guard suite on a second runner. Keep the
            # duplicate suite as a fallback only while the check is missing or
            # still pending.
            skip = "true"
            verdict = state
            break
        if attempt < POLL_COUNT - 1:
            time.sleep(POLL_SECONDS)
    with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
        output.write("skip=%s\n" % skip)
        output.write("state=%s\n" % verdict)
    print(
        "CI fast guards: %s"
        % (
            "success; duplicate ci group skipped"
            if verdict == "success"
            else "failure; duplicate ci group skipped"
            if verdict == "failure"
            else "unavailable; running ci group"
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
