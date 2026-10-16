#!/usr/bin/env python3
"""Report restore-action evidence without inferring the physical cache store."""

import json
import os
from pathlib import Path
import time


def receipt(environment, now_ns):
    env = environment
    routes = ("github", "warp", "r2")
    selected = [route for route in routes if env.get(f"CACHE_{route.upper()}_OUTCOME") not in (None, "", "skipped")]
    route = selected[0] if len(selected) == 1 else None
    outcome = env.get(f"CACHE_{route.upper()}_OUTCOME") if route else None
    hit = env.get(f"CACHE_{route.upper()}_HIT", "") if route else ""
    matched = env.get(f"CACHE_{route.upper()}_MATCHED", "") if route else ""
    if outcome == "failure":
        result = "error"
    elif outcome == "cancelled":
        result = "cancelled"
    elif outcome != "success":
        result = "unknown"
    elif hit == "true":
        result = "exact"
    elif matched:
        result = "prefix"
    else:
        # Cache actions can return success after warning about backend errors.
        # An empty matched key proves no restore, not that the service was healthy.
        result = "miss_or_unavailable"
    try:
        start = int(env.get("CACHE_STARTED_NS", ""))
        elapsed = round((now_ns - start) / 1_000_000_000, 3) if 0 <= start <= now_ns else None
    except ValueError:
        elapsed = None
    return {
        "schema_version": 1,
        "requested_backend": env.get("CACHE_REQUESTED_BACKEND", ""),
        "action_route": {"github": "github-cache", "warp": "warp-cache", "r2": "r2"}.get(route),
        "key": env.get("CACHE_KEY", ""),
        "matched_key": matched or None,
        "cache_hit_output": hit or None,
        "step_outcome": outcome,
        "result": result,
        "elapsed_seconds": elapsed,
        "run_id": env.get("GITHUB_RUN_ID"),
        "run_attempt": env.get("GITHUB_RUN_ATTEMPT"),
        "job": env.get("GITHUB_JOB"),
        "runner_name": env.get("RUNNER_NAME"),
        "runner_os": env.get("RUNNER_OS"),
        "runner_arch": env.get("RUNNER_ARCH"),
    }


def main():
    record = receipt(os.environ, time.monotonic_ns())
    print("CMUX_CACHE_RESTORE " + json.dumps(record, sort_keys=True))
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        # JSON in an indented block also keeps arbitrary key text from creating
        # summary headings or closing a Markdown fence.
        with Path(summary).open("a") as output:
            output.write("### Cache restore\n\n")
            output.write("\n".join("    " + line for line in json.dumps(record, indent=2, sort_keys=True).splitlines()))
            output.write("\n\nElapsed time includes action lookup, transfer and extraction. The action route does not identify the physical storage provider.\n")


if __name__ == "__main__":
    main()
