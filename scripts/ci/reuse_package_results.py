#!/usr/bin/env python3
"""Drop the selected Swift packages whose test inputs already passed on this branch.

swift-package-tests publishes the input key (package_input_key.py) of every
package that passed as the artifact swift-package-passed-<attempt>. A later
pull request run of the same branch reads the artifacts of its recent runs and
removes from the selection each package whose current key one of them names:
the package's tests would see exactly the inputs they passed with. A run that
failed still vouches for the packages that passed in it, which is what makes a
fix-up push after a red run test only what it can change.

Only runs from this repository's own branches count: a fork's run can rewrite
its workflow and publish anything. Reuse is optional, so any API error, a slow
API or a malformed artifact reuses nothing and every selected package runs.
"""

from __future__ import annotations

import argparse
import io
import json
import subprocess
import sys
import time
import zipfile
from pathlib import Path
from typing import Callable, Iterable
from urllib.parse import urlencode

ARTIFACT_PREFIX = "swift-package-passed-"
RUNS_TO_CHECK = 6
REQUEST_TIMEOUT_SECONDS = 10
LOOKUP_TIMEOUT_SECONDS = 45

Passes = set[tuple[str, str]]


def recorded_passes(repository: str, branch: str, current_run_id: int,
                    runs: Callable[[str], list[dict]],
                    artifacts: Callable[[int], list[dict]],
                    payload: Callable[[int], object]) -> Passes:
    """(package, key) pairs that earlier same-repository runs of `branch` published."""
    found: Passes = set()
    for run in runs(branch):
        if run["id"] == current_run_id or run["head_repository"]["full_name"] != repository:
            continue
        for artifact in artifacts(run["id"]):
            if artifact.get("expired") or not str(artifact.get("name", "")).startswith(ARTIFACT_PREFIX):
                continue
            passed = payload(artifact["id"])
            if isinstance(passed, dict):
                found.update((package, key) for package, key in passed.items()
                             if isinstance(package, str) and isinstance(key, str))
    return found


def split(selected: list[str], keys: dict[str, str], passes: Passes) -> tuple[list[str], list[str]]:
    """(packages still to test, packages reused), each in selection order."""
    reused = [package for package in selected if package in keys and (package, keys[package]) in passes]
    return [package for package in selected if package not in reused], reused


def apply(selected_file: Path, keys_file: Path, lookup: Callable[[], Passes]) -> list[str]:
    """Rewrite `selected_file` without the reused packages and return them."""
    selected = [line for line in selected_file.read_text(encoding="utf-8").splitlines() if line]
    try:
        keys = json.loads(keys_file.read_text(encoding="utf-8"))
        passes = lookup()
    except Exception as error:  # noqa: BLE001 - reuse is optional; run everything
        print(f"Package result lookup failed, testing every selected package: {error}", file=sys.stderr)
        return []
    remaining, reused = split(selected, keys, passes)
    if reused:
        selected_file.write_text("".join(f"{package}\n" for package in remaining), encoding="utf-8")
    return reused


def github(repository: str) -> tuple[Callable[[str], list[dict]], Callable[[int], list[dict]], Callable[[int], object]]:
    deadline = time.monotonic() + LOOKUP_TIMEOUT_SECONDS

    def call(path: str) -> bytes:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("package result lookup deadline reached")
        return subprocess.check_output(["gh", "api", path], timeout=min(REQUEST_TIMEOUT_SECONDS, remaining))

    def runs(branch: str) -> list[dict]:
        query = urlencode({"event": "pull_request", "branch": branch, "per_page": RUNS_TO_CHECK + 1})
        return json.loads(call(f"repos/{repository}/actions/workflows/ci.yml/runs?{query}"))["workflow_runs"]

    def artifacts(run_id: int) -> list[dict]:
        query = urlencode({"per_page": 100})
        return json.loads(call(f"repos/{repository}/actions/runs/{run_id}/artifacts?{query}"))["artifacts"]

    def payload(artifact_id: int) -> object:
        with zipfile.ZipFile(io.BytesIO(call(f"repos/{repository}/actions/artifacts/{artifact_id}/zip"))) as archive:
            return json.loads(archive.read("passed-packages.json"))

    return runs, artifacts, payload


def main(argv: Iterable[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repository", required=True)
    parser.add_argument("--branch", required=True)
    parser.add_argument("--current-run-id", type=int, required=True)
    parser.add_argument("--selected", type=Path, required=True, help="selected packages, one per line; rewritten")
    parser.add_argument("--keys", type=Path, required=True, help="package_input_key.py output")
    parser.add_argument("--reused", type=Path, required=True, help="written with the reused packages")
    args = parser.parse_args(list(argv))

    def lookup() -> Passes:
        return recorded_passes(args.repository, args.branch, args.current_run_id, *github(args.repository))

    reused = apply(args.selected, args.keys, lookup)
    args.reused.write_text("".join(f"{package}\n" for package in reused), encoding="utf-8")
    for package in reused:
        print(f"{package}: these inputs already passed on this branch; not testing again.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
