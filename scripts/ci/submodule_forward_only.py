#!/usr/bin/env python3
"""Reject submodule gitlinks that move backwards from the merge base."""
from __future__ import annotations

import argparse
import configparser
import os
import re
import subprocess
import sys
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

MARKER_PREFIX = "submodule-forward-only: allow "


def run(*args: str, cwd: str | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(args, cwd=cwd, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def gitlink(ref: str, path: str) -> str | None:
    result = run("git", "rev-parse", f"{ref}:{path}")
    if result.returncode:
        ref_exists = run("git", "rev-parse", f"{ref}^{{commit}}")
        if ref_exists.returncode:
            raise RuntimeError(result.stderr.strip() or f"gitlink {ref}:{path} is unavailable")
        return None
    return result.stdout.strip()


def submodule_paths() -> list[tuple[str, str]]:
    parser = configparser.ConfigParser()
    parser.read(".gitmodules")
    return [(parser[section]["path"], parser[section]["url"])
            for section in parser.sections() if parser.has_option(section, "path")]


def merge_base(base: str, head: str) -> str:
    result = run("git", "merge-base", base, head)
    if result.returncode or not result.stdout.strip():
        raise RuntimeError(
            f"cannot compute merge base of {base} and {head}: "
            f"{result.stderr.strip() or 'git merge-base returned no result'}"
        )
    return result.stdout.strip()


def local_relation(path: str, base: str, new: str) -> str | None:
    fetch = run("git", "-C", path, "fetch", "origin", base, new)
    # Fetch failure is expected in partial or shallow clones. Try the checks
    # anyway because the objects may already be present locally.
    forward = run("git", "-C", path, "merge-base", "--is-ancestor", base, new)
    backward = run("git", "-C", path, "merge-base", "--is-ancestor", new, base)
    if forward.returncode == 0:
        return "forward"
    if backward.returncode == 0:
        return "backward"
    base_exists = run("git", "-C", path, "cat-file", "-e", f"{base}^{{commit}}")
    new_exists = run("git", "-C", path, "cat-file", "-e", f"{new}^{{commit}}")
    if base_exists.returncode == 0 and new_exists.returncode == 0:
        return "diverged"
    return None


def github_relation(url: str, new: str, base: str) -> str | None:
    match = re.search(r"github\.com[:/]([^/]+)/([^/#]+?)(?:\.git)?$", url)
    if not match:
        return None
    owner, repo = match.groups()
    endpoint = f"https://api.github.com/repos/{owner}/{repo}/compare/{new}...{base}"
    request = Request(endpoint, headers={"Accept": "application/vnd.github+json"})
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if token:
        request.add_header("Authorization", f"Bearer {token}")
    try:
        import json
        with urlopen(request, timeout=15) as response:
            data = json.load(response)
    except (HTTPError, URLError, OSError, ValueError):
        return None
    status = data.get("status")
    ahead = data.get("ahead_by")
    behind = data.get("behind_by")
    # The API compares new...base. Thus base ahead means new is backward.
    if status == "identical" or (ahead == 0 and behind == 0):
        return "unchanged"
    if status == "diverged" or (
        isinstance(ahead, int) and ahead > 0 and isinstance(behind, int) and behind > 0
    ):
        return "diverged"
    if status == "behind" or (isinstance(behind, int) and behind > 0):
        return "forward"
    if status == "ahead" or (isinstance(ahead, int) and ahead > 0):
        return "backward"
    return None


def dropped(path: str, new: str, base: str) -> list[str]:
    result = run("git", "-C", path, "log", "--format=%s", f"{new}..{base}")
    return result.stdout.splitlines() if result.returncode == 0 else []


def rollback_declared(base: str, head: str) -> set[str]:
    result = run("git", "log", "--format=%B", f"{base}..{head}")
    if result.returncode:
        return set()
    return {
        line.strip()[len(MARKER_PREFIX):].strip()
        for line in result.stdout.splitlines()
        if line.strip().lower().startswith(MARKER_PREFIX)
        and line.strip()[len(MARKER_PREFIX):].strip()
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", default=os.environ.get("GITHUB_BASE_SHA") or "origin/main")
    parser.add_argument("--head", default=os.environ.get("GITHUB_HEAD_SHA") or "HEAD")
    args = parser.parse_args()
    try:
        modules = submodule_paths()
    except (configparser.Error, KeyError) as exc:
        print(f"submodule-forward-only: cannot read .gitmodules: {exc}", file=sys.stderr)
        return 1
    try:
        comparison = merge_base(args.base, args.head)
    except RuntimeError as exc:
        print(f"submodule-forward-only: {exc}", file=sys.stderr)
        return 1
    declared = rollback_declared(comparison, args.head)
    failures = 0
    for path, url in modules:
        try:
            base_sha = gitlink(comparison, path)
            new_sha = gitlink(args.head, path)
        except RuntimeError as exc:
            print(f"submodule-forward-only: {path}: cannot read gitlink: {exc}", file=sys.stderr)
            failures += 1
            continue
        if base_sha is None and new_sha is not None:
            print(f"PASS {path}: submodule added at {new_sha}")
            continue
        if new_sha is None:
            print(f"FAIL {path}: gitlink is absent at {args.head} but present at merge base {base_sha}", file=sys.stderr)
            failures += 1
            continue
        if base_sha == new_sha:
            print(f"PASS {path}: unchanged at {new_sha}")
            continue
        relation = local_relation(path, base_sha, new_sha) or github_relation(url, new_sha, base_sha)
        if relation == "forward":
            print(f"PASS {path}: {base_sha} -> {new_sha} (forward)")
            continue
        if relation == "unchanged":
            print(f"PASS {path}: unchanged at {new_sha}")
            continue
        if relation in {"backward", "diverged"} and path in declared:
            print(f"PASS {path}: {base_sha} -> {new_sha} ({relation}; {MARKER_PREFIX}{path} declared)")
            continue
        if relation is None:
            print(f"FAIL {path}: could not determine ancestry for {base_sha} -> {new_sha}; local git and GitHub compare both failed. Add '{MARKER_PREFIX}{path}' to a branch commit only for a deliberate rollback.", file=sys.stderr)
            failures += 1
            continue
        subjects = dropped(path, new_sha, base_sha)
        count = len(subjects)
        detail = "; ".join(subjects[:8]) if subjects else "subjects unavailable"
        if count > 8:
            detail += f"; ... ({count - 8} more)"
        print(f"FAIL {path}: {base_sha} -> {new_sha} ({relation}); drops {count} commit(s): {detail}. Usual cause: branch cut before a submodule bump followed by a squash merge. Remedy: merge main into the branch. For a deliberate rollback, add a commit containing '{MARKER_PREFIX}{path}'.", file=sys.stderr)
        failures += 1
    if failures:
        return 1
    print("submodule-forward-only: all submodule gitlinks are unchanged or forward")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
