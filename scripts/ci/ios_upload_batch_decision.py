#!/usr/bin/env python3
"""Batch scheduled iOS TestFlight uploads by commit count and age.

Both iOS upload workflows poll main (CMUX INTERNAL every 20 minutes, official
cmux.app hourly). Their decide jobs already skip an unchanged main, a delta
with no iOS-relevant path, and (INTERNAL) inputs that already failed to
upload. On a busy day nearly every poll still finds something, so each poll
spent a cold Release archive on the macOS pool that PR CI shares.

This script adds one batching condition on top of those rules, and runs only
when they already chose to upload. A scheduled poll uploads when there is at
least one relevant commit since the last successful upload AND either

- at least N relevant commits are waiting (min commits), or
- the oldest waiting relevant commit is at least T minutes old (max age).

A manual dispatch always uploads. "Commits" are main's first-parent commits
(one per merged pull request), each diffed against its first parent; the time
is the committer date, which is when the pull request landed on main.

"Relevant" reuses the workflow's own filter: --paths-from-workflow reads the
`const iosRelevantPaths = [...]` array out of the workflow's decide script, so
there is a single list. The official lane uses --public-path-filter to skip only known unrelated
paths, matching its conservative decide gate. Without either filter all commits count.

History comes from the checkout (ios/scripts/fetch-testflight-notes-history.sh
deepens it to the base), not the REST API. Anything that cannot be read fails
open to an upload, like the decide jobs' own compare step.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Optional, Sequence

PATH_ARRAY_NAME = "iosRelevantPaths"


@dataclass(frozen=True)
class Thresholds:
    min_commits: int
    max_age_minutes: int


@dataclass(frozen=True)
class Decision:
    upload: bool
    reason: str


def resolve_thresholds(
    min_commits: Optional[str],
    max_age_minutes: Optional[str],
    default_min_commits: int,
    default_max_age_minutes: int,
    warn=lambda message: None,
) -> Thresholds:
    """Repo variables arrive as strings; unset or empty means the default.

    A value that is not a whole number in range also falls back to the
    default (with a warning), so a typo in a repo variable cannot stop uploads.
    """

    def parse(raw: Optional[str], default: int, minimum: int, name: str) -> int:
        text = (raw or "").strip()
        if not text:
            return default
        if re.fullmatch(r"[0-9]+", text) and int(text) >= minimum:
            return int(text)
        warn(f"ignoring {name}={text!r}: expected a whole number >= {minimum}; using {default}")
        return default

    return Thresholds(
        min_commits=parse(min_commits, default_min_commits, 0, "min commits"),
        max_age_minutes=parse(max_age_minutes, default_max_age_minutes, 0, "max age minutes"),
    )


def decide(
    event_name: str,
    commit_times: Sequence[int],
    now: int,
    thresholds: Thresholds,
    label: str = "iOS commits",
) -> Decision:
    """Apply the batching rule to the relevant commits' unix times."""
    if event_name == "workflow_dispatch":
        return Decision(True, "upload: manual dispatch")
    count = len(commit_times)
    n, t = thresholds.min_commits, thresholds.max_age_minutes
    if count == 0:
        return Decision(False, f"skipped: 0/{n} {label} since the last upload")
    if n == 0 and t == 0:
        return Decision(True, f"upload: batching disabled ({count} {label} pending)")
    age = max(0, (now - min(commit_times)) // 60)
    detail = f"{count}/{n} {label}, oldest {age}/{t} min"
    if n > 0 and count >= n:
        return Decision(True, f"upload: {detail} (count reached)")
    if t > 0 and age >= t:
        return Decision(True, f"upload: {detail} (age reached)")
    return Decision(False, f"skipped: {detail}")


def workflow_path_filter(workflow_text: str, name: str = PATH_ARRAY_NAME) -> tuple[str, ...]:
    """Read a `const <name> = ['a', 'b'];` string array from a workflow."""
    match = re.search(rf"const {re.escape(name)} = \[(.*?)\];", workflow_text, re.S)
    if match is None:
        raise ValueError(f"missing {name} array")
    paths = tuple(re.findall(r"'([^'\n]+)'", match.group(1)))
    if not paths:
        raise ValueError(f"empty {name} array")
    return paths


def touches(filename: str, paths: Iterable[str]) -> bool:
    """Same rule as the decide script: a trailing / is a prefix, else exact."""
    return any(
        filename.startswith(path) if path.endswith("/") else filename == path
        for path in paths
    )


def first_parent_commits(base: str, head: str = "HEAD", cwd: Optional[Path] = None):
    """Yield (sha, committer unix time, changed files) for base..head on main."""
    if subprocess.run(
        ["git", "merge-base", "--is-ancestor", base, head],
        cwd=cwd,
        capture_output=True,
    ).returncode != 0:
        raise LookupError(f"{base[:12]} is not an ancestor of {head} in this checkout")
    base_sha, head_sha = subprocess.run(
        ["git", "rev-parse", f"{base}^{{commit}}", f"{head}^{{commit}}"],
        cwd=cwd, capture_output=True, text=True, check=True,
    ).stdout.splitlines()
    boundaries = subprocess.run(
        ["git", "rev-list", "--first-parent", "--boundary", f"{base_sha}..{head_sha}"],
        cwd=cwd, capture_output=True, text=True, check=True,
    ).stdout.splitlines()
    if base_sha != head_sha and f"-{base_sha}" not in boundaries:
        raise LookupError("first-parent history does not reach the last upload")
    output = subprocess.run(
        [
            "git", "log", "-z",
            "--first-parent", "--diff-merges=first-parent",
            "--name-only", "--no-renames", "--format=%x00%H%x00%ct",
            f"{base}..{head}",
        ],
        cwd=cwd,
        capture_output=True,
        text=True,
        errors="surrogateescape",
        check=True,
    ).stdout
    commits = []
    # The header's leading NUL follows the previous record's terminating NUL.
    # Pathnames cannot contain NUL, including names with newlines or tabs.
    for record in output.removeprefix("\x00").split("\x00\x00"):
        if not record:
            continue
        sha, _, rest = record.partition("\x00")
        committed, _, files = rest.partition("\x00")
        # Git inserts exactly one newline before the first changed path.
        names = tuple(name for name in files.removeprefix("\n").split("\x00") if name)
        commits.append((sha, int(committed), names))
    return commits


def public_path_relevant(path: str) -> bool:
    """Mirror the public compare gate; parity is exercised against its code."""
    if not isinstance(path, str) or not path:
        return True
    if path.startswith(("web/", "docs/", "tests/", "cmuxTests/")):
        return False
    if path.startswith(".github/workflows/"):
        return path in {
            ".github/workflows/ios-appstore-upload.yml",
            ".github/workflows/ios-testflight.yml",
        }
    return True


def relevant_commit_times(commits, paths: Optional[Sequence[str]], public: bool = False) -> list[int]:
    return [
        committed
        for _sha, committed, files in commits
        if (any(public_path_relevant(name) for name in files) if public
            else paths is None or any(touches(name, paths) for name in files))
    ]


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--event", required=True)
    parser.add_argument("--base", default="", help="last successfully uploaded main SHA")
    parser.add_argument("--head", default="HEAD")
    filters = parser.add_mutually_exclusive_group()
    filters.add_argument("--paths-from-workflow", type=Path)
    filters.add_argument("--public-path-filter", action="store_true")
    parser.add_argument("--min-commits", default="")
    parser.add_argument("--max-age-minutes", default="")
    parser.add_argument("--default-min-commits", type=int, required=True)
    parser.add_argument("--default-max-age-minutes", type=int, required=True)
    parser.add_argument("--output-name", required=True, help="step output to write true/false to")
    parser.add_argument("--github-output", type=Path)
    parser.add_argument("--summary", type=Path)
    parser.add_argument("--now", type=int, help="unix time override for tests")
    args = parser.parse_args(argv)

    def warn(message: str) -> None:
        print(f"::warning::{message}")

    thresholds = resolve_thresholds(
        args.min_commits,
        args.max_age_minutes,
        args.default_min_commits,
        args.default_max_age_minutes,
        warn,
    )
    now = args.now if args.now is not None else int(time.time())
    paths = None
    label = "commits"
    try:
        if args.paths_from_workflow is not None:
            paths = workflow_path_filter(args.paths_from_workflow.read_text(encoding="utf-8"))
            label = "iOS commits"
        if args.public_path_filter:
            label = "iOS commits"
        if args.event == "workflow_dispatch":
            decision = decide(args.event, [], now, thresholds, label)
        elif not args.base:
            decision = Decision(True, "upload: no prior upload to batch against")
        else:
            commits = first_parent_commits(args.base, args.head)
            decision = decide(args.event, relevant_commit_times(commits, paths, args.public_path_filter), now, thresholds, label)
    except (OSError, ValueError, LookupError, subprocess.CalledProcessError) as error:
        warn(f"could not batch this upload ({error}); uploading")
        decision = Decision(True, "upload: batching history unavailable (fail open)")

    value = "true" if decision.upload else "false"
    print(decision.reason)
    if args.github_output:
        with args.github_output.open("a", encoding="utf-8") as handle:
            handle.write(f"{args.output_name}={value}\n")
    if args.summary:
        conditions = []
        if thresholds.min_commits:
            conditions.append(f"at {thresholds.min_commits} {label}")
        if thresholds.max_age_minutes:
            conditions.append(f"when the oldest is {thresholds.max_age_minutes} min old")
        rule = "upload " + " or ".join(conditions) if conditions else "batching disabled"
        with args.summary.open("a", encoding="utf-8") as handle:
            handle.write(
                "\n### Upload batching\n\n"
                f"- Decision: {decision.reason}\n"
                f"- Rule: {rule}\n"
            )
    return 0


if __name__ == "__main__":
    sys.exit(main())
