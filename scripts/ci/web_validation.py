#!/usr/bin/env python3
"""Route web validation and enforce its one required GitHub check."""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

from detect_ci_change_areas import classify_files


def requires_web(paths: list[str]) -> bool:
    # Both required workflows must agree: CI owns tests for PRs/merge groups,
    # while this workflow owns the production build and standalone validation.
    return classify_files(paths).web


def merge_parent(head: str) -> str:
    """Return the base a pull request's synthetic merge commit was built on.

    The event's base SHA is where the pull request last synced. Once main
    moves on it is outside the depth-2 checkout, and a diff from it would also
    count what main gained since.
    """
    def resolve(revision: str) -> str:
        result = subprocess.run(
            ["git", "rev-parse", "-q", "--verify", revision], text=True, capture_output=True
        )
        return result.stdout.strip() if result.returncode == 0 else ""

    # Only a merge commit has a second parent.
    return resolve(f"{head}^1") if resolve(f"{head}^2") else ""


def required_for_event(event: str, base: str, head: str) -> bool:
    if event not in {"pull_request", "push"} or not base or not head:
        return True
    if event == "pull_request":
        base = merge_parent(head) or base
    try:
        paths = subprocess.check_output(
            ["git", "diff", "--no-renames", "--name-only", "-z", base, head, "--"], text=True,
            stderr=subprocess.PIPE,
        ).split("\0")
        paths = [path for path in paths if path]
    except subprocess.CalledProcessError:
        print("Diff unavailable; running web validation.", file=sys.stderr)
        return True
    return not paths or requires_web(paths)


def failures(needs: dict, event: str = "") -> dict[str, str]:
    changes = needs.get("changes", {})
    required = changes.get("outputs", {}).get("required")
    if changes.get("result") != "success" or required not in {"true", "false"}:
        return {"changes": "routing failed or produced no valid decision"}
    allowed = {"success"} if required == "true" else {"success", "skipped"}
    return {
        job: needs.get(job, {}).get("result", "missing")
        for job in sorted((set(needs) - {"changes"}) | {"build", "tests", "database"})
        if needs.get(job, {}).get("result") not in (
            allowed | {"skipped"}
            if event in {"pull_request", "merge_group"} and job in {"build", "tests", "database"}
            else allowed
        )
    }


def main() -> int:
    if sys.argv[1:] == ["route"]:
        required = required_for_event(
            os.environ.get("EVENT_NAME", ""),
            os.environ.get("BASE_SHA", ""),
            os.environ.get("HEAD_SHA", ""),
        )
        value = f"required={str(required).lower()}"
        with Path(os.environ["GITHUB_OUTPUT"]).open("a") as output:
            output.write(value + "\n")
        print(value)
        return 0
    if sys.argv[1:] == ["check"]:
        bad = failures(json.loads(os.environ["WEB_VALIDATION_NEEDS"]), os.environ.get("GITHUB_EVENT_NAME", ""))
        for name, result in bad.items():
            print(f"{name}: {result}", file=sys.stderr)
        return int(bool(bad))
    raise SystemExit("usage: web_validation.py route|check")


if __name__ == "__main__":
    raise SystemExit(main())
