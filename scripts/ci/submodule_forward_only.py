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
FETCH_TIMEOUT_SECONDS = 15
INIT_TIMEOUT_SECONDS = 60
DEEPEN_CHUNK = 256
MAX_DEEPEN_ROUNDS = 8


def run(*args: str, cwd: str | None = None, timeout: float = FETCH_TIMEOUT_SECONDS) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(
            args, cwd=cwd, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout,
        )
    except subprocess.TimeoutExpired as exc:
        def text(value: str | bytes | None, fallback: str) -> str:
            if isinstance(value, bytes):
                return value.decode(errors="replace")
            return value or fallback

        return subprocess.CompletedProcess(
            args, 124, stdout=text(exc.stdout, ""), stderr=text(exc.stderr, "command timed out"),
        )


def clear_stale_shallow_lock(path: str) -> None:
    """Remove a shallow.lock left by a timed-out fetch when no fetch remains."""
    git_dir = run("git", "-C", path, "rev-parse", "--git-dir", timeout=5)
    if git_dir.returncode:
        return
    lock = Path(git_dir.stdout.strip())
    if not lock.is_absolute():
        lock = Path(path) / lock
    lock /= "shallow.lock"
    if not lock.exists():
        return
    active = run("pgrep", "-af", f"git.*{re.escape(path)}.*fetch", timeout=2)
    if active.returncode == 0:
        return
    try:
        lock.unlink()
        print(f"submodule-forward-only: removed stale {lock}", file=sys.stderr)
    except FileNotFoundError:
        pass


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


def initialize_changed_submodule(path: str) -> bool:
    """Materialize one changed gitlink for the local ancestry check.

    CI intentionally checks out the parent repository without submodules. A
    changed gitlink is the only case that needs a local repository, and a
    shallow recursive update keeps this fallback bounded. The caller treats
    an update failure as a guard failure instead of silently falling back to a
    less authoritative result.
    """
    result = run(
        "git", "submodule", "update", "--init", "--depth", "1", "--recursive", "--", path,
        timeout=INIT_TIMEOUT_SECONDS,
    )
    if result.returncode == 0:
        return True
    detail = result.stderr.strip() or result.stdout.strip() or "git submodule update failed"
    print(f"FAIL {path}: could not initialize changed submodule: {detail}", file=sys.stderr)
    return False


def merge_base(base: str, head: str) -> str:
    result = run("git", "merge-base", base, head)
    if result.returncode or not result.stdout.strip():
        raise RuntimeError(
            f"cannot compute merge base of {base} and {head}: "
            f"{result.stderr.strip() or 'git merge-base returned no result'}"
        )
    return result.stdout.strip()


def local_relation(path: str, base: str, new: str, *, fetch_remote: bool = True) -> str | None:
    if fetch_remote:
        fetch = run("git", "-C", path, "fetch", "origin", base, new)
        # Fetch failure is expected in partial or shallow clones. Try the checks
        # anyway because the objects may already be present locally.
    forward = run("git", "-C", path, "merge-base", "--is-ancestor", base, new)
    backward = run("git", "-C", path, "merge-base", "--is-ancestor", new, base)
    if forward.returncode == 0:
        return "forward"
    if backward.returncode == 0:
        return "backward"
    # A shallow clone lacks the shared history, so two present commits look
    # unrelated. Let the GitHub compare decide instead of reporting divergence.
    shallow = run("git", "-C", path, "rev-parse", "--is-shallow-repository")
    if shallow.stdout.strip() == "true":
        return None
    base_exists = run("git", "-C", path, "cat-file", "-e", f"{base}^{{commit}}")
    new_exists = run("git", "-C", path, "cat-file", "-e", f"{new}^{{commit}}")
    if base_exists.returncode == 0 and new_exists.returncode == 0:
        # A shallow clone cuts the history between the two commits, so a
        # failed ancestry check there proves nothing; let GitHub decide.
        shallow = run("git", "-C", path, "rev-parse", "--is-shallow-repository")
        if shallow.stdout.strip() == "true":
            return None
        return "diverged"
    return None


def deepened_relation(path: str, base: str, new: str) -> str | None:
    """Fetches the history a shallow clone lacks, then decides locally.

    The last resort after the GitHub compare, which fails whenever the
    repository's shared Actions token is out of API quota. Without it, a
    forward bump whose old pin sits deeper than the clone reads as
    undecidable. Ancestry needs only commits, so blobs are skipped.
    """
    shallow = run("git", "-C", path, "rev-parse", "--is-shallow-repository")
    if shallow.returncode != 0 or shallow.stdout.strip() != "true":
        return None
    for round_number in range(1, MAX_DEEPEN_ROUNDS + 1):
        clear_stale_shallow_lock(path)
        fetched = run(
            "git", "-C", path, "fetch", "--quiet", "--filter=blob:none",
            f"--deepen={DEEPEN_CHUNK}", "origin", base, new,
        )
        if fetched.returncode:
            detail = fetched.stderr.strip() or "git fetch failed"
            print(
                f"submodule-forward-only: bounded history fetch failed for {path} "
                f"(round {round_number}/{MAX_DEEPEN_ROUNDS}): {detail}",
                file=sys.stderr,
            )
            return None
        relation = local_relation(path, base, new, fetch_remote=False)
        if relation:
            return relation
        state = run("git", "-C", path, "rev-parse", "--is-shallow-repository")
        if state.returncode == 0 and state.stdout.strip() != "true":
            return local_relation(path, base, new, fetch_remote=False)
    print(
        f"submodule-forward-only: bounded history fetch reached {MAX_DEEPEN_ROUNDS * DEEPEN_CHUNK} "
        f"commits for {path} without resolving {base} -> {new}",
        file=sys.stderr,
    )
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
        if not initialize_changed_submodule(path):
            failures += 1
            continue
        relation = (
            local_relation(path, base_sha, new_sha)
            or github_relation(url, new_sha, base_sha)
            or deepened_relation(path, base_sha, new_sha)
        )
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
