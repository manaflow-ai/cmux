#!/usr/bin/env python3
"""Decide whether this main push must build a DerivedData seed.

    seed_decide.py --repository OWNER/REPO --xcode XCODE_APP [--github-output PATH]

A push may skip the Mac only when a seed with its exact build inputs already
exists, because pull requests then adopt that seed by prefix. Comparing with
the parent commit alone assumed the parent had a seed. It often had none:
seed-derived-data.yml never cancels a running seed, so a newer push replaces
the pending run, and the replaced commit is never built. The next push that
changed nothing but docs then skipped too, and main's newest seed stayed on an
older build for as long as such pushes kept arriving. On 2026-09-24, 8 of 22
skips left main 2 to 6 commits past its newest seed with different inputs,
including 80 minutes after #14241 merged.

So walk main's first-parent history to the nearest commit whose seeder run
saved a seed (or is saving one now), and skip only if that commit's build
inputs equal this one's. Anything unknown (API errors, no seeded ancestor
within the window, a commit outside the shallow checkout) builds.
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path
from typing import Callable, Iterable

WORKFLOW = "seed-derived-data.yml"
SEED_JOB = "seed"
SAVE_STEP = "Save seed"
# The decide job checks out this many commits of history, plus HEAD.
ANCESTOR_LIMIT = 30
FINGERPRINT = Path(__file__).resolve().parent / "build_input_fingerprint.py"

Api = Callable[[str], dict]


def gh_api(path: str) -> dict:
    return json.loads(subprocess.check_output(["gh", "api", path], text=True, timeout=20))


def lineage(limit: int = ANCESTOR_LIMIT) -> list[str]:
    """HEAD's first-parent ancestors, nearest first, excluding HEAD."""
    out = subprocess.check_output(
        ["git", "rev-list", "--first-parent", f"--max-count={limit + 1}", "HEAD"], text=True
    )
    return out.split()[1:]


def fingerprint(revision: str, xcode: str) -> str:
    return subprocess.check_output(
        [sys.executable, str(FINGERPRINT), "--revision", revision, "--extra", f"xcode={xcode}"], text=True
    ).strip()


def seed_state(api: Api, repository: str, run: dict) -> str:
    """'seeded', 'seeding', 'skipped' or 'none' for one seeder run."""
    status, conclusion = run.get("status"), run.get("conclusion")
    if status == "completed" and conclusion != "success":
        return "none"
    if status not in ("completed", "in_progress"):
        # Queued or pending: a newer push can still replace it.
        return "none"
    jobs = api(f"repos/{repository}/actions/runs/{run['id']}/jobs?per_page=100").get("jobs", [])
    job = next((j for j in jobs if j.get("name") == SEED_JOB), None)
    if job is None:
        return "none"
    if job.get("conclusion") == "skipped":
        return "skipped"
    if job.get("status") == "in_progress":
        # Never cancelled in progress, so it will publish unless it fails.
        return "seeding"
    if job.get("conclusion") != "success":
        return "none"
    save = next((s for s in job.get("steps", []) if s.get("name") == SAVE_STEP), None)
    return "seeded" if save is not None and save.get("conclusion") == "success" else "none"


def nearest_seed(api: Api, repository: str, ancestors: Iterable[str]) -> str | None:
    """The nearest ancestor with a published (or publishing) seed, or None."""
    runs = api(f"repos/{repository}/actions/workflows/{WORKFLOW}/runs?branch=main&per_page=100").get(
        "workflow_runs", []
    )
    by_sha: dict[str, list[dict]] = {}
    for run in runs:
        by_sha.setdefault(run.get("head_sha", ""), []).append(run)
    for sha in ancestors:
        states = {seed_state(api, repository, run) for run in by_sha.get(sha, [])}
        if states & {"seeded", "seeding"}:
            return sha
        # "skipped" means that commit matched its own nearest seed; the walk
        # continues to that seed and compares against it directly.
    return None


def decide(
    event_name: str,
    repository: str,
    xcode: str,
    api: Api = gh_api,
    ancestors: Callable[[], list[str]] = lineage,
    fingerprint_of: Callable[[str, str], str] = fingerprint,
) -> tuple[bool, str]:
    if event_name == "workflow_dispatch":
        return True, "Dispatched; building."
    try:
        seed = nearest_seed(api, repository, ancestors())
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, OSError,
            json.JSONDecodeError, KeyError, TypeError, AttributeError) as error:
        return True, f"Could not find the nearest seed ({error}); building."
    if seed is None:
        return True, f"No seeded ancestor within {ANCESTOR_LIMIT} commits; building."
    try:
        same = fingerprint_of("HEAD", xcode) == fingerprint_of(seed, xcode)
    except (subprocess.CalledProcessError, OSError) as error:
        return True, f"Could not fingerprint against {seed} ({error}); building."
    if same:
        return False, f"Build inputs equal those of {seed}, which has a seed; skipping."
    return True, f"Build inputs differ from {seed}, the nearest seed; building."


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repository", required=True)
    parser.add_argument("--xcode", required=True)
    parser.add_argument("--event-name", default="push")
    parser.add_argument("--github-output")
    args = parser.parse_args(argv)
    build, reason = decide(args.event_name, args.repository, args.xcode)
    print(reason)
    if args.github_output:
        with open(args.github_output, "a", encoding="utf-8") as handle:
            handle.write(f"build={'true' if build else 'false'}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
